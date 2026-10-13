import AVFoundation
import os

/// The four synthesized chimes: start, stop, done and error.
@MainActor
final class Sounds {
    static let shared = Sounds()

    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Sound")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private lazy var start = chirp(from: 480, to: 880, ms: 80, volume: 0.135)
    private lazy var stop = chirp(from: 550, to: 550, ms: 50, volume: 0.105)
    private lazy var done = chirp(from: 660, to: 440, ms: 100, volume: 0.105)
    private lazy var error = chirp(from: 320, to: 180, ms: 160, volume: 0.12)
    private var observer: NSObjectProtocol?

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.isAutoShutdownEnabled = true
        ensureRunning()
        // The output engine stops when the default output changes (headphones, AirPods).
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureRunning() }
        }
    }

    func playStart() { play(start) }
    func playStop() { play(stop) }
    func playDone() { play(done) }
    func playError() { play(error) }

    private func play(_ buffer: AVAudioPCMBuffer) {
        guard AppSettings.shared.soundsEnabled else { return }
        ensureRunning()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            player.play()
        } catch {
            log.error("Sound engine: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A sine sweep with a 10% fade in and 20% fade out, so it never clicks.
    private func chirp(from startHz: Double, to endHz: Double, ms: Double, volume: Double) -> AVAudioPCMBuffer {
        let count = AVAudioFrameCount(format.sampleRate * ms / 1000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let data = buffer.floatChannelData![0]
        var phase = 0.0
        for i in 0 ..< Int(count) {
            let t = Double(i) / Double(count)
            let envelope = t < 0.1 ? sin(t / 0.1 * .pi / 2) : t > 0.8 ? sin((1 - t) / 0.2 * .pi / 2) : 1
            data[i] = Float(sin(phase) * envelope * volume)
            phase += 2 * .pi * (startHz + (endHz - startHz) * t) / format.sampleRate
        }
        return buffer
    }
}
