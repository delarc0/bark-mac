import Foundation
import MLX
import WhisperKit

// Spike S8: bark-eval's contract on the Swift MLX engine. Transcribes every .wav in a directory
// and writes one JSON line per clip.

let usage = "usage: mlx-eval --model swedish|swedish8|general --language <code> --clips <dir> --out <file.jsonl>"

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

func log(_ message: String) {
    FileHandle.standardError.write(Data("[mlx-eval] \(message)\n".utf8))
}

let home = FileManager.default.homeDirectoryForCurrentUser
let models = home.appending(path: "Library/Application Support/Bark/eval/models")
func kbTokenizer() -> URL? {
    let snapshots = home.appending(path: ".cache/huggingface/hub/models--KBLab--kb-whisper-large/snapshots")
    return (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil))?.first
}
let modelFolder: URL
let tokenizerFolder: URL?
switch model {
case "swedish": (modelFolder, tokenizerFolder) = (models.appending(path: "kb-whisper-large-mlx"), kbTokenizer())
case "swedish8": (modelFolder, tokenizerFolder) = (models.appending(path: "kb-whisper-large-mlx-q8"), kbTokenizer())
case "general": (modelFolder, tokenizerFolder) = (models.appending(path: "whisper-large-v3-mlx"),
                                                  home.appending(path: "Documents/huggingface/models/openai/whisper-large-v3"))
default:
    FileHandle.standardError.write(Data("unknown model \(model)\n\(usage)\n".utf8))
    exit(2)
}
guard let tokenizerFolder,
      FileManager.default.fileExists(atPath: modelFolder.appending(path: "weights.safetensors").path),
      FileManager.default.fileExists(atPath: tokenizerFolder.appending(path: "tokenizer.json").path) else {
    log("model or tokenizer missing: \(modelFolder.path), \(tokenizerFolder?.path ?? "no KB tokenizer snapshot")")
    exit(1)
}

let clock = ContinuousClock()
func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
func gigabytes(_ bytes: Int) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }

let loadStart = clock.now
let engine = try Engine(model: try Whisper.load(modelFolder),
                        tokens: try WhisperTokens(try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder)),
                        language: language)
log("loaded \(model) in \(String(format: "%.2f", seconds(clock.now - loadStart)))s, active \(gigabytes(Memory.activeMemory)), peak \(gigabytes(Memory.peakMemory))")

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
    try AudioProcessor.loadAudioAsFloatArray(fromPath: (clipsDir as NSString).appendingPathComponent(clip))
        .map { min(max(($0 * 32768 + 0.5).rounded(.down), -32768), 32767) / 32768 }
}

let warmStart = clock.now
_ = try engine.transcribe(try load(clips[0]))
log("first decode \(String(format: "%.2f", seconds(clock.now - warmStart)))s")

FileManager.default.createFile(atPath: outPath, contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
defer { try? out.close() }

struct Row: Encodable {
    let id: String
    let hypothesis: String
    let decode_seconds: Double
    let audio_seconds: Double
    let tokens: Int
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

for (index, clip) in clips.enumerated() {
    let samples = try load(clip)
    let start = clock.now
    let result = try engine.transcribe(samples)
    let decode = seconds(clock.now - start)
    let row = Row(id: String(clip.dropLast(4)), hypothesis: result.text, decode_seconds: decode,
                  audio_seconds: Double(samples.count) / Double(sampleRate), tokens: result.tokens)
    try out.write(contentsOf: encoder.encode(row) + Data("\n".utf8))
    log("\(index + 1)/\(clips.count) \(row.id) \(String(format: "%.2f", decode))s t=\(result.temperature)")
}
log("peak memory \(gigabytes(Memory.peakMemory))")
