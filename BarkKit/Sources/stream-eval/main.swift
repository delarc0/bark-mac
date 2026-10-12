import Darwin
import FluidAudio
import Foundation
import WhisperKit

// Spike S1: streaming mechanisms under a real-time feed. Each clip is fed in
// 100 ms blocks at wall-clock pace while the mechanism runs; "release" is the
// moment the last block lands. Writes the bark-eval JSONL fields plus
// release_to_final, decoder busy time, process CPU time and the decoded parts.
//   oneshot: decode everything at release (today's app).
//   confirm: AudioStreamTranscriber's loop (re-decode from the last confirmed
//            segment end each time 1 s of audio arrives, confirm all but the
//            last 2 timestamped segments), then decode the unconfirmed tail at
//            release prompted with the confirmed text.
//   silero:  decode each segment as Silero v6 closes it (threshold 0.5),
//            prompted with everything decoded so far; at release decode the
//            open segment, if there is one.
// --prompt 0 drops the conditioning on earlier text. WhisperKit 1.1.0 feeds
// prompt tokens through the decoder one forward pass each (~35 ms per token
// on KB), so a long prompt costs more than the audio it conditions.

let usage = """
    usage: stream-eval --mechanism oneshot|confirm|silero [--pause <s>] --model general|swedish
                       --language <code> --clips <dir> --out <file.jsonl> [--suppress-short 1] [--prompt 0]
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[stream-eval] \(message)\n".utf8))
}

var argv = CommandLine.arguments.dropFirst()
var args: [String: String] = [:]
while let flag = argv.popFirst() {
    guard flag.hasPrefix("--"), let value = argv.popFirst() else { fail(usage) }
    args[String(flag.dropFirst(2))] = value
}
guard let mechanism = args["mechanism"], ["oneshot", "confirm", "silero"].contains(mechanism),
      let model = args["model"], let language = args["language"],
      let clipsDir = args["clips"], let outPath = args["out"] else { fail(usage) }
let pause = Double(args["pause"] ?? "0.5") ?? 0.5
let suppressShort = args["suppress-short"] == "1"
let usePrompt = args["prompt"] != "0"

let models = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/huggingface/models")
let modelFolder = switch model {
case "general": models.appendingPathComponent("argmaxinc/whisperkit-coreml/openai_whisper-large-v3")
case "swedish": models.appendingPathComponent("lab37/kb-whisper-coreml/kb_whisper-large")
default: fail(usage)
}

let rate = 16_000
let block = 1_600
let clock = ContinuousClock()
func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

let kit = try await WhisperKit(WhisperKitConfig(
    model: "openai_whisper-large-v3",
    modelFolder: modelFolder.path,
    computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndNeuralEngine),
    verbose: false,
    logLevel: .error,
    download: false))
guard let tokenizer = kit.tokenizer else { fail("no tokenizer") }
let noSpeechFilter = SuppressTokensFilter(suppressTokens: [tokenizer.specialTokens.noSpeechToken])

// Shipping options (Transcriber.makeDecodingOptions plus the 74446f7 fix).
var shipping = DecodingOptions()
shipping.task = .transcribe
shipping.usePrefillPrompt = true
shipping.skipSpecialTokens = true
shipping.withoutTimestamps = true
shipping.windowClipTime = 0
shipping.firstTokenLogProbThreshold = nil
shipping.language = language

let vad = mechanism == "silero" ? try await VadManager(config: VadConfig(defaultThreshold: 0.5)) : nil
let vadSegmentation = VadSegmentationConfig(minSilenceDuration: pause)

/// One decode. Sub-1 s audio optionally gets KB's no-speech token suppressed
/// (the S1b fix); everything else runs exactly as shipped.
var busy = 0.0
@MainActor func decode(_ audio: ArraySlice<Float>, options: DecodingOptions, prompt: String = "") async throws -> [TranscriptionResult] {
    var options = options
    if usePrompt, !prompt.isEmpty {
        options.promptTokens = tokenizer.encode(text: " " + prompt)
    }
    kit.textDecoder.logitsFilters = suppressShort && audio.count < rate ? [noSpeechFilter] : []
    let start = clock.now
    defer { busy += seconds(clock.now - start) }
    return try await kit.transcribe(audioArray: Array(audio), decodeOptions: options)
}

func text(_ results: [TranscriptionResult]) -> String {
    results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

func joined(_ parts: [String]) -> String {
    parts.filter { !$0.isEmpty }.joined(separator: " ")
}

@MainActor final class Feed {
    var samples: [Float] = []
    var released: ContinuousClock.Instant?
}

func feed(_ audio: [Float], into feed: Feed, realTime: Bool) async {
    let start = clock.now
    var offset = 0
    var index = 0
    while offset < audio.count {
        index += 1
        if realTime {
            try? await Task.sleep(until: start + .milliseconds(100 * index), clock: .continuous)
        }
        let end = min(offset + block, audio.count)
        await MainActor.run { feed.samples.append(contentsOf: audio[offset..<end]) }
        offset = end
    }
    let now = clock.now
    await MainActor.run { feed.released = now }
}

func idle() async {
    try? await Task.sleep(for: .milliseconds(10))
}

@MainActor func oneshot(_ feed: Feed) async throws -> [String] {
    while feed.released == nil { await idle() }
    return [text(try await decode(feed.samples[...], options: shipping))]
}

@MainActor func confirm(_ feed: Feed) async throws -> [String] {
    var confirmed: [String] = []
    var confirmedEnd: Float = 0
    var lastSize = 0
    var timestamped = shipping
    timestamped.withoutTimestamps = false
    while feed.released == nil {
        guard feed.samples.count - lastSize > rate else {
            await idle()
            continue
        }
        lastSize = feed.samples.count
        timestamped.clipTimestamps = [confirmedEnd]
        let segments = try await decode(feed.samples[...], options: timestamped).flatMap(\.segments)
        if segments.count > 2 {
            let ready = segments.prefix(segments.count - 2)
            if let last = ready.last, last.end > confirmedEnd {
                confirmedEnd = last.end
                confirmed += ready.map { $0.text.trimmingCharacters(in: .whitespaces) }
            }
        }
    }
    var tail = shipping
    tail.clipTimestamps = [confirmedEnd]
    return confirmed + [text(try await decode(feed.samples[...], options: tail, prompt: joined(confirmed)))]
}

@MainActor func silero(_ feed: Feed, vad: VadManager) async throws -> [String] {
    var parts: [String] = []
    var state = await vad.makeStreamState()
    var processed = 0
    var openStart: Int?
    var closed: [Range<Int>] = []
    func step(_ chunk: [Float]) async throws {
        let result = try await vad.processStreamingChunk(chunk, state: state, config: vadSegmentation)
        state = result.state
        processed += VadManager.chunkSize
        guard let event = result.event else { return }
        if event.isStart {
            openStart = event.sampleIndex
        } else if let start = openStart {
            closed.append(start..<max(start, min(event.sampleIndex, feed.samples.count)))
            openStart = nil
        }
    }
    while true {
        if feed.samples.count - processed >= VadManager.chunkSize {
            try await step(Array(feed.samples[processed..<(processed + VadManager.chunkSize)]))
        } else if !closed.isEmpty {
            let segment = closed.removeFirst()
            parts.append(text(try await decode(feed.samples[segment], options: shipping, prompt: joined(parts))))
        } else if feed.released != nil {
            break
        } else {
            await idle()
        }
    }
    if processed < feed.samples.count {
        try await step(Array(feed.samples[processed...]))
    }
    for segment in closed {
        parts.append(text(try await decode(feed.samples[segment], options: shipping, prompt: joined(parts))))
    }
    if let start = openStart {
        parts.append(text(try await decode(feed.samples[start...], options: shipping, prompt: joined(parts))))
    }
    return parts
}

struct Row: Encodable {
    let id: String
    let hypothesis: String
    let parts: [String]
    let decode_seconds: Double
    let release_to_final: Double
    let decoder_busy: Double
    let cpu_seconds: Double
    let audio_seconds: Double
}

let clips = try FileManager.default.contentsOfDirectory(atPath: clipsDir)
    .filter { $0.hasSuffix(".wav") }
    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
guard !clips.isEmpty else { fail("no .wav files in \(clipsDir)") }

_ = try await decode(ArraySlice(repeating: 0, count: 48_000), options: shipping)
if let vad { _ = try await vad.process([Float](repeating: 0, count: 48_000)) }

FileManager.default.createFile(atPath: outPath, contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

for (index, clip) in clips.enumerated() {
    let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: (clipsDir as NSString).appendingPathComponent(clip))
    let session = Feed()
    busy = 0
    let cpuStart = cpuSeconds()
    // Nothing runs before release in oneshot, so it needs no wall-clock feed.
    let feeding = Task { await feed(audio, into: session, realTime: mechanism != "oneshot") }
    let parts: [String] = switch mechanism {
    case "oneshot": try await oneshot(session)
    case "confirm": try await confirm(session)
    default: try await silero(session, vad: vad!)
    }
    let done = clock.now
    await feeding.value
    guard let released = session.released else { fail("feed never released") }
    let row = Row(id: String(clip.dropLast(4)), hypothesis: joined(parts), parts: parts,
                  decode_seconds: seconds(done - released), release_to_final: seconds(done - released),
                  decoder_busy: busy, cpu_seconds: cpuSeconds() - cpuStart,
                  audio_seconds: Double(audio.count) / Double(rate))
    try out.write(contentsOf: encoder.encode(row) + Data("\n".utf8))
    log("\(index + 1)/\(clips.count) \(row.id) release->final \(String(format: "%.2f", row.release_to_final))s, \(parts.count) parts")
}
try out.close()
