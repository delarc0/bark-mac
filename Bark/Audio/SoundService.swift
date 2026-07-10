import AVFoundation
import os

@MainActor
final class SoundService {
    static let shared = SoundService()

    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Sound")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let startBuffer: AVAudioPCMBuffer
    private let stopBuffer: AVAudioPCMBuffer
    private let doneBuffer: AVAudioPCMBuffer
    private let errorBuffer: AVAudioPCMBuffer

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        startBuffer = Self.chirp(startHz: 480, endHz: 880, durationMs: 80, volume: 0.135, format: format)
        stopBuffer = Self.tone(hz: 550, durationMs: 50, volume: 0.105, format: format)
        doneBuffer = Self.chirp(startHz: 660, endHz: 440, durationMs: 100, volume: 0.105, format: format)
        errorBuffer = Self.chirp(startHz: 320, endHz: 180, durationMs: 160, volume: 0.12, format: format)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.isAutoShutdownEnabled = true
        ensureRunning()

        // The output engine dies silently when the default output device changes
        // (headphones plugged in, AirPods connect). Restart it so chimes survive.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ensureRunning()
            }
        }
    }

    func playStart() {
        guard AppSettings.shared.soundsEnabled else { return }
        schedule(startBuffer)
    }

    func playStop() {
        guard AppSettings.shared.soundsEnabled else { return }
        schedule(stopBuffer)
    }

    func playDone() {
        guard AppSettings.shared.soundsEnabled else { return }
        schedule(doneBuffer)
    }

    func playError() {
        guard AppSettings.shared.soundsEnabled else { return }
        schedule(errorBuffer)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        ensureRunning()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            player.play()
        } catch {
            log.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Synthesis

    private static func chirp(startHz: Double, endHz: Double, durationMs: Double, volume: Double,
                              format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let count = AVAudioFrameCount(sr * durationMs / 1000.0)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        guard let data = buffer.floatChannelData?[0] else { return buffer }

        var phase = 0.0
        let n = Double(count)
        for i in 0..<Int(count) {
            let t = Double(i) / n
            let freq = startHz + (endHz - startHz) * t
            let env = envelope(at: t)
            let sample = sin(phase) * env * volume
            data[i] = Float(sample)
            phase += 2.0 * .pi * freq / sr
        }
        return buffer
    }

    private static func tone(hz: Double, durationMs: Double, volume: Double,
                             format: AVAudioFormat) -> AVAudioPCMBuffer {
        return chirp(startHz: hz, endHz: hz, durationMs: durationMs, volume: volume, format: format)
    }

    /// Sine-shaped 10% fade in / 20% fade out to avoid clicks.
    private static func envelope(at t: Double) -> Double {
        let fadeIn = 0.10
        let fadeOut = 0.20
        if t < fadeIn {
            return sin((t / fadeIn) * .pi / 2.0)
        }
        if t > 1.0 - fadeOut {
            let x = (1.0 - t) / fadeOut
            return sin(x * .pi / 2.0)
        }
        return 1.0
    }
}
