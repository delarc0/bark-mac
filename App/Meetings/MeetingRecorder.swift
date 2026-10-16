import AVFoundation
import AppKit
import BarkCapture
import BarkCore
import BarkEngine
import BarkStore
import IOKit.pwr_mgt
import os

/// One meeting at a time: CallCapture feeds a MeetingSession until Stop. Only an explicit Start
/// records. Idle sleep is held off while recording; a real sleep stops capture with a gap marker
/// and wake rebuilds it into the same meeting.
@MainActor
final class MeetingRecorder {
    enum State: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case finishing
    }

    private(set) var state = State.idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?
    var onMessage: ((PanelMessage) -> Void)?
    /// For the next meeting only; back to automatic once one starts.
    var nextMode = MeetingModeChoice.automatic
    let notes = NotesModel()
    private(set) var plan: MeetingCapturePlan?

    private let settings: AppSettings
    private let models: Models
    private let library: MeetingLibrary
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Meeting")
    private var session: MeetingSession?
    private var paired = false
    private var capture: CallCapture?
    private var consumer: Task<Void, Never>?
    private var asleep = false
    private var assertion: IOPMAssertionID?
    // Start, stop, sleep and wake run one after another, never interleaved.
    private var lifecycle: Task<Void, Never>?
    private var warnedTapSilent = false
    private var warnedDeadMic = false
    private var warnedDisk = false

    init(settings: AppSettings, models: Models, library: MeetingLibrary) {
        self.settings = settings
        self.models = models
        self.library = library
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    var meetingID: UUID? { session?.id }

    /// What Start would record right now: a detected call unless the user picked otherwise.
    func upcomingPlan() -> MeetingCapturePlan {
        .plan(nextMode, processes: AudioApps.running(), appName: AudioApps.localizedName(forPID:))
    }

    /// `callApp` is the call an offer was accepted for; otherwise the plan follows `nextMode`.
    func start(callApp: CallApp? = nil) {
        guard state == .idle else { return }
        let processes = AudioApps.running()
        let offered = callApp.map { CallApps.processes(of: $0, in: processes).map(\.pid) } ?? []
        // An offer accepted after its call ended falls back to the usual pick.
        let plan = callApp.flatMap { offered.isEmpty ? nil : MeetingCapturePlan.app($0, pids: offered) }
            ?? .plan(nextMode, processes: processes, appName: AudioApps.localizedName(forPID:))
        let language = settings.nextMeetingLanguage
        state = .starting
        serially { await self.begin(plan, language: language) }
    }

    /// Stops and finishes the meeting. The returned task ends once it is done.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        guard case .recording = state else { return nil }
        state = .finishing
        return serially { await self.finish() }
    }

    /// The work that finishes the current meeting, started if needed; nil when none is recording.
    func finishForQuit() -> Task<Void, Never>? {
        switch state {
        case .recording: stop()
        case .finishing: lifecycle
        case .idle, .starting: nil
        }
    }

    @discardableResult
    private func serially(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = lifecycle
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        lifecycle = task
        return task
    }

    // MARK: Start and finish

    private func begin(_ plan: MeetingCapturePlan, language: String) async {
        guard await Self.microphoneGranted() else {
            state = .idle
            return say(PanelMessage(title: "Bark can't use the microphone",
                                    detail: "Allow Bark under Privacy & Security, Microphone, then start the meeting again.",
                                    action: ("Open System Settings", { SystemSettings.open(.microphone) })))
        }
        guard let transcriber = await transcriber() else {
            state = .idle
            return say(PanelMessage(title: "The voice model isn't ready",
                                    detail: "Bark needs its voice model to record a meeting.",
                                    action: ("Show Model", { OnboardingWindowController.shared.present(at: .done) })))
        }
        guard let store = library.store else {
            state = .idle
            return say(PanelMessage(title: "Bark can't open its meeting library",
                                    detail: "Meetings are stored in Library/Application Support/Bark/Meetings."))
        }
        let paired = plan != .microphone
        let events: AsyncStream<CallCapture.Event>
        let capture = CallCapture()
        do {
            events = try capture.start(mode: Self.captureMode(plan), micUID: settings.inputDeviceUID,
                                       echoCancellation: settings.echoCancellation)
        } catch {
            log.error("Meeting capture failed to start: \(String(describing: error), privacy: .public)")
            state = .idle
            return say(PanelMessage(title: "Bark couldn't start recording", detail: String(describing: error)))
        }
        let session: MeetingSession
        do {
            session = try await MeetingSession.start(store: store, transcriber: transcriber, language: language,
                                                     mode: paired ? .call : .inPerson, streams: paired ? [.me, .them] : [.room])
        } catch {
            await capture.stop()
            log.error("Meeting failed to start: \(String(describing: error), privacy: .public)")
            state = .idle
            return say(PanelMessage(title: "Bark couldn't start the meeting", detail: String(describing: error)))
        }
        self.session = session
        self.paired = paired
        self.plan = plan
        attach(capture, events)
        settings.meetingLanguage = language
        nextMode = .automatic
        warnedTapSilent = false
        warnedDeadMic = false
        warnedDisk = false
        holdIdleSleep()
        notes.begin(session.id, store: store)
        log.info("Meeting \(session.id, privacy: .public) started: \(String(describing: plan), privacy: .public), \(language, privacy: .public)")
        state = .recording(since: .now)
        library.notifyChanged()
    }

    private func finish() async {
        await detach()
        notes.end()
        releaseIdleSleep()
        asleep = false
        guard let session else {
            state = .idle
            return
        }
        self.session = nil
        plan = nil
        do {
            let result = try await session.finish()
            log.info("Meeting \(session.id, privacy: .public) done: \(result.segments, privacy: .public) segments, \(result.finishToDone, format: .fixed(precision: 2), privacy: .public) s to done")
            library.diarize()
        } catch {
            // Left transcribing: the next launch recovers it from its audio.
            log.error("Meeting \(session.id, privacy: .public) did not finish: \(String(describing: error), privacy: .public)")
            say(PanelMessage(title: "The meeting didn't finish transcribing",
                             detail: "Its audio is saved. Bark finishes it the next time it starts."))
        }
        state = .idle
        library.notifyChanged()
        library.hq.sync()
    }

    // MARK: Capture

    private func attach(_ capture: CallCapture, _ events: AsyncStream<CallCapture.Event>) {
        guard let session else { return }
        let paired = paired
        self.capture = capture
        consumer = Task { [weak self] in
            for await event in events {
                await self?.handle(event, session: session, paired: paired)
            }
        }
    }

    /// Stops capture and waits until every block it delivered has been fed.
    private func detach() async {
        guard let capture else { return }
        self.capture = nil
        await capture.stop()
        await consumer?.value
        consumer = nil
    }

    private func handle(_ event: CallCapture.Event, session: MeetingSession, paired: Bool) async {
        switch event {
        case .audio(let me, let them):
            do {
                if paired {
                    try await session.feed(me, stream: .me)
                    // Mic only after a wake that found the call app gone: silence keeps the streams aligned.
                    try await session.feed(them.isEmpty ? [Float](repeating: 0, count: me.count) : them, stream: .them)
                } else {
                    try await session.feed(me, stream: .room)
                }
            } catch {
                log.error("Meeting audio not written: \(String(describing: error), privacy: .public)")
                guard !warnedDisk else { return }
                warnedDisk = true
                say(PanelMessage(title: "Bark can't save the meeting audio", detail: "The disk may be full. Free up space to keep recording."))
            }
        case .gap(let reason):
            do {
                try await session.markGap(reason: reason)
            } catch {
                log.error("Gap not recorded: \(String(describing: error), privacy: .public)")
            }
        case .tapSilent:
            guard !warnedTapSilent else { return }
            warnedTapSilent = true
            say(PanelMessage(title: "No call audio",
                             detail: "Allow Bark to record system audio in System Settings.",
                             action: ("Open System Settings", { SystemSettings.open(.systemAudio) })))
        case .micHealth(.silent):
            guard !warnedDeadMic else { return }
            warnedDeadMic = true
            let name = settings.inputDeviceUID.flatMap { AudioInputs.device(uid: $0)?.name } ?? AudioInputs.defaultInput()?.name
            say(PanelMessage(title: "Bark hears nothing from \(name ?? "the microphone")",
                             detail: "Bark's microphone access may have been revoked, or the input is muted or unplugged.",
                             action: ("Open Microphone Settings", { SystemSettings.open(.microphone) })))
        case .micHealth:
            break
        }
    }

    private static func captureMode(_ plan: MeetingCapturePlan) -> CallCapture.Mode {
        switch plan {
        case .app(_, let pids): .call(.processes(pids))
        case .allSystemAudio: .call(.global)
        case .microphone: .inPerson
        }
    }

    // MARK: Sleep

    private func willSleep() {
        guard case .recording = state else { return }
        serially {
            guard let session = self.session, !self.asleep else { return }
            await self.detach()
            self.asleep = true
            do {
                try await session.markGap(reason: "sleep")
            } catch {
                self.log.error("Sleep gap not recorded: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func didWake() {
        serially {
            guard self.asleep, self.session != nil, case .recording = self.state else { return }
            self.asleep = false
            self.resumeAfterWake()
        }
    }

    /// The call app's processes are found again (they may have changed); without them the meeting
    /// carries on mic only, its call stream filled with silence.
    private func resumeAfterWake() {
        var mode = CallCapture.Mode.inPerson
        switch plan {
        case .app(let app, _):
            let pids = CallApps.processes(of: app, in: AudioApps.running()).map(\.pid)
            if !pids.isEmpty { mode = .call(.processes(pids)) }
        case .allSystemAudio: mode = .call(.global)
        case .microphone, nil: break
        }
        for candidate in mode == .inPerson ? [mode] : [mode, .inPerson] {
            let capture = CallCapture()
            do {
                let events = try capture.start(mode: candidate, micUID: settings.inputDeviceUID,
                                               echoCancellation: settings.echoCancellation)
                attach(capture, events)
                log.info("Meeting capture rebuilt after wake")
                return
            } catch {
                log.error("Meeting capture failed after wake: \(String(describing: error), privacy: .public)")
            }
        }
        say(PanelMessage(title: "Bark couldn't resume recording after sleep",
                         detail: "The meeting so far is saved and transcribed."))
        state = .finishing
        serially { await self.finish() }
    }

    private func holdIdleSleep() {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Bark is recording a meeting" as CFString, &id)
        if result == kIOReturnSuccess {
            assertion = id
        } else {
            log.error("Could not hold off idle sleep (\(result, privacy: .public))")
        }
    }

    private func releaseIdleSleep() {
        guard let assertion else { return }
        IOPMAssertionRelease(assertion)
        self.assertion = nil
    }

    // MARK: Helpers

    private func say(_ message: PanelMessage) {
        onMessage?(message)
    }

    /// Waits only for a model that is loading; a missing one is reported at once.
    private func transcriber() async -> Transcriber? {
        if let ready = models.readyTranscriber { return ready }
        guard models.state == .loading else { return nil }
        return await models.waitForTranscriber()
    }

    private static func microphoneGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
