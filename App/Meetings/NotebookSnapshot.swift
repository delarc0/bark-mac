#if DEBUG
import AppKit
import BarkStore
import Darwin
import SwiftUI

@MainActor
enum NotebookSnapshot {
    static func run(_ directory: String) {
        do {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let temporary = FileManager.default.temporaryDirectory.appending(path: "BarkNotebookSnapshot-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let store = try MeetingStore(root: temporary)
            let live = try populate(store)
            let model = NotebookModel(store: store)
            model.reload()
            model.selection = live
            let sizes = [NSSize(width: 1100, height: 700), NSSize(width: 360, height: 640)]
            for size in sizes {
                for dark in [false, true] {
                    let name = "notebook-\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light").png"
                    try render(model, size: size, dark: dark, to: output.appending(path: name))
                }
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func render(_ model: NotebookModel, size: NSSize, dark: Bool, to url: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Bark"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentMinSize = NSSize(width: 320, height: 240)
        let content = NotebookView(model: model).environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = window.appearance
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.setContentSize(size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        window.setContentSize(size)
        hosting.setFrameSize(size)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let cached = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw SnapshotError.rendering }
        hosting.cacheDisplay(in: hosting.bounds, to: cached)
        let image = NSImage(size: cached.size)
        image.addRepresentation(cached)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw SnapshotError.rendering
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.rendering }
        try data.write(to: url)
        window.close()
    }

    private static func populate(_ store: MeetingStore) throws -> UUID {
        let now = Date.now
        let live = try store.createMeeting(language: "en", mode: .call, title: "Weekly with Tegen",
                                           startedAt: now.addingTimeInterval(-42 * 60))
        try store.setNotes(live.id, "# Decisions\n- Budget for Q1 agreed\n- Helena sends the brief on Friday afternoon after the client review is complete\n## Actions\n[ ] Book the shoot\n- [x] Share the agenda")
        try store.addSegment(Segment(stream: .me, start: 4, end: 9, text: "Can we agree the Q1 budget today?",
                                     model: "fixture", language: "en"), to: live.id)
        try store.addSegment(Segment(stream: .them, start: 12, end: 18, text: "Yes, the numbers look good.",
                                     model: "fixture", language: "en"), to: live.id)
        try store.addSegment(Segment(stream: .me, start: 24, end: 30, text: "I will book the shoot afterwards.",
                                     model: "fixture", language: "en"), to: live.id)

        _ = try finished(store, title: "Standup", startedAt: now.addingTimeInterval(-3 * 3600),
                         notes: "# Summary\n## Decisions\n- Ship the notebook\n* Review on Friday\n[ ] Book the shoot\n[x] Send the brief\n- [x] Nested follow-up",
                         lines: ["The notebook is ready for review.", "I can send the brief on Friday.", "Let us book the studio today."],
                         namedSpeakers: true)
        _ = try finished(store, title: "Bionic sync", startedAt: dayOffset(-1, from: now),
                         lines: ["The launch checklist is nearly done."])
        _ = try finished(store, title: "Mana CMO", startedAt: dayOffset(-4, from: now),
                         lines: ["We reviewed the autumn campaign."])
        _ = try finished(store, title: "Product review", startedAt: dayOffset(-12, from: now),
                         lines: ["The next release is scoped."])
        _ = try finished(store, title: nil, startedAt: dayOffset(-45, from: now))
        _ = try finished(store, title: "August planning", startedAt: dayOffset(-75, from: now))
        return live.id
    }

    private static func finished(_ store: MeetingStore, title: String?, startedAt: Date, notes: String? = nil,
                                 lines: [String] = [], namedSpeakers: Bool = false) throws -> Meeting {
        let meeting = try store.createMeeting(language: "en", mode: .call, title: title, startedAt: startedAt)
        for (index, line) in lines.enumerated() {
            try store.addSegment(Segment(stream: index.isMultiple(of: 2) ? .me : .them,
                                         start: Double(index * 30), end: Double(index * 30 + 20), text: line,
                                         model: "fixture", language: "en"), to: meeting.id)
        }
        if let notes { try store.setNotes(meeting.id, notes) }
        try store.finish(meeting.id, endedAt: startedAt.addingTimeInterval(42 * 60))
        if namedSpeakers {
            let speakers = try ["Me", "Speaker 1", "Speaker 2"].map { try store.addSpeaker($0, to: meeting.id) }
            for (id, name) in zip(speakers.dropFirst(), ["Helena", "Jens"]) {
                try store.nameSpeaker(id, name)
            }
            for (index, segment) in try store.segments(meeting.id).enumerated() {
                if let id = segment.id { try store.setSpeaker(speakers[index % speakers.count], forSegment: id) }
            }
            try store.setDiarization(meeting.id, .done)
        }
        return meeting
    }

    private static func dayOffset(_ days: Int, from date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: date)!.addingTimeInterval(-2 * 3600)
    }

    private enum SnapshotError: Error { case rendering }
}
#endif
