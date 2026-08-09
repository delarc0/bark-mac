import AppKit
import Carbon.HIToolbox
import os

@MainActor
enum PasteService {
    private static let log = Logger(subsystem: "se.lab37.bark.mac", category: "Paste")
    private static var prepared: (snapshot: Snapshot, changeCount: Int)?

    /// Snapshot the clipboard while transcription runs, off the paste critical path.
    /// Large clipboard contents (images, promised data) can take long to read; doing
    /// it here means the synthesized ⌘V isn't delayed when transcription finishes.
    static func prepareSnapshot() {
        let pb = NSPasteboard.general
        prepared = (snapshot(pb), pb.changeCount)
    }

    /// Saves the current clipboard, writes `text`, synthesizes ⌘V, then restores the
    /// previous clipboard after a short delay so the frontmost app has time to paste.
    static func pasteAtCursor(_ text: String) {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general
        let saved: Snapshot
        if let prepared, prepared.changeCount == pb.changeCount {
            saved = prepared.snapshot
        } else {
            saved = snapshot(pb)
        }
        prepared = nil

        pb.clearContents()
        pb.writeObjects([concealedItem(text)])
        let ownChangeCount = pb.changeCount

        synthesizeCommandV()

        // Electron apps need ≥150ms to actually read the pasteboard on ⌘V;
        // restoring earlier races the app and pastes the previous clipboard contents.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                // Someone else wrote to the clipboard in the window — don't clobber it.
                let pb = NSPasteboard.general
                guard pb.changeCount == ownChangeCount else { return }
                restore(pb, saved)
            }
        }
    }

    /// Dictated text tagged so clipboard managers skip it. Bark keeps speech out
    /// of any file it writes, but Raycast, Maccy, Alfred and friends poll the
    /// pasteboard every few hundred milliseconds — well inside the restore
    /// window — and would archive every transcription to their own on-disk
    /// history. The nspasteboard.org convention is how you opt out.
    static func concealedItem(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        return item
    }

    /// The snapshot holds a full copy of whatever the user had on their
    /// clipboard, so it must not outlive the dictation that took it.
    static func discardSnapshot() {
        prepared = nil
    }

    private struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
        return Snapshot(items: items)
    }

    private static func restore(_ pb: NSPasteboard, _ snap: Snapshot) {
        pb.clearContents()
        let newItems: [NSPasteboardItem] = snap.items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        if !newItems.isEmpty {
            pb.writeObjects(newItems)
        }
    }

    private static func synthesizeCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = CGKeyCode(kVK_ANSI_V)

        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else {
            log.error("Failed to build CGEvent for ⌘V")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
