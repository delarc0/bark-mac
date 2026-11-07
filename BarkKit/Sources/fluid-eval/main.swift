import AVFoundation
import FluidAudio
import Foundation

// Eval-only comparisons that need FluidAudio.
//   parakeet: Parakeet TDT 0.6B v3 over a clip dir, same JSONL as mlx-eval.
//   gate:     speech gate over a clip dir; writes the trimmed audio of every
//             clip it lets through, plus gate.jsonl with each decision.

let usage = """
    usage: fluid-eval parakeet --clips <dir> --out <file.jsonl>
           fluid-eval gate --kind energy|silero [--threshold <p>] --clips <dir> --out <dir>
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[fluid-eval] \(message)\n".utf8))
}

var argv = CommandLine.arguments.dropFirst()
guard let command = argv.popFirst() else { fail(usage) }
var args: [String: String] = [:]
while let flag = argv.popFirst() {
    guard flag.hasPrefix("--"), let value = argv.popFirst() else { fail(usage) }
    args[String(flag.dropFirst(2))] = value
}
guard let clipsDir = args["clips"], let outPath = args["out"] else { fail(usage) }

let rate = 16_000.0
let clips = try FileManager.default.contentsOfDirectory(atPath: clipsDir)
    .filter { $0.hasSuffix(".wav") }
    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
guard !clips.isEmpty else { fail("no .wav files in \(clipsDir)") }

func readWav(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.processingFormat.sampleRate == rate, file.processingFormat.channelCount == 1 else {
        fail("\(path): expected 16 kHz mono")
    }
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func writeWav(_ samples: [Float], to path: String) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

let clock = ContinuousClock()
func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

func jsonLines(_ path: String) throws -> FileHandle {
    FileManager.default.createFile(atPath: path, contents: nil)
    return try FileHandle(forWritingTo: URL(fileURLWithPath: path))
}

/// Bark's shipping energy gate, Transcriber.trimSilence, verbatim: 10 ms RMS
/// frames, speech above 0.01, 100 ms margin, nil when no frame is voiced.
func energyGate(_ samples: [Float]) -> [Float]? {
    let frameSize = 160
    let marginFrames = 10
    let threshold: Float = 0.01
    let frameCount = samples.count / frameSize
    var firstVoiced = -1
    var lastVoiced = -1
    for i in 0..<frameCount {
        var sumSq: Float = 0
        for j in 0..<frameSize {
            let s = samples[i * frameSize + j]
            sumSq += s * s
        }
        if (sumSq / Float(frameSize)).squareRoot() > threshold {
            if firstVoiced < 0 { firstVoiced = i }
            lastVoiced = i
        }
    }
    if firstVoiced < 0 { return nil }
    guard samples.count > 3200 else { return samples }
    let startFrame = max(0, firstVoiced - marginFrames)
    let endFrame = min(frameCount - 1, lastVoiced + marginFrames)
    return Array(samples[(startFrame * frameSize)..<((endFrame + 1) * frameSize)])
}

switch command {
case "parakeet":
    struct Row: Encodable {
        let id: String
        let hypothesis: String
        let decode_seconds: Double
        let audio_seconds: Double
    }
    let loadStart = clock.now
    let asr = AsrManager(config: .default)
    try await asr.loadModels(try await AsrModels.downloadAndLoad(version: .v3))
    log("loaded parakeet-tdt-0.6b-v3 in \(String(format: "%.1f", seconds(clock.now - loadStart)))s")
    var warm = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    _ = try await asr.transcribe([Float](repeating: 0, count: 48_000), decoderState: &warm)

    let out = try jsonLines(outPath)
    defer { try? out.close() }
    for (index, clip) in clips.enumerated() {
        let samples = try readWav((clipsDir as NSString).appendingPathComponent(clip))
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let start = clock.now
        let result = try await asr.transcribe(samples, decoderState: &state)
        let row = Row(id: String(clip.dropLast(4)),
                      hypothesis: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                      decode_seconds: seconds(clock.now - start), audio_seconds: Double(samples.count) / rate)
        try out.write(contentsOf: encoder.encode(row) + Data("\n".utf8))
        log("\(index + 1)/\(clips.count) \(row.id) \(String(format: "%.3f", row.decode_seconds))s")
    }

case "gate":
    struct Decision: Encodable {
        let id: String
        let passed: Bool
        let in_seconds: Double
        let kept_seconds: Double
    }
    let kind = args["kind"] ?? ""
    var vad: VadManager?
    switch kind {
    case "energy": break
    case "silero":
        let threshold = Float(args["threshold"] ?? "") ?? VadConfig.default.defaultThreshold
        vad = try await VadManager(config: VadConfig(defaultThreshold: threshold))
        log("silero threshold \(threshold)")
    default: fail(usage)
    }
    try FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)
    let decisions = try jsonLines((outPath as NSString).appendingPathComponent("gate.jsonl"))
    defer { try? decisions.close() }
    for clip in clips {
        let samples = try readWav((clipsDir as NSString).appendingPathComponent(clip))
        var kept: [Float]?
        if let vad {
            let segments = try await vad.segmentSpeech(samples)
            if let first = segments.first, let last = segments.last {
                kept = Array(samples[first.startSample(sampleRate: 16_000)..<last.endSample(sampleRate: 16_000)])
            }
        } else {
            kept = energyGate(samples)
        }
        if let kept, !kept.isEmpty {
            try writeWav(kept, to: (outPath as NSString).appendingPathComponent(clip))
        }
        let decision = Decision(id: String(clip.dropLast(4)), passed: !(kept ?? []).isEmpty,
                                in_seconds: Double(samples.count) / rate, kept_seconds: Double(kept?.count ?? 0) / rate)
        try decisions.write(contentsOf: encoder.encode(decision) + Data("\n".utf8))
    }
    log("\(kind): \(clips.count) clips gated into \(outPath)")

default:
    fail(usage)
}
