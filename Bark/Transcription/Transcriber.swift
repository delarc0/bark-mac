import Foundation
import WhisperKit
import os

actor Transcriber {

    enum State: Sendable {
        case unloaded
        case loading
        case ready
        case failed(String)
    }

    static let defaultModel = "openai_whisper-large-v3_turbo"

    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Transcriber")
    private var pipeline: WhisperKit?
    private(set) var state: State = .unloaded
    private var loadTask: Task<Void, Error>?
    private var onStateChanged: (@Sendable (State) -> Void)?
    private let modelVariant: String

    init(modelVariant: String = Transcriber.defaultModel) {
        self.modelVariant = modelVariant
    }

    func setStateObserver(_ observer: @escaping @Sendable (State) -> Void) {
        onStateChanged = observer
        observer(state)
    }

    private func setState(_ new: State) {
        state = new
        onStateChanged?(new)
    }

    private static func resolvedCompute() -> ModelComputeOptions {
        let cpuOnly = ProcessInfo.processInfo.environment["BARK_CPU_ONLY"] == "1"
        if cpuOnly {
            return ModelComputeOptions(audioEncoderCompute: .cpuAndGPU,
                                       textDecoderCompute: .cpuAndGPU)
        }
        return ModelComputeOptions(audioEncoderCompute: .cpuAndGPU,
                                   textDecoderCompute: .cpuAndNeuralEngine)
    }

    func load() async throws {
        if case .ready = state { return }
        // Single-flight: a transcribe arriving mid-load must join the in-flight
        // load, not kick off a second WhisperKit init (and model download).
        if let existing = loadTask {
            return try await existing.value
        }
        setState(.loading)
        log.info("Loading WhisperKit model '\(self.modelVariant, privacy: .public)'...")
        let task = Task { () throws in
            do {
                let config = WhisperKitConfig(model: modelVariant,
                                              computeOptions: Self.resolvedCompute(),
                                              verbose: false,
                                              logLevel: .error)
                let kit = try await WhisperKit(config)
                pipeline = kit
                setState(.ready)
                log.info("WhisperKit ready.")
            } catch {
                setState(.failed(error.localizedDescription))
                log.error("WhisperKit load failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    func warmup() async {
        do {
            if case .ready = state {} else { try await load() }
            let silent = [Float](repeating: 0, count: 48000)  // 3s primes the decoder closer to typical clips
            let t0 = Date()
            _ = try await transcribe(samples: silent)
            log.info("Warmup complete in \(Date().timeIntervalSince(t0), privacy: .public)s")
        } catch {
            log.error("Warmup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func transcribe(samples: [Float], language: String? = nil) async throws -> String {
        if case .ready = state {} else { try await load() }
        guard let pipeline else {
            throw NSError(domain: "Transcriber", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Pipeline not loaded"])
        }

        var options = DecodingOptions()
        options.task = .transcribe
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        if let language { options.language = language }

        let trimmed = Self.trimSilence(samples)
        if trimmed.count < samples.count {
            let savedSec = Double(samples.count - trimmed.count) / 16000.0
            log.info("Trimmed \(savedSec, privacy: .public)s of silence (\(samples.count, privacy: .public) → \(trimmed.count, privacy: .public) samples)")
        }

        let results = try await pipeline.transcribe(audioArray: trimmed, decodeOptions: options)
        let text = results.map { $0.text }.joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trim leading/trailing silence based on 10ms RMS frames. Keeps 100ms of head/tail
    /// margin so we don't clip onset consonants or trailing breath.
    private static func trimSilence(_ samples: [Float]) -> [Float] {
        guard samples.count > 3200 else { return samples }
        let sampleRate = 16_000
        let frameSize = sampleRate / 100           // 10ms
        let marginFrames = 10                      // 100ms
        let threshold: Float = 0.01                // RMS above this counts as speech

        let frameCount = samples.count / frameSize
        var firstVoiced = -1
        var lastVoiced = -1
        for i in 0..<frameCount {
            let start = i * frameSize
            var sumSq: Float = 0
            for j in 0..<frameSize {
                let s = samples[start + j]
                sumSq += s * s
            }
            let rms = (sumSq / Float(frameSize)).squareRoot()
            if rms > threshold {
                if firstVoiced < 0 { firstVoiced = i }
                lastVoiced = i
            }
        }

        if firstVoiced < 0 { return samples }  // pure silence → let Whisper see it

        let startFrame = max(0, firstVoiced - marginFrames)
        let endFrame = min(frameCount - 1, lastVoiced + marginFrames)
        let startSample = startFrame * frameSize
        let endSample = (endFrame + 1) * frameSize
        return Array(samples[startSample..<endSample])
    }
}
