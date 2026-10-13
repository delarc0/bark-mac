import AVFoundation
@testable import BarkEngine
import BarkStore
import Foundation
import Testing

/// Two streams built from FLEURS en clips, speech never overlapping, with where each clip sits.
private struct Conversation {
    var me: [Float] = []
    var them: [Float] = []
    /// Per stream, the clips' sample ranges.
    var speech: [MeetingStream: [Range<Int>]] = [:]

    init(clips: [[Float]], pause: Int = 2 * 16_000) {
        for (index, clip) in clips.enumerated() {
            let stream: MeetingStream = index.isMultiple(of: 2) ? .me : .them
            let at = me.count
            speech[stream, default: []].append(at ..< at + clip.count)
            let silence = [Float](repeating: 0, count: clip.count + pause)
            me += stream == .me ? clip + [Float](repeating: 0, count: pause) : silence
            them += stream == .them ? clip + [Float](repeating: 0, count: pause) : silence
        }
    }

    subscript(stream: MeetingStream) -> [Float] { stream == .me ? me : them }
}

@Suite(.serialized)
struct MeetingTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "bark-meeting-\(UUID().uuidString)")

    private func conversation(_ count: Int) throws -> Conversation {
        let ids = try FileManager.default.contentsOfDirectory(atPath: Fixtures.evalSets.appending(path: "fleurs-en/clips").path)
            .filter { $0.hasSuffix(".wav") }.sorted().prefix(count).map { String($0.dropLast(4)) }
        return Conversation(clips: try ids.map { try Fixtures.clip("fleurs-en", $0) })
    }

    /// Feeds both streams in 100 ms blocks, as capture would, up to `fraction` of their length.
    private func feed(_ session: MeetingSession, _ talk: Conversation, upTo fraction: Double = 1) async throws -> Int {
        let end = Int(Double(talk.me.count) * fraction)
        for offset in stride(from: 0, to: end, by: 1_600) {
            for stream in [MeetingStream.me, .them] {
                try await session.feed(Array(talk[stream][offset ..< min(offset + 1_600, end)]), stream: stream)
            }
        }
        return end
    }

    private func waitFor(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while try !condition() {
            #expect(ContinuousClock.now < deadline)
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Each stream's segments in time order, none overlapping the one before.
    private func expectOrdered(_ segments: [Segment]) {
        for stream in MeetingStream.allCases {
            let mine = segments.filter { $0.stream == stream }
            for (a, b) in zip(mine, mine.dropFirst()) { #expect(a.end <= b.start, "\(stream): \(a.end) > \(b.start)") }
        }
    }

    /// Every clip fed (wholly, or in part up to `fed`) overlaps a segment of its stream with words.
    private func expectEveryClipTranscribed(_ segments: [Segment], _ talk: Conversation, fed: Int) {
        for (stream, clips) in talk.speech {
            for clip in clips where clip.lowerBound + 16_000 < fed {
                let from = Double(clip.lowerBound) / 16_000, to = Double(min(clip.upperBound, fed)) / 16_000
                #expect(segments.contains { $0.stream == stream && $0.start < to && $0.end > from && !$0.text.isEmpty },
                        "\(stream) clip at \(from) s has no transcript")
            }
        }
    }

    @Test(.enabled(if: Fixtures.clipsInstalled))
    func segmentsAreCommittedAsTheyAreDecoded() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let talk = try conversation(4)
        let session = try await MeetingSession.start(store: store, transcriber: Fixtures.transcriber.value, language: "en",
                                                     mode: .call, streams: [.me, .them], title: "test")
        let fed = try await feed(session, talk)
        // The last segment of each stream is held for a short one that may join it, so before
        // finish() at least the first clip of each stream is in.
        try await waitFor { try Set(store.segments(session.id).map(\.stream)).count == 2 }
        #expect(try store.meeting(session.id)?.status == .recording)

        let result = try await session.finish()
        let meeting = try #require(try store.meeting(session.id))
        #expect(meeting.status == .done && meeting.endedAt != nil)
        #expect(try store.pendingOutbox().map(\.meetingID) == [session.id])
        let segments = try store.segments(session.id)
        #expect(result.segments == segments.count && result.archiveSeconds != nil)
        #expect(segments.allSatisfy { $0.model == Fixtures.generalID && $0.language == "en" && $0.end - $0.start <= 28.5 })
        expectOrdered(segments)
        expectEveryClipTranscribed(segments, talk, fed: fed)
        for stream in [MeetingStream.me, .them] {
            #expect(!FileManager.default.fileExists(atPath: store.rawAudio(session.id, stream).path))
            #expect(try AVAudioFile(forReading: store.archivedAudio(session.id, stream)).length == AVAudioFramePosition(fed))
        }
    }

    /// A crash mid-meeting: the session is dropped without finish(), after the decodes it had in
    /// flight. Recovery transcribes the rest from disk, losing no audio and decoding none twice.
    @Test(.enabled(if: Fixtures.clipsInstalled))
    func recoveryAfterAKillLosesNothingAndRepeatsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let talk = try conversation(8)
        var session: MeetingSession? = try await MeetingSession.start(
            store: MeetingStore(root: root), transcriber: Fixtures.transcriber.value, language: "en", mode: .call, streams: [.me, .them])
        let id = session!.id
        let fed = try await feed(session!, talk, upTo: 0.7)
        weak var dying = session
        session = nil
        try await waitFor { dying == nil }

        let store = try MeetingStore(root: root) // the relaunch
        #expect(try store.unfinished().map(\.id) == [id])
        let before = try store.segments(id)
        #expect(!before.isEmpty)
        for stream in [MeetingStream.me, .them] {
            #expect(try PCM.sampleCount(store.rawAudio(id, stream)) == fed)
        }

        try await MeetingSession.recover(id, store: store, transcriber: Fixtures.transcriber.value)
        #expect(try store.unfinished().isEmpty)
        let meeting = try #require(try store.meeting(id))
        #expect(meeting.status == .done)
        #expect(abs(meeting.endedAt!.timeIntervalSince(meeting.startedAt) - Double(fed) / 16_000) < 0.01)
        let after = try store.segments(id)
        let recovered = after.filter { segment in !before.contains { $0.id == segment.id } }
        #expect(!recovered.isEmpty)
        for stream in [MeetingStream.me, .them] {
            let resumeAt = before.filter { $0.stream == stream }.map(\.end).max() ?? 0
            #expect(recovered.filter { $0.stream == stream }.allSatisfy { $0.start >= resumeAt })
            #expect(try AVAudioFile(forReading: store.archivedAudio(id, stream)).length == AVAudioFramePosition(fed))
        }
        expectOrdered(after)
        expectEveryClipTranscribed(after, talk, fed: fed)
        #expect(try store.pendingOutbox().map(\.meetingID) == [id])
    }

    @Test(.enabled(if: Fixtures.clipsInstalled))
    func recoveryOfAMeetingWithNothingCommitted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let clip = try Fixtures.clip("fleurs-en")
        var session: MeetingSession? = try await MeetingSession.start(
            store: store, transcriber: Fixtures.transcriber.value, language: "en", mode: .inPerson, streams: [.room])
        let id = session!.id
        try await session!.feed(clip, stream: .room)
        try await session!.markGap(reason: "sleep")
        weak var dying = session
        session = nil
        try await waitFor { dying == nil }
        #expect(try store.gaps(id) == [Gap(at: Double(clip.count) / 16_000, reason: "sleep")])
        // Speech up to the end of the clip is one open segment: nothing was committed.
        #expect(try store.segments(id).isEmpty)

        try await MeetingSession.recover(id, store: store, transcriber: Fixtures.transcriber.value)
        let segments = try store.segments(id)
        #expect(segments.first?.start ?? -1 >= 0 && segments.allSatisfy { $0.stream == .room })
        #expect(segments.map(\.text).joined(separator: " ").split(separator: " ").count > 5)
    }

    @Test(.enabled(if: Fixtures.modelsInstalled))
    func unknownLanguageFailsAtStart() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        await #expect(throws: (any Error).self) {
            try await MeetingSession.start(store: store, transcriber: Fixtures.transcriber.value, language: "xx", mode: .call, streams: [.me])
        }
        #expect(try store.meetings().isEmpty)
    }
}
