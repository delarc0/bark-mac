import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import ServiceManagement
import os

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Settings")

    // Notification posted whenever any stored setting changes (keyCode/flagMask/displayName/model).
    static let didChange = Notification.Name("se.lab37.bark.mac.AppSettings.didChange")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyFlagMask = "hotkey.flagMask"
        static let hotkeyDisplayName = "hotkey.displayName"
        static let modelVariant = "transcriber.model"
        static let language = "transcriber.language"
        static let inputDeviceUID = "audio.deviceUID"
        static let onboardingCompleted = "onboarding.completed"
        static let soundsEnabled = "sounds.enabled"
        static let darkModeEnabled = "ui.darkMode"
        static let overlayEnabled = "ui.overlayEnabled"
        static let notchIslandEnabled = "ui.notchIsland"
        static let cleanupEnabled = "text.cleanup"
        static let vocabulary = "text.vocabulary"
        static let streamingEnabled = "transcription.streaming"
        static let axWasGranted = "permissions.ax.wasGranted"
        static let micWasGranted = "permissions.mic.wasGranted"
    }

    @Published var hotkeyKeyCode: CGKeyCode {
        didSet {
            defaults.set(Int(hotkeyKeyCode), forKey: Key.hotkeyKeyCode)
            notify()
        }
    }

    @Published var hotkeyFlagMask: UInt64 {
        didSet {
            defaults.set(String(hotkeyFlagMask), forKey: Key.hotkeyFlagMask)
            notify()
        }
    }

    @Published var hotkeyDisplayName: String {
        didSet {
            defaults.set(hotkeyDisplayName, forKey: Key.hotkeyDisplayName)
            notify()
        }
    }

    @Published var modelVariant: String {
        didSet {
            defaults.set(modelVariant, forKey: Key.modelVariant)
            notify()
        }
    }

    @Published var language: String? {
        didSet {
            if let language {
                defaults.set(language, forKey: Key.language)
            } else {
                defaults.removeObject(forKey: Key.language)
            }
            notify()
        }
    }

    @Published var inputDeviceUID: String? {
        didSet {
            if let inputDeviceUID {
                defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID)
            } else {
                defaults.removeObject(forKey: Key.inputDeviceUID)
            }
            notify()
        }
    }

    @Published var onboardingCompleted: Bool {
        didSet {
            defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted)
            notify()
        }
    }

    @Published var soundsEnabled: Bool {
        didSet {
            defaults.set(soundsEnabled, forKey: Key.soundsEnabled)
            notify()
        }
    }

    @Published var darkModeEnabled: Bool {
        didSet {
            defaults.set(darkModeEnabled, forKey: Key.darkModeEnabled)
            notify()
        }
    }

    @Published var overlayEnabled: Bool {
        didSet {
            defaults.set(overlayEnabled, forKey: Key.overlayEnabled)
            notify()
        }
    }

    // When on, recording shows in the notch of the built-in display (a fake
    // Dynamic Island) instead of the bottom-center pill. Only has any effect on
    // a Mac with a notch; falls back to the pill on external/clamshell displays.
    @Published var notchIslandEnabled: Bool {
        didSet {
            defaults.set(notchIslandEnabled, forKey: Key.notchIslandEnabled)
            notify()
        }
    }

    @Published var cleanupEnabled: Bool {
        didSet {
            defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled)
            notify()
        }
    }

    @Published var vocabulary: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(vocabulary) {
                defaults.set(data, forKey: Key.vocabulary)
            }
            notify()
        }
    }

    @Published var streamingEnabled: Bool {
        didSet {
            defaults.set(streamingEnabled, forKey: Key.streamingEnabled)
            notify()
        }
    }

    // Backed by barkCpuOnlyDefaultsKey so the Transcriber actor can read it
    // off-main via UserDefaults. Set manually in Settings → Model, or
    // automatically by the warmup self-heal when the ANE path wedges.
    @Published var computeCpuOnly: Bool {
        didSet {
            defaults.set(computeCpuOnly, forKey: barkCpuOnlyDefaultsKey)
            notify()
        }
    }

    // Truth lives in SMAppService, not UserDefaults. On failure the assignment
    // reverts to the actual registration state; the guard stops the recursion.
    // .requiresApproval (registered, but user disabled it in System Settings)
    // can't be resolved by register() alone, so surface the Login Items pane.
    @Published var launchAtLogin: Bool {
        didSet {
            let actual = SMAppService.mainApp.status == .enabled
            guard launchAtLogin != actual else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                    if SMAppService.mainApp.status == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                } else {
                    try SMAppService.mainApp.unregister()
                }
                notify()
            } catch {
                log.error("launch-at-login \(self.launchAtLogin ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if launchAtLogin, SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
                launchAtLogin = actual
            }
        }
    }

    // The user can also flip this in System Settings → Login Items; re-read on
    // Settings-window open so the toggle reflects reality.
    func refreshLaunchAtLogin() {
        let actual = SMAppService.mainApp.status == .enabled
        if launchAtLogin != actual { launchAtLogin = actual }
    }

    private init() {
        let storedKeyCode = defaults.object(forKey: Key.hotkeyKeyCode) as? Int
        self.hotkeyKeyCode = CGKeyCode(storedKeyCode ?? kVK_RightOption)

        // UInt64 doesn't fit cleanly in UserDefaults; store as string.
        let storedMask = (defaults.string(forKey: Key.hotkeyFlagMask)).flatMap(UInt64.init)
        self.hotkeyFlagMask = storedMask ?? AppSettings.defaultRightOptionFlagMask

        self.hotkeyDisplayName = defaults.string(forKey: Key.hotkeyDisplayName) ?? "Right Option"
        self.modelVariant = defaults.string(forKey: Key.modelVariant) ?? "openai_whisper-large-v3_turbo"
        self.language = defaults.string(forKey: Key.language)
        self.inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID)
        self.onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        self.soundsEnabled = (defaults.object(forKey: Key.soundsEnabled) as? Bool) ?? true
        self.darkModeEnabled = (defaults.object(forKey: Key.darkModeEnabled) as? Bool) ?? true
        self.overlayEnabled = (defaults.object(forKey: Key.overlayEnabled) as? Bool) ?? true
        self.notchIslandEnabled = (defaults.object(forKey: Key.notchIslandEnabled) as? Bool) ?? true
        self.cleanupEnabled = (defaults.object(forKey: Key.cleanupEnabled) as? Bool) ?? true
        if let data = defaults.data(forKey: Key.vocabulary),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.vocabulary = decoded
        } else {
            self.vocabulary = [:]
        }
        self.streamingEnabled = (defaults.object(forKey: Key.streamingEnabled) as? Bool) ?? false
        self.computeCpuOnly = defaults.bool(forKey: barkCpuOnlyDefaultsKey)
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // Not @Published: bookkeeping for lost-grant detection, not UI state.
    var axWasGranted: Bool {
        get { defaults.bool(forKey: Key.axWasGranted) }
        set { defaults.set(newValue, forKey: Key.axWasGranted) }
    }

    var micWasGranted: Bool {
        get { defaults.bool(forKey: Key.micWasGranted) }
        set { defaults.set(newValue, forKey: Key.micWasGranted) }
    }

    private func notify() {
        NotificationCenter.default.post(name: AppSettings.didChange, object: self)
    }

    // NX_DEVICERALTKEYMASK — isolates right-Option from left-Option.
    static let defaultRightOptionFlagMask: UInt64 = 0x0000_0040

    static let availableModels: [(id: String, label: String, approxSizeGB: Double)] = [
        ("openai_whisper-large-v3_turbo", "Large v3 turbo (best quality)", 1.5),
        ("openai_whisper-small", "Small (faster, lower quality)", 0.5),
        ("openai_whisper-tiny", "Tiny (fastest, lowest quality)", 0.08),
    ]
}
