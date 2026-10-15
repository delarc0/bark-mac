import BarkCore
import BarkStore
import FluidAudio
import Foundation
import os

public struct MeetingResult: Sendable {
    /// Segments committed by this session (a recovery counts only its own).
    public let segments: Int
    /// From finish() being called to the meeting being done: every segment committed, queued for hq.
    public let finishToDone: Double
    /// Compressing the audio after that; nil when it failed and the PCM was kept (MeetingStore.archiveLeftovers).
    public let archiveSeconds: Double?
}

/// One meeting: named streams (me, them, room), never mixed, each segmented by its own Silero
/// state (Segmenter, as in dictation). Segments are decoded one at a time through the shared
/// Transcriber with the dictation decode policy, the oldest of any stream first, in the meeting's
/// explicit language (sv runs on KB), and each is committed to the store as soon as it is decoded.
/// Audio is written to disk as it is fed and never held beyond the segment being decoded, so a
/// crash costs only the decodes in flight: recover() picks the meeting up from its files.
public actor MeetingSession {
    public nonisolated let id: UUID
    private let store: MeetingStore
    private let transcriber: Transcriber
    private let vad: VadManager
    private let language: String
    private let role: ModelRole
    private var streams: [MeetingStream: Stream]
    private var released = false
    private var pump: Task<Void, Never>?
    private var swedishSettled = false
    private var committed = 0
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Meeting")

    private struct Stream {
        var segmenter = Segmenter()
        /// Where the segmenter's first sample sits in the stream's audio file.
        let origin: Int
        /// nil while recovering: the audio is already on disk.
        let writer: PCMWriter?
    }

    private init(id: UUID, store: MeetingStore, transcriber: Transcriber, vad: VadManager, language: String,
                 streams: [MeetingStream: Stream]) {
        self.id = id
        self.store = store
        self.transcriber = transcriber
        self.vad = vad
        self.language = language
        self.streams = streams
        role = Routing.route(.explicit(language), detection: nil, remembered: nil).model
    }

    /// Creates the meeting in the store (recording) with an audio file per stream. `language` is
    /// the explicit meeting language; an unknown code fails here, not in every decode.
    public static func start(store: MeetingStore, transcriber: Transcriber, language: String, mode: MeetingMode,
                             streams: [MeetingStream], title: String? = nil) async throws -> MeetingSession {
        let vad = try await transcriber.startedVAD()
        try await transcriber.checkLanguage(language)
        let meeting = try store.createMeeting(language: language, mode: mode, title: title)
        var files: [MeetingStream: Stream] = [:]
        for stream in streams {
            files[stream] = Stream(origin: 0, writer: try PCMWriter(url: store.rawAudio(meeting.id, stream)))
        }
        return MeetingSession(id: meeting.id, store: store, transcriber: transcriber, vad: vad, language: language, streams: files)
    }

    /// Appends 16 kHz mono audio to a stream: to its file first, then to its segmenter. Throws when
    /// the file cannot take it (disk full). Ignored once finish() has been called.
    public func feed(_ samples: [Float], stream: MeetingStream) throws {
        guard !released else { return }
        guard streams[stream] != nil else { preconditionFailure("\(stream) is not a stream of this meeting") }
        try streams[stream]!.writer?.append(samples)
        streams[stream]!.segmenter.append(samples)
        startPump()
    }

    /// Marks a gap at the current position (sleep, a lost device): audio is missing from here.
    public func markGap(reason: String) throws {
        let position = streams.values.map { $0.origin + $0.segmenter.end }.max() ?? 0
        try store.addGap(id, at: Double(position) / Double(Segmenter.sampleRate), reason: reason)
    }

    /// Work queued behind the decoder: segments ready to decode, and seconds of audio in them plus
    /// audio Silero has not reached yet. Bounded when decoding keeps up with the meeting. A last
    /// segment held for a short one to join it is not backlog.
    public var backlog: (segments: Int, seconds: Double) {
        let segments = streams.values.reduce(0) { $0 + $1.segmenter.ready.count }
        let samples = streams.values.reduce(0) { total, stream in
            total + stream.segmenter.ready.reduce(0) { $0 + $1.count } + max(0, stream.segmenter.end - stream.segmenter.processed)
        }
        return (segments, Double(samples) / Double(Segmenter.sampleRate))
    }

    /// Stops the meeting: decodes every stream's tail, marks the meeting done and queues it for hq,
    /// then compresses its audio.
    @discardableResult
    public func finish() async throws -> MeetingResult {
        try await finish(endedAt: .now)
    }

    /// Finishes a meeting a crash or quit left recording or transcribing (MeetingStore.unfinished):
    /// each stream's audio on disk past its last committed segment is transcribed, so nothing is
    /// lost and nothing decoded twice, then the meeting is finished like finish(). Its end is set
    /// to the end of its longest stream.
    @discardableResult
    public static func recover(_ id: UUID, store: MeetingStore, transcriber: Transcriber) async throws -> MeetingResult {
        guard let meeting = try store.meeting(id) else { throw StoreError("no meeting \(id)") }
        let vad = try await transcriber.startedVAD()
        var files: [MeetingStream: Stream] = [:]
        var lengths: [MeetingStream: Int] = [:]
        for stream in MeetingStream.allCases where FileManager.default.fileExists(atPath: store.rawAudio(id, stream).path) {
            let resume = try store.committedEnd(id, stream).map { Int(($0 * Double(Segmenter.sampleRate)).rounded()) } ?? 0
            files[stream] = Stream(origin: resume, writer: nil)
            lengths[stream] = try PCM.sampleCount(store.rawAudio(id, stream))
        }
        try store.setStatus(id, .transcribing)
        let session = MeetingSession(id: id, store: store, transcriber: transcriber, vad: vad, language: meeting.language, streams: files)
        try await session.replay(lengths)
        let seconds = Double(lengths.values.max() ?? 0) / Double(Segmenter.sampleRate)
        return try await session.finish(endedAt: meeting.startedAt.addingTimeInterval(seconds))
    }

    /// Feeds the files from each stream's origin in meeting-time blocks, letting each block be
    /// segmented and decoded before the next is read, so memory stays bounded.
    private func replay(_ lengths: [MeetingStream: Int]) async throws {
        let block = 30 * Segmenter.sampleRate
        let first = streams.values.map(\.origin).min() ?? 0
        for offset in stride(from: first, to: lengths.values.max() ?? 0, by: block) {
            for (stream, length) in lengths {
                let from = max(offset, streams[stream]!.origin), to = min(offset + block, length)
                guard from < to else { continue }
                streams[stream]!.segmenter.append(try PCM.read(store.rawAudio(id, stream), from: from, count: to - from))
            }
            startPump()
            await pump?.value
        }
    }

    private func finish(endedAt: Date) async throws -> MeetingResult {
        precondition(!released, "finish() runs once")
        released = true
        let clock = ContinuousClock()
        let stop = clock.now
        try store.setStatus(id, .transcribing, endedAt: endedAt)
        // A failed close (disk full) must not abandon the meeting: the tail is still in the
        // segmenters and gets decoded; recovery covers whatever the .pcm lacks.
        for (name, stream) in streams {
            do {
                try stream.writer?.close()
            } catch {
                log.error("closing \(String(describing: name), privacy: .public) audio failed: \(String(describing: error), privacy: .public)")
            }
        }
        await pump?.value
        for stream in Array(streams.keys) {
            if let remainder = streams[stream]!.segmenter.remainder {
                await step(stream, remainder)
            }
            streams[stream]!.segmenter.closeOpen()
        }
        while let stream = oldest(includingHeld: true) {
            await decode(stream)
        }
        try store.finish(id, endedAt: endedAt)
        let done = clock.now
        var archive: Double?
        do {
            try store.archiveAudio(id)
            archive = (clock.now - done).seconds
        } catch {
            log.error("archiving meeting \(self.id, privacy: .public) failed, PCM kept: \(String(describing: error), privacy: .public)")
        }
        return MeetingResult(segments: committed, finishToDone: (done - stop).seconds, archiveSeconds: archive)
    }

    private func startPump() {
        if pump == nil { pump = Task { await drain() } }
    }

    /// Silero first, so segments close on time, then the oldest ready segment of any stream. The
    /// pump ends when nothing is left and the next feed starts another.
    private func drain() async {
        while true {
            if let (stream, chunk) = streams.lazy.compactMap({ entry in entry.value.segmenter.nextChunk.map { (entry.key, $0) } }).first {
                await step(stream, chunk)
            } else if let stream = oldest(includingHeld: false) {
                await decode(stream)
            } else {
                break
            }
        }
        pump = nil
    }

    private func step(_ stream: MeetingStream, _ chunk: [Float]) async {
        let result = await vad.step(chunk, streams[stream]!.segmenter.state)
        streams[stream]!.segmenter.apply(result)
    }

    /// The stream whose next segment starts earliest in the meeting, among those that can decode.
    private func oldest(includingHeld: Bool) -> MeetingStream? {
        streams.filter { includingHeld ? !$0.value.segmenter.pending.isEmpty : !$0.value.segmenter.ready.isEmpty }
            .min { $0.value.origin + $0.value.segmenter.pending[0].lowerBound < $1.value.origin + $1.value.segmenter.pending[0].lowerBound }?
            .key
    }

    private func decode(_ stream: MeetingStream) async {
        let (range, audio) = streams[stream]!.segmenter.takeFirst()
        let speech = streams[stream]!.segmenter.speechSeconds(range)
        let origin = streams[stream]!.origin
        // A meeting has no release to answer, so it waits for KB rather than decode Swedish on large-v3.
        if role == .swedish, !swedishSettled {
            _ = await transcriber.swedishReady()
            swedishSettled = true
        }
        let model = await transcriber.available(role)
        let (result, redecoded) = await transcriber.decodeSegment(audio, speechSeconds: speech, on: model, language: language, .background)
        let rate = Double(Segmenter.sampleRate)
        let start = Double(origin + range.lowerBound) / rate
        do {
            if let result {
                try store.addSegment(Segment(stream: stream, start: start, end: Double(origin + range.upperBound) / rate,
                                             text: result.text, model: await transcriber.modelID(model), language: language,
                                             redecoded: redecoded), to: id)
                committed += 1
            } else {
                try store.addGap(id, at: start, reason: "decode failed")
            }
        } catch {
            log.error("meeting \(self.id, privacy: .public): segment at \(start) s not committed: \(String(describing: error), privacy: .public)")
        }
    }
}
