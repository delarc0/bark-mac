import AppKit
import BarkStore
import Observation
import SwiftUI
import os

/// The user's own notes for the meeting being recorded, saved to the store a second after typing stops.
@MainActor
@Observable
final class NotesModel {
    var text = "" {
        didSet {
            guard text != oldValue, meeting != nil else { return }
            dirty = true
            save?.cancel()
            save = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    @ObservationIgnored private var meeting: UUID?
    @ObservationIgnored private var store: MeetingStore?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var save: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Notes")

    func begin(_ meeting: UUID, store: MeetingStore) {
        flush()
        self.meeting = nil
        text = ""
        self.store = store
        self.meeting = meeting
    }

    func flush() {
        save?.cancel()
        save = nil
        guard dirty, let meeting, let store else { return }
        dirty = false
        do {
            try store.setNotes(meeting, text)
        } catch {
            log.error("Saving notes failed: \(String(describing: error), privacy: .public)")
            dirty = true
        }
    }

    /// Saves and lets go of the meeting; later typing is not saved anywhere.
    func end() {
        flush()
        meeting = nil
    }
}

/// A small floating panel that stays above the call while the user switches back to it.
@MainActor
final class NotesWindowController: NSWindowController, NSWindowDelegate {
    private let model: NotesModel

    init(model: NotesModel) {
        self.model = model
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "Notes"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 240, height: 160)
        panel.contentViewController = NSHostingController(rootView: NotesView(model: model))
        super.init(window: panel)
        panel.delegate = self
        if !panel.setFrameUsingName("BarkNotes") { placeTopRight(panel) }
        panel.setFrameAutosaveName("BarkNotes")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shown without taking focus from the call; a click into it makes it the place to type.
    func show() {
        window?.orderFrontRegardless()
    }

    func hide() {
        model.flush()
        window?.orderOut(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { model.flush() }
    }

    private func placeTopRight(_ panel: NSPanel) {
        guard let visible = NSScreen.main?.visibleFrame else { return panel.center() }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24))
    }
}

private struct NotesView: View {
    @Bindable var model: NotesModel

    var body: some View {
        TextEditor(text: $model.text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .overlay(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("Your notes")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
    }
}
