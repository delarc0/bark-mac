import BarkCore
import CoreML
import FluidAudio
import Foundation
import MLX
import Synchronization
import os

public enum TranscriberError: Error {
    case timedOut
    case notStarted
}

/// Runs MLX work one job at a time on one serial queue, because MLXArray is not thread safe. A job
/// that outlives its timeout is abandoned, not cancelled (MLX cannot be interrupted): the caller
/// gets `timedOut` at once, and the job holds the queue until it returns.
final class MLXWorker: Sendable {
    private let queue = DispatchQueue(label: "se.lab37.bark.mlx", qos: .userInitiated)

    private final class Once<T: Sendable>: Sendable {
        let continuation: Mutex<CheckedContinuation<T, Error>?>
        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = Mutex(continuation) }
        func resume(_ result: Result<T, Error>) {
            continuation.withLock { $0.take() }?.resume(with: result)
        }
    }

    func run<T: Sendable>(timeout seconds: TimeInterval? = nil, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            queue.async { once.resume(Result { try work() }) }
            if let seconds {
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.resume(.failure(TranscriberError.timedOut)) }
            }
        }
    }
}

/// The models behind dictation: large-v3 (general, and the language judge) and KB-Whisper
/// (Swedish), plus Silero for the session's segmenter.
public actor Transcriber {
    public static let decodeTimeout: TimeInterval = 20
    /// The first decode after install compiles the Metal shaders (4 to 16 s measured).
    public static let warmUpTimeout: TimeInterval = 120
    public static let vadThreshold: Float = 0.5
    /// Uncapped, MLX's buffer cache adds ~2.5 GB to a meeting process with no latency win (tasks/bark2.md, Memory cap).
    public static let mlxCacheLimit = 256 * 1024 * 1024
    static let sampleRate = 16_000

    let worker = MLXWorker()
    private let generalFolder: URL
    private let swedishFolder: URL?
    private let vadFolder: URL
    private var engines: [ModelRole: Engine] = [:]
    private var swedishLoad: Task<Void, Never>?
    private var vad: VadManager?
    /// The last confidently detected language, kept across dictations. Prefills, never routes.
    private(set) var remembered: String?
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Transcriber")

    /// The compiled Silero model `vadFolder` must hold.
    public static let sileroModel = ModelNames.VAD.sileroVadFile

    /// Model folders as ModelStore lays them out. Without a Swedish folder, Swedish runs on general.
    /// `vad` holds `sileroModel`; it is loaded from there and never downloaded.
    public init(general: URL, swedish: URL?, vad: URL) {
        generalFolder = general
        swedishFolder = swedish
        vadFolder = vad
    }

    /// Loads and warms the general model and Silero, then starts loading the Swedish model in the
    /// background. Returns once dictation can run.
    public func start() async throws {
        Memory.cacheLimit = Self.mlxCacheLimit
        if vad == nil {
            vad = try Self.loadVAD(vadFolder)
        }
        if engines[.general] == nil {
            let folder = generalFolder
            let engine = try await worker.run { try Engine(folder: folder) }
            try await warmUp(engine, language: "en")
            engines[.general] = engine
        }
        if let swedishFolder, swedishLoad == nil {
            swedishLoad = Task { await loadSwedish(swedishFolder) }
        }
    }

    /// The model goes in directly: FluidAudio's own loaders fetch a missing model from Hugging Face.
    static func loadVAD(_ folder: URL) throws -> VadManager {
        let config = VadConfig(defaultThreshold: vadThreshold)
        let options = MLModelConfiguration()
        options.computeUnits = config.computeUnits
        options.allowLowPrecisionAccumulationOnGPU = true
        let model = try MLModel(contentsOf: folder.appending(path: sileroModel), configuration: options)
        return VadManager(config: config, vadModel: model)
    }

    private func loadSwedish(_ folder: URL) async {
        do {
            let engine = try await worker.run { try Engine(folder: folder) }
            try await warmUp(engine, language: "sv")
            engines[.swedish] = engine
        } catch {
            log.error("Swedish model failed to load, Swedish runs on the general model: \(String(describing: error), privacy: .public)")
        }
    }

    /// Waits for the background Swedish load; true when the Swedish model is ready.
    public func swedishReady() async -> Bool {
        await swedishLoad?.value
        return engines[.swedish] != nil
    }

    /// Decodes 1 s of real silence straight on the engine (a session's speech gate would skip it),
    /// which compiles the Metal kernels and pages in the weights before the first dictation.
    private func warmUp(_ engine: Engine, language: String) async throws {
        _ = try await worker.run(timeout: Self.warmUpTimeout) {
            try engine.transcribe([Float](repeating: 0, count: Self.sampleRate), language: language)
        }
    }

    public func makeSession(language: LanguageChoice, cleanup: Bool = true, vocabulary: [String: String] = [:]) throws -> DictationSession {
        DictationSession(transcriber: self, vad: try startedVAD(), choice: language, cleanup: cleanup, vocabulary: vocabulary)
    }

    /// Silero for a session's segmenters, once start() has run.
    func startedVAD() throws -> VadManager {
        guard let vad, engines[.general] != nil else { throw TranscriberError.notStarted }
        return vad
    }

    /// The model a dictation routed to `role` runs on: Swedish falls back to general until KB is loaded.
    func available(_ role: ModelRole) -> ModelRole {
        engines[role] != nil ? role : .general
    }

    /// Throws for a language code the models have no token for.
    func checkLanguage(_ code: String) throws {
        guard let engine = engines[.general] else { throw TranscriberError.notStarted }
        _ = try engine.vocabulary.language(code)
    }

    /// The model's id, its folder's name (kb-whisper-large-8bit).
    func modelID(_ role: ModelRole) -> String {
        (role == .swedish ? swedishFolder ?? generalFolder : generalFolder).lastPathComponent
    }

    func remember(_ language: String?) {
        remembered = language
    }

    func transcribe(_ samples: [Float], on role: ModelRole, language: String) async throws -> Transcription {
        guard let engine = engines[role] ?? engines[.general] else { throw TranscriberError.notStarted }
        return try await worker.run(timeout: Self.decodeTimeout) { try engine.transcribe(samples, language: language) }
    }

    /// The timestamped re-decode with a seek loop, for a decode that stopped short.
    func transcribeTimestamped(_ samples: [Float], on role: ModelRole, language: String) async throws -> Transcription {
        guard let engine = engines[role] ?? engines[.general] else { throw TranscriberError.notStarted }
        return try await worker.run(timeout: Self.decodeTimeout) { try engine.transcribeTimestamped(samples, language: language) }
    }

    /// The decode policy for one segment: the plain decode, then the timestamped re-decode when it
    /// stopped short (BarkCore Truncation). A cancelled calling task skips the re-decode. A nil
    /// result means the decode timed out or threw.
    func decodeSegment(_ audio: [Float], speechSeconds: Double, on role: ModelRole, language: String) async
        -> (result: Transcription?, redecoded: Bool) {
        guard let plain = try? await transcribe(audio, on: role, language: language) else { return (nil, false) }
        guard !Task.isCancelled, Truncation.isTruncated(speechSeconds: speechSeconds, tokens: plain.tokens, language: language),
              let full = try? await transcribeTimestamped(audio, on: role, language: language) else { return (plain, false) }
        return (full, true)
    }

    /// Detection always runs on the general model: KB is a Swedish fine-tune and no fair judge.
    func detectLanguage(_ samples: [Float]) async throws -> [(language: String, probability: Double)] {
        guard let engine = engines[.general] else { throw TranscriberError.notStarted }
        return try await worker.run(timeout: Self.decodeTimeout) { engine.detectLanguage(samples) }
    }
}
