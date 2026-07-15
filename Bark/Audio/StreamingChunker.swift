import Foundation
import os

@MainActor
final class StreamingChunker {
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Chunker")
    private var timer: Timer?
    private var silenceStart: Date?
    private var chunkStart: Date?
    private var hasSpeech = false

    /// Peak level below this is treated as silence (AudioLevelMonitor reports peak amplitude).
    private let silenceThreshold: Float = 0.015
    /// Sustained silence this long closes the current chunk.
    private let silenceMinDuration: TimeInterval = 0.4
    /// Don't emit a chunk if the speaker has spoken for less than this.
    private let chunkMinSpeech: TimeInterval = 0.5
    /// Force-close a chunk after this long even without silence — protects against runaway chunks.
    private let chunkMaxDuration: TimeInterval = 12.0
    /// Polling cadence.
    private let tickInterval: TimeInterval = 0.05

    var onChunkReady: (() -> Void)?

    func start() {
        stop()
        chunkStart = Date()
        silenceStart = nil
        hasSpeech = false
        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        let level = AudioLevelMonitor.shared.level

        if level >= silenceThreshold {
            hasSpeech = true
            silenceStart = nil
        } else if silenceStart == nil {
            silenceStart = now
        }

        guard let chunkStart else { return }
        let chunkElapsed = now.timeIntervalSince(chunkStart)

        let silenceBounded: Bool = {
            guard hasSpeech,
                  let silence = silenceStart else { return false }
            return now.timeIntervalSince(silence) >= silenceMinDuration
                && chunkElapsed >= chunkMinSpeech
        }()

        if silenceBounded || chunkElapsed >= chunkMaxDuration {
            if hasSpeech {
                log.info("Chunk closed: elapsed=\(chunkElapsed, privacy: .public)s reason=\(silenceBounded ? "silence" : "max", privacy: .public)")
                onChunkReady?()
            } else {
                log.info("Silent chunk discarded after \(chunkElapsed, privacy: .public)s")
            }
            self.chunkStart = now
            self.silenceStart = nil
            self.hasSpeech = false
        }
    }
}
