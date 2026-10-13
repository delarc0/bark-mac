import AVFoundation
import BarkCore
import BarkEngine
import Foundation
import MLX

// bark-eval's contract on BarkEngine: transcribes every .wav in a directory and writes one JSON
// line per clip. Engine-only by default (the S8 mode: one decode per clip, no gate, no clean-up).
// --pipeline feeds each clip through a DictationSession exactly as the app will (Silero segments,
// 28 s cut, routing, clean-up): as fast as possible, or with --realtime 1 in 100 ms blocks at
// wall-clock pace, where release_to_final is the wait after the last block.
// --language auto (pipeline only) routes each clip through detection; --model auto|auto8 loads
// large-v3 plus KB at fp16 or 8-bit. Models come from ModelStore (BarkKit/scripts/dev-models.sh).
// --meeting runs the S7 meeting budget (MeetingBudget.swift).

let usage = """
    usage: mlx-eval --model swedish|swedish8|general|general8 --language <code> --clips <dir> --out <file.jsonl>
           mlx-eval --pipeline [--realtime 1] --model <as above> --language <code> ...
           mlx-eval --pipeline [--realtime 1] --model auto|auto8 --language auto ...
           mlx-eval --meeting [--speed 10] [--minutes 90] [--sample 60] --out <file.jsonl>
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

var args: [String: String] = [:]
var argv = CommandLine.arguments.dropFirst()
while let flag = argv.popFirst() {
    guard flag.hasPrefix("--") else { fail(usage) }
    if flag == "--pipeline" || flag == "--meeting" {
        args[String(flag.dropFirst(2))] = "1"
        continue
    }
    guard let value = argv.popFirst() else { fail(usage) }
    args[String(flag.dropFirst(2))] = value
}

// Where FluidAudio cached Silero for the spike tools; the app ships its own copy.
let sileroFolder = URL.applicationSupportDirectory.appending(path: "FluidAudio/Models/silero-vad")

if args["meeting"] == "1" {
    guard let outPath = args["out"], let speed = Double(args["speed"] ?? "10"), let minutes = Double(args["minutes"] ?? "90"),
          let sample = Double(args["sample"] ?? "60") else { fail(usage) }
    let evalDir = URL.applicationSupportDirectory.appending(path: "Bark/eval")
    FileManager.default.createFile(atPath: outPath, contents: nil)
    let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
    try await MeetingBudget.run(speed: speed, minutes: minutes, sampleEvery: sample, sets: evalDir.appending(path: "sets"),
                                storeRoot: evalDir.appending(path: "meeting/store"), out: out, models: ModelStore(),
                                silero: sileroFolder) { FileHandle.standardError.write(Data("[mlx-eval] \($0)\n".utf8)) }
    try out.close()
    exit(0)
}
guard let model = args["model"], let language = args["language"],
      let clipsDir = args["clips"], let outPath = args["out"] else { fail(usage) }
let pipeline = args["pipeline"] == "1"
let realtime = args["realtime"] == "1"

func log(_ message: String) {
    FileHandle.standardError.write(Data("[mlx-eval] \(message)\n".utf8))
}

let store = ModelStore()
let modelIDs: [String: String] = [
    "swedish": ModelID.swedish, "swedish8": ModelID.swedish8, "general": ModelID.general, "general8": ModelID.general8,
]
// (general, swedish) for --language auto.
let autoPairs: [String: (String, String)] = [
    "auto": (ModelID.general, ModelID.swedish), "auto8": (ModelID.general8, ModelID.swedish8),
]
if language == "auto", !pipeline || autoPairs[model] == nil { fail("--language auto needs --pipeline and --model auto|auto8\n\(usage)") }
let needed = language == "auto" ? [autoPairs[model]!.0, autoPairs[model]!.1] : [modelIDs[model] ?? ""]
for id in needed where !store.isInstalled(id) {
    log("model \(id.isEmpty ? model : id) missing in \(store.root.path); run BarkKit/scripts/dev-models.sh")
    exit(1)
}

let clock = ContinuousClock()
func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
func gigabytes(_ bytes: Int) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }

let clips = try FileManager.default.contentsOfDirectory(atPath: clipsDir)
    .filter { $0.hasSuffix(".wav") }
    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
guard !clips.isEmpty else {
    log("no .wav files in \(clipsDir)")
    exit(1)
}

// The Python proof loads clips through ffmpeg as s16le; quantise the same way so per-clip diffs
// measure the engine, not the input. The app feeds float samples directly.
func load(_ clip: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: (clipsDir as NSString).appendingPathComponent(clip)),
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.fileFormat.sampleRate == 16_000, file.fileFormat.channelCount == 1 else {
        throw EngineError(description: "\(clip): need 16 kHz mono")
    }
    var samples: [Float] = []
    // One read can return fewer frames than asked for, so read until the end.
    while file.framePosition < file.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16) else { break }
        try file.read(into: buffer)
        if buffer.frameLength == 0 { break }
        samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    }
    return samples.map { min(max(($0 * 32768 + 0.5).rounded(.down), -32768), 32767) / 32768 }
}

FileManager.default.createFile(atPath: outPath, contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
defer { try? out.close() }
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

if !pipeline {
    let loadStart = clock.now
    let engine = try Engine(folder: store.folder(modelIDs[model]!))
    log("loaded \(model) in \(String(format: "%.2f", seconds(clock.now - loadStart)))s, active \(gigabytes(Memory.activeMemory)), peak \(gigabytes(Memory.peakMemory))")

    let warmStart = clock.now
    _ = try engine.transcribe(try load(clips[0]), language: language)
    log("first decode \(String(format: "%.2f", seconds(clock.now - warmStart)))s")

    struct Row: Encodable {
        let id: String
        let hypothesis: String
        let decode_seconds: Double
        let audio_seconds: Double
        let tokens: Int
    }
    for (index, clip) in clips.enumerated() {
        let samples = try load(clip)
        let start = clock.now
        let result = try engine.transcribe(samples, language: language)
        let decode = seconds(clock.now - start)
        let row = Row(id: String(clip.dropLast(4)), hypothesis: result.text, decode_seconds: decode,
                      audio_seconds: Double(samples.count) / 16_000, tokens: result.tokens)
        try out.write(contentsOf: encoder.encode(row) + Data("\n".utf8))
        log("\(index + 1)/\(clips.count) \(row.id) \(String(format: "%.2f", decode))s t=\(result.temperature)")
    }
} else {
    // An explicit language runs on the one model named, loaded as general, so every route of the
    // matrix (KB on English included) can be measured; auto loads both and routes for real.
    let transcriber: Transcriber
    let choice: LanguageChoice
    if let (general, swedish) = autoPairs[model], language == "auto" {
        transcriber = Transcriber(general: store.folder(general), swedish: store.folder(swedish), vad: sileroFolder)
        choice = .auto
    } else {
        transcriber = Transcriber(general: store.folder(modelIDs[model]!), swedish: nil, vad: sileroFolder)
        choice = .explicit(language)
    }
    let loadStart = clock.now
    try await transcriber.start()
    let swedishReady = await transcriber.swedishReady()
    log("loaded \(model) in \(String(format: "%.2f", seconds(clock.now - loadStart)))s (Swedish ready: \(swedishReady)), active \(gigabytes(Memory.activeMemory))")

    func dictate(_ samples: [Float]) async throws -> DictationResult {
        let session = try await transcriber.makeSession(language: choice)
        let block = 1_600
        let start = clock.now
        for (index, offset) in stride(from: 0, to: samples.count, by: block).enumerated() {
            if realtime { try await Task.sleep(until: start + .milliseconds(100 * (index + 1)), clock: .continuous) }
            await session.feed(Array(samples[offset ..< min(offset + block, samples.count)]))
        }
        return await session.finish()
    }

    // Explicit runs load the named model as general, so name the role by the model asked for.
    func routedModel(_ result: DictationResult) -> String {
        choice == .auto ? (result.model?.rawValue ?? "") : (model.hasPrefix("swedish") ? ModelRole.swedish : ModelRole.general).rawValue
    }

    let warm = try await dictate(try load(clips[0]))
    log("first dictation \(String(format: "%.2f", warm.releaseToFinal))s")

    struct Row: Encodable {
        let id: String
        let hypothesis: String
        let parts: [String]
        let segment_decode_seconds: [Double]
        let segment_audio_seconds: [Double]
        let segment_speech_seconds: [Double]
        let segment_tokens: [Int]
        let redecoded_segments: Int
        let failed_segments: Int
        let decode_seconds: Double
        let release_to_final: Double
        let audio_seconds: Double
        let model: String?
        let language: String?
        let detected: String?
        let detected_probability: Double?
    }
    for (index, clip) in clips.enumerated() {
        let samples = try load(clip)
        let result = try await dictate(samples)
        let row = Row(id: String(clip.dropLast(4)), hypothesis: result.text, parts: result.segments.map(\.text),
                      segment_decode_seconds: result.segments.map(\.decodeSeconds),
                      segment_audio_seconds: result.segments.map(\.audioSeconds),
                      segment_speech_seconds: result.segments.map(\.speechSeconds),
                      segment_tokens: result.segments.map(\.tokens),
                      redecoded_segments: result.segments.filter(\.redecoded).count,
                      failed_segments: result.segments.filter(\.failed).count,
                      decode_seconds: result.releaseToFinal, release_to_final: result.releaseToFinal,
                      audio_seconds: Double(samples.count) / 16_000, model: result.model.map { _ in routedModel(result) }, language: result.language,
                      detected: result.detection?.language, detected_probability: result.detection?.probability)
        try out.write(contentsOf: encoder.encode(row) + Data("\n".utf8))
        log("\(index + 1)/\(clips.count) \(row.id) \(String(format: "%.2f", row.release_to_final))s \(result.segments.count) parts \(row.model ?? "-")/\(row.language ?? "-")")
    }
}
log("peak memory \(gigabytes(Memory.peakMemory))")
