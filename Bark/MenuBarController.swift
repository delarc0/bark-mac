import AppKit
import AVFoundation
import CoreAudio
import os

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "MenuBar")
    private let statusItem: NSStatusItem
    private let transcriber: Transcriber
    private let settings = AppSettings.shared
    private let dictation: DictationCoordinator
    private let overlay = OverlayController()
    private var dictationState: DictationCoordinator.State = .idle
    private var modelState: Transcriber.State = .unloaded
    private var axPollTimer: Timer?
    private let statusMenu = NSMenu()
    private var menuIsTracking = false
    private var lastHotkeyConfig: (keyCode: CGKeyCode, mask: UInt64) = (AppSettings.shared.hotkeyKeyCode,
                                                                        AppSettings.shared.hotkeyFlagMask)

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let rec: AudioRecorder?
        do {
            rec = try AudioRecorder()
        } catch {
            rec = nil
            Logger(subsystem: "se.lab37.bark.mac", category: "MenuBar")
                .error("AudioRecorder init failed — dictation disabled: \(error.localizedDescription, privacy: .public)")
        }
        transcriber = Transcriber(modelVariant: AppSettings.shared.modelVariant)
        dictation = DictationCoordinator(recorder: rec, transcriber: transcriber)
        super.init()

        dictation.deviceIDProvider = { [weak self] in
            guard let uid = self?.settings.inputDeviceUID else { return nil }
            return AudioDeviceCatalog.inputID(matching: uid)
        }
        dictation.onStateChanged = { [weak self] state in
            self?.handleDictationState(state)
        }
        dictation.onMicPermissionDenied = { [weak self] in
            self?.rebuildMenu()
        }

        dictation.onDeadInput = { [weak self] deviceName in
            self?.presentDeadInputAlert(deviceName: deviceName)
        }

        dictation.onQuietInput = { [weak self] in
            self?.presentQuietInputNotice()
        }

        dictation.onEmptyResult = { [weak self] in
            self?.presentQuietInputNotice()
        }

        // A dictation that worked proves the input is healthy, so a later
        // failure deserves its explanation again.
        dictation.onTranscriptionSucceeded = { [weak self] in
            self?.didWarnDeadInput = false
            self?.didWarnQuietInput = false
        }

        // Restart the hotkey tap only when the mapping itself changed — a restart
        // resets held-state, so unrelated settings changes mid-hold would orphan
        // the recording session.
        NotificationCenter.default.addObserver(
            forName: AppSettings.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let config = (self.settings.hotkeyKeyCode, self.settings.hotkeyFlagMask)
                if config != self.lastHotkeyConfig {
                    self.lastHotkeyConfig = config
                    self.dictation.hotkey.restart()
                }
                self.rebuildMenu()
            }
        }

        // Pause the global hotkey tap while the settings panel is capturing a key.
        NotificationCenter.default.addObserver(
            forName: HotkeyRecorder.listeningChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                if (note.object as? Bool) == true {
                    self.dictation.hotkey.stop()
                } else {
                    _ = self.dictation.hotkey.start()
                }
            }
        }

        statusMenu.delegate = self
        statusItem.menu = statusMenu
        configureButton()
        rebuildMenu()
        startHotkeyIfPossible(promptIfNeeded: false)

        _ = UpdaterController.shared

        if !settings.onboardingCompleted {
            DispatchQueue.main.async {
                OnboardingWindowController.shared.present()
            }
        } else {
            presentPermissionRecoveryIfNeeded()
        }

        Task.detached { [transcriber, log, weak self] in
            await transcriber.setStateObserver { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.modelState = state
                    ModelStatus.shared.state = state
                    self?.rebuildMenu()
                    self?.refreshOverlayForModelState()
                }
            }
            let t0 = Date()
            await transcriber.warmupSelfHealing()
            log.info("Eager load + warmup finished in \(Date().timeIntervalSince(t0), privacy: .public)s")
        }
    }

    deinit {
        axPollTimer?.invalidate()
    }

    private func handleDictationState(_ state: DictationCoordinator.State) {
        dictationState = state
        configureButton()
        switch state {
        case .idle:
            overlay.hide()
        case .recording:
            overlay.show(.recording)
        case .transcribing:
            overlay.show(overlayStateWhileTranscribing())
        }
    }

    // A dictation that lands before the model is on disk waits on the 1.5 GB
    // download — show that in the pill instead of an indefinite spinner.
    private func overlayStateWhileTranscribing() -> OverlayModel.State {
        if case .downloading(let fraction) = modelState {
            return .downloading(fraction)
        }
        return .transcribing
    }

    // Shown at most once per launch: the condition persists across attempts and
    // a dialog on every hotkey press would be worse than the silence it replaces.
    private var didWarnDeadInput = false
    private var didWarnQuietInput = false

    private func presentDeadInputAlert(deviceName: String) {
        guard !didWarnDeadInput else { return }
        didWarnDeadInput = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Bark heard nothing from \(deviceName)"
        alert.informativeText = """
            The recording contained no audio at all. Usually one of:

            • Bark's microphone access was revoked. Even if System Settings shows it enabled, switch it off and on again.
            • \(deviceName) is muted, unplugged, or its gain is down.
            • A different input is selected than the one you speak into (Settings → Audio).
            """
        alert.addButton(withTitle: "Open Microphone Settings")
        alert.addButton(withTitle: "Bark Settings")
        alert.addButton(withTitle: "Dismiss")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            SettingsWindowController.shared.present()
        default:
            break
        }
    }

    private func presentQuietInputNotice() {
        guard !didWarnQuietInput else { return }
        didWarnQuietInput = true
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "That was too quiet to transcribe"
        alert.informativeText = "Bark captured audio, but the level was too low for speech recognition. Turn up the gain on your microphone, move closer to it, or pick a different input under Settings → Audio."
        alert.addButton(withTitle: "Bark Settings")
        alert.addButton(withTitle: "Dismiss")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SettingsWindowController.shared.present()
        }
    }

    private func refreshOverlayForModelState() {
        guard dictationState == .transcribing else { return }
        overlay.show(overlayStateWhileTranscribing())
    }

    /// A rebuild re-signs the ad-hoc bundle, so macOS silently wipes TCC grants
    /// (the System Settings toggle can even still show "on" while being dead).
    /// Without this, the app just sits there doing nothing after every update.
    private func presentPermissionRecoveryIfNeeded() {
        let axNow = DictationCoordinator.hasAccessibilityPermission()
        let micNow = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if axNow { settings.axWasGranted = true }
        if micNow { settings.micWasGranted = true }

        let axLost = !axNow && settings.axWasGranted
        let micLost = !micNow && settings.micWasGranted
        guard axLost || micLost else { return }
        if axLost { settings.axWasGranted = false }
        if micLost { settings.micWasGranted = false }
        log.warning("Permission grant lost since last run (ax=\(axLost, privacy: .public) mic=\(micLost, privacy: .public)) — showing recovery")
        // A re-sign wipes both at once. The mic step precedes the accessibility
        // step, so starting at .mic walks the user through both in one pass.
        let step: OnboardingModel.Step = micLost ? .mic : .accessibility
        DispatchQueue.main.async {
            OnboardingWindowController.shared.present(at: step)
        }
    }

    private func startHotkeyIfPossible(promptIfNeeded: Bool) {
        if DictationCoordinator.hasAccessibilityPermission(prompt: promptIfNeeded) {
            _ = dictation.start()
            settings.axWasGranted = true
        } else {
            log.info("Accessibility permission not granted; hotkey disabled — polling for grant")
            startAXPolling()
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        switch dictationState {
        case .recording:
            button.toolTip = "Bark — recording…"
            button.image = Self.recordingIndicator
            button.title = ""
        case .transcribing:
            // Without this, overlay-off users get zero feedback after release.
            button.toolTip = "Bark — transcribing…"
            button.image = Self.transcribingIndicator
            button.title = ""
        case .idle:
            button.toolTip = "Bark — local dictation"
            if let icon = Self.statusIcon {
                button.image = icon
                button.title = ""
            } else {
                button.image = nil
                button.title = "Bark"
            }
        }
    }

    // Cached: configureButton runs on every state change (twice per dictation);
    // re-reading and re-decoding the PNG each time is wasted disk I/O.
    private static let statusIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = false
        return image
    }()

    private static let recordingIndicator = dotIndicator(BarkPalette.recordingRedNS)
    private static let transcribingIndicator = dotIndicator(BarkPalette.transcribingAmberNS)

    private static func dotIndicator(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        let rect = NSRect(x: 3, y: 3, width: 10, height: 10)
        NSBezierPath(ovalIn: rect).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // Devices come and go between menu opens; rebuild so the Input Device
    // submenu never shows an unplugged mic or misses a fresh one.
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            // Rebuild BEFORE raising the tracking flag — rebuildMenu() refuses
            // to run while tracking, so the old order made this a no-op and the
            // menu always showed last-closed state (stale devices, empty history).
            rebuildMenu()
            menuIsTracking = true
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated { menuIsTracking = false }
    }

    private func rebuildMenu() {
        // Observers (model state, settings) may fire while the menu is open;
        // mutating a tracking menu flickers or dismisses it. menuWillOpen
        // rebuilds fresh on the next open anyway.
        guard !menuIsTracking else { return }
        let menu = statusMenu
        menu.removeAllItems()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Bark v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let hasAX = DictationCoordinator.hasAccessibilityPermission()
        if hasAX {
            let status = NSMenuItem(title: "Hold \(settings.hotkeyDisplayName) to dictate",
                                    action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        } else {
            let status = NSMenuItem(title: "Grant Accessibility permission…",
                                    action: #selector(grantAccessibility),
                                    keyEquivalent: "")
            status.target = self
            menu.addItem(status)
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            let mic = NSMenuItem(title: "Grant Microphone access…",
                                 action: #selector(grantMicrophone),
                                 keyEquivalent: "")
            mic.target = self
            menu.addItem(mic)
        }

        switch modelState {
        case .unloaded, .loading:
            let item = NSMenuItem(title: "Loading model…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .downloading(let fraction):
            let item = NSMenuItem(title: "Downloading voice model… \(Int(fraction * 100))%",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .failed:
            let item = NSMenuItem(title: "Model failed to load — Retry",
                                  action: #selector(retryModelLoad),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        case .ready:
            break
        }
        menu.addItem(.separator())

        menu.addItem(recentTranscriptionsItem())
        menu.addItem(deviceMenuItem())
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let onboardingItem = NSMenuItem(title: "Show Onboarding…",
                                        action: #selector(openOnboarding),
                                        keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(UpdaterController.checkForUpdates(_:)),
                                     keyEquivalent: "")
        updatesItem.target = UpdaterController.shared
        menu.addItem(updatesItem)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)


    }

    private func deviceMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let systemDefaultItem = NSMenuItem(title: "System default", action: #selector(pickSystemDefault), keyEquivalent: "")
        systemDefaultItem.target = self
        systemDefaultItem.state = (settings.inputDeviceUID == nil) ? .on : .off
        submenu.addItem(systemDefaultItem)
        submenu.addItem(.separator())

        for device in AudioDeviceCatalog.listInputs() {
            let item = NSMenuItem(
                title: "\(device.name)  (\(device.inputChannels)ch @ \(Int(device.sampleRate))Hz)",
                action: #selector(pickDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uid
            item.state = (settings.inputDeviceUID == device.uid) ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
    }

    private func recentTranscriptionsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Copy Recent", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let entries = TranscriptionHistory.shared.entries
        if entries.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for entry in entries {
                let flat = entry.text.replacingOccurrences(of: "\n", with: " ")
                let preview = flat.count > 48 ? String(flat.prefix(48)) + "…" : flat
                let row = NSMenuItem(title: preview,
                                     action: #selector(copyHistoryEntry(_:)),
                                     keyEquivalent: "")
                row.target = self
                row.representedObject = entry.text
                row.toolTip = entry.text
                submenu.addItem(row)
            }
        }
        item.submenu = submenu
        return item
    }

    // MARK: - Actions

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        // Never restored, unlike a dictation paste, so the concealed marker is
        // the only thing keeping this out of clipboard-manager history files.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([PasteService.concealedItem(text)])
    }

    @objc private func pickSystemDefault() {
        settings.inputDeviceUID = nil
        rebuildMenu()
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        settings.inputDeviceUID = uid
        rebuildMenu()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.present()
    }

    @objc private func openOnboarding() {
        OnboardingWindowController.shared.present()
    }

    @objc private func grantMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.rebuildMenu() }
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func retryModelLoad() {
        Task.detached { [transcriber] in
            await transcriber.warmupSelfHealing()
        }
    }

    @objc private func grantAccessibility() {
        // Open System Settings first so the user can toggle; then poll until the
        // running process is trusted, and start the tap live (no relaunch needed).
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // Fire the prompt-flagged check to register Bark in the AX list if not present.
        _ = DictationCoordinator.hasAccessibilityPermission(prompt: true)
        startAXPolling()
        rebuildMenu()
    }

    private func startAXPolling() {
        axPollTimer?.invalidate()
        // No deadline: this poll is the only path that arms the tap without a
        // relaunch, and granting access routinely takes longer than a couple of
        // minutes (finding the pane, unlocking, or the remove-and-re-add dance
        // after an update). Giving up leaves an app that looks installed and
        // does nothing. It self-terminates the moment the grant lands, and
        // until then Bark cannot work anyway.
        //
        // .common mode: a default-mode timer stops firing while the status menu
        // is open, which is exactly when the user is staring at the AX hint.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if DictationCoordinator.hasAccessibilityPermission() {
                    self.log.info("AX granted — arming hotkey tap")
                    self.settings.axWasGranted = true
                    _ = self.dictation.start()
                    self.rebuildMenu()
                    timer.invalidate()
                    self.axPollTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        axPollTimer = timer
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

}
