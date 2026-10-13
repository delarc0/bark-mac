import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Captures the next hotkey: any modifier (left and right apart), Fn, Caps Lock, or a key that
/// does not edit text. The tap is listen-only, so a bound letter, Space, Return or Delete would
/// also type into the focused app on every dictation; those are refused.
struct HotkeyRecorder: View {
    /// Posted with a Bool (true = capturing) so the global tap pauses while a key is captured.
    static let listeningChanged = Notification.Name("se.lab37.bark.mac.HotkeyRecorder.listeningChanged")

    @Bindable var settings: AppSettings
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 12) {
            Text("Hotkey")
                .frame(width: 80, alignment: .trailing)
            Button(action: toggle) {
                Text(listening ? "Press a key…" : settings.hotkey.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(listening ? Color.accentColor : .primary)
                    .frame(minWidth: 180)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(listening ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: listening ? 2 : 1))
            }
            .buttonStyle(.plain)
            Button("Reset") { settings.hotkey = .rightOption }
                .disabled(listening)
            Spacer()
        }
        .onDisappear { stopListening() }
        // onDisappear does not fire when the window is closed outright, which would leave the
        // global tap paused.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stopListening() }
    }

    private func toggle() {
        if listening { stopListening() } else { startListening() }
    }

    private func startListening() {
        stopListening()
        listening = true
        NotificationCenter.default.post(name: Self.listeningChanged, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            MainActor.assumeIsolated { capture(event) }
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard listening else { return }
        listening = false
        NotificationCenter.default.post(name: Self.listeningChanged, object: false)
    }

    private func capture(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        if event.type == .keyDown, keyCode == kVK_Escape {
            stopListening()
            return
        }
        guard let hotkey = Self.hotkey(keyCode: keyCode, isKeyDown: event.type == .keyDown) else { return }
        settings.hotkey = hotkey
        stopListening()
    }

    static func hotkey(keyCode: Int, isKeyDown: Bool) -> Hotkey? {
        if !isKeyDown, let (mask, name) = modifiers[keyCode] {
            return Hotkey(keyCode: CGKeyCode(keyCode), mask: mask, name: name)
        }
        if isKeyDown, let name = plainKeys[keyCode] {
            return Hotkey(keyCode: CGKeyCode(keyCode), mask: 0, name: name)
        }
        return nil
    }

    /// Device-specific masks from IOKit/hidsystem/IOLLEvent.h. Caps Lock carries NX_ALPHASHIFTMASK
    /// for the record; the monitor reads its events as edges.
    static let modifiers: [Int: (UInt64, String)] = [
        kVK_Shift: (0x02, "Left Shift"),
        kVK_RightShift: (0x04, "Right Shift"),
        kVK_Control: (0x01, "Left Control"),
        kVK_RightControl: (0x2000, "Right Control"),
        kVK_Option: (0x20, "Left Option"),
        kVK_RightOption: (0x40, "Right Option"),
        kVK_Command: (0x08, "Left Command"),
        kVK_RightCommand: (0x10, "Right Command"),
        kVK_Function: (0x0080_0000, "Fn"),
        kVK_CapsLock: (0x0001_0000, "Caps Lock"),
    ]

    static let plainKeys: [Int: String] = {
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        var keys = Dictionary(uniqueKeysWithValues: functionKeys.enumerated().map { ($1, "F\($0 + 1)") })
        keys[kVK_Help] = "Help"
        keys[kVK_Home] = "Home"
        keys[kVK_End] = "End"
        keys[kVK_PageUp] = "Page Up"
        keys[kVK_PageDown] = "Page Down"
        return keys
    }()
}
