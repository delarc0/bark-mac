import Foundation

public enum MeetingMode: String, Sendable {
    case call
    case inPerson = "in_person"
    case hybrid
}

public enum MeetingStatus: String, Sendable {
    case recording, transcribing, done, interrupted
}

/// The audio streams of a meeting, never mixed: the mic (me), system audio (them), or a mic that
/// hears the whole room.
public enum MeetingStream: String, Sendable, CaseIterable {
    case me, them, room
}

public struct Meeting: Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let title: String?
    public let language: String
    public let mode: MeetingMode
    public let status: MeetingStatus
    public let audioDeletedAt: Date?
}

/// A decoded stretch of one stream. Times are seconds from the meeting's start. An empty text is a
/// segment the model heard no words in; it is kept so its audio is known to be decoded.
public struct Segment: Sendable, Equatable {
    public var id: Int64?
    public let stream: MeetingStream
    public let start: Double
    public let end: Double
    public let text: String
    /// The model's id (its folder name), e.g. kb-whisper-large-8bit.
    public let model: String
    public let language: String
    public let redecoded: Bool
    public var speakerID: Int64?

    public init(id: Int64? = nil, stream: MeetingStream, start: Double, end: Double, text: String, model: String,
                language: String, redecoded: Bool = false, speakerID: Int64? = nil) {
        self.id = id
        self.stream = stream
        self.start = start
        self.end = end
        self.text = text
        self.model = model
        self.language = language
        self.redecoded = redecoded
        self.speakerID = speakerID
    }
}

public struct Speaker: Sendable, Equatable {
    public let id: Int64
    public let label: String
    public let name: String?
}

/// The user's own notes, kept apart from anything an agent adds.
public struct Notes: Sendable, Equatable {
    public let body: String
    public let updatedAt: Date
}

public struct Gap: Sendable, Equatable {
    public let at: Double
    public let reason: String

    public init(at: Double, reason: String) {
        self.at = at
        self.reason = reason
    }
}

/// A meeting waiting for hq. The row stays until hq acknowledges it.
public struct OutboxItem: Sendable, Equatable {
    public enum State: String, Sendable { case pending, acknowledged }
    public let meetingID: UUID
    public let state: State
    public let attempts: Int
    public let lastError: String?
}

/// Meetings on this Mac: `bark.sqlite` plus one folder per meeting holding its audio, under
/// ~/Library/Application Support/Bark/Meetings. Segments are committed as they are decoded.
public final class MeetingStore: Sendable {
    public static let defaultRoot = URL.applicationSupportDirectory.appending(path: "Bark/Meetings")
    /// Audio is kept this long after a meeting so a better model can re-run it; transcripts stay.
    public static let defaultRetention: TimeInterval = 30 * 86_400

    public let root: URL
    private let db: Database

    static let migrations = [
        """
        CREATE TABLE meetings (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL,
            title TEXT,
            language TEXT NOT NULL,
            mode TEXT NOT NULL CHECK (mode IN ('call', 'in_person', 'hybrid')),
            status TEXT NOT NULL CHECK (status IN ('recording', 'transcribing', 'done', 'interrupted')),
            audio_deleted_at REAL
        );
        CREATE TABLE speakers (
            id INTEGER PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            name TEXT
        );
        CREATE TABLE segments (
            id INTEGER PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            stream TEXT NOT NULL CHECK (stream IN ('me', 'them', 'room')),
            start_s REAL NOT NULL,
            end_s REAL NOT NULL,
            text TEXT NOT NULL,
            model TEXT NOT NULL,
            language TEXT NOT NULL,
            redecoded INTEGER NOT NULL DEFAULT 0,
            speaker_id INTEGER REFERENCES speakers(id) ON DELETE SET NULL
        );
        CREATE INDEX segments_by_meeting ON segments(meeting_id, stream, end_s);
        CREATE TABLE notes (
            meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
            body TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE gaps (
            id INTEGER PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            at_s REAL NOT NULL,
            reason TEXT NOT NULL
        );
        CREATE TABLE outbox (
            meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
            state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged')),
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT
        );
        """,
    ]

    public init(root: URL = MeetingStore.defaultRoot) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try Database(path: root.appending(path: "bark.sqlite").path, migrations: Self.migrations)
    }

    var schemaVersion: Int { db.userVersion }

    public func folder(_ meeting: UUID) -> URL {
        root.appending(path: meeting.uuidString)
    }

    /// Where a stream's audio is appended while the meeting records.
    public func rawAudio(_ meeting: UUID, _ stream: MeetingStream) -> URL {
        folder(meeting).appending(path: "\(stream.rawValue).pcm")
    }

    /// Where a stream's audio lives once the meeting is archived.
    public func archivedAudio(_ meeting: UUID, _ stream: MeetingStream) -> URL {
        folder(meeting).appending(path: "\(stream.rawValue).caf")
    }

    // MARK: Meetings

    public func createMeeting(language: String, mode: MeetingMode, title: String? = nil, startedAt: Date = .now) throws -> Meeting {
        let id = UUID()
        try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try db.run("INSERT INTO meetings (id, started_at, title, language, mode, status) VALUES (?, ?, ?, ?, ?, 'recording')",
                   [id.uuidString, startedAt.timeIntervalSince1970, title, language, mode.rawValue])
        return try meeting(id)!
    }

    private static let meetingColumns = "id, started_at, ended_at, title, language, mode, status, audio_deleted_at"

    private static func meeting(_ row: SQLRow) throws -> Meeting {
        guard let id = UUID(uuidString: row.text(0)), let mode = MeetingMode(rawValue: row.text(5)),
              let status = MeetingStatus(rawValue: row.text(6)) else { throw StoreError("malformed meeting row \(row.text(0))") }
        return Meeting(id: id, startedAt: Date(timeIntervalSince1970: row.double(1)),
                       endedAt: row.optionalDouble(2).map(Date.init(timeIntervalSince1970:)),
                       title: row.optionalText(3), language: row.text(4), mode: mode, status: status,
                       audioDeletedAt: row.optionalDouble(7).map(Date.init(timeIntervalSince1970:)))
    }

    public func meeting(_ id: UUID) throws -> Meeting? {
        try db.query("SELECT \(Self.meetingColumns) FROM meetings WHERE id = ?", [id.uuidString], Self.meeting).first
    }

    /// Newest first.
    public func meetings() throws -> [Meeting] {
        try db.query("SELECT \(Self.meetingColumns) FROM meetings ORDER BY started_at DESC", [], Self.meeting)
    }

    /// Meetings a crash or quit left recording or transcribing: offer to finish them (MeetingSession.recover).
    public func unfinished() throws -> [Meeting] {
        try db.query("SELECT \(Self.meetingColumns) FROM meetings WHERE status IN ('recording', 'transcribing') ORDER BY started_at",
                     [], Self.meeting)
    }

    public func setTitle(_ id: UUID, _ title: String?) throws {
        try db.run("UPDATE meetings SET title = ? WHERE id = ?", [title, id.uuidString])
    }

    public func setStatus(_ id: UUID, _ status: MeetingStatus, endedAt: Date? = nil) throws {
        try db.run("UPDATE meetings SET status = ?, ended_at = COALESCE(?, ended_at) WHERE id = ?",
                   [status.rawValue, endedAt?.timeIntervalSince1970, id.uuidString])
    }

    /// Marks the meeting done and queues it for hq, in one transaction.
    public func finish(_ id: UUID, endedAt: Date) throws {
        try db.transaction {
            try setStatus(id, .done, endedAt: endedAt)
            try enqueue(id)
        }
    }

    /// Deletes the meeting, its rows and its audio.
    public func delete(_ id: UUID) throws {
        try db.run("DELETE FROM meetings WHERE id = ?", [id.uuidString])
        try? FileManager.default.removeItem(at: folder(id))
    }

    // MARK: Segments

    @discardableResult
    public func addSegment(_ segment: Segment, to meeting: UUID) throws -> Int64 {
        try db.insert("""
            INSERT INTO segments (meeting_id, stream, start_s, end_s, text, model, language, redecoded, speaker_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [meeting.uuidString, segment.stream.rawValue, segment.start, segment.end, segment.text, segment.model,
                  segment.language, segment.redecoded, segment.speakerID])
    }

    /// In time order, streams interleaved.
    public func segments(_ meeting: UUID) throws -> [Segment] {
        try db.query("""
            SELECT id, stream, start_s, end_s, text, model, language, redecoded, speaker_id
            FROM segments WHERE meeting_id = ? ORDER BY start_s, id
            """, [meeting.uuidString]) { row in
            guard let stream = MeetingStream(rawValue: row.text(1)) else { throw StoreError("malformed segment row \(row.int(0))") }
            return Segment(id: row.int(0), stream: stream, start: row.double(2), end: row.double(3), text: row.text(4),
                           model: row.text(5), language: row.text(6), redecoded: row.int(7) != 0, speakerID: row.optionalInt(8))
        }
    }

    /// Where the stream's committed segments end: decoding resumes there after a crash.
    public func committedEnd(_ meeting: UUID, _ stream: MeetingStream) throws -> Double? {
        try db.query("SELECT MAX(end_s) FROM segments WHERE meeting_id = ? AND stream = ?",
                     [meeting.uuidString, stream.rawValue]) { $0.optionalDouble(0) }.first ?? nil
    }

    public func setSpeaker(_ speaker: Int64?, forSegment segment: Int64) throws {
        try db.run("UPDATE segments SET speaker_id = ? WHERE id = ?", [speaker, segment])
    }

    // MARK: Speakers

    public func addSpeaker(_ label: String, to meeting: UUID) throws -> Int64 {
        try db.insert("INSERT INTO speakers (meeting_id, label) VALUES (?, ?)", [meeting.uuidString, label])
    }

    public func nameSpeaker(_ id: Int64, _ name: String?) throws {
        try db.run("UPDATE speakers SET name = ? WHERE id = ?", [name, id])
    }

    public func speakers(_ meeting: UUID) throws -> [Speaker] {
        try db.query("SELECT id, label, name FROM speakers WHERE meeting_id = ? ORDER BY id", [meeting.uuidString]) {
            Speaker(id: $0.int(0), label: $0.text(1), name: $0.optionalText(2))
        }
    }

    // MARK: Notes and gaps

    public func setNotes(_ meeting: UUID, _ body: String, at date: Date = .now) throws {
        try db.run("""
            INSERT INTO notes (meeting_id, body, updated_at) VALUES (?, ?, ?)
            ON CONFLICT (meeting_id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at
            """, [meeting.uuidString, body, date.timeIntervalSince1970])
    }

    public func notes(_ meeting: UUID) throws -> Notes? {
        try db.query("SELECT body, updated_at FROM notes WHERE meeting_id = ?", [meeting.uuidString]) {
            Notes(body: $0.text(0), updatedAt: Date(timeIntervalSince1970: $0.double(1)))
        }.first
    }

    /// Audio is missing or untranscribed from `at` (seconds from the meeting's start): sleep, a
    /// lost device, a failed decode.
    public func addGap(_ meeting: UUID, at: Double, reason: String) throws {
        try db.run("INSERT INTO gaps (meeting_id, at_s, reason) VALUES (?, ?, ?)", [meeting.uuidString, at, reason])
    }

    public func gaps(_ meeting: UUID) throws -> [Gap] {
        try db.query("SELECT at_s, reason FROM gaps WHERE meeting_id = ? ORDER BY at_s, id", [meeting.uuidString]) {
            Gap(at: $0.double(0), reason: $0.text(1))
        }
    }

    // MARK: Outbox (the durable push queue to hq)

    /// Queues the meeting; a meeting already queued or acknowledged is queued afresh.
    public func enqueue(_ meeting: UUID) throws {
        try db.run("""
            INSERT INTO outbox (meeting_id, state) VALUES (?, 'pending')
            ON CONFLICT (meeting_id) DO UPDATE SET state = 'pending', attempts = 0, last_error = NULL
            """, [meeting.uuidString])
    }

    /// Oldest first.
    public func pendingOutbox() throws -> [OutboxItem] {
        try db.query("SELECT meeting_id, state, attempts, last_error FROM outbox WHERE state = 'pending' ORDER BY rowid", []) { row in
            guard let id = UUID(uuidString: row.text(0)), let state = OutboxItem.State(rawValue: row.text(1)) else {
                throw StoreError("malformed outbox row \(row.text(0))")
            }
            return OutboxItem(meetingID: id, state: state, attempts: Int(row.int(2)), lastError: row.optionalText(3))
        }
    }

    public func outboxFailed(_ meeting: UUID, error: String) throws {
        try db.run("UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE meeting_id = ?", [error, meeting.uuidString])
    }

    public func outboxAcknowledged(_ meeting: UUID) throws {
        try db.run("UPDATE outbox SET state = 'acknowledged', last_error = NULL WHERE meeting_id = ?", [meeting.uuidString])
    }

    // MARK: Audio

    /// Compresses every stream's PCM to Apple Lossless and deletes the PCM once the CAF checks out.
    public func archiveAudio(_ meeting: UUID) throws {
        for stream in MeetingStream.allCases where FileManager.default.fileExists(atPath: rawAudio(meeting, stream).path) {
            try PCM.archive(rawAudio(meeting, stream), to: archivedAudio(meeting, stream))
        }
    }

    /// Archives finished meetings whose PCM is still there (an archive cut short by a quit or crash).
    public func archiveLeftovers() throws {
        for meeting in try meetings() where meeting.status == .done || meeting.status == .interrupted {
            try archiveAudio(meeting.id)
        }
    }

    /// Deletes the audio of finished meetings that ended (or, without an end, started) more than
    /// `retention` ago and marks them; transcripts stay. Returns the meetings it deleted audio for.
    @discardableResult
    public func deleteExpiredAudio(retention: TimeInterval = MeetingStore.defaultRetention, now: Date = .now) throws -> [UUID] {
        let expired = try db.query("""
            SELECT id FROM meetings
            WHERE status IN ('done', 'interrupted') AND audio_deleted_at IS NULL AND COALESCE(ended_at, started_at) < ?
            """, [now.addingTimeInterval(-retention).timeIntervalSince1970]) { UUID(uuidString: $0.text(0)) }.compactMap { $0 }
        for id in expired {
            for stream in MeetingStream.allCases {
                for url in [rawAudio(id, stream), archivedAudio(id, stream)] where FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            try db.run("UPDATE meetings SET audio_deleted_at = ? WHERE id = ?", [now.timeIntervalSince1970, id.uuidString])
        }
        return expired
    }
}
