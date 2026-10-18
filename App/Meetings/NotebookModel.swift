import AppKit
import BarkCore
import BarkStore
import Observation
import os

@MainActor
@Observable
final class NotebookModel {
    struct Row: Identifiable, Equatable {
        let meeting: Meeting
        let preview: String?
        var id: UUID { meeting.id }
    }

    struct Group: Identifiable, Equatable {
        let title: String
        let rows: [Row]
        var id: String { title }
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
        var speakers: [Int64: Speaker] = [:]
        var findingSpeakers = false
        var rejected: String?
        var calendarEvent: CalendarEvent?
    }

    private(set) var rows: [Row] = []
    private(set) var groups: [Group] = []
    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            loadNotes()
            reloadDetail()
        }
    }
    private(set) var detail = Detail()
    var notesText = "" {
        didSet {
            guard !loadingNotes, notesText != oldValue, notesMeetingID != nil else { return }
            dirty = true
            save?.cancel()
            save = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.flushNotes()
            }
        }
    }
    var transcriptOpen = false
    var focusNotesToken = 0
    private(set) var recorderState: MeetingRecorder.State = .idle

    @ObservationIgnored private let store: MeetingStore?
    @ObservationIgnored private let hq: HQLink?
    let calendar: CalendarLink?
    @ObservationIgnored private weak var recorder: MeetingRecorder?
    @ObservationIgnored private var previews: [UUID: String?] = [:]
    @ObservationIgnored private var notesMeetingID: UUID?
    @ObservationIgnored private var loadingNotes = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var save: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Notes")

    init(library: MeetingLibrary) {
        store = library.store
        hq = library.hq
        calendar = library.calendar
    }

    init(store: MeetingStore, calendar: CalendarLink? = nil) {
        self.store = store
        hq = nil
        self.calendar = calendar
    }

    var selected: Meeting? { rows.first { $0.id == selection }?.meeting }
    var canStart: Bool {
        if recorder != nil { return recorderState == .idle }
        return !rows.contains { $0.meeting.status == .recording || $0.meeting.status == .transcribing }
    }
    var canDelete: Bool { selected?.status.isFinished == true }
    var transcriptCount: Int {
        detail.items.reduce(into: 0) { count, item in
            if case .segment = item { count += 1 }
        }
    }

    func connect(_ recorder: MeetingRecorder) {
        self.recorder = recorder
        recorderState = recorder.state
    }

    func recorderChanged(_ state: MeetingRecorder.State) {
        recorderState = state
        reload()
    }

    func reload() {
        guard let store else { return }
        let meetings = (try? store.meetings()) ?? []
        let next = meetings.map { Row(meeting: $0, preview: preview($0, store)) }
        if next != rows { rows = next }
        let nextGroups = Self.grouped(next)
        if nextGroups != groups { groups = nextGroups }
        if selection == nil || !meetings.contains(where: { $0.id == selection }) {
            selection = meetings.first?.id
        } else {
            reloadDetail()
        }
    }

    func displayTitle(for meeting: Meeting) -> String {
        if let title = meeting.title, !title.isEmpty { return title }
        if let row = rows.first(where: { $0.id == meeting.id }), let preview = row.preview, !preview.isEmpty {
            return preview
        }
        return meeting.startedAt.formatted(.dateTime.weekday(.wide).hour().minute())
    }

    func isRecording(_ meeting: Meeting) -> Bool {
        #if DEBUG
        if recorder == nil { return meeting.status == .recording }
        #endif
        guard case .recording = recorderState else { return false }
        return recorder?.meetingID == meeting.id
    }

    func isFinishing(_ meeting: Meeting) -> Bool {
        recorderState == .finishing && recorder?.meetingID == meeting.id
    }

    func speakerCount(for meeting: Meeting) -> Int? {
        meeting.diarization == .done ? detail.speakers.count : nil
    }

    func focusNotes() {
        focusNotesToken += 1
    }

    func startMeeting() {
        guard canStart else { return }
        recorder?.start()
    }

    func stopMeeting() {
        recorder?.stop()
    }

    func flushNotes() {
        save?.cancel()
        save = nil
        guard dirty, let notesMeetingID, let store else { return }
        do {
            try store.setNotes(notesMeetingID, notesText)
            if let meeting = try store.meeting(notesMeetingID), meeting.status.isFinished {
                try store.enqueue(notesMeetingID)
                hq?.sync()
            }
            dirty = false
        } catch {
            log.error("Saving notes failed: \(String(describing: error), privacy: .public)")
        }
    }

    private var transcriptLines: [TranscriptText.Line] {
        detail.items.compactMap { item -> TranscriptText.Line? in
            guard case .segment(let segment) = item else { return nil }
            return TranscriptText.Line(label: speaker(of: segment)?.displayName ?? segment.stream.label,
                                       start: segment.start, text: segment.text)
        }
    }

    func copyTranscript() {
        copy(TranscriptText.plain(transcriptLines))
    }

    func copyNotes() {
        flushNotes()
        copy(notesText)
    }

    /// Title, when, who, the notes and the transcript as Markdown, for pasting into anything.
    func copyMeeting() {
        guard let meeting = selected else { return }
        flushNotes()
        var meta = [meeting.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())]
        if meeting.status.isFinished {
            meta.append(Duration.seconds(max(0, meeting.duration)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
        }
        if let others = detail.calendarEvent?.others, !others.isEmpty {
            meta.append(others.map(\.name).joined(separator: ", "))
        }
        copy(TranscriptText.markdown(title: displayTitle(for: meeting), meta: meta, notes: notesText, lines: transcriptLines))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func rename(_ title: String, for id: UUID) {
        guard let store, let meeting = try? store.meeting(id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.setTitle(id, trimmed.isEmpty ? nil : trimmed)
            if meeting.status == .done {
                try store.enqueue(id)
                hq?.sync()
            }
        } catch {
            log.error("Rename failed: \(String(describing: error), privacy: .public)")
        }
        reload()
    }

    func speaker(of segment: Segment) -> Speaker? {
        guard segment.stream != .me else { return nil }
        return segment.speakerID.flatMap { detail.speakers[$0] }
    }

    func name(_ speaker: Speaker, _ name: String) {
        guard let store, let meeting = selected else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.nameSpeaker(speaker.id, trimmed.isEmpty ? nil : trimmed)
            if meeting.status == .done {
                try store.enqueue(meeting.id)
                hq?.sync()
            }
        } catch {
            log.error("Naming a speaker failed: \(String(describing: error), privacy: .public)")
        }
        reloadDetail()
    }

    func delete() {
        guard let store, let meeting = selected, meeting.status.isFinished else { return }
        save?.cancel()
        save = nil
        dirty = false
        notesMeetingID = nil
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
        guard let store, let id = selection else { return }
        do {
            try store.enqueue(id)
        } catch {
            log.error("Queueing for hq failed: \(String(describing: error), privacy: .public)")
        }
        hq?.sync()
        reloadDetail()
    }

    private func loadNotes() {
        flushNotes()
        notesMeetingID = nil
        loadingNotes = true
        notesText = ""
        if let selection, let store {
            notesText = (try? store.notes(selection))?.body ?? ""
            notesMeetingID = selection
        }
        loadingNotes = false
        dirty = false
    }

    private func reloadDetail() {
        guard let store, let id = selection else {
            if detail != Detail() { detail = Detail() }
            return
        }
        let segments = ((try? store.segments(id)) ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let gaps = (try? store.gaps(id)) ?? []
        let items = (segments.map(Item.segment) + gaps.map(Item.gap)).sorted { $0.start < $1.start }
        let outbox = try? store.outboxItem(id)
        let speakers = Dictionary(uniqueKeysWithValues: ((try? store.speakers(id)) ?? []).map { ($0.id, $0) })
        let diarization = (try? store.meeting(id))?.diarization
        let event = ((try? store.calendarEvent(id)) ?? nil).flatMap { try? CalendarEvent.decode($0) }
        let next = Detail(items: items, speakers: speakers,
                          findingSpeakers: diarization == .pending || diarization == .running,
                          rejected: outbox?.state == .rejected ? (outbox?.lastError ?? "No reason given.") : nil,
                          calendarEvent: event)
        if next != detail { detail = next }
    }

    private func preview(_ meeting: Meeting, _ store: MeetingStore) -> String? {
        if let cached = previews[meeting.id] { return cached }
        let text = TranscriptText.firstWords(((try? store.segments(meeting.id)) ?? []).prefix(6).map(\.text))
        if meeting.status.isFinished { previews[meeting.id] = .some(text) }
        return text
    }

    private static func grouped(_ rows: [Row]) -> [Group] {
        var titles: [String] = []
        var rowsByTitle: [String: [Row]] = [:]
        for row in rows {
            let title = groupTitle(for: row.meeting.startedAt)
            if rowsByTitle[title] == nil { titles.append(title) }
            rowsByTitle[title, default: []].append(row)
        }
        return titles.map { Group(title: $0, rows: rowsByTitle[$0] ?? []) }
    }

    private static func groupTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let today = calendar.startOfDay(for: .now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 31
        if days > 0 && days <= 7 { return "Previous 7 Days" }
        if days > 0 && days <= 30 { return "Previous 30 Days" }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

extension MeetingStream {
    var label: String? {
        switch self {
        case .me: "Me"
        case .them: "Them"
        case .room: nil
        }
    }
}

extension Speaker {
    var displayName: String { name ?? label }
}

extension MeetingStatus {
    var isFinished: Bool { self == .done || self == .interrupted }
}

extension Meeting {
    var duration: TimeInterval { (endedAt ?? .now).timeIntervalSince(startedAt) }
}
