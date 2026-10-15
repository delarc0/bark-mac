import AVFoundation
@testable import BarkStore
import Foundation
import SQLite3
import Testing

struct MeetingStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "bark-meetings-\(UUID().uuidString)")

    @Test func migratesOnceAndKeepsData() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try MeetingStore(root: root)
        #expect(first.schemaVersion == MeetingStore.migrations.count)
        let meeting = try first.createMeeting(language: "sv", mode: .call, title: "Tegen")
        let reopened = try MeetingStore(root: root)
        #expect(reopened.schemaVersion == MeetingStore.migrations.count)
        #expect(try reopened.meeting(meeting.id) == meeting)
        var journal = ""
        _ = try Database(path: root.appending(path: "bark.sqlite").path, migrations: MeetingStore.migrations)
            .query("PRAGMA journal_mode") { journal = $0.text(0) }
        #expect(journal == "wal")
    }

    @Test func refusesAStoreFromANewerBark() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try MeetingStore(root: root)
        var db: OpaquePointer?
        sqlite3_open(root.appending(path: "bark.sqlite").path, &db)
        sqlite3_exec(db, "PRAGMA user_version = 99", nil, nil, nil)
        sqlite3_close(db)
        #expect(throws: StoreError.self) { try MeetingStore(root: root) }
    }

    @Test func meetingCRUD() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = try store.createMeeting(language: "sv", mode: .inPerson, startedAt: start)
        #expect(meeting.status == .recording && meeting.mode == .inPerson && meeting.title == nil && meeting.startedAt == start)
        #expect(FileManager.default.fileExists(atPath: store.folder(meeting.id).path))
        try store.setTitle(meeting.id, "Bionic weekly")
        try store.setStatus(meeting.id, .transcribing, endedAt: start.addingTimeInterval(60))
        #expect(try store.unfinished().map(\.id) == [meeting.id])
        try store.finish(meeting.id, endedAt: start.addingTimeInterval(61))
        let done = try #require(try store.meeting(meeting.id))
        #expect(done.status == .done && done.title == "Bionic weekly" && done.endedAt == start.addingTimeInterval(61))
        #expect(try store.unfinished().isEmpty)
        #expect(try store.pendingOutbox().map(\.meetingID) == [meeting.id])

        let speaker = try store.addSpeaker("SPEAKER_1", to: meeting.id)
        try store.nameSpeaker(speaker, "Jossan")
        #expect(try store.speakers(meeting.id) == [Speaker(id: speaker, label: "SPEAKER_1", name: "Jossan")])
        let later = try store.addSegment(Segment(stream: .them, start: 5, end: 9, text: "Hej", model: "kb-whisper-large-8bit", language: "sv"), to: meeting.id)
        let earlier = try store.addSegment(Segment(stream: .me, start: 1, end: 4, text: "Hallå", model: "kb-whisper-large-8bit",
                                                   language: "sv", redecoded: true), to: meeting.id)
        try store.setSpeaker(speaker, forSegment: later)
        let segments = try store.segments(meeting.id)
        #expect(segments.map(\.id) == [earlier, later])
        #expect(segments[0].redecoded && segments[0].stream == .me && segments[1].speakerID == speaker)
        #expect(try store.committedEnd(meeting.id, .them) == 9)
        #expect(try store.committedEnd(meeting.id, .room) == nil)

        try store.setNotes(meeting.id, "ask about pricing", at: start)
        try store.setNotes(meeting.id, "ask about pricing\nsend deck", at: start.addingTimeInterval(5))
        #expect(try store.notes(meeting.id) == Notes(body: "ask about pricing\nsend deck", updatedAt: start.addingTimeInterval(5)))
        try store.addGap(meeting.id, at: 30, reason: "sleep")
        #expect(try store.gaps(meeting.id) == [Gap(at: 30, reason: "sleep")])

        try store.delete(meeting.id)
        #expect(try store.meeting(meeting.id) == nil)
        #expect(try store.segments(meeting.id).isEmpty && store.speakers(meeting.id).isEmpty && store.pendingOutbox().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.folder(meeting.id).path))
    }

    @Test func outboxQueue() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let a = try store.createMeeting(language: "sv", mode: .call).id
        let b = try store.createMeeting(language: "en", mode: .call).id
        try store.enqueue(a)
        try store.enqueue(b)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try store.outboxFailed(a, generation: 1, error: "hq 503", at: t))
        #expect(try store.outboxFailed(a, generation: 1, error: "timeout", at: t.addingTimeInterval(60)))
        #expect(try store.pendingOutbox() == [
            OutboxItem(meetingID: a, state: .pending, generation: 1, attempts: 2, lastError: "timeout", lastAttemptAt: t.addingTimeInterval(60)),
            OutboxItem(meetingID: b, state: .pending, generation: 1, attempts: 0, lastError: nil, lastAttemptAt: nil),
        ])
        #expect(try store.outboxAcknowledged(a, generation: 1))
        #expect(try store.pendingOutbox().map(\.meetingID) == [b])
        // A meeting changed after hq has it goes out again, as a new generation.
        try store.enqueue(a)
        #expect(try store.outboxItem(a) == OutboxItem(meetingID: a, state: .pending, generation: 2, attempts: 0, lastError: nil, lastAttemptAt: nil))
        #expect(try Set(store.pendingOutbox().map(\.meetingID)) == [a, b])

        #expect(try store.outboxRejected(b, generation: 1, message: "too long", at: t))
        #expect(try store.pendingOutbox().map(\.meetingID) == [a])
        #expect(try store.rejectedOutbox() == [
            OutboxItem(meetingID: b, state: .rejected, generation: 1, attempts: 1, lastError: "too long", lastAttemptAt: t),
        ])
        #expect(try !store.outboxAcknowledged(b, generation: 1))
        try store.enqueue(b)
        #expect(try store.outboxItem(b)?.state == .pending && store.outboxItem(b)?.generation == 2 && store.rejectedOutbox().isEmpty)
        // Reopening keeps the queue.
        #expect(try MeetingStore(root: root).pendingOutbox().count == 2)
    }

    @Test func outboxIgnoresResultsForAnOlderGeneration() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let id = try store.createMeeting(language: "sv", mode: .call).id
        try store.enqueue(id)
        let uploading = try #require(try store.outboxItem(id)).generation
        try store.enqueue(id)
        #expect(try !store.outboxAcknowledged(id, generation: uploading))
        #expect(try !store.outboxFailed(id, generation: uploading, error: "HTTP 503"))
        #expect(try !store.outboxRejected(id, generation: uploading, message: "invalid"))
        #expect(try store.pendingOutbox() == [
            OutboxItem(meetingID: id, state: .pending, generation: uploading + 1, attempts: 0, lastError: nil, lastAttemptAt: nil),
        ])
    }

    @Test func upgradesTheV1Outbox() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appending(path: "bark.sqlite").path
        let a = UUID(), b = UUID(), c = UUID()
        do {
            let v1 = try Database(path: path, migrations: [MeetingStore.migrations[0]])
            #expect(v1.userVersion == 1)
            for id in [a, b, c] {
                try v1.run("INSERT INTO meetings (id, started_at, language, mode, status) VALUES (?, 0, 'sv', 'call', 'done')", [id.uuidString])
            }
            try v1.run("INSERT INTO outbox (meeting_id, state, attempts, last_error) VALUES (?, 'pending', 2, 'HTTP 503')", [c.uuidString])
            try v1.run("INSERT INTO outbox (meeting_id, state) VALUES (?, 'acknowledged')", [a.uuidString])
            try v1.run("INSERT INTO outbox (meeting_id, state) VALUES (?, 'pending')", [b.uuidString])
        }

        let store = try MeetingStore(root: root)
        #expect(store.schemaVersion == MeetingStore.migrations.count)
        #expect(try store.pendingOutbox() == [
            OutboxItem(meetingID: c, state: .pending, generation: 1, attempts: 2, lastError: "HTTP 503", lastAttemptAt: nil),
            OutboxItem(meetingID: b, state: .pending, generation: 1, attempts: 0, lastError: nil, lastAttemptAt: nil),
        ])
        #expect(try store.outboxItem(a)?.state == .acknowledged)
        #expect(try store.outboxRejected(c, generation: 1, message: "too long"))
        try store.delete(b)
        #expect(try store.outboxItem(b) == nil)
        #expect(try MeetingStore(root: root).schemaVersion == MeetingStore.migrations.count)
    }

    @Test func upgradesV2AndQueuesFinishedMeetingsForSpeakers() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appending(path: "bark.sqlite").path
        let done = UUID(), expired = UUID(), recording = UUID()
        do {
            let v2 = try Database(path: path, migrations: Array(MeetingStore.migrations.prefix(2)))
            #expect(v2.userVersion == 2)
            try v2.run("INSERT INTO meetings (id, started_at, language, mode, status) VALUES (?, 0, 'sv', 'call', 'done')", [done.uuidString])
            try v2.run("INSERT INTO meetings (id, started_at, language, mode, status, audio_deleted_at) VALUES (?, 1, 'sv', 'call', 'done', 5)",
                       [expired.uuidString])
            try v2.run("INSERT INTO meetings (id, started_at, language, mode, status) VALUES (?, 2, 'en', 'in_person', 'recording')",
                       [recording.uuidString])
            let speaker = try v2.insert("INSERT INTO speakers (meeting_id, label, name) VALUES (?, 'SPEAKER_1', 'Anna')", [done.uuidString])
            try v2.run("""
                INSERT INTO segments (meeting_id, stream, start_s, end_s, text, model, language, speaker_id)
                VALUES (?, 'them', 1, 2, 'Hej', 'kb', 'sv', ?)
                """, [done.uuidString, speaker])
            try v2.run("INSERT INTO outbox (meeting_id, state, generation) VALUES (?, 'acknowledged', 3)", [done.uuidString])
        }

        let store = try MeetingStore(root: root)
        #expect(store.schemaVersion == 3)
        #expect(try store.meeting(done)?.diarization == .pending)
        #expect(try store.meeting(expired)?.diarization == nil)
        #expect(try store.meeting(recording)?.diarization == nil)
        #expect(try store.pendingDiarization().map(\.id) == [done])
        #expect(try store.speakers(done).map(\.name) == ["Anna"])
        #expect(try store.segments(done).first?.speakerID != nil)
        #expect(try store.outboxItem(done) == OutboxItem(meetingID: done, state: .acknowledged, generation: 3, attempts: 0,
                                                         lastError: nil, lastAttemptAt: nil))
        #expect(try MeetingStore(root: root).schemaVersion == 3)
    }

    @Test func speakersAreSavedAfterTheMeetingIsDone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let id = try store.createMeeting(language: "sv", mode: .call).id
        #expect(try store.meeting(id)?.diarization == nil)
        let a = try store.addSegment(Segment(stream: .me, start: 0, end: 2, text: "Hej", model: "kb", language: "sv"), to: id)
        let b = try store.addSegment(Segment(stream: .them, start: 2, end: 5, text: "Hallå", model: "kb", language: "sv"), to: id)
        let c = try store.addSegment(Segment(stream: .them, start: 5, end: 6, text: " ", model: "kb", language: "sv"), to: id)
        try store.finish(id, endedAt: .now)
        #expect(try store.meeting(id)?.status == .done && store.meeting(id)?.diarization == .pending)
        #expect(try store.pendingDiarization().map(\.id) == [id])
        try store.outboxAcknowledged(id, generation: 1)

        try store.setDiarization(id, .running)
        #expect(try store.pendingDiarization().isEmpty)
        try store.saveSpeakers(id, labels: ["Me", "Speaker 1"], assignments: [a: 0, b: 1])
        let speakers = try store.speakers(id)
        #expect(speakers.map(\.label) == ["Me", "Speaker 1"] && speakers.allSatisfy { $0.name == nil })
        #expect(try store.segments(id).map(\.speakerID) == [speakers[0].id, speakers[1].id, nil])
        #expect(try store.meeting(id)?.diarization == .done)
        #expect(try store.outboxItem(id)?.state == .pending && store.outboxItem(id)?.generation == 2)

        // Saving again replaces the speakers; no segment keeps a stale one.
        try store.saveSpeakers(id, labels: ["Speaker 1"], assignments: [c: 0])
        #expect(try store.speakers(id).map(\.label) == ["Speaker 1"])
        #expect(try store.segments(id).map { $0.speakerID != nil } == [false, false, true])
    }

    @Test func aDiarizationCutShortIsNotRetried() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let crashed = try store.createMeeting(language: "sv", mode: .call).id
        let waiting = try store.createMeeting(language: "sv", mode: .inPerson).id
        try store.finish(crashed, endedAt: .now)
        try store.finish(waiting, endedAt: .now)
        try store.setDiarization(crashed, .running)
        #expect(try store.failInterruptedDiarization() == 1)
        #expect(try store.meeting(crashed)?.diarization == .failed)
        #expect(try store.pendingDiarization().map(\.id) == [waiting])
    }

    @Test func pcmAppendsSurviveAnUnclosedWriter() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "me.pcm")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tone = (0 ..< 40_000).map { Float(sin(Double($0) * 0.05) * 0.5) }
        var writer: PCMWriter? = try PCMWriter(url: url)
        try writer!.append(Array(tone.prefix(30_000)))
        writer = nil // no close(): what a crash leaves
        // A torn last write leaves half a sample; it is ignored and dropped on reopen.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7f]))
        try handle.close()
        #expect(try PCM.sampleCount(url) == 30_000)
        let resumed = try PCMWriter(url: url)
        #expect(resumed.count == 30_000)
        try resumed.append(Array(tone.suffix(10_000)))
        try resumed.close()
        let back = try PCM.read(url, from: 0, count: 50_000)
        #expect(back.count == 40_000)
        #expect(zip(back, tone).allSatisfy { abs($0 - $1) <= 1.0 / 32768 })
        #expect(try PCM.read(url, from: 39_990, count: 100).count == 10)
    }

    @Test func archiveIsLosslessAndDeletesThePCM() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = try store.createMeeting(language: "sv", mode: .call)
        // 2.5 blocks of the archiver, an odd length.
        let samples: [Float] = (0 ..< 163_841).map { i in
            let t = Double(i)
            return Float(0.3 * sin(t * 0.01) + 0.1 * sin(t * 0.37))
        }
        let writer = try PCMWriter(url: store.rawAudio(meeting.id, .me))
        try writer.append(samples)
        try writer.close()
        let raw = try PCM.read(store.rawAudio(meeting.id, .me), from: 0, count: samples.count)
        try store.archiveAudio(meeting.id)
        #expect(!FileManager.default.fileExists(atPath: store.rawAudio(meeting.id, .me).path))
        let file = try AVAudioFile(forReading: store.archivedAudio(meeting.id, .me), commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.length == AVAudioFramePosition(samples.count))
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        try file.read(into: buffer)
        let decoded = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        #expect(decoded == raw)
        let size = try FileManager.default.attributesOfItem(atPath: store.archivedAudio(meeting.id, .me).path)[.size] as! Int
        #expect(size < samples.count * 2)
    }

    @Test func retentionDeletesOldAudioAndKeepsTranscripts() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func meeting(endedDaysAgo days: Double, status: MeetingStatus) throws -> UUID {
            let id = try store.createMeeting(language: "sv", mode: .call, startedAt: now.addingTimeInterval(-days * 86_400 - 3_600)).id
            let writer = try PCMWriter(url: store.rawAudio(id, .them))
            try writer.append([Float](repeating: 0.1, count: 16_000))
            try writer.close()
            if status == .done {
                try store.finish(id, endedAt: now.addingTimeInterval(-days * 86_400))
                try store.archiveAudio(id)
            } else {
                try store.setStatus(id, status)
            }
            try store.addSegment(Segment(stream: .them, start: 0, end: 1, text: "Hej", model: "m", language: "sv"), to: id)
            return id
        }
        let old = try meeting(endedDaysAgo: 31, status: .done)
        let recent = try meeting(endedDaysAgo: 29, status: .done)
        let unfinished = try meeting(endedDaysAgo: 40, status: .recording)
        #expect(try store.deleteExpiredAudio(now: now) == [old])
        #expect(!FileManager.default.fileExists(atPath: store.archivedAudio(old, .them).path))
        #expect(try store.meeting(old)?.audioDeletedAt == now)
        #expect(try store.segments(old).map(\.text) == ["Hej"])
        #expect(FileManager.default.fileExists(atPath: store.archivedAudio(recent, .them).path))
        // An unfinished meeting's audio is what recovery needs: never expired.
        #expect(FileManager.default.fileExists(atPath: store.rawAudio(unfinished, .them).path))
        #expect(try store.deleteExpiredAudio(now: now).isEmpty)
    }

    @Test func leftoverPCMOfAFinishedMeetingIsArchived() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let done = try store.createMeeting(language: "sv", mode: .call).id
        let recording = try store.createMeeting(language: "sv", mode: .call).id
        for id in [done, recording] {
            let writer = try PCMWriter(url: store.rawAudio(id, .me))
            try writer.append([Float](repeating: 0.2, count: 8_000))
            try writer.close()
        }
        try store.finish(done, endedAt: .now)
        try store.archiveLeftovers()
        #expect(FileManager.default.fileExists(atPath: store.archivedAudio(done, .me).path))
        #expect(!FileManager.default.fileExists(atPath: store.rawAudio(done, .me).path))
        #expect(FileManager.default.fileExists(atPath: store.rawAudio(recording, .me).path))
    }
}
