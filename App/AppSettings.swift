import AppKit
import BarkCore
import Carbon.HIToolbox
import Foundation
import Observation
import ServiceManagement
import os

/// The key held to dictate. `mask` is the device-specific modifier bit (NX_DEVICE*KEYMASK), which
/// tells right Option from left; 0 for a plain key.
struct Hotkey: Equatable {
    var keyCode: CGKeyCode
    var mask: UInt64
    var name: String

    static let rightOption = Hotkey(keyCode: CGKeyCode(kVK_RightOption), mask: 0x40, name: "Right Option")
}

/// Settings in UserDefaults. The release build shares the 0.2.x domain (same bundle id): hotkey,
/// input device and language are read from 0.2.x's keys, everything else starts from defaults
/// under new keys. Debug builds have their own domain through the dev bundle id.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Settings")

    private enum Key {
        // Carried over from 0.2.x.
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyFlagMask = "hotkey.flagMask"
        static let hotkeyName = "hotkey.displayName"
        static let inputDeviceUID = "audio.deviceUID"
        static let language = "transcriber.language"
        // Bark2.
        static let swedishModel = "bark2.swedishModel"
        static let onboardingCompleted = "bark2.onboardingCompleted"
        static let sounds = "bark2.sounds"
        static let overlay = "bark2.overlay"
        static let notchIsland = "bark2.notchIsland"
        static let darkOverlay = "bark2.darkOverlay"
        static let cleanup = "bark2.cleanup"
        static let vocabulary = "bark2.vocabulary"
        static let axWasGranted = "bark2.axWasGranted"
        static let micWasGranted = "bark2.micWasGranted"
    }

    /// Called after the hotkey changes, so the event tap can rebind.
    @ObservationIgnored var onHotkeyChange: (() -> Void)?

    var hotkey: Hotkey {
        didSet {
            guard hotkey != oldValue else { return }
            defaults.set(Int(hotkey.keyCode), forKey: Key.hotkeyKeyCode)
            // 0.2.x stored the UInt64 mask as a string.
            defaults.set(String(hotkey.mask), forKey: Key.hotkeyFlagMask)
            defaults.set(hotkey.name, forKey: Key.hotkeyName)
            onHotkeyChange?()
        }
    }

    var language: LanguageChoice {
        didSet {
            if case .explicit(let code) = language {
                defaults.set(code, forKey: Key.language)
            } else {
                defaults.removeObject(forKey: Key.language)
            }
        }
    }

    /// nil = the system default input.
    var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID) }
    }

    /// Whether KB-Whisper is installed and loaded at all. Takes effect on the next model load.
    var swedishModelEnabled: Bool {
        didSet { defaults.set(swedishModelEnabled, forKey: Key.swedishModel) }
    }

    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: Key.sounds) }
    }

    var overlayEnabled: Bool {
        didSet { defaults.set(overlayEnabled, forKey: Key.overlay) }
    }

    /// Recording shows in the notch of a built-in notched display instead of the pill.
    var notchIslandEnabled: Bool {
        didSet { defaults.set(notchIslandEnabled, forKey: Key.notchIsland) }
    }

    var darkOverlay: Bool {
        didSet { defaults.set(darkOverlay, forKey: Key.darkOverlay) }
    }

    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanup) }
    }

    var vocabulary: [String: String] {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }

    // Truth lives in SMAppService, not UserDefaults: the user can flip it in System Settings too.
    var launchAtLogin: Bool {
        didSet {
            let actual = SMAppService.mainApp.status == .enabled
            guard launchAtLogin != actual else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log.error("Launch at login: \(error.localizedDescription, privacy: .public)")
                launchAtLogin = actual
            }
            // Registered but switched off in Login Items: only the user can approve it there.
            if launchAtLogin, SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    func refreshLaunchAtLogin() {
        let actual = SMAppService.mainApp.status == .enabled
        if launchAtLogin != actual { launchAtLogin = actual }
    }

    // Bookkeeping for lost-grant detection: a re-signed build silently loses its TCC grants.
    var axWasGranted: Bool {
        get { defaults.bool(forKey: Key.axWasGranted) }
        set { defaults.set(newValue, forKey: Key.axWasGranted) }
    }

    var micWasGranted: Bool {
        get { defaults.bool(forKey: Key.micWasGranted) }
        set { defaults.set(newValue, forKey: Key.micWasGranted) }
    }

    private init() {
        if let keyCode = defaults.object(forKey: Key.hotkeyKeyCode) as? Int,
           let mask = defaults.string(forKey: Key.hotkeyFlagMask).flatMap(UInt64.init),
           let name = defaults.string(forKey: Key.hotkeyName) {
            hotkey = Hotkey(keyCode: CGKeyCode(keyCode), mask: mask, name: name)
        } else {
            hotkey = .rightOption
        }
        let language = LegacySettings.language(defaults.string(forKey: Key.language))
        self.language = language
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID)
        swedishModelEnabled = defaults.object(forKey: Key.swedishModel) as? Bool ?? Self.speaksSwedish(language)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        soundsEnabled = defaults.object(forKey: Key.sounds) as? Bool ?? true
        overlayEnabled = defaults.object(forKey: Key.overlay) as? Bool ?? true
        notchIslandEnabled = defaults.object(forKey: Key.notchIsland) as? Bool ?? true
        darkOverlay = defaults.object(forKey: Key.darkOverlay) as? Bool ?? true
        cleanupEnabled = defaults.object(forKey: Key.cleanup) as? Bool ?? true
        vocabulary = defaults.dictionary(forKey: Key.vocabulary) as? [String: String] ?? [:]
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The Swedish model is on by default only for Swedish users (PRD): Swedish chosen as the
    /// language, among the preferred languages, or a Swedish region.
    private static func speaksSwedish(_ language: LanguageChoice) -> Bool {
        language == .explicit("sv")
            || Locale.preferredLanguages.contains { Locale(identifier: $0).language.languageCode?.identifier == "sv" }
            || Locale.current.region?.identifier == "SE"
    }
}
