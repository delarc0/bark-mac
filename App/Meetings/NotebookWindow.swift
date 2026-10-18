import AppKit
import BarkCore
import BarkStore
import SwiftUI

final class NotebookWindowController: AppWindowController, NSMenuItemValidation {
    static let shared = NotebookWindowController()

    private let model: NotebookModel
    private var timer: Timer?

    private init() {
        let model = NotebookModel(library: .shared)
        self.model = model
        super.init(title: "Bark", styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   content: NotebookView(model: model))
        window?.setContentSize(NSSize(width: 1000, height: 650))
        window?.contentMinSize = NSSize(width: 320, height: 240)
        window?.setFrameAutosaveName("BarkNotebook")
        installNewMeetingCommand()
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
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.flushNotes() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.flushNotes() }
        }
    }

    func connect(_ recorder: MeetingRecorder) {
        model.connect(recorder)
    }

    func recorderChanged(_ state: MeetingRecorder.State) {
        model.recorderChanged(state)
    }

    func present(selecting id: UUID? = nil, activating: Bool = true, focusNotes: Bool = false) {
        model.reload()
        if let id { model.selection = id }
        if activating {
            bringForward()
        } else {
            window?.orderFrontRegardless()
        }
        if focusNotes { model.focusNotes() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        window?.isKeyWindow == true && model.canStart
    }

    private func installNewMeetingCommand() {
        guard let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu else { return }
        let command = NSMenuItem(title: "New Meeting", action: #selector(newMeeting), keyEquivalent: "n")
        command.keyEquivalentModifierMask = .command
        command.target = self
        file.insertItem(command, at: 0)
    }

    @objc private func newMeeting() {
        model.startMeeting()
    }
}

struct NotebookView: View {
    @Bindable var model: NotebookModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var compact = false
    @State private var deleting = false

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $columnVisibility) {
                NotebookSidebar(model: model, delete: requestDelete)
                    .navigationSplitViewColumnWidth(min: 190, ideal: 250, max: 340)
            } detail: {
                if let meeting = model.selected {
                    NotebookDetail(model: model, meeting: meeting, compact: compact, delete: requestDelete)
                } else {
                    ContentUnavailableView("No Meeting Selected", systemImage: "text.alignleft")
                }
            }
            .frame(minWidth: 320, minHeight: 240)
            .onChange(of: geometry.size.width, initial: true) { _, width in
                compact = width < 560
                if compact {
                    columnVisibility = .detailOnly
                } else if columnVisibility == .detailOnly {
                    columnVisibility = .doubleColumn
                }
            }
        }
        .confirmationDialog("Delete this meeting?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { model.delete() }
        } message: {
            Text("Its transcript, notes and audio are deleted from this Mac.")
        }
    }

    private func requestDelete() {
        if model.canDelete { deleting = true }
    }
}

private struct NotebookSidebar: View {
    @Bindable var model: NotebookModel
    let delete: () -> Void

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        NotebookRow(row: row, recording: model.isRecording(row.meeting))
                            .tag(row.id)
                    }
                } header: {
                    Text(group.title)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.rows.isEmpty {
                ContentUnavailableView("No Meetings", systemImage: "waveform")
            }
        }
        .onKeyPress(.delete) {
            guard model.canDelete else { return .ignored }
            delete()
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let calendar = model.calendar, calendar.offersConnect {
                CalendarConnectRow(calendar: calendar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: model.startMeeting) {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Meeting")
                .disabled(!model.canStart)
            }
        }
    }
}

/// One quiet line at the foot of the sidebar until the calendar is connected.
private struct CalendarConnectRow: View {
    let calendar: CalendarLink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Button(action: calendar.connect) {
                Label(calendar.connecting ? "Connecting…" : "Connect Google Calendar", systemImage: "calendar")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(calendar.connecting)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if let problem = calendar.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
    }
}

private struct NotebookRow: View {
    let row: NotebookModel.Row
    let recording: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .lineLimit(1)
                    .foregroundStyle(Color(nsColor: .labelColor))
                HStack(spacing: 5) {
                    Text(row.meeting.startedAt, format: .dateTime.hour().minute())
                    Text("·")
                    if recording {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(durationText(context.date.timeIntervalSince(row.meeting.startedAt)))
                        }
                    } else {
                        Text(durationText(row.meeting.duration))
                    }
                    if !recording && (row.meeting.status == .recording || row.meeting.status == .transcribing) {
                        Text("·")
                        Text("Transcribing")
                    }
                }
                .font(.caption)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            Spacer(minLength: 0)
            if recording {
                Circle()
                    .fill(Color(nsColor: .systemRed))
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Recording")
            }
        }
        .padding(.vertical, 3)
    }

    private var displayTitle: String {
        if let title = row.meeting.title, !title.isEmpty { return title }
        if let preview = row.preview, !preview.isEmpty { return preview }
        return row.meeting.startedAt.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}

private struct NotebookDetail: View {
    @Bindable var model: NotebookModel
    let meeting: Meeting
    let compact: Bool
    let delete: () -> Void
    @State private var followTranscript = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NotebookTitleField(model: model, meeting: meeting)
                        .id(meeting.id)
                    NotebookMetaLine(model: model, meeting: meeting, compact: compact)
                        .padding(.top, 4)
                    if let message = model.detail.rejected {
                        NotebookRejectedNotice(message: message, retry: model.retryUpload)
                            .padding(.top, 12)
                    }
                    NoteEditor(text: $model.notesText, focusToken: model.focusNotesToken)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topLeading) {
                            if model.notesText.isEmpty {
                                Text("Your notes")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 5)
                                    .padding(.top, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                        .padding(.top, 18)
                    if !compact {
                        DisclosureGroup(isExpanded: $model.transcriptOpen) {
                            NotebookTranscript(model: model, meeting: meeting)
                                .padding(.top, 10)
                            Color.clear
                                .frame(height: 1)
                                .id("transcript-end")
                        } label: {
                            HStack(spacing: 6) {
                                Text("Transcript")
                                Text("\(model.transcriptCount)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 18)
                    }
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, compact ? 16 : 24)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
            }
            .onChange(of: model.detail.items.count) {
                guard !compact, meeting.status == .recording, model.transcriptOpen, followTranscript else { return }
                withAnimation { proxy.scrollTo("transcript-end", anchor: .bottom) }
            }
            .onChange(of: model.transcriptOpen) {
                guard !compact, model.transcriptOpen, meeting.status == .recording else { return }
                followTranscript = true
                proxy.scrollTo("transcript-end", anchor: .bottom)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
                if new < old - 1 { followTranscript = false }
            }
            .onScrollGeometryChange(for: CGFloat.self,
                                    of: { $0.contentSize.height - $0.contentOffset.y - $0.containerSize.height }) { _, remaining in
                if remaining < 32 { followTranscript = true }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Copy Notes", action: model.copyNotes)
                        .disabled(model.notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Copy Transcript", action: model.copyTranscript)
                        .disabled(model.transcriptCount == 0)
                    Button("Copy Meeting", action: model.copyMeeting)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy")
                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .help("Delete")
                .disabled(!model.canDelete)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct NotebookTitleField: View {
    let model: NotebookModel
    let meeting: Meeting
    @State private var draft: String
    @State private var committed: String
    @FocusState private var focused: Bool

    init(model: NotebookModel, meeting: Meeting) {
        self.model = model
        self.meeting = meeting
        let title = meeting.title ?? ""
        _draft = State(initialValue: title)
        _committed = State(initialValue: title)
    }

    var body: some View {
        TextField(model.displayTitle(for: meeting), text: $draft)
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.system(size: 26, weight: .semibold))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) {
                if !focused { commit() }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard draft != committed else { return }
        model.rename(draft, for: meeting.id)
        committed = draft
    }
}

private struct NotebookMetaLine: View {
    let model: NotebookModel
    let meeting: Meeting
    let compact: Bool

    var body: some View {
        // Narrow beside a call, the live controls take their own line rather than wrap.
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                info
                if live { controls }
            }
            .font(.callout)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                info
                Spacer(minLength: 0)
                if live { controls }
            }
            .font(.callout)
        }
    }

    private var live: Bool { model.isFinishing(meeting) || model.isRecording(meeting) }

    private var info: some View {
        Text(leftText)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(attendeesHelp)
    }

    @ViewBuilder private var controls: some View {
        if model.isFinishing(meeting) {
            Text("Finishing…")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 7) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text("Recording").foregroundStyle(.red)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(TranscriptText.timestamp(context.date.timeIntervalSince(meeting.startedAt)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("Stop", action: model.stopMeeting)
                    .controlSize(.small)
            }
            .fixedSize()
        }
    }

    private var others: [CalendarAttendee] { model.detail.calendarEvent?.others ?? [] }

    /// "Anna, Johan, Sara +2": the people invited, besides the user.
    private var attendeesText: String? {
        guard !others.isEmpty else { return nil }
        let names = others.prefix(3).map(\.firstName).joined(separator: ", ")
        return others.count > 3 ? "\(names) +\(others.count - 3)" : names
    }

    private var attendeesHelp: String {
        others.map { $0.name == $0.email ? $0.email : "\($0.name) (\($0.email))" }.joined(separator: "\n")
    }

    private var leftText: String {
        let date = meeting.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        var parts = [date]
        if model.isRecording(meeting) {
            if let attendees = attendeesText { parts.append(attendees) }
            return parts.joined(separator: " · ")
        }
        parts.append(durationText(meeting.duration))
        if let attendees = attendeesText {
            parts.append(attendees)
        } else if let speakers = model.speakerCount(for: meeting) {
            parts.append(speakers == 1 ? "1 speaker" : "\(speakers) speakers")
        }
        if !model.isFinishing(meeting) && (meeting.status == .recording || meeting.status == .transcribing) {
            parts.append("Transcribing")
        }
        if meeting.status == .interrupted { parts.append("Interrupted") }
        return parts.joined(separator: " · ")
    }
}

private struct NotebookRejectedNotice: View {
    let message: String
    let retry: () -> Void

    var body: some View {
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
                Button("Try Again", action: retry)
            }
            .padding(4)
        }
    }
}

private func durationText(_ duration: TimeInterval) -> String {
    Duration.seconds(max(0, duration)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}
