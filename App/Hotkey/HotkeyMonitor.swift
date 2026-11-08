import AppKit
import Carbon.HIToolbox
import os

/// Press and release of the hotkey, from a listen-only session event tap (never swallows keys).
@MainActor
final class HotkeyMonitor {
    enum Event { case pressed, released }

    var onEvent: ((Event) -> Void)?
    private(set) var isHeld = false

    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Hotkey")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hotkey = Hotkey.rightOption

    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static var prompted = false

    /// One thing opens per click. The first time, Apple's prompt: it adds Bark to the Accessibility
    /// list and its own button opens the pane. It does not come back, so later clicks open the pane.
    static func requestTrust() {
        guard !prompted else { return SystemSettings.open(.accessibility) }
        prompted = true
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 treats as shared mutable state.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @discardableResult
    func start(_ hotkey: Hotkey) -> Bool {
        stop()
        guard Self.isTrusted else { return false }
        self.hotkey = hotkey
        let types: [CGEventType] = hotkey.mask == 0 && hotkey.keyCode != CGKeyCode(kVK_CapsLock)
            ? [.keyDown, .keyUp] : [.flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            if let refcon {
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags.rawValue
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                // The tap's run loop source is on the main run loop.
                MainActor.assumeIsolated { monitor.handle(type, keyCode: keyCode, flags: flags, isRepeat: isRepeat) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.error("Event tap could not be created")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        log.info("Hotkey armed: \(hotkey.name, privacy: .public)")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        // Without a tap the release can never arrive.
        set(held: false)
    }

    private func handle(_ type: CGEventType, keyCode: CGKeyCode, flags: UInt64, isRepeat: Bool) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables taps on main-thread stalls and across sleep and login; the
            // release may have happened while it was off.
            guard let tap else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
            log.warning("Event tap re-enabled after the system disabled it")
            if isHeld, !CGEventSource.keyState(.combinedSessionState, key: hotkey.keyCode) { set(held: false) }
        case .flagsChanged where keyCode == hotkey.keyCode:
            if keyCode == CGKeyCode(kVK_CapsLock) {
                // Caps Lock's flag is the lock state, not the key: each event is one edge.
                set(held: !isHeld)
            } else {
                set(held: flags & hotkey.mask != 0)
            }
        case .keyDown where keyCode == hotkey.keyCode && !isRepeat:
            set(held: true)
        case .keyUp where keyCode == hotkey.keyCode:
            set(held: false)
        default:
            break
        }
    }

    private func set(held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        onEvent?(held ? .pressed : .released)
    }
}
