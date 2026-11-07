import AppKit
import Carbon
import os

/// Puts dictated text at the cursor through the clipboard and leaves the clipboard as it was.
@MainActor
enum Paste {
    private static let log = Logger(subsystem: "se.lab37.bark.mac", category: "Paste")
    // Electron apps read the pasteboard up to ~150 ms after the keystroke.
    private static let restoreDelay = 0.15
    private static var prepared: (items: [[NSPasteboard.PasteboardType: Data]], changeCount: Int)?

    /// Copies the clipboard while transcription runs, off the paste's critical path: images and
    /// promised data can take a while to read.
    static func prepareSnapshot() {
        let board = NSPasteboard.general
        prepared = (snapshot(board), board.changeCount)
    }

    /// The snapshot is a full copy of the user's clipboard; it must not outlive the dictation.
    static func discardSnapshot() {
        prepared = nil
    }

    static func paste(_ text: String) {
        let board = NSPasteboard.general
        let saved = prepared?.changeCount == board.changeCount ? prepared!.items : snapshot(board)
        prepared = nil
        board.clearContents()
        board.writeObjects([concealedItem(text)])
        let ours = board.changeCount
        pressCommandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            MainActor.assumeIsolated {
                // Something else wrote to the clipboard meanwhile: theirs wins.
                guard board.changeCount == ours else { return }
                board.clearContents()
                board.writeObjects(saved.map { types in
                    let item = NSPasteboardItem()
                    for (type, data) in types { item.setData(data, forType: type) }
                    return item
                })
            }
        }
    }

    /// On the clipboard to stay: never restored, so the concealed marker is all that keeps it out of
    /// clipboard histories.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([concealedItem(text)])
    }

    /// Clipboard managers poll well inside the restore window and would archive every dictation
    /// to their own history on disk; the nspasteboard.org marker opts out.
    static func concealedItem(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        return item
    }

    private static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = keyCode(typing: "v") ?? CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            log.error("Could not build the Cmd-V events")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// The key that types `character` with Command held on the current layout. On Dvorak V sits
    /// elsewhere; "Dvorak - QWERTY Command" switches to QWERTY under Command, which translating
    /// with the Command modifier honours.
    static func keyCode(typing character: String) -> CGKeyCode? {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let layoutSource = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) != nil
            ? source : TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(layoutSource, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in UInt16(0) ..< 128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeys, chars.count, &length, &chars)
                if status == noErr, String(utf16CodeUnits: chars, count: length) == character { return CGKeyCode(code) }
            }
            return nil
        }
    }
}
