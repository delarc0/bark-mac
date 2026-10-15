import AVFoundation
import BarkCore
import BarkEngine
import BarkStore
import Foundation

/// mlx-eval --split-eval: one recording as a meeting's them (call) or room (in person) stream,
/// transcribed in English through a MeetingSession once (kept in `work`), then the speaker pass
/// on a fresh copy of that store without splitting and once per --min-turn with it. Each run's
/// segments go to `<out>-<run>.jsonl`, its report to stderr and `<out>-runs.jsonl`.
enum SplitEval {
    static func run(wav: URL, mode: MeetingMode, work: URL, minTurns: [Double], out: String, transcriber: Transcriber,
                    diarizer: MeetingDiarizer, log: (String) -> Void) async throws {
        let transcribed = work.appending(path: "transcribed")
        let id = try await transcribe(wav, mode: mode, into: transcribed, transcriber: transcriber, log: log)
        let runs = try FileHandle.create(URL(fileURLWithPath: "\(out)-runs.jsonl"))
        defer { try? runs.close() }
        for minTurn in [nil] + minTurns.map(Optional.some) {
            let name = minTurn.map { "split\($0)" } ?? "base"
            let copy = work.appending(path: name)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: transcribed, to: copy)
            let store = try MeetingStore(root: copy)
            let report = try await diarizer.run(id, store: store, transcriber: minTurn == nil ? nil : transcriber,
                                                rule: SegmentSplit.Rule(minTurn: minTurn ?? 1))
            let labels = Dictionary(uniqueKeysWithValues: try store.speakers(id).map { ($0.id, $0.label) })
            let lines = try store.segments(id).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.map { segment in
                try JSONSerialization.data(withJSONObject: [
                    "start": segment.start, "end": segment.end, "text": segment.text,
                    "speaker": segment.speakerID.flatMap { labels[$0] } ?? NSNull(),
                ] as [String: Any], options: [.sortedKeys]) + Data("\n".utf8)
            }
            try lines.reduce(Data(), +).write(to: URL(fileURLWithPath: "\(out)-\(name).jsonl"))
            let row: [String: Any] = ["run": name, "seconds": report.seconds, "audio_s": report.audioSeconds, "segments": report.segments,
                                      "split": report.split, "pieces": report.pieces, "kept_whole": report.keptWhole,
                                      "speakers": report.speakers]
            runs.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8))
            log("\(wav.lastPathComponent) \(name): \(report.segments) segments, \(report.split) split into \(report.pieces), \(report.keptWhole) kept whole, \(String(format: "%.1f", report.seconds)) s")
        }
    }

    /// The meeting in `root`, transcribed once; later runs reuse it.
    private static func transcribe(_ wav: URL, mode: MeetingMode, into root: URL, transcriber: Transcriber,
                                   log: (String) -> Void) async throws -> UUID {
        if let done = try MeetingStore(root: root).meetings().first(where: { $0.status == .done }) { return done.id }
        try? FileManager.default.removeItem(at: root)
        let store = try MeetingStore(root: root)
        let stream: MeetingStream = mode == .call ? .them : .room
        let session = try await MeetingSession.start(store: store, transcriber: transcriber, language: "en", mode: mode, streams: [stream])
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        let clock = ContinuousClock(), start = clock.now
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 160_000) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try await session.feed(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))), stream: stream)
            while await session.backlog.seconds > 120 { try await Task.sleep(for: .milliseconds(200)) }
        }
        let result = try await session.finish()
        log("\(wav.lastPathComponent): \(result.segments) segments in \(String(format: "%.0f", (clock.now - start) / .seconds(1))) s")
        return session.id
    }
}

extension FileHandle {
    static func create(_ url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }
}
