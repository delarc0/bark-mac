import AVFoundation
import BarkCapture
import BarkCore
import BarkEngine
import os

/// Hotkey to text at the cursor: press starts capture into a DictationSession, release finishes
/// it, cleans the text and pastes. Audio and text stay in memory.
@MainActor
final class Dictation {
    enum State { case idle, recording, transcribing }

    static let minimumHold: Duration = .milliseconds(200)
    /// A release can be swallowed (screen lock, secure input, a disabled tap).
    static let maximumHold: Duration = .seconds(300)

    let hotkey = HotkeyMonitor()
    let capture = MicCapture()
    private(set) var state = State.idle {
        didSet {
            // Every path back to idle passes here, so the clipboard copy never outlives a dictation.
            if state == .idle { Paste.discardSnapshot() }
            onStateChange?(state)
        }
    }

    var onStateChange: ((State) -> Void)?
    var onDeadInput: ((String) -> Void)?
    var onNothingHeard: (() -> Void)?
    var onSuccess: (() -> Void)?
    /// The overlay while waiting on the model: spinner, or spinner and percentage on a download.
    var onWaiting: ((Double?) -> Void)?

    private let settings: AppSettings
    private let models: Models
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Dictation")
    private var pressedAt: ContinuousClock.Instant?
    private var feeder: Task<Pending, Never>?
    private var hardStop: Task<Void, Never>?
    private var awaitingMicGrant = false

    /// What the capture produced: the session if it already started, plus audio it has not seen.
    private struct Pending {
        var session: DictationSession?
        var samples: [Float] = []
    }

    init(settings: AppSettings, models: Models) {
        self.settings = settings
        self.models = models
        hotkey.onEvent = { [weak self] event in
            switch event {
            case .pressed: self?.pressed()
            case .released: self?.released()
            }
        }
    }

    private func pressed() {
        guard state == .idle else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // First press ever: ask, and start if the key is still down when the grant lands.
            awaitingMicGrant = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self, granted, self.awaitingMicGrant, self.hotkey.isHeld else { return }
                    self.awaitingMicGrant = false
                    self.pressed()
                }
            }
            return
        default:
            log.error("Microphone access denied")
            Sounds.shared.playError()
            return
        }

        let stream: AsyncStream<[Float]>
        do {
            stream = try capture.start(deviceUID: settings.inputDeviceUID)
        } catch {
            log.error("Capture failed to start: \(String(describing: error), privacy: .public)")
            Sounds.shared.playError()
            return
        }
        let start = ContinuousClock.now
        pressedAt = start
        state = .recording
        Sounds.shared.playStart()
        feeder = Task { [models, settings] in
            var pending = Pending()
            for await chunk in stream {
                if let session = pending.session {
                    await session.feed(chunk)
                    continue
                }
                pending.samples += chunk
                // No session for an accidental tap: one only starts once the hold counts.
                guard ContinuousClock.now - start >= Self.minimumHold, let transcriber = models.readyTranscriber,
                      let session = try? await Self.session(on: transcriber, settings) else { continue }
                await session.feed(pending.samples)
                pending = Pending(session: session)
            }
            return pending
        }
        hardStop = Task { [weak self] in
            try? await Task.sleep(for: Self.maximumHold)
            guard !Task.isCancelled, let self, self.pressedAt == start else { return }
            self.log.warning("Maximum dictation length reached, stopping")
            self.released()
        }
    }

    private func released() {
        awaitingMicGrant = false
        guard state == .recording, let pressedAt, let feeder else { return }
        hardStop?.cancel()
        hardStop = nil
        self.pressedAt = nil
        self.feeder = nil
        let held = ContinuousClock.now - pressedAt
        let health = capture.stop()
        Task { await finish(feeder.value, held: held, health: health) }
    }

    private func finish(_ pending: Pending, held: Duration, health: InputHealth) async {
        func discard() {
            if let session = pending.session { Task { await session.cancel() } }
            state = .idle
        }
        guard held >= Self.minimumHold else {
            log.info("Tap shorter than the minimum hold, ignored")
            return discard()
        }
        switch health {
        case .noCallbacks:
            log.warning("The input delivered no audio callbacks; the device was probably still starting")
            Sounds.shared.playError()
            return discard()
        case .silent:
            log.error("The input delivered only digital silence")
            Sounds.shared.playError()
            discard()
            let name = settings.inputDeviceUID.flatMap { AudioInputs.device(uid: $0)?.name } ?? AudioInputs.defaultInput()?.name
            onDeadInput?(name ?? "the selected microphone")
            return
        case .ok:
            break
        }

        state = .transcribing
        Sounds.shared.playStop()
        Paste.prepareSnapshot()
        var session = pending.session
        if session == nil {
            let waiting = Task { [weak self, models] in
                while !Task.isCancelled {
                    self?.onWaiting?(models.download)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            if let transcriber = await models.waitForTranscriber() {
                session = try? await Self.session(on: transcriber, settings)
            }
            waiting.cancel()
            await session?.feed(pending.samples)
        }
        guard let session else {
            log.error("No model to transcribe with")
            Sounds.shared.playError()
            state = .idle
            return
        }

        let result = await session.finish()
        let lossy = result.segments.contains(where: \.failed)
        log.info("Dictation: \(result.segments.count, privacy: .public) segments, model \(result.model?.rawValue ?? "none", privacy: .public), \(result.language ?? "-", privacy: .public), release to text \(result.releaseToFinal, format: .fixed(precision: 2), privacy: .public) s")
        if result.text.isEmpty {
            Sounds.shared.playError()
            if !lossy { onNothingHeard?() }
        } else {
            History.shared.add(result.text)
            Paste.paste(result.text)
            // A dictation with a lost segment still pastes what it has, without the done chime.
            if lossy {
                Sounds.shared.playError()
            } else {
                Sounds.shared.playDone()
                onSuccess?()
            }
        }
        state = .idle
    }

    private static func session(on transcriber: Transcriber, _ settings: AppSettings) async throws -> DictationSession {
        try await transcriber.makeSession(language: settings.language, cleanup: settings.cleanupEnabled,
                                          vocabulary: settings.vocabulary)
    }
}

/// The last few dictations, in memory only, so a paste that landed in the wrong window is not lost.
@MainActor
final class History {
    static let shared = History()
    private(set) var entries: [String] = []

    func add(_ text: String) {
        entries.insert(text, at: 0)
        entries = Array(entries.prefix(10))
    }
}
