import Foundation
import WhisperKit
import os

// Shared between AppSettings (MainActor) and the Transcriber actor, which reads
// it via thread-safe UserDefaults during load().
let barkCpuOnlyDefaultsKey = "transcriber.cpuOnly"

actor Transcriber {

    enum State: Sendable {
        case unloaded
        case loading
        case downloading(Double)
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

    static func cpuOnlyRequested() -> Bool {
        ProcessInfo.processInfo.environment["BARK_CPU_ONLY"] == "1"
            || UserDefaults.standard.bool(forKey: barkCpuOnlyDefaultsKey)
    }

    private static func resolvedCompute() -> ModelComputeOptions {
        if cpuOnlyRequested() {
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
                // Cached model: skip the Hub round-trip (keeps relaunches
                // working offline). A folder that exists but fails to load
                // (interrupted download) falls through to a repair download.
                if let local = Self.localModelFolder(for: modelVariant) {
                    do {
                        try await buildPipeline(modelFolder: local.path)
                        return
                    } catch {
                        log.error("Cached model failed to load (\(error.localizedDescription, privacy: .public)) — re-fetching")
                    }
                }
                let folder = try await downloadModel()
                setState(.loading)
                try await buildPipeline(modelFolder: folder.path)
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

    private func buildPipeline(modelFolder: String) async throws {
        let config = WhisperKitConfig(model: modelVariant,
                                      modelFolder: modelFolder,
                                      computeOptions: Self.resolvedCompute(),
                                      verbose: false,
                                      logLevel: .error,
                                      download: false)
        let kit = try await WhisperKit(config)
        pipeline = kit
        setState(.ready)
        log.info("WhisperKit ready.")
    }

    private func downloadModel() async throws -> URL {
        log.info("Downloading model '\(self.modelVariant, privacy: .public)'...")
        downloadActive = true
        lastLoggedDecile = -1
        defer { downloadActive = false }
        // Progress fires on a URLSession queue; throttle to whole-percent
        // steps before hopping onto the actor.
        let lastReported = OSAllocatedUnfairLock(initialState: -1.0)
        return try await WhisperKit.download(variant: modelVariant) { [weak self] progress in
            let fraction = progress.fractionCompleted
            let report = lastReported.withLock { (last: inout Double) -> Bool in
                guard fraction - last >= 0.01 else { return false }
                last = fraction
                return true
            }
            guard report, let self else { return }
            Task { await self.noteDownloadProgress(fraction) }
        }
    }

    // Progress hops are queued Tasks; ones that land after the download ended
    // must not repaint .loading (compile phase) or .failed as "Downloading".
    private var downloadActive = false
    private var lastLoggedDecile = -1

    private func noteDownloadProgress(_ fraction: Double) {
        guard downloadActive else { return }
        let decile = Int(fraction * 10)
        if decile > lastLoggedDecile {
            lastLoggedDecile = decile
            log.info("Model download \(decile * 10, privacy: .public)%")
        }
        setState(.downloading(fraction))
    }

    private static func localModelFolder(for variant: String) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let folder = docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(variant)")
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              contents.contains(where: { $0.hasSuffix(".mlmodelc") }) else { return nil }
        return folder
    }

    func warmup() async {
        do {
            let t0 = Date()
            try await warmupDecode()
            log.info("Warmup complete in \(Date().timeIntervalSince(t0), privacy: .public)s")
        } catch {
            log.error("Warmup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Decode 3s of silence straight on the pipeline: primes the decoder and
    /// doubles as the wedge probe. Deliberately bypasses transcribe(), whose
    /// speechless-audio guard would skip the decode this exists to run.
    private func warmupDecode() async throws {
        if case .ready = state {} else { try await load() }
        guard let pipeline else { return }
        var options = Self.makeDecodingOptions()
        options.language = "en"  // pin: don't language-detect silence
        _ = try await pipeline.transcribe(audioArray: [Float](repeating: 0, count: 48000),
                                          decodeOptions: options)
    }

    /// Launch-time warmup with a wedge detector. The ANE decoder path hangs
    /// indefinitely (busy-spin) on some chips — confirmed M1 and M2 Max — and
    /// WhisperKit offers no cancellation, so a healthy-warmup timeout is the only
    /// signal. On a wedge we persist the CPU+GPU fallback and rebuild the
    /// pipeline, so every later launch (including Finder ones, where
    /// BARK_CPU_ONLY can't reach) starts on the working path.
    func warmupSelfHealing() async {
        // Load is NOT under the wedge timeout: a first-run 1.5GB download or a
        // slow CoreML compile can legitimately take minutes, and a false
        // positive here would permanently downgrade a healthy machine to CPU.
        do { try await load() } catch { return }  // load errors surface via state
        // Healthy warmup is 1-8s measured (M1 CPU path through M5 Pro ANE).
        // The model is already compiled by load(); warmup never legitimately
        // takes 30s — but a wedge holds this forever.
        if await warmupCompleted(within: 30) { return }

        guard !Self.cpuOnlyRequested() else {
            log.error("Warmup timed out on the CPU+GPU path — no further fallback available")
            return
        }

        log.error("Warmup wedged on the ANE decoder path — self-healing to CPU+GPU (persisted). The wedged task cannot be cancelled and may spin until relaunch.")
        await MainActor.run { AppSettings.shared.computeCpuOnly = true }
        pipeline = nil
        loadTask = nil
        setState(.unloaded)
        do { try await load() } catch { return }
        if await warmupCompleted(within: 120) {
            log.info("Self-heal succeeded — running on CPU+GPU")
        } else {
            log.error("Self-heal reload also failed to warm up")
        }
    }

    private func warmupCompleted(within seconds: TimeInterval) async -> Bool {
        // All racing tasks are detached: Task {} here would inherit this actor's
        // executor, and a wedge that spins ON the actor would starve the very
        // timeout meant to detect it.
        let work = Task.detached { [weak self] in
            guard let self else { return }
            try await self.warmupDecode()
        }
        let timeout = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce(_ value: Bool) {
                let first = finished.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first {
                    timeout.cancel()
                    cont.resume(returning: value)
                }
            }
            Task.detached {
                do {
                    try await work.value
                    resumeOnce(true)
                } catch {
                    resumeOnce(true)  // errored ≠ wedged; load()/transcribe() surface errors themselves
                }
            }
            Task.detached {
                await timeout.value
                resumeOnce(false)
            }
        }
    }

    func transcribe(samples: [Float], language: String? = nil) async throws -> String {
        if case .ready = state {} else { try await load() }
        guard let pipeline else {
            throw NSError(domain: "Transcriber", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Pipeline not loaded"])
        }

        // Whisper hallucinates confidently on speechless audio ("Thank you."
        // at noSpeechProb 0.00, so WhisperKit's own gate can't catch it) —
        // never decode audio our VAD saw no speech in. This also kills the
        // "Thank you." that streaming used to append from pause/tail chunks.
        guard let trimmed = Self.trimSilence(samples) else {
            var peak: Float = 0, sumSq: Float = 0
            for s in samples { let a = abs(s); if a > peak { peak = a }; sumSq += s * s }
            let rms = (sumSq / Float(max(samples.count, 1))).squareRoot()
            log.info("No speech energy in \(samples.count, privacy: .public) samples (peak \(peak, privacy: .public), rms \(rms, privacy: .public)), skipping decode (hallucination guard)")
            return ""
        }
        if trimmed.count < samples.count {
            let savedSec = Double(samples.count - trimmed.count) / 16000.0
            log.info("Trimmed \(savedSec, privacy: .public)s of silence (\(samples.count, privacy: .public) → \(trimmed.count, privacy: .public) samples)")
        }

        var options = Self.makeDecodingOptions()
        if let language {
            options.language = language
        } else if let detected = await resolveAutoLanguage(for: trimmed, pipeline: pipeline) {
            options.language = detected
        }
        // If detection failed outright, language stays nil (prefill falls back
        // to en). NEVER set options.detectLanguage: WhisperKit 0.18's
        // in-transcribe detection returns wrong languages (id/nl) even on
        // clean English audio, and the wrong prefill token then renders the
        // output in that language.

        let results = try await pipeline.transcribe(audioArray: trimmed, decodeOptions: options)
        let text = results.map { $0.text }.joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Auto language, resolved with the (accurate) dedicated detection API and
    // pinned per dictation session so streaming chunks can't diverge into
    // different languages. Detections too weak to pin (sub-second chunks,
    // low confidence) fall back to the last confident language — short quips
    // are almost always in the language you last dictated in.
    private var autoLanguage: String?
    private var lastConfidentLanguage: String?
    private var sessionToken = 0

    func beginDictationSession() {
        sessionToken += 1
        autoLanguage = nil
    }

    private func resolveAutoLanguage(for samples: [Float], pipeline: WhisperKit) async -> String? {
        if let autoLanguage { return autoLanguage }
        let token = sessionToken
        guard let detection = try? await pipeline.detectLangauge(audioArray: samples) else {
            return lastConfidentLanguage
        }
        let confidence = detection.langProbs[detection.language].map { exp(Double($0)) } ?? 0
        log.info("Auto language: '\(detection.language, privacy: .public)' confidence \(String(format: "%.2f", confidence), privacy: .public)")
        // Trust needs both gates: a 0.3s slice measured "vi" at 0.54
        // confidence, so confidence alone isn't enough.
        if confidence >= 0.5, samples.count >= 16000 {
            lastConfidentLanguage = detection.language
            // A session that began while this detection was in flight must not
            // inherit the pin (its own audio may be a different language).
            if token == sessionToken { autoLanguage = detection.language }
            return detection.language
        }
        return lastConfidentLanguage ?? detection.language
    }

    private static func makeDecodingOptions() -> DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        // The default windowClipTime (1.0) makes the decode loop skip audio
        // shorter than 1s ENTIRELY — every short dictation ("keep going")
        // returned deterministically empty. Its anti-hallucination job is
        // covered by our own speechless-audio guard, so turn it off.
        options.windowClipTime = 0
        return options
    }

    /// Trim leading/trailing silence based on 10ms RMS frames. Keeps 100ms of head/tail
    /// margin so we don't clip onset consonants or trailing breath. Returns nil when no
    /// frame rises above the speech threshold: decoding speechless audio is Whisper's
    /// number one hallucination trigger ("Thank you.").
    private static func trimSilence(_ samples: [Float]) -> [Float]? {
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

        if firstVoiced < 0 { return nil }
        guard samples.count > 3200 else { return samples }  // too short to bother trimming

        let startFrame = max(0, firstVoiced - marginFrames)
        let endFrame = min(frameCount - 1, lastVoiced + marginFrames)
        let startSample = startFrame * frameSize
        let endSample = (endFrame + 1) * frameSize
        return Array(samples[startSample..<endSample])
    }
}
