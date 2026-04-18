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
    private let modelVariant: String
    private let language: String?

    init(modelVariant: String = Transcriber.defaultModel, language: String? = nil) {
        self.modelVariant = modelVariant
        self.language = language
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
        state = .loading
        log.info("Loading WhisperKit model '\(self.modelVariant, privacy: .public)'...")
        do {
            let config = WhisperKitConfig(model: modelVariant,
                                          computeOptions: Self.resolvedCompute(),
                                          verbose: false,
                                          logLevel: .error)
            let kit = try await WhisperKit(config)
            pipeline = kit
            state = .ready
            log.info("WhisperKit ready.")
        } catch {
            state = .failed(error.localizedDescription)
            log.error("WhisperKit load failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func warmup() async {
        do {
            if case .ready = state {} else { try await load() }
            let silent = [Float](repeating: 0, count: 16000)
            let t0 = Date()
            _ = try await transcribe(samples: silent)
            log.info("Warmup complete in \(Date().timeIntervalSince(t0), privacy: .public)s")
        } catch {
            log.error("Warmup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
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

        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map { $0.text }.joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
