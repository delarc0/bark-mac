import CoreML
import Foundation
import WhisperKit

// Transcribes every .wav in a directory on the shipping engine config and
// writes one JSON line per clip. Deliberately skips Bark's silence trimming:
// this measures the raw engine.

let usage = "usage: bark-eval --model general|turbo|swedish --language <code> --clips <dir> --out <file.jsonl> [--suppress-nospeech 1] [--encoder gpu|ane|all] [--decoder gpu|ane|all]"

var args: [String: String] = [:]
var argv = CommandLine.arguments.dropFirst()
while let flag = argv.popFirst() {
    guard flag.hasPrefix("--"), let value = argv.popFirst() else {
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(2)
    }
    args[String(flag.dropFirst(2))] = value
}
guard let model = args["model"], let language = args["language"],
      let clipsDir = args["clips"], let outPath = args["out"] else {
    FileHandle.standardError.write(Data("\(usage)\n".utf8))
    exit(2)
}

// Mirrors Transcriber.ModelRole in the shipping app.
let models = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/huggingface/models")
let modelFolder: URL
switch model {
case "general": modelFolder = models.appendingPathComponent("argmaxinc/whisperkit-coreml/openai_whisper-large-v3")
case "turbo": modelFolder = models.appendingPathComponent("argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo")
case "swedish": modelFolder = models.appendingPathComponent("lab37/kb-whisper-coreml/kb_whisper-large")
default:
    FileHandle.standardError.write(Data("unknown model \(model)\n\(usage)\n".utf8))
    exit(2)
}
guard FileManager.default.fileExists(atPath: modelFolder.path) else {
    FileHandle.standardError.write(Data("model folder missing: \(modelFolder.path)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[bark-eval] \(message)\n".utf8))
}

let clock = ContinuousClock()
func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

func computeUnits(_ name: String?, default fallback: MLComputeUnits) -> MLComputeUnits {
    switch name {
    case "gpu": .cpuAndGPU
    case "ane": .cpuAndNeuralEngine
    case "all": .all
    default: fallback
    }
}

let loadStart = clock.now
let kit = try await WhisperKit(WhisperKitConfig(
    model: "openai_whisper-large-v3",
    modelFolder: modelFolder.path,
    computeOptions: ModelComputeOptions(audioEncoderCompute: computeUnits(args["encoder"], default: .cpuAndGPU),
                                        textDecoderCompute: computeUnits(args["decoder"], default: .cpuAndNeuralEngine)),
    verbose: false,
    logLevel: .error,
    download: false))
log("loaded \(model) in \(String(format: "%.1f", seconds(clock.now - loadStart)))s")

// Spike S1b: KB answers sub-1 s Swedish with its no-speech token. Off by default.
if args["suppress-nospeech"] == "1", let tokenizer = kit.tokenizer {
    kit.textDecoder.logitsFilters = (kit.textDecoder.logitsFilters ?? [])
        + [SuppressTokensFilter(suppressTokens: [tokenizer.specialTokens.noSpeechToken])]
    log("suppressing no-speech token \(tokenizer.specialTokens.noSpeechToken)")
}

// Same as Transcriber.makeDecodingOptions(). NEVER set detectLanguage.
var options = DecodingOptions()
options.task = .transcribe
options.usePrefillPrompt = true
options.skipSpecialTokens = true
options.withoutTimestamps = true
options.windowClipTime = 0
// Shipping fix 74446f7: the WhisperKit-only default (-1.5) ends the decode at
// zero tokens when the first word, typically a name, is uncertain.
options.firstTokenLogProbThreshold = nil
options.language = language
// Long-dictation candidates: without timestamps a 30 s window can end early and
// the seek jumps to the next window, dropping everything in between.
if args["timestamps"] == "1" { options.withoutTimestamps = false }
if args["chunking"] == "vad" { options.chunkingStrategy = .vad }

let warmStart = clock.now
_ = try await kit.transcribe(audioArray: [Float](repeating: 0, count: 48_000), decodeOptions: options)
log("warmup \(String(format: "%.2f", seconds(clock.now - warmStart)))s")

let clips = try FileManager.default.contentsOfDirectory(atPath: clipsDir)
    .filter { $0.hasSuffix(".wav") }
    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
guard !clips.isEmpty else {
    log("no .wav files in \(clipsDir)")
    exit(1)
}

FileManager.default.createFile(atPath: outPath, contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
defer { try? out.close() }

struct Row: Encodable {
    let id: String
    let hypothesis: String
    let decode_seconds: Double
    let audio_seconds: Double
    // WhisperKit's own split, summed over windows: where a release decode goes.
    let encoding: Double
    let decoding_loop: Double
    let decoding_predictions: Double
    let tokens: Double
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

for (index, clip) in clips.enumerated() {
    let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: (clipsDir as NSString).appendingPathComponent(clip))
    let start = clock.now
    let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
    let decode = seconds(clock.now - start)
    let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let row = Row(id: String(clip.dropLast(4)), hypothesis: text,
                  decode_seconds: decode, audio_seconds: Double(samples.count) / 16_000,
                  encoding: results.map(\.timings.encoding).reduce(0, +),
                  decoding_loop: results.map(\.timings.decodingLoop).reduce(0, +),
                  decoding_predictions: results.map(\.timings.decodingPredictions).reduce(0, +),
                  tokens: results.map(\.timings.totalDecodingLoops).reduce(0, +))
    try out.write(contentsOf: encoder.encode(row) + Data("\n".utf8))
    log("\(index + 1)/\(clips.count) \(row.id) \(String(format: "%.2f", decode))s")
}
