import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Captures the next modifier key press (or a regular key) and persists it to AppSettings.
struct HotkeyRecorder: View {
    /// Posted when the recorder enters/exits capture mode. `object` is a Bool (true = listening).
    static let listeningChanged = Notification.Name("se.lab37.bark.mac.HotkeyRecorder.listeningChanged")

    @ObservedObject var settings: AppSettings
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 12) {
            Text("Hotkey")
                .frame(width: 80, alignment: .trailing)

            Button(action: toggle) {
                Text(listening ? "Press a key…" : settings.hotkeyDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(listening ? Color.accentColor : .primary)
                    .frame(minWidth: 180)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(listening ? Color.accentColor : Color(nsColor: .separatorColor),
                                          lineWidth: listening ? 2 : 1)
                    )
            }
            .buttonStyle(.plain)

            Button("Reset") {
                applyPreset(keyCode: CGKeyCode(kVK_RightOption),
                            mask: AppSettings.defaultRightOptionFlagMask,
                            name: "Right Option")
            }
            .disabled(listening)

            Spacer()
        }
        .onDisappear { stopListening() }
    }

    private func toggle() {
        if listening { stopListening() } else { startListening() }
    }

    private func startListening() {
        stopListening()
        listening = true
        NotificationCenter.default.post(name: Self.listeningChanged, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            capture(event)
            return nil
        }
    }

    private func stopListening() {
        let wasListening = listening
        listening = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if wasListening {
            NotificationCenter.default.post(name: Self.listeningChanged, object: false)
        }
    }

    private func capture(_ event: NSEvent) {
        let keyCode = CGKeyCode(event.keyCode)

        // Escape cancels capture — binding it as the hotkey is never what the
        // user reaching for the universal "get me out" key means.
        if event.type == .keyDown && Int(keyCode) == kVK_Escape {
            stopListening()
            return
        }

        if let info = HotkeyRecorder.modifierLookup[Int(keyCode)] {
            applyPreset(keyCode: keyCode, mask: info.mask, name: info.name)
            stopListening()
            return
        }

        if event.type == .keyDown {
            // Only hold-safe keys may bind without a modifier. The tap is
            // .listenOnly, so a bound letter/Space/Return would both type into
            // the focused app AND fire a dictation on every press.
            guard HotkeyRecorder.soloBindable(Int(keyCode)),
                  let name = HotkeyRecorder.friendlyName(for: Int(keyCode)) else { return }
            applyPreset(keyCode: keyCode, mask: 0, name: name)
            stopListening()
            return
        }
    }

    private static func soloBindable(_ keyCode: Int) -> Bool {
        switch keyCode {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
             kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
             kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20, kVK_CapsLock:
            return true
        default:
            return false
        }
    }

    static func friendlyName(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_Escape: return "Escape"
        case kVK_Tab: return "Tab"
        case kVK_Return: return "Return"
        case kVK_Space: return "Space"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_CapsLock: return "Caps Lock (remap in System Settings → Keyboard)"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        default: return nil
        }
    }

    private func applyPreset(keyCode: CGKeyCode, mask: UInt64, name: String) {
        settings.hotkeyKeyCode = keyCode
        settings.hotkeyFlagMask = mask
        settings.hotkeyDisplayName = name
    }

    /// NX device masks from IOKit/hidsystem/IOLLEvent.h.
    static let modifierLookup: [Int: (mask: UInt64, name: String)] = [
        kVK_Shift: (0x02, "Left Shift"),
        kVK_RightShift: (0x04, "Right Shift"),
        kVK_Control: (0x01, "Left Control"),
        kVK_RightControl: (0x2000, "Right Control"),
        kVK_Option: (0x20, "Left Option"),
        kVK_RightOption: (0x40, "Right Option"),
        kVK_Command: (0x08, "Left Command"),
        kVK_RightCommand: (0x10, "Right Command"),
        kVK_Function: (0x00800000, "Fn"),
    ]
}
