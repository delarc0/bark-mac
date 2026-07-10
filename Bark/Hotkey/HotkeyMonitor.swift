import AppKit
import Carbon.HIToolbox
import os

@MainActor
final class HotkeyMonitor {
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Hotkey")

    enum Event {
        case pressed
        case released
    }

    var onEvent: ((Event) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false

    // Cached at start() — changing them requires stop()+start().
    private var targetKeyCode: CGKeyCode = CGKeyCode(kVK_RightOption)
    private var flagMask: UInt64 = AppSettings.defaultRightOptionFlagMask

    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard Self.hasAccessibilityPermission() else {
            log.error("Cannot start: Accessibility permission not granted")
            return false
        }

        let settings = AppSettings.shared
        targetKeyCode = settings.hotkeyKeyCode
        flagMask = settings.hotkeyFlagMask

        // flagMask == 0 means the hotkey is a regular (non-modifier) key; listen on keyDown/keyUp.
        // Otherwise it's a modifier — listen on flagsChanged.
        let eventMask: UInt64
        if flagMask == 0 {
            eventMask = (UInt64(1) << CGEventType.keyDown.rawValue)
                      | (UInt64(1) << CGEventType.keyUp.rawValue)
        } else {
            eventMask = UInt64(1) << CGEventType.flagsChanged.rawValue
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                switch type {
                case .flagsChanged:
                    Task { @MainActor in monitor.handleFlagsChanged(keyCode: keyCode, flags: flags) }
                case .keyDown:
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    Task { @MainActor in monitor.handleKey(keyCode: keyCode, down: true, isRepeat: isRepeat) }
                case .keyUp:
                    Task { @MainActor in monitor.handleKey(keyCode: keyCode, down: false, isRepeat: false) }
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    Task { @MainActor in monitor.handleTapDisabled(type) }
                default:
                    break
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        )

        guard let tap else {
            log.error("CGEvent.tapCreate returned nil")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        log.info("Hotkey monitor started keyCode=\(self.targetKeyCode, privacy: .public) mask=0x\(String(self.flagMask, radix: 16), privacy: .public)")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isHeld = false
    }

    func restart() {
        stop()
        _ = start()
    }

    // macOS disables event taps on main-thread stalls and across sleep/login
    // transitions. Without re-enabling here the hotkey dies until relaunch.
    private func handleTapDisabled(_ type: CGEventType) {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        log.warning("Event tap disabled by system (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)) — re-enabled")
        if isHeld, !CGEventSource.keyState(.combinedSessionState, key: targetKeyCode) {
            isHeld = false
            onEvent?(.released)
        }
    }

    private func handleFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard keyCode == targetKeyCode else { return }

        let nowDown = (flags.rawValue & flagMask) != 0

        if nowDown && !isHeld {
            isHeld = true
            onEvent?(.pressed)
        } else if !nowDown && isHeld {
            isHeld = false
            onEvent?(.released)
        }
    }

    private func handleKey(keyCode: CGKeyCode, down: Bool, isRepeat: Bool) {
        guard keyCode == targetKeyCode else { return }
        if down {
            guard !isHeld else { return }  // swallow auto-repeat
            isHeld = true
            onEvent?(.pressed)
        } else {
            guard isHeld else { return }
            isHeld = false
            onEvent?(.released)
        }
    }
}
