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
                    self?.rebuildMenu()
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
            overlay.show(.transcribing)
        }
    }

    /// A rebuild re-signs the ad-hoc bundle, so macOS silently wipes TCC grants
    /// (the System Settings toggle can even still show "on" while being dead).
    /// Without this, the app just sits there doing nothing after every update.
    private func presentPermissionRecoveryIfNeeded() {
        let axNow = DictationCoordinator.hasAccessibilityPermission()
        let micNow = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if axNow { settings.axWasGranted = true }
        if micNow { settings.micWasGranted = true }

        if !axNow && settings.axWasGranted {
            log.warning("Accessibility grant lost since last run (update re-sign?) — showing recovery")
            settings.axWasGranted = false
            DispatchQueue.main.async {
                OnboardingWindowController.shared.present(at: .accessibility)
            }
        } else if !micNow && settings.micWasGranted {
            log.warning("Microphone grant lost since last run — showing recovery")
            settings.micWasGranted = false
            DispatchQueue.main.async {
                OnboardingWindowController.shared.present(at: .mic)
            }
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

    private static let recordingIndicator = dotIndicator(NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0))
    private static let transcribingIndicator = dotIndicator(NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0))

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
            menuIsTracking = true
            rebuildMenu()
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

    // MARK: - Actions

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
        let deadline = Date().addingTimeInterval(120) // poll for 2 minutes
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
                } else if Date() > deadline {
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
