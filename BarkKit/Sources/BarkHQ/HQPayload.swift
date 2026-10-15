import BarkStore
import Foundation

/// The body of `PUT /api/bark/meetings/{id}`, contract v1 (tasks/bark-hq-api.md).
struct MeetingPayload: Encodable {
    struct Info: Encodable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date?
        let title: String?
        let language: String
        let mode: MeetingMode

        enum CodingKeys: String, CodingKey { case id, startedAt = "started_at", endedAt = "ended_at", title, language, mode }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id.uuidString.lowercased(), forKey: .id)
            try container.encode(HQTime.format(startedAt), forKey: .startedAt)
            try container.encode(endedAt.map(HQTime.format), forKey: .endedAt)
            try container.encode(title, forKey: .title)
            try container.encode(language, forKey: .language)
            try container.encode(mode.rawValue, forKey: .mode)
        }
    }

    struct SegmentItem: Encodable {
        let stream: MeetingStream
        let start: Double
        let end: Double
        let text: String
        let speaker: String?

        enum CodingKeys: String, CodingKey { case stream, start = "start_s", end = "end_s", text, speaker }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(stream.rawValue, forKey: .stream)
            try container.encode(HQTime.seconds(start), forKey: .start)
            try container.encode(HQTime.seconds(end), forKey: .end)
            try container.encode(text, forKey: .text)
            try container.encode(speaker, forKey: .speaker)
        }
    }

    struct SpeakerItem: Encodable {
        let label: String
        let name: String?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(label, forKey: .label)
            try container.encode(name, forKey: .name)
        }

        enum CodingKeys: String, CodingKey { case label, name }
    }

    struct GapItem: Encodable {
        let at: Double
        let reason: String

        enum CodingKeys: String, CodingKey { case at = "at_s", reason }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(HQTime.seconds(at), forKey: .at)
            try container.encode(reason, forKey: .reason)
        }
    }

    let meeting: Info
    let segments: [SegmentItem]
    let speakers: [SpeakerItem]
    let notes: String?
    let gaps: [GapItem]
    let appVersion: String

    enum CodingKeys: String, CodingKey { case meeting, segments, speakers, notes, gaps, appVersion = "app_version" }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meeting, forKey: .meeting)
        try container.encode(segments, forKey: .segments)
        try container.encode(speakers, forKey: .speakers)
        try container.encode(notes, forKey: .notes)
        try container.encode(gaps, forKey: .gaps)
        try container.encode(appVersion, forKey: .appVersion)
    }

    /// Segments the model heard no words in stay on the Mac.
    init(meeting id: UUID, store: MeetingStore, appVersion: String) throws {
        guard let meeting = try store.meeting(id) else { throw StoreError("no meeting \(id)") }
        let speakers = try store.speakers(id)
        let labels = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.label) })
        self.meeting = Info(id: meeting.id, startedAt: meeting.startedAt, endedAt: meeting.endedAt, title: meeting.title,
                            language: meeting.language, mode: meeting.mode)
        segments = try store.segments(id)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { SegmentItem(stream: $0.stream, start: $0.start, end: $0.end, text: $0.text, speaker: $0.speakerID.flatMap { labels[$0] }) }
        self.speakers = speakers.map { SpeakerItem(label: $0.label, name: $0.name) }
        notes = try store.notes(id)?.body
        gaps = try store.gaps(id).map { GapItem(at: $0.at, reason: $0.reason) }
        self.appVersion = appVersion
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// The body of `GET /api/bark/deletions`.
struct DeletionsResponse: Decodable {
    let deleted: [String]
    let serverTime: String

    enum CodingKeys: String, CodingKey { case deleted, serverTime = "server_time" }
}

enum HQTime {
    static func format(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func parse(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    /// Millisecond precision, so 4.2 is sent as 4.2 and not 4.199999999999999.
    static func seconds(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}
