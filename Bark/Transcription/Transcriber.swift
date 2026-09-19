import Foundation
import WhisperKit
import os

// Shared between AppSettings (MainActor) and the Transcriber actor, which reads
// it via thread-safe UserDefaults during load().
let barkCpuOnlyDefaultsKey = "transcriber.cpuOnly"
let barkSwedishModelDefaultsKey = "transcriber.swedishModel"

actor Transcriber {

    enum State: Sendable {
        case unloaded
        case loading
        case downloading(Double)
        case ready
        case failed(String)
    }

    /// Which model answers for a given language. Measured on FLEURS (60 clips
    /// per language, M5 Pro): KB-Whisper cuts Swedish errors roughly in half
    /// (4.56% vs 8.43% WER), but is UNUSABLE on English (40.85%) because the
    /// Swedish fine-tune overrides the task and silently TRANSLATES English
    /// audio into Swedish. That asymmetry is why this routes instead of
    /// picking one model.
    enum ModelRole: Sendable, CaseIterable {
        case general
        case swedish

        /// WhisperKit resolves the tokenizer from the model NAME, separately
        /// from where the weights are loaded. KB-Whisper kept Whisper's own
        /// tokenizer, so it loads correctly under the large-v3 name.
        var tokenizerVariant: String { "openai_whisper-large-v3" }

        /// Our own CoreML conversion of KBLab's official checkpoint, produced
        /// with whisperkittools and verified to match the reference output.
        /// A signed product does not ship third-party community weights.
        var repo: String {
            switch self {
            case .general: "argmaxinc/whisperkit-coreml"
            case .swedish: "lab37/kb-whisper-coreml"
            }
        }

        var variant: String {
            switch self {
            case .general: "openai_whisper-large-v3"
            case .swedish: "kb_whisper-large"
            }
        }

        var label: String {
            switch self {
            case .general: "whisper-large-v3"
            case .swedish: "kb-whisper-large"
            }
        }
    }

    static func role(forLanguage language: String?) -> ModelRole {
        language == "sv" ? .swedish : .general
    }

    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Transcriber")
    private var pipelines: [ModelRole: WhisperKit] = [:]
    private(set) var state: State = .unloaded
    // Keyed by role, tagged with a registration token so a finishing load can
    // only retract its OWN entry. Without the token, a load that outlived a
    // self-heal would clear the replacement task registered after it, and the
    // next caller would start a duplicate WhisperKit init and model download.
    private var loadTasks: [ModelRole: (token: Int, task: Task<Void, Error>)] = [:]
    private var nextLoadToken = 0
    // Bumped whenever the compute path changes under us (the ANE self-heal).
    // A load that started before the switch must not install its pipeline
    // afterwards: it was built on the path we just abandoned.
    private var pipelineGeneration = 0
    private var onStateChanged: (@Sendable (State) -> Void)?

    init() {}

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
        try await load(role: .general)
    }

    /// Only the general model drives `state`: it is what gates dictation, and a
    /// Swedish model still loading in the background must never paint the UI as
    /// not-ready or, worse, as failed.
    private func load(role: ModelRole) async throws {
        if pipelines[role] != nil { return }
        // Single-flight: a transcribe arriving mid-load must join the in-flight
        // load, not kick off a second WhisperKit init (and model download).
        if let existing = loadTasks[role] {
            return try await existing.task.value
        }
        if role == .general { setState(.loading) }
        log.info("Loading \(role.label, privacy: .public)...")
        let generation = pipelineGeneration
        let task = Task { () throws in
            do {
                // Cached model: skip the Hub round-trip (keeps relaunches
                // working offline). A folder that exists but fails to load
                // (interrupted download) falls through to a repair download.
                if let local = Self.localModelFolder(for: role) {
                    do {
                        try await buildPipeline(role: role, modelFolder: local.path, generation: generation)
                        return
                    } catch {
                        log.error("Cached \(role.label, privacy: .public) failed to load (\(error.localizedDescription, privacy: .public)) — re-fetching")
                    }
                }
                let folder = try await downloadModel(role: role)
                if role == .general { setState(.loading) }
                try await buildPipeline(role: role, modelFolder: folder.path, generation: generation)
            } catch {
                if role == .general { setState(.failed(error.localizedDescription)) }
                log.error("\(role.label, privacy: .public) load failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        nextLoadToken += 1
        let token = nextLoadToken
        loadTasks[role] = (token: token, task: task)
        defer { if loadTasks[role]?.token == token { loadTasks[role] = nil } }
        try await task.value
    }

    /// Warms the Swedish model after the general one is up. Deliberately NOT
    /// awaited by dictation: a first-ever KB load includes a one-time CoreML/ANE
    /// compile measured at ~239s, and making the first Swedish dictation wait for
    /// that is far worse than transcribing one clip on the general model.
    func prepareSwedishModel() async {
        guard Self.swedishModelEnabled() else { return }
        do {
            try await load(role: .swedish)
        } catch {
            log.error("Swedish model unavailable, staying on \(ModelRole.general.label, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static func swedishModelEnabled() -> Bool {
        (UserDefaults.standard.object(forKey: barkSwedishModelDefaultsKey) as? Bool) ?? true
    }

    private func buildPipeline(role: ModelRole, modelFolder: String, generation: Int) async throws {
        let config = WhisperKitConfig(model: role.tokenizerVariant,
                                      modelFolder: modelFolder,
                                      computeOptions: Self.resolvedCompute(),
                                      verbose: false,
                                      logLevel: .error,
                                      download: false)
        let kit = try await WhisperKit(config)
        guard generation == pipelineGeneration else {
            log.info("Discarding \(role.label, privacy: .public): compute path changed while it loaded")
            return
        }
        pipelines[role] = kit
        if role == .general { setState(.ready) }
        log.info("\(role.label, privacy: .public) ready.")
    }

    private func downloadModel(role: ModelRole) async throws -> URL {
        log.info("Downloading \(role.label, privacy: .public)...")
        // Only the general model reports download progress to the UI; the
        // Swedish one downloads in the background and must not repaint the
        // overlay mid-dictation.
        let reportsProgress = (role == .general)
        if reportsProgress {
            downloadActive = true
            lastLoggedDecile = -1
        }
        defer { if reportsProgress { downloadActive = false } }
        // Progress fires on a URLSession queue; throttle to whole-percent
        // steps before hopping onto the actor.
        let lastReported = OSAllocatedUnfairLock(initialState: -1.0)
        return try await WhisperKit.download(variant: role.variant, from: role.repo) { [weak self] progress in
            let fraction = progress.fractionCompleted
            let report = lastReported.withLock { (last: inout Double) -> Bool in
                guard fraction - last >= 0.01 else { return false }
                last = fraction
                return true
            }
            guard report, reportsProgress, let self else { return }
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

    private static func localModelFolder(for role: ModelRole) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let folder = docs.appendingPathComponent("huggingface/models/\(role.repo)/\(role.variant)")
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
        try await load(role: .general)
        guard let pipeline = pipelines[.general] else { return }
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
        pipelineGeneration += 1
        for entry in loadTasks.values { entry.task.cancel() }
        pipelines.removeAll()
        loadTasks.removeAll()
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
        try await load(role: .general)
        guard let general = pipelines[.general] else {
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

        // windowClipTime is 0 so short clips decode at all, which also means a
        // speechless sliver in the final 30s window gets decoded and is prime
        // hallucination material. Drop it when that is all it is.
        let decoded = Self.trimTrailingSliver(trimmed)

        // Detection always runs on the general model. KB-Whisper is a Swedish
        // fine-tune and is not a trustworthy judge of whether audio is Swedish.
        var resolved = language
        // An explicit language is the user's own instruction and is authoritative.
        var routable = (language != nil)
        if resolved == nil {
            let decision = await resolveAutoLanguage(for: decoded, pipeline: general)
            resolved = decision.language
            routable = decision.routable
        }

        var options = Self.makeDecodingOptions()
        options.language = resolved
        // If detection failed outright, language stays nil (prefill falls back
        // to en). NEVER set options.detectLanguage: the in-transcribe detection
        // returns wrong languages (id/nl) even on clean English audio, and the
        // wrong prefill token then renders the output in that language.
        // Re-verified against argmax-oss-swift 1.1.0.

        let role = routable ? Self.role(forLanguage: resolved) : .general
        let pipeline: WhisperKit
        if let routed = pipelines[role] {
            pipeline = routed
        } else {
            if role != .general {
                log.info("\(role.label, privacy: .public) not loaded yet — this clip runs on \(ModelRole.general.label, privacy: .public)")
            }
            pipeline = general
        }

        let results = try await pipeline.transcribe(audioArray: decoded, decodeOptions: options)
        let text = results.map { $0.text }.joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Auto language, resolved with the (accurate) dedicated detection API and
    // pinned per dictation session so streaming chunks can't diverge into
    // different languages. Detections too weak to pin (sub-second chunks,
    // low confidence) fall back to the last confident language — short quips
    // are almost always in the language you last dictated in.
    private var autoLanguage: String?
    private var autoLanguageRoutable = false
    private var lastConfidentLanguage: String?
    private var sessionToken = 0

    /// A language guess, plus whether it is strong enough to pick the MODEL.
    ///
    /// These are two different questions and conflating them is dangerous. A
    /// remembered language is fine for prefilling a multilingual model's first
    /// token: guess wrong and the general model still transcribes the words. It
    /// is NOT enough to switch to KB-Whisper, whose failure mode on non-Swedish
    /// audio is not degradation but silent TRANSLATION into Swedish. So routing
    /// demands fresh, long, confident evidence from THIS audio; everything else
    /// stays on the general model and merely borrows the language token.
    private struct LanguageDecision {
        let language: String?
        let routable: Bool
    }

    private static let routingConfidence = 0.85

    func beginDictationSession() {
        sessionToken += 1
        autoLanguage = nil
        autoLanguageRoutable = false
    }

    private func resolveAutoLanguage(for samples: [Float], pipeline: WhisperKit) async -> LanguageDecision {
        if let autoLanguage { return LanguageDecision(language: autoLanguage, routable: autoLanguageRoutable) }
        let token = sessionToken
        guard let detection = try? await pipeline.detectLangauge(audioArray: samples) else {
            return LanguageDecision(language: lastConfidentLanguage, routable: false)
        }
        let confidence = detection.langProbs[detection.language].map { exp(Double($0)) } ?? 0
        log.info("Auto language: '\(detection.language, privacy: .public)' confidence \(String(format: "%.2f", confidence), privacy: .public)")

        // Two separate questions. Long, confident audio may both be used and
        // pin the session. Short audio may still be USED when it is very sure
        // of itself — a 0.9s clip detected at 0.95 is better evidence than a
        // language remembered from an earlier dictation — but never pins, since
        // a 0.3s slice once measured "vi" at 0.54.
        let longEnough = samples.count >= 16000
        if longEnough, confidence >= 0.5 {
            lastConfidentLanguage = detection.language
            let routable = confidence >= Self.routingConfidence
            // A session that began while this detection was in flight must not
            // inherit the pin (its own audio may be a different language).
            if token == sessionToken {
                autoLanguage = detection.language
                autoLanguageRoutable = routable
            }
            return LanguageDecision(language: detection.language, routable: routable)
        }
        if confidence >= 0.9 { return LanguageDecision(language: detection.language, routable: false) }
        return LanguageDecision(language: lastConfidentLanguage ?? detection.language, routable: false)
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

    /// Whisper decodes in 30s windows. If the last window is under a second and
    /// holds no speech, hand it back trimmed: decoding a lone silent sliver is
    /// what produces a stray "Thank you." glued to the end of a transcript.
    private static func trimTrailingSliver(_ samples: [Float]) -> [Float] {
        let window = 30 * 16_000
        let remainder = samples.count % window
        guard remainder > 0, remainder < 16_000, samples.count > remainder else { return samples }
        let sliver = Array(samples[(samples.count - remainder)...])
        guard trimSilence(sliver) == nil else { return samples }
        return Array(samples[..<(samples.count - remainder)])
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
