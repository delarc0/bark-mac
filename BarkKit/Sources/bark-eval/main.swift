import Foundation
import WhisperKit

// Transcribes every .wav in a directory on the shipping engine config and
// writes one JSON line per clip. Deliberately skips Bark's silence trimming:
// this measures the raw engine.

let usage = "usage: bark-eval --model general|swedish --language <code> --clips <dir> --out <file.jsonl>"

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

let loadStart = clock.now
let kit = try await WhisperKit(WhisperKitConfig(
    model: "openai_whisper-large-v3",
    modelFolder: modelFolder.path,
    computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndGPU,
                                        textDecoderCompute: .cpuAndNeuralEngine),
    verbose: false,
    logLevel: .error,
    download: false))
log("loaded \(model) in \(String(format: "%.1f", seconds(clock.now - loadStart)))s")

// Same as Transcriber.makeDecodingOptions(). NEVER set detectLanguage.
var options = DecodingOptions()
options.task = .transcribe
options.usePrefillPrompt = true
options.skipSpecialTokens = true
options.withoutTimestamps = true
options.windowClipTime = 0
options.language = language

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
                  decode_seconds: decode, audio_seconds: Double(samples.count) / 16_000)
    try out.write(contentsOf: encoder.encode(row) + Data("\n".utf8))
    log("\(index + 1)/\(clips.count) \(row.id) \(String(format: "%.2f", decode))s")
}
