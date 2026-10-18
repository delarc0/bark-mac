import BarkCore
import BarkStore
import SwiftUI

struct NotebookTranscript: View {
    let model: NotebookModel
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.detail.findingSpeakers && !model.detail.items.isEmpty {
                Text("Finding who said what…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.detail.items.isEmpty {
                Text(meeting.status.isFinished ? "Nothing was transcribed." : "Nothing transcribed yet.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.detail.items) { item in
                        NotebookTranscriptRow(model: model, item: item)
                    }
                }
            }
        }
    }
}

private struct NotebookTranscriptRow: View {
    let model: NotebookModel
    let item: NotebookModel.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(TranscriptText.timestamp(item.start))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            switch item {
            case .segment(let segment):
                if let speaker = model.speaker(of: segment) {
                    NotebookSpeakerLabel(model: model, speaker: speaker)
                } else if let label = segment.stream.label {
                    Text(label)
                        .fontWeight(.semibold)
                        .foregroundStyle(segment.stream == .me ? .primary : .secondary)
                        .frame(width: NotebookSpeakerLabel.width, alignment: .leading)
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

private struct NotebookSpeakerLabel: View {
    static let width: CGFloat = 96
    let model: NotebookModel
    let speaker: Speaker
    @State private var naming = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = speaker.name ?? ""
            naming = true
        } label: {
            Text(speaker.displayName)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .help("Name this speaker")
        .frame(width: Self.width, alignment: .leading)
        .popover(isPresented: $naming, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                let invited = model.detail.calendarEvent?.others ?? []
                if !invited.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(invited, id: \.email) { attendee in
                            Button {
                                model.name(speaker, attendee.name == attendee.email ? attendee.firstName : attendee.name)
                                naming = false
                            } label: {
                                Text(attendee.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                    Divider()
                }
                TextField(speaker.label, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.name(speaker, draft)
                        naming = false
                    }
            }
            .frame(width: 200)
            .padding(12)
        }
    }
}
