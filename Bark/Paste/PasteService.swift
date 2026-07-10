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
        pb.setString(text, forType: .string)
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
