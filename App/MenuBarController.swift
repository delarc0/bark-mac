import AVFoundation
import AppKit
import BarkCapture
import BarkCore
import os

/// The status item and its menu, and the glue between dictation, models, overlay and windows.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "MenuBar")
    private let settings = AppSettings.shared
    private let models = Models.shared
    private let dictation: Dictation
    let recorder: MeetingRecorder
    private let watcher = CallWatcher()
    private var panel: MenuBarPanel!
    private var meetingStartedFromOffer = false
    private let overlay: OverlayController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var axTimer: Timer?
    // Each explanation shows once per launch: the condition persists across presses, and an
    // alert on every press would be worse than the silence it explains.
    private var warnedDeadInput = false
    private var warnedNothingHeard = false

    override init() {
        dictation = Dictation(settings: .shared, models: .shared)
        let capture = dictation.capture
        overlay = OverlayController(settings: .shared) { capture.level }
        recorder = MeetingRecorder(settings: .shared, models: .shared, library: .shared)
        super.init()
        panel = MenuBarPanel { [weak self] in self?.statusItem.button?.window?.frame }
        NotebookWindowController.shared.connect(recorder)
        recorder.onStateChange = { [weak self] state in self?.meetingChanged(state) }
        recorder.onMessage = { [weak self] message in self?.panel.show(message) }
        watcher.onChange = { [weak self] change in self?.callChanged(change) }

        dictation.onStateChange = { [weak self] state in self?.dictationChanged(state) }
        dictation.onWaiting = { [weak self] download in
            self?.overlay.show(download.map(OverlayIndicator.downloading) ?? .transcribing)
        }
        dictation.onDeadInput = { [weak self] name in self?.explainDeadInput(name) }
        dictation.onNothingHeard = { [weak self] in self?.explainNothingHeard() }
        // A dictation that worked proves the input; a later failure deserves its explanation again.
        dictation.onSuccess = { [weak self] in
            self?.warnedDeadInput = false
            self?.warnedNothingHeard = false
        }
        settings.onHotkeyChange = { [weak self] in self?.armHotkey() }
        NotificationCenter.default.addObserver(forName: HotkeyRecorder.listeningChanged, object: nil, queue: .main) { [weak self] note in
            let listening = note.object as? Bool == true
            MainActor.assumeIsolated {
                // The key being captured must not also start a dictation on the old mapping.
                if listening { self?.dictation.hotkey.stop() } else { self?.armHotkey() }
            }
        }

        menu.delegate = self
        statusItem.menu = menu
        updateButton()
        rebuildMenu()
        armHotkey()
        #if SPARKLE
        _ = Updater.shared
        #endif
        models.load()
        // As 0.2.x did on first launch; once per launch, so a failing network is not retried in a loop.
        models.downloadMissing()
        MeetingLibrary.shared.launch(models: models, settings: settings)
        watcher.resume()

        if !settings.onboardingCompleted {
            DispatchQueue.main.async { OnboardingWindowController.shared.present() }
        } else {
            recoverLostGrants()
        }
    }

    private func dictationChanged(_ state: Dictation.State) {
        updateButton()
        switch state {
        case .idle: overlay.hide()
        case .recording: overlay.show(.recording)
        case .transcribing: overlay.show(.transcribing)
        }
    }

    // MARK: Meetings

    private func meetingChanged(_ state: MeetingRecorder.State) {
        updateButton()
        NotebookWindowController.shared.recorderChanged(state)
        switch state {
        case .recording:
            watcher.pause()
            if panel.isShowingOffer { panel.hide() }
            NotebookWindowController.shared.present(selecting: recorder.meetingID,
                                                   activating: !meetingStartedFromOffer, focusNotes: true)
            meetingStartedFromOffer = false
        case .finishing:
            break
        case .idle:
            meetingStartedFromOffer = false
            watcher.resume()
        case .starting:
            break
        }
    }

    private func callChanged(_ change: CallOffers.Change) {
        switch change {
        case .offer(let app):
            guard recorder.state == .idle else { return }
            panel.show(PanelMessage(title: "Record this call?", detail: Self.describe(app),
                                    action: ("Record", { [weak self] in self?.startOfferedMeeting(app) }),
                                    dismissTitle: "Not Now"), offer: true)
        case .withdraw:
            if panel.isShowingOffer { panel.hide() }
        case .none:
            break
        }
    }

    private func startOfferedMeeting(_ app: CallApp) {
        meetingStartedFromOffer = true
        recorder.start(callApp: app)
    }

    /// A browser is tapped whole, every tab, and the user has to know that before recording.
    private static func describe(_ app: CallApp) -> String {
        app.capturesAllTabs ? "\(app.name): all of its tabs are recorded, not only the call." : app.name
    }

    private static func describe(_ plan: MeetingCapturePlan) -> String {
        switch plan {
        case .app(let app, _): app.capturesAllTabs ? "\(app.name), all tabs recorded" : "\(app.name) call"
        case .allSystemAudio: "Call, all system audio"
        case .microphone: "In person, microphone only"
        }
    }

    // MARK: Hotkey and Accessibility

    private func armHotkey() {
        if dictation.hotkey.start(settings.hotkey) {
            settings.axWasGranted = true
            axTimer?.invalidate()
            axTimer = nil
        } else if axTimer == nil {
            log.info("Accessibility not granted; waiting for it")
            // No deadline: granting can take minutes, and until then Bark cannot work at all.
            // Common mode, so it also fires while the menu is open on the Accessibility hint.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, HotkeyMonitor.isTrusted else { return }
                    self.log.info("Accessibility granted, arming the hotkey")
                    self.armHotkey()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            axTimer = timer
        }
    }

    /// A re-signed build silently loses its TCC grants (System Settings can even still show them
    /// on). Walk the user back through the onboarding steps instead of sitting there doing nothing.
    private func recoverLostGrants() {
        let ax = HotkeyMonitor.isTrusted
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axLost = !ax && settings.axWasGranted
        let micLost = !mic && settings.micWasGranted
        if ax { settings.axWasGranted = true }
        if mic { settings.micWasGranted = true }
        guard axLost || micLost else { return }
        settings.axWasGranted = ax
        settings.micWasGranted = mic
        log.warning("Grants lost since the last run (accessibility \(axLost, privacy: .public), microphone \(micLost, privacy: .public))")
        // The microphone step comes first, so starting there covers both.
        DispatchQueue.main.async {
            OnboardingWindowController.shared.present(at: micLost ? .mic : .accessibility)
        }
    }

    // MARK: Explanations

    private func explainDeadInput(_ device: String) {
        guard !warnedDeadInput else { return }
        warnedDeadInput = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Bark heard nothing from \(device)"
        alert.informativeText = """
            The recording contained no audio at all. Usually one of:

            • Bark's microphone access was revoked. Even if System Settings shows it enabled, switch it off and on again.
            • \(device) is muted, unplugged, or its gain is down.
            • A different input is selected than the one you speak into (Settings → Audio).
            """
        alert.addButton(withTitle: "Open Microphone Settings")
        alert.addButton(withTitle: "Bark Settings")
        alert.addButton(withTitle: "Dismiss")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: SystemSettings.open(.microphone)
        case .alertSecondButtonReturn: SettingsWindowController.shared.present()
        default: break
        }
    }

    private func explainNothingHeard() {
        guard !warnedNothingHeard else { return }
        warnedNothingHeard = true
        let alert = NSAlert()
        alert.messageText = "That was too quiet to transcribe"
        alert.informativeText = "Bark captured audio, but the level was too low for speech recognition. Turn up the gain on your microphone, move closer to it, or pick a different input under Settings → Audio."
        alert.addButton(withTitle: "Bark Settings")
        alert.addButton(withTitle: "Dismiss")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            SettingsWindowController.shared.present()
        }
    }

    // MARK: Status item

    /// Dictation shows over a meeting: it is the shorter, more urgent state.
    private func updateButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        switch dictation.state {
        case .recording:
            button.toolTip = "Bark: recording"
            button.image = Self.recordingDot
        case .transcribing:
            // Without this an overlay-off user gets no feedback after release.
            button.toolTip = "Bark: transcribing"
            button.image = Self.transcribingDot
        case .idle where recorder.state != .idle:
            if case .recording = recorder.state {
                button.toolTip = "Bark: recording a meeting"
                button.image = Self.meetingRing
            } else {
                button.toolTip = recorder.state == .starting ? "Bark: starting a meeting" : "Bark: finishing the meeting"
                button.image = Self.transcribingDot
            }
        case .idle:
            button.toolTip = "Bark: local dictation"
            button.image = Self.icon
            if Self.icon == nil { button.title = "Bark" }
        }
    }

    private static let icon: NSImage? = {
        guard let image = NSImage(named: "Icon")?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 20, height: 20)
        return image
    }()

    private static let recordingDot = dot(NSColor(BarkPalette.recordingRed))
    private static let transcribingDot = dot(NSColor(BarkPalette.transcribingAmber))

    // A ring around the dot, so a meeting reads apart from a dictation at a glance.
    private static let meetingRing = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
        let red = NSColor(BarkPalette.recordingRed)
        red.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 1.75, y: 1.75, width: 12.5, height: 12.5))
        ring.lineWidth = 1.5
        ring.stroke()
        red.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 6, height: 6)).fill()
        return true
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 10, height: 10)).fill()
            return true
        }
    }

    // MARK: Menu

    // Rebuilt on every open: devices come and go, and the history and model state change.
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuildMenu() }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        menu.addItem(disabled("\(Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Bark") v\(version)"))
        menu.addItem(.separator())

        if HotkeyMonitor.isTrusted {
            menu.addItem(disabled("Hold \(settings.hotkey.name) to dictate"))
        } else {
            menu.addItem(item("Grant Accessibility permission…", #selector(grantAccessibility)))
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            menu.addItem(item("Grant Microphone access…", #selector(grantMicrophone)))
        }
        if let line = modelLine() { menu.addItem(line) }
        menu.addItem(.separator())

        meetingItems().forEach(menu.addItem)
        menu.addItem(.separator())

        menu.addItem(historyItem())
        menu.addItem(devicesItem())
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Show Onboarding…", #selector(openOnboarding)))
        #if SPARKLE
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = Updater.shared
        menu.addItem(updates)
        #endif
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func modelLine() -> NSMenuItem? {
        if let download = models.download {
            return disabled("Downloading voice model… \(Int(download * 100))%")
        }
        switch models.state {
        case .ready: return nil
        case .loading: return disabled("Loading model…")
        case .missing: return item("Voice model not installed…", #selector(openModels))
        case .failed: return item("Model failed to load: Retry", #selector(retryModels))
        }
    }

    private func meetingItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        switch recorder.state {
        case .idle:
            let start = item("Start Meeting", #selector(startMeeting))
            start.subtitle = "\(Self.describe(recorder.upcomingPlan())) · \(Languages.name(settings.nextMeetingLanguage))"
            items += [start, nextMeetingItem()]
        case .starting:
            items.append(disabled("Starting meeting…"))
        case .recording(let since):
            let stop = item("Stop Meeting", #selector(stopMeeting))
            stop.subtitle = "Recording \(TranscriptText.timestamp(Date.now.timeIntervalSince(since)))"
            items += [stop, item("Show Notes", #selector(showNotes))]
        case .finishing:
            items.append(disabled("Finishing meeting…"))
        }
        items.append(item("Meetings…", #selector(openMeetings)))
        return items
    }

    private func nextMeetingItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Next Meeting", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(.sectionHeader(title: "Language"))
        let current = settings.nextMeetingLanguage
        for language in Languages.common {
            let row = item(language.label, #selector(pickMeetingLanguage(_:)))
            row.representedObject = language.code
            row.state = language.code == current ? .on : .off
            submenu.addItem(row)
        }
        submenu.addItem(.separator())
        submenu.addItem(.sectionHeader(title: "Audio"))
        let modes: [(MeetingModeChoice, String)] = [(.automatic, "Automatic"), (.call, "Call"), (.inPerson, "In Person")]
        for (mode, title) in modes {
            let row = item(title, #selector(pickMeetingMode(_:)))
            row.representedObject = mode.rawValue
            row.state = recorder.nextMode == mode ? .on : .off
            switch mode {
            case .automatic: row.subtitle = "Records a call when one is detected"
            case .call: row.subtitle = "Microphone and the call's audio"
            case .inPerson: row.subtitle = "Microphone only"
            }
            submenu.addItem(row)
        }
        parent.submenu = submenu
        return parent
    }

    private func historyItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Copy Recent", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if History.shared.entries.isEmpty { submenu.addItem(disabled("Nothing yet")) }
        for text in History.shared.entries {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            let row = item(flat.count > 48 ? String(flat.prefix(48)) + "…" : flat, #selector(copyEntry(_:)))
            row.representedObject = text
            row.toolTip = text
            submenu.addItem(row)
        }
        parent.submenu = submenu
        return parent
    }

    private func devicesItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let systemDefault = item("System default", #selector(pickDevice(_:)))
        systemDefault.state = settings.inputDeviceUID == nil ? .on : .off
        submenu.addItem(systemDefault)
        submenu.addItem(.separator())
        for device in AudioInputs.all() {
            let row = item(device.label, #selector(pickDevice(_:)))
            row.representedObject = device.uid
            row.state = settings.inputDeviceUID == device.uid ? .on : .off
            submenu.addItem(row)
        }
        parent.submenu = submenu
        return parent
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func startMeeting() {
        panel.hide()
        meetingStartedFromOffer = false
        recorder.start()
    }

    @objc private func stopMeeting() {
        recorder.stop()
    }

    @objc private func showNotes() {
        NotebookWindowController.shared.present(selecting: recorder.meetingID, focusNotes: true)
    }

    @objc private func openMeetings() {
        NotebookWindowController.shared.present(selecting: recorder.meetingID)
    }

    @objc private func pickMeetingLanguage(_ sender: NSMenuItem) {
        settings.meetingLanguage = sender.representedObject as? String
    }

    @objc private func pickMeetingMode(_ sender: NSMenuItem) {
        recorder.nextMode = (sender.representedObject as? String).flatMap(MeetingModeChoice.init(rawValue:)) ?? .automatic
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        // Never restored, so the concealed marker is all that keeps it out of clipboard histories.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([Paste.concealedItem(text)])
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        settings.inputDeviceUID = sender.representedObject as? String
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.present()
    }

    @objc private func openOnboarding() {
        OnboardingWindowController.shared.present()
    }

    @objc private func openModels() {
        OnboardingWindowController.shared.present(at: .done)
    }

    @objc private func retryModels() {
        models.load()
        // As 0.2.x did on first launch; once per launch, so a failing network is not retried in a loop.
        models.downloadMissing()
    }

    @objc private func grantMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            SystemSettings.open(.microphone)
        }
    }

    @objc private func grantAccessibility() {
        SystemSettings.open(.accessibility)
        HotkeyMonitor.promptForTrust()
        armHotkey()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AudioInput {
    var label: String { "\(name)  (\(channels)ch @ \(Int(sampleRate))Hz)" }
}

enum SystemSettings {
    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        // Screen & System Audio Recording, which holds the system-audio-only list too.
        case systemAudio = "Privacy_ScreenCapture"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
