import AppKit
import BarkCore
import BarkStore
import Observation
import SwiftUI
import os

/// The meetings list and the selected meeting, read from the store. Reloaded every 2 s while the
/// window is visible, so a meeting being recorded fills in as its segments commit.
@MainActor
@Observable
final class MeetingsModel {
    struct Row: Identifiable, Equatable {
        let meeting: Meeting
        let preview: String?
        var id: UUID { meeting.id }
    }

    enum Item: Identifiable, Equatable {
        case segment(Segment)
        case gap(Gap)

        var id: String {
            switch self {
            case .segment(let segment): "s\(segment.id ?? 0)"
            case .gap(let gap): "g\(gap.at)\(gap.reason)"
            }
        }

        var start: Double {
            switch self {
            case .segment(let segment): segment.start
            case .gap(let gap): gap.at
            }
        }
    }

    struct Detail: Equatable {
        var items: [Item] = []
        var notes: String?
        /// hq's reason for refusing the meeting, when it did.
        var rejected: String?
    }

    private(set) var rows: [Row] = []
    var selection: UUID? {
        didSet { if selection != oldValue { reloadDetail() } }
    }
    private(set) var detail = Detail()

    @ObservationIgnored private let library: MeetingLibrary
    @ObservationIgnored private var previews: [UUID: String?] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Meetings")

    init(library: MeetingLibrary) {
        self.library = library
    }

    var selected: Meeting? { rows.first { $0.id == selection }?.meeting }

    func reload() {
        guard let store = library.store else { return }
        let meetings = (try? store.meetings()) ?? []
        let next = meetings.map { Row(meeting: $0, preview: preview($0, store)) }
        if next != rows { rows = next }
        if selection == nil || !meetings.contains(where: { $0.id == selection }) {
            selection = meetings.first?.id
        }
        reloadDetail()
    }

    private func reloadDetail() {
        guard let store = library.store, let id = selection else {
            if detail != Detail() { detail = Detail() }
            return
        }
        let segments = ((try? store.segments(id)) ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let gaps = (try? store.gaps(id)) ?? []
        let items = (segments.map(Item.segment) + gaps.map(Item.gap)).sorted { $0.start < $1.start }
        let notes = (try? store.notes(id))?.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let outbox = try? store.outboxItem(id)
        let next = Detail(items: items, notes: notes?.isEmpty == false ? notes : nil,
                          rejected: outbox?.state == .rejected ? (outbox?.lastError ?? "No reason given.") : nil)
        if next != detail { detail = next }
    }

    /// The first words, cached once the meeting is done.
    private func preview(_ meeting: Meeting, _ store: MeetingStore) -> String? {
        if let cached = previews[meeting.id] { return cached }
        let text = TranscriptText.firstWords(((try? store.segments(meeting.id)) ?? []).prefix(6).map(\.text))
        if meeting.status.isFinished { previews[meeting.id] = .some(text) }
        return text
    }

    // MARK: Actions

    func copyTranscript() {
        let lines = detail.items.compactMap { item -> TranscriptText.Line? in
            guard case .segment(let segment) = item else { return nil }
            return TranscriptText.Line(label: segment.stream.label, start: segment.start, text: segment.text)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscriptText.plain(lines), forType: .string)
    }

    /// A finished meeting is sent to hq again with its new title.
    func rename(_ title: String) {
        guard let store = library.store, let meeting = selected else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.setTitle(meeting.id, trimmed.isEmpty ? nil : trimmed)
            if meeting.status == .done {
                try store.enqueue(meeting.id)
                library.hq.sync()
            }
        } catch {
            log.error("Rename failed: \(String(describing: error), privacy: .public)")
        }
        reload()
    }

    func delete() {
        guard let store = library.store, let meeting = selected, meeting.status.isFinished else { return }
        do {
            try store.delete(meeting.id)
        } catch {
            log.error("Delete failed: \(String(describing: error), privacy: .public)")
        }
        previews.removeValue(forKey: meeting.id)
        selection = nil
        reload()
    }

    func retryUpload() {
        guard let store = library.store, let id = selection else { return }
        do {
            try store.enqueue(id)
        } catch {
            log.error("Queueing for hq failed: \(String(describing: error), privacy: .public)")
        }
        library.hq.sync()
        reloadDetail()
    }
}

extension MeetingStream {
    /// Me and Them on a call; a room mic has no side.
    var label: String? {
        switch self {
        case .me: "Me"
        case .them: "Them"
        case .room: nil
        }
    }
}

extension MeetingStatus {
    var isFinished: Bool { self == .done || self == .interrupted }
}

extension Meeting {
    var duration: TimeInterval { (endedAt ?? .now).timeIntervalSince(startedAt) }
}

final class MeetingsWindowController: AppWindowController {
    static let shared = MeetingsWindowController()

    private let model: MeetingsModel
    private var timer: Timer?

    private init() {
        let model = MeetingsModel(library: .shared)
        self.model = model
        super.init(title: "Meetings", styleMask: [.titled, .closable, .miniaturizable, .resizable], content: MeetingsView(model: model))
        window?.setContentSize(NSSize(width: 820, height: 540))
        window?.setFrameAutosaveName("BarkMeetings")
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.model.reload()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NotificationCenter.default.addObserver(forName: MeetingLibrary.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.model.reload()
            }
        }
    }

    func present(selecting id: UUID? = nil) {
        model.reload()
        if let id { model.selection = id }
        bringForward()
    }
}

struct MeetingsView: View {
    @Bindable var model: MeetingsModel

    var body: some View {
        NavigationSplitView {
            List(model.rows, selection: $model.selection) { row in
                MeetingRow(row: row)
            }
            .overlay {
                if model.rows.isEmpty {
                    ContentUnavailableView("No Meetings", systemImage: "waveform",
                                           description: Text("Start one from the Bark menu."))
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            if let meeting = model.selected {
                MeetingDetail(model: model, meeting: meeting)
            } else {
                ContentUnavailableView("No Meeting Selected", systemImage: "text.alignleft")
            }
        }
        .frame(minWidth: 680, minHeight: 420)
    }
}

private struct MeetingRow: View {
    let row: MeetingsModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.meeting.title ?? row.preview ?? "Meeting")
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(row.meeting.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                if row.meeting.status == .recording {
                    Text(row.meeting.startedAt, style: .timer).monospacedDigit()
                } else {
                    Text(Duration.seconds(row.meeting.duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                }
                Spacer(minLength: 0)
                StatusLabel(status: row.meeting.status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct StatusLabel: View {
    let status: MeetingStatus

    var body: some View {
        switch status {
        case .recording:
            Text("Recording").foregroundStyle(.red)
        case .transcribing:
            Text("Transcribing")
        case .interrupted:
            Text("Interrupted")
        case .done:
            EmptyView()
        }
    }
}

private struct MeetingDetail: View {
    let model: MeetingsModel
    let meeting: Meeting
    @State private var renaming = false
    @State private var draft = ""
    @State private var deleting = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let message = model.detail.rejected { rejected(message) }
                    if let notes = model.detail.notes {
                        GroupBox("Your Notes") {
                            Text(notes)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(4)
                        }
                    }
                    transcript
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.detail.items.count) {
                if meeting.status == .recording { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .alert("Rename Meeting", isPresented: $renaming) {
            TextField("Title", text: $draft)
            Button("Rename") { model.rename(draft) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this meeting?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { model.delete() }
        } message: {
            Text("Its transcript, notes and audio are deleted from this Mac.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title ?? "Meeting")
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Button { model.copyTranscript() } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy Transcript")
                    .disabled(model.detail.items.isEmpty)
                Button {
                    draft = meeting.title ?? ""
                    renaming = true
                } label: { Image(systemName: "pencil") }
                    .help("Rename")
                Button { deleting = true } label: { Image(systemName: "trash") }
                    .help("Delete")
                    .disabled(!meeting.status.isFinished)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
        }
    }

    private var subtitle: String {
        let date = meeting.startedAt.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())
        let duration = Duration.seconds(meeting.duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        let mode = meeting.mode == .inPerson ? "In person" : "Call"
        return [date, duration, Languages.name(meeting.language), mode].joined(separator: " · ")
    }

    private func rejected(_ message: String) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("hq didn't accept this meeting")
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Try Again") { model.retryUpload() }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if model.detail.items.isEmpty {
            Text(meeting.status.isFinished ? "Nothing was transcribed." : "Nothing transcribed yet.")
                .foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.detail.items) { item in
                    TranscriptRow(item: item)
                }
            }
        }
    }
}

private struct TranscriptRow: View {
    let item: MeetingsModel.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(TranscriptText.timestamp(item.start))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            switch item {
            case .segment(let segment):
                if let label = segment.stream.label {
                    Text(label)
                        .fontWeight(.semibold)
                        .foregroundStyle(segment.stream == .me ? .primary : .secondary)
                        .frame(width: 40, alignment: .leading)
                }
                Text(segment.text.trimmingCharacters(in: .whitespaces))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .gap(let gap):
                Text("Gap: \(gap.reason)")
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
