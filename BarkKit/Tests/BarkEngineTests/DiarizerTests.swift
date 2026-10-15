import AVFoundation
import BarkCore
@testable import BarkEngine
@testable import BarkStore
import Foundation
import Testing

struct DiarizerTests {
    typealias Turn = SpeakerAttribution.Turn

    /// The bundled models, as the app ships them.
    static let models = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../App/Resources/speaker-diarization").standardizedFileURL
    static let ami = URL.applicationSupportDirectory.appending(path: "Bark/eval/ami")
    static var amiInstalled: Bool {
        MeetingDiarizer.modelsPresent(in: models)
            && FileManager.default.fileExists(atPath: ami.appending(path: "mix-headset/TS3003c.wav").path)
            && FileManager.default.fileExists(atPath: ami.appending(path: "rttm/TS3003c.rttm").path)
    }

    @Test func onlyACallsMicIsTheUser() {
        #expect(MeetingDiarizer.role(of: .me, in: .call) == .user)
        #expect(MeetingDiarizer.role(of: .them, in: .call) == .diarize)
        #expect(MeetingDiarizer.role(of: .room, in: .inPerson) == .diarize)
        #expect(MeetingDiarizer.role(of: .me, in: .inPerson) == .diarize)
        #expect(MeetingDiarizer.role(of: .me, in: .hybrid) == .diarize)
    }

    @Test func segmentsGetMeOrSpeakersInOrderOfAppearance() {
        func segment(_ id: Int64, _ stream: MeetingStream, _ start: Double, _ end: Double) -> Segment {
            Segment(id: id, stream: stream, start: start, end: end, text: "x", model: "kb", language: "sv")
        }
        let segments = [segment(1, .me, 0, 2), segment(2, .them, 2, 5), segment(3, .them, 5, 9), segment(4, .me, 9, 10),
                        segment(5, .them, 10, 12), segment(6, .them, 20, 22)]
        // The diarizer calls the second voice 0 and the first 1: labels follow the transcript.
        let turns: [MeetingStream: [Turn]] = [.them: [Turn(speaker: 1, start: 2, end: 5.2), Turn(speaker: 0, start: 5.2, end: 9),
                                                      Turn(speaker: 1, start: 10, end: 12)]]
        let (labels, speakers) = MeetingDiarizer.attribute(segments, mode: .call, turns: turns)
        #expect(labels == ["Me", "Speaker 1", "Speaker 2"])
        #expect(speakers == [0, 1, 2, 0, 1, nil])

        let room = segments.map { segment($0.id!, .room, $0.start, $0.end) }
        let (roomLabels, roomSpeakers) = MeetingDiarizer.attribute(room, mode: .inPerson, turns: [.room: turns[.them]!])
        #expect(roomLabels == ["Speaker 1", "Speaker 2"])
        #expect(roomSpeakers == [nil, 0, 1, nil, 0, nil])

        let empty = MeetingDiarizer.attribute([], mode: .call, turns: [:])
        #expect(empty.labels.isEmpty && empty.speakers.isEmpty)
    }

    /// 90 s of a real meeting with two people and no crosstalk (AMI TS3003c from 885 s), as the
    /// them stream of a call, with segments cut where the reference speaker changes: once from
    /// the PCM, once from the archived audio.
    @Test(.enabled(if: amiInstalled)) func twoSpeakersFromCallAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bark-diarize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let window = 885.0 ..< 975.0
        let audio = try Self.read(Self.ami.appending(path: "mix-headset/TS3003c.wav"), window)
        let reference = try Self.reference(Self.ami.appending(path: "rttm/TS3003c.rttm"), window)
        #expect(Set(reference.map(\.speaker)).count == 2)

        let store = try MeetingStore(root: root)
        let id = try store.createMeeting(language: "en", mode: .call).id
        let writer = try PCMWriter(url: store.rawAudio(id, .them))
        try writer.append(audio)
        try writer.close()
        var truth: [Int64: String] = [:]
        for turn in reference {
            truth[try store.addSegment(Segment(stream: .them, start: turn.start, end: turn.end, text: "words", model: "m", language: "en"),
                                       to: id)] = turn.speaker
        }
        let mine = try store.addSegment(Segment(stream: .me, start: 1, end: 3, text: "hello", model: "m", language: "en"), to: id)
        try store.addSegment(Segment(stream: .them, start: 40, end: 41, text: " ", model: "m", language: "en"), to: id)
        try store.finish(id, endedAt: .now)
        let generation = try #require(try store.outboxItem(id)).generation

        let diarizer = MeetingDiarizer(models: Self.models)
        for archived in [false, true] {
            if archived { try store.archiveAudio(id) }
            #expect(FileManager.default.fileExists(atPath: store.archivedAudio(id, .them).path) == archived)
            let report = try await diarizer.run(id, store: store)
            #expect(report.speakers == 3 && report.segments == truth.count + 1 && abs(report.audioSeconds - 90) < 0.1)

            let speakers = try store.speakers(id)
            #expect(speakers.map(\.label) == ["Me", "Speaker 1", "Speaker 2"])
            let labels = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.label) })
            let segments = try store.segments(id)
            #expect(segments.first { $0.id == mine }?.speakerID.flatMap { labels[$0] } == "Me")
            #expect(segments.first { $0.text == " " }?.speakerID == nil)
            // Each reference speaker maps to one label by majority; nearly all speech agrees with it.
            var votes: [String: [String: Double]] = [:]
            for segment in segments {
                guard let id = segment.id, let who = truth[id], let label = segment.speakerID.flatMap({ labels[$0] }) else { continue }
                votes[who, default: [:]][label, default: 0] += segment.end - segment.start
            }
            let mapping = votes.mapValues { $0.max { $0.value < $1.value }!.key }
            #expect(Set(mapping.values) == ["Speaker 1", "Speaker 2"])
            let right = votes.reduce(0.0) { $0 + ($1.value[mapping[$1.key]!] ?? 0) }
            let total = reference.reduce(0.0) { $0 + $1.end - $1.start }
            #expect(right / total > 0.9, "\(right) of \(total) s attributed to the right speaker")
            #expect(try store.meeting(id)?.diarization == .done)
        }
        #expect(try store.outboxItem(id)?.state == .pending && store.outboxItem(id)?.generation == generation + 2)
    }

    /// A room mic where two people take turns with 0.3 s between them (the two speakers of AMI
    /// TS3003c from 885 s, cut and interleaved), transcribed as segments that each hold both: with
    /// the Transcriber each is cut where the speaker changes and re-decoded, so the right person
    /// gets nearly all the speech. A segment whose model is not loaded keeps its text whole.
    @Test(.enabled(if: amiInstalled && Fixtures.modelsInstalled)) func segmentsHoldingTwoPeopleAreSplit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bark-split-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try Self.read(Self.ami.appending(path: "mix-headset/TS3003c.wav"), 885 ..< 975)
        let a: [Range<Double>] = [0 ..< 4.1, 4.7 ..< 12, 12 ..< 20, 20 ..< 30.8]
        let b: [Range<Double>] = [35.1 ..< 39.3, 64.6 ..< 68.2, 70.5 ..< 75.2, 76.6 ..< 85.1]
        var audio: [Float] = []
        var turns: [(speaker: String, start: Double, end: Double)] = []
        for (speaker, range) in zip(a, b).flatMap({ [("A", $0), ("B", $1)] }) {
            let start = Double(audio.count) / 16_000
            audio += source[Int(range.lowerBound * 16_000) ..< Int(range.upperBound * 16_000)]
            turns.append((speaker, start, Double(audio.count) / 16_000))
            audio += [Float](repeating: 0, count: 4_800)
        }
        let transcriber = try await Fixtures.transcriber.value
        let model = await transcriber.modelID(.general)

        let store = try MeetingStore(root: root)
        let id = try store.createMeeting(language: "en", mode: .inPerson).id
        let writer = try PCMWriter(url: store.rawAudio(id, .room))
        try writer.append(audio)
        try writer.close()
        var foreign: Int64?
        for pair in 0 ..< 4 {
            let last = pair == 3
            let segment = try store.addSegment(Segment(stream: .room, start: turns[2 * pair].start, end: turns[2 * pair + 1].end,
                                                       text: "two people", model: last ? "another-model" : model, language: "en"), to: id)
            if last { foreign = segment }
        }
        let before = try store.segments(id)
        try store.finish(id, endedAt: .now)
        try store.archiveAudio(id)

        let report = try await MeetingDiarizer(models: Self.models).run(id, store: store, transcriber: transcriber)
        #expect(report.split >= 2 && report.keptWhole == 1, "\(report)")
        let segments = try store.segments(id)
        #expect(segments.allSatisfy { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(segments.first { $0.id == foreign }?.text == "two people")
        // Nothing lost: the pieces cover exactly what the originals covered.
        func covered(_ segments: [Segment]) -> Double { segments.reduce(0) { $0 + $1.end - $1.start } }
        #expect(abs(covered(segments) - covered(before)) < 1e-6)

        let labels = Dictionary(uniqueKeysWithValues: try store.speakers(id).map { ($0.id, $0.label) })
        var votes: [String: [String: Double]] = [:]
        for segment in segments where segment.id != foreign {
            guard let label = segment.speakerID.flatMap({ labels[$0] }) else { continue }
            for turn in turns {
                let shared = min(segment.end, turn.end) - max(segment.start, turn.start)
                if shared > 0 { votes[turn.speaker, default: [:]][label, default: 0] += shared }
            }
        }
        let mapping = votes.mapValues { $0.max { $0.value < $1.value }!.key }
        #expect(Set(mapping.values).count == 2)
        let right = votes.reduce(0.0) { $0 + ($1.value[mapping[$1.key]!] ?? 0) }
        let total = votes.values.reduce(0.0) { $0 + $1.values.reduce(0, +) }
        #expect(right / total > 0.8, "\(right) of \(total) s attributed to the right speaker")
    }

    @Test(.enabled(if: MeetingDiarizer.modelsPresent(in: models))) func missingAudioFailsAndLeavesTheTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bark-diarize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let id = try store.createMeeting(language: "sv", mode: .inPerson).id
        try store.addSegment(Segment(stream: .room, start: 0, end: 2, text: "Hej", model: "m", language: "sv"), to: id)
        try store.finish(id, endedAt: .now)
        await #expect(throws: StoreError.self) { try await MeetingDiarizer(models: Self.models).run(id, store: store) }
        #expect(try store.meeting(id)?.diarization == .failed)
        #expect(try store.segments(id).map(\.text) == ["Hej"] && store.speakers(id).isEmpty)
    }

    /// Reference turns inside `window`, shifted to start at 0, with a speaker's turns less than
    /// 0.5 s apart merged, the way a pause-closed segment would hold them.
    static func reference(_ rttm: URL, _ window: Range<Double>) throws -> [(speaker: String, start: Double, end: Double)] {
        var turns: [(speaker: String, start: Double, end: Double)] = []
        let lines = try String(contentsOf: rttm, encoding: .utf8).split(separator: "\n").map { $0.split(separator: " ") }
        let raw = lines.compactMap { fields -> (String, Double, Double)? in
            guard fields.count > 7, let start = Double(fields[3]), let length = Double(fields[4]) else { return nil }
            return (String(fields[7]), start, start + length)
        }.filter { $0.2 > window.lowerBound && $0.1 < window.upperBound }.sorted { $0.1 < $1.1 }
        for (speaker, start, end) in raw {
            let s = max(start, window.lowerBound) - window.lowerBound, e = min(end, window.upperBound) - window.lowerBound
            if let last = turns.last, last.speaker == speaker, s - last.end < 0.5 {
                turns[turns.count - 1].end = max(last.end, e)
            } else {
                turns.append((speaker, s, e))
            }
        }
        return turns
    }

    static func read(_ url: URL, _ window: Range<Double>) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        #expect(rate == 16_000)
        file.framePosition = AVAudioFramePosition(window.lowerBound * rate)
        let count = AVAudioFrameCount((window.upperBound - window.lowerBound) * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        try file.read(into: buffer, frameCount: count)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
