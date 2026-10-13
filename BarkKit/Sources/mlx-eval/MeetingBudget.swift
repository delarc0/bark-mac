import AVFoundation
import BarkEngine
import BarkStore
import Darwin
import Foundation
import MLX

/// mlx-eval --meeting: the S7 budget on this Mac. A two-stream Swedish call built from eval clips
/// (them: long-sv back to back with 1 s pauses; me: dict-sv with silence after each clip, about
/// 30% talk) is fed through a MeetingSession in 100 ms blocks at `speed` times real time. Every
/// `sample` seconds of audio it records the decode backlog, committed segments, thermal state,
/// memory and CPU time; then finish() to done. Rows go to --out as JSON lines, the summary last.
enum MeetingBudget {
    static let rate = 16_000

    /// The clips of one set, looped forever with a pause after each (`pauseFactor` times the clip,
    /// plus `pause` samples).
    struct Loop {
        let clips: [[Float]]
        let pauseFactor: Double
        let pause: Int
        var clip = 0
        var position = 0

        mutating func next(_ count: Int) -> [Float] {
            var out: [Float] = []
            out.reserveCapacity(count)
            while out.count < count {
                let speech = clips[clip]
                let length = speech.count + Int(Double(speech.count) * pauseFactor) + pause
                let take = min(count - out.count, length - position)
                if position < speech.count {
                    let end = min(speech.count, position + take)
                    out += speech[position ..< end]
                    out += [Float](repeating: 0, count: take - (end - position))
                } else {
                    out += [Float](repeating: 0, count: take)
                }
                position += take
                if position == length {
                    position = 0
                    clip = (clip + 1) % clips.count
                }
            }
            return out
        }
    }

    struct Sample: Encodable {
        let audio_minutes: Double
        let wall_seconds: Double
        let backlog_segments: Int
        let backlog_seconds: Double
        let committed_segments: Int
        let feed_lag_seconds: Double
        let thermal: String
        let cpu_seconds: Double
        let footprint_gb: Double
        let mlx_active_gb: Double
        let mlx_cache_gb: Double
    }

    struct Summary: Encodable {
        let summary = true
        let speed: Double
        let audio_minutes: Double
        let wall_seconds: Double
        let segments: Int
        let empty_segments: Int
        let redecoded_segments: Int
        let failed_decodes: Int
        let words: Int
        let max_backlog_seconds: Double
        let max_backlog_segments: Int
        let backlog_seconds_at_stop: Double
        let max_feed_lag_seconds: Double
        let finish_to_done_seconds: Double
        let archive_seconds: Double?
        let cpu_seconds_per_audio_minute: Double
        let peak_footprint_gb: Double
        let mlx_peak_gb: Double
        let thermal_states: [String]
        let load_seconds: Double
    }

    static func clips(_ folder: URL) throws -> [[Float]] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".wav") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return try names.map { name in
            let file = try AVAudioFile(forReading: folder.appending(path: name), commonFormat: .pcmFormatFloat32, interleaved: false)
            var samples: [Float] = []
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16) else { break }
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
                samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            }
            return samples
        }
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Physical footprint (what Activity Monitor shows as Memory, GPU buffers included) and its peak.
    static func footprint() -> (now: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return (Double(info.phys_footprint) / 1e9, Double(info.ledger_phys_footprint_peak) / 1e9)
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func run(speed: Double, minutes: Double, sampleEvery: Double, sets: URL, storeRoot: URL, out: FileHandle,
                    models: ModelStore, silero: URL, log: (String) -> Void) async throws {
        let them = Loop(clips: try clips(sets.appending(path: "long-sv/clips")), pauseFactor: 0, pause: rate)
        // 0.7 / 0.3 of each clip in silence: 30% talk.
        let me = Loop(clips: try clips(sets.appending(path: "dict-sv/clips")), pauseFactor: 7.0 / 3.0, pause: 0)
        var streams: [(MeetingStream, Loop)] = [(.me, me), (.them, them)]

        let clock = ContinuousClock()
        let loadStart = clock.now
        let transcriber = Transcriber(general: models.folder(ModelID.general8), swedish: models.folder(ModelID.swedish8), vad: silero)
        try await transcriber.start()
        guard await transcriber.swedishReady() else { throw EngineError(description: "KB 8-bit did not load") }
        let load = (clock.now - loadStart).seconds
        log("models loaded in \(String(format: "%.1f", load)) s")

        try? FileManager.default.removeItem(at: storeRoot)
        let store = try MeetingStore(root: storeRoot)
        let session = try await MeetingSession.start(store: store, transcriber: transcriber, language: "sv", mode: .call,
                                                     streams: [.me, .them], title: "S7 budget x\(speed)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func write(_ row: some Encodable) throws {
            try out.write(contentsOf: encoder.encode(row) + Data("\n".utf8))
        }

        let block = rate / 10
        let blocks = Int(minutes * 60 * 10)
        let sampleBlocks = Int(sampleEvery * 10)
        let cpuStart = cpuSeconds()
        let start = clock.now
        var maxBacklog = (segments: 0, seconds: 0.0)
        var maxLag = 0.0
        var thermals: Set<String> = []
        for index in 0 ..< blocks {
            let due = start + .seconds(Double(index) * 0.1 / speed)
            try await Task.sleep(until: due, clock: .continuous)
            maxLag = max(maxLag, (clock.now - due).seconds)
            for i in streams.indices {
                try await session.feed(streams[i].1.next(block), stream: streams[i].0)
            }
            if (index + 1) % sampleBlocks == 0 {
                let backlog = await session.backlog
                maxBacklog = (max(maxBacklog.segments, backlog.segments), max(maxBacklog.seconds, backlog.seconds))
                let state = thermal()
                thermals.insert(state)
                let row = Sample(audio_minutes: Double(index + 1) / 600, wall_seconds: (clock.now - start).seconds,
                                 backlog_segments: backlog.segments, backlog_seconds: backlog.seconds,
                                 committed_segments: try store.segments(session.id).count, feed_lag_seconds: maxLag,
                                 thermal: state, cpu_seconds: cpuSeconds() - cpuStart, footprint_gb: footprint().now,
                                 mlx_active_gb: Double(Memory.activeMemory) / 1e9, mlx_cache_gb: Double(Memory.cacheMemory) / 1e9)
                try write(row)
                log(String(format: "%5.1f min  wall %6.1f s  backlog %2d seg %5.1f s  committed %4d  %@  %.2f GB (MLX cache %.2f GB)",
                           row.audio_minutes, row.wall_seconds, row.backlog_segments, row.backlog_seconds,
                           row.committed_segments, row.thermal, row.footprint_gb, row.mlx_cache_gb))
            }
        }
        let atStop = await session.backlog
        let fed = clock.now
        let result = try await session.finish()
        let wall = (clock.now - start).seconds
        let segments = try store.segments(session.id)
        let failed = try store.gaps(session.id).filter { $0.reason == "decode failed" }.count
        thermals.insert(thermal())
        let summary = Summary(
            speed: speed, audio_minutes: minutes, wall_seconds: wall, segments: segments.count,
            empty_segments: segments.filter(\.text.isEmpty).count, redecoded_segments: segments.filter(\.redecoded).count,
            failed_decodes: failed, words: segments.reduce(0) { $0 + $1.text.split(separator: " ").count },
            max_backlog_seconds: maxBacklog.seconds, max_backlog_segments: maxBacklog.segments,
            backlog_seconds_at_stop: atStop.seconds, max_feed_lag_seconds: maxLag,
            finish_to_done_seconds: result.finishToDone, archive_seconds: result.archiveSeconds,
            cpu_seconds_per_audio_minute: (cpuSeconds() - cpuStart) / minutes, peak_footprint_gb: footprint().peak,
            mlx_peak_gb: Double(Memory.peakMemory) / 1e9, thermal_states: thermals.sorted(), load_seconds: load)
        try write(summary)
        log(String(format: "fed in %.1f s; finish to done %.2f s, archive %.2f s; %d segments, %d failed; backlog max %.1f s; CPU %.1f s per audio min; peak %.2f GB (MLX %.2f GB)",
                   (fed - start).seconds, result.finishToDone, result.archiveSeconds ?? -1, segments.count, failed,
                   maxBacklog.seconds, summary.cpu_seconds_per_audio_minute, summary.peak_footprint_gb, summary.mlx_peak_gb))
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
