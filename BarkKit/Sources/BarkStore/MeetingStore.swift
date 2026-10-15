import Foundation

public enum MeetingMode: String, Sendable {
    case call
    case inPerson = "in_person"
    case hybrid
}

public enum MeetingStatus: String, Sendable {
    case recording, transcribing, done, interrupted
}

/// Who said what, worked out after the meeting is done: the transcript never waits for it.
public enum DiarizationState: String, Sendable {
    case pending, running, done, failed
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
    /// nil until the meeting is done.
    public let diarization: DiarizationState?
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

/// A meeting queued for hq. The row stays until hq acknowledges it or rejects it for good.
public struct OutboxItem: Sendable, Equatable {
    public enum State: String, Sendable { case pending, acknowledged, rejected }
    public let meetingID: UUID
    public let state: State
    /// Bumped by every enqueue; a result reported for an older generation is ignored, so a meeting
    /// queued again while its upload was in flight is sent again.
    public let generation: Int64
    public let attempts: Int
    /// The last failure, or for a rejected meeting hq's reason.
    public let lastError: String?
    public let lastAttemptAt: Date?
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
        // v2: outbox gains the rejected state, a generation per enqueue and the last attempt's time.
        """
        CREATE TABLE outbox_v2 (
            meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
            state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
            generation INTEGER NOT NULL DEFAULT 1,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            last_attempt_at REAL
        );
        INSERT INTO outbox_v2 (meeting_id, state, attempts, last_error)
            SELECT meeting_id, state, attempts, last_error FROM outbox ORDER BY rowid;
        DROP TABLE outbox;
        ALTER TABLE outbox_v2 RENAME TO outbox;
        """,
        // v3: speakers are found after a meeting is done; finished meetings with audio get them too.
        """
        ALTER TABLE meetings ADD COLUMN diarization TEXT CHECK (diarization IN ('pending', 'running', 'done', 'failed'));
        UPDATE meetings SET diarization = 'pending' WHERE status = 'done' AND audio_deleted_at IS NULL;
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

    private static let meetingColumns = "id, started_at, ended_at, title, language, mode, status, audio_deleted_at, diarization"

    private static func meeting(_ row: SQLRow) throws -> Meeting {
        guard let id = UUID(uuidString: row.text(0)), let mode = MeetingMode(rawValue: row.text(5)),
              let status = MeetingStatus(rawValue: row.text(6)) else { throw StoreError("malformed meeting row \(row.text(0))") }
        let diarization = try row.optionalText(8).map { text in
            guard let state = DiarizationState(rawValue: text) else { throw StoreError("malformed meeting row \(row.text(0))") }
            return state
        }
        return Meeting(id: id, startedAt: Date(timeIntervalSince1970: row.double(1)),
                       endedAt: row.optionalDouble(2).map(Date.init(timeIntervalSince1970:)),
                       title: row.optionalText(3), language: row.text(4), mode: mode, status: status,
                       audioDeletedAt: row.optionalDouble(7).map(Date.init(timeIntervalSince1970:)), diarization: diarization)
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

    /// Marks the meeting done, queues it for hq and leaves its speakers to be found, in one transaction.
    public func finish(_ id: UUID, endedAt: Date) throws {
        try db.transaction {
            try setStatus(id, .done, endedAt: endedAt)
            try setDiarization(id, .pending)
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

    public func setDiarization(_ id: UUID, _ state: DiarizationState) throws {
        try db.run("UPDATE meetings SET diarization = ? WHERE id = ?", [state.rawValue, id.uuidString])
    }

    /// Done meetings whose speakers are still to be found, oldest first.
    public func pendingDiarization() throws -> [Meeting] {
        try db.query("SELECT \(Self.meetingColumns) FROM meetings WHERE status = 'done' AND diarization = 'pending' ORDER BY started_at",
                     [], Self.meeting)
    }

    /// Diarizations a crash or kill cut short are marked failed, not retried, so a meeting that
    /// crashes the diarizer cannot crash every launch. Returns how many there were.
    @discardableResult
    public func failInterruptedDiarization() throws -> Int {
        try db.run("UPDATE meetings SET diarization = 'failed' WHERE diarization = 'running'")
    }

    /// Replaces the meeting's speakers with `labels` (names unset) and points each segment in
    /// `assignments` (segment id to an index in `labels`) at its speaker; other segments get none.
    /// Each segment in `replacing` is swapped for its pieces, each with its own speaker. Marks
    /// diarization done and queues the meeting for hq again, in one transaction.
    public func saveSpeakers(_ meeting: UUID, labels: [String], assignments: [Int64: Int],
                             replacing: [Int64: [(segment: Segment, speaker: Int?)]] = [:]) throws {
        try db.transaction {
            try db.run("UPDATE segments SET speaker_id = NULL WHERE meeting_id = ?", [meeting.uuidString])
            try db.run("DELETE FROM speakers WHERE meeting_id = ?", [meeting.uuidString])
            let ids = try labels.map { try addSpeaker($0, to: meeting) }
            for (segment, index) in assignments {
                try db.run("UPDATE segments SET speaker_id = ? WHERE id = ? AND meeting_id = ?", [ids[index], segment, meeting.uuidString])
            }
            for (original, pieces) in replacing {
                guard try db.run("DELETE FROM segments WHERE id = ? AND meeting_id = ?", [original, meeting.uuidString]) == 1 else {
                    throw StoreError("no segment \(original) in meeting \(meeting)")
                }
                for (piece, speaker) in pieces {
                    var piece = piece
                    piece.speakerID = speaker.map { ids[$0] }
                    try addSegment(piece, to: meeting)
                }
            }
            try setDiarization(meeting, .done)
            try enqueue(meeting)
        }
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

    /// Queues the meeting as a new generation; a meeting already queued, acknowledged or rejected is
    /// queued afresh.
    public func enqueue(_ meeting: UUID) throws {
        try db.run("""
            INSERT INTO outbox (meeting_id, state) VALUES (?, 'pending')
            ON CONFLICT (meeting_id) DO UPDATE SET state = 'pending', generation = generation + 1, attempts = 0,
                last_error = NULL, last_attempt_at = NULL
            """, [meeting.uuidString])
    }

    private func outbox(where condition: String, _ arguments: [SQLBindable?]) throws -> [OutboxItem] {
        try db.query("""
            SELECT meeting_id, state, generation, attempts, last_error, last_attempt_at
            FROM outbox WHERE \(condition) ORDER BY rowid
            """, arguments) { row in
            guard let id = UUID(uuidString: row.text(0)), let state = OutboxItem.State(rawValue: row.text(1)) else {
                throw StoreError("malformed outbox row \(row.text(0))")
            }
            return OutboxItem(meetingID: id, state: state, generation: row.int(2), attempts: Int(row.int(3)),
                              lastError: row.optionalText(4), lastAttemptAt: row.optionalDouble(5).map(Date.init(timeIntervalSince1970:)))
        }
    }

    /// Oldest first.
    public func pendingOutbox() throws -> [OutboxItem] {
        try outbox(where: "state = 'pending'", [])
    }

    /// Meetings hq refused for good, oldest first.
    public func rejectedOutbox() throws -> [OutboxItem] {
        try outbox(where: "state = 'rejected'", [])
    }

    public func outboxItem(_ meeting: UUID) throws -> OutboxItem? {
        try outbox(where: "meeting_id = ?", [meeting.uuidString]).first
    }

    // Each result names the generation that was uploaded and is a no-op (false) once it has moved on.

    @discardableResult
    public func outboxFailed(_ meeting: UUID, generation: Int64, error: String, at date: Date = .now) throws -> Bool {
        try db.run("""
            UPDATE outbox SET attempts = attempts + 1, last_error = ?, last_attempt_at = ?
            WHERE meeting_id = ? AND generation = ? AND state = 'pending'
            """, [error, date.timeIntervalSince1970, meeting.uuidString, generation]) == 1
    }

    /// hq refused the meeting for good: it is not retried until it is queued again.
    @discardableResult
    public func outboxRejected(_ meeting: UUID, generation: Int64, message: String, at date: Date = .now) throws -> Bool {
        try db.run("""
            UPDATE outbox SET state = 'rejected', attempts = attempts + 1, last_error = ?, last_attempt_at = ?
            WHERE meeting_id = ? AND generation = ? AND state = 'pending'
            """, [message, date.timeIntervalSince1970, meeting.uuidString, generation]) == 1
    }

    @discardableResult
    public func outboxAcknowledged(_ meeting: UUID, generation: Int64) throws -> Bool {
        try db.run("""
            UPDATE outbox SET state = 'acknowledged', last_error = NULL
            WHERE meeting_id = ? AND generation = ? AND state = 'pending'
            """, [meeting.uuidString, generation]) == 1
    }

    // MARK: Audio

    /// Up to `count` samples of a stream from sample `start`, from its archive or, before that,
    /// its PCM.
    public func readAudio(_ meeting: UUID, _ stream: MeetingStream, from start: Int, count: Int) throws -> [Float] {
        let archived = archivedAudio(meeting, stream)
        guard FileManager.default.fileExists(atPath: archived.path) else { return try PCM.read(rawAudio(meeting, stream), from: start, count: count) }
        return try PCM.readArchive(archived, from: start, count: count)
    }

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
