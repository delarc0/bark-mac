import AVFoundation
import BarkCore
import CoreAudio
import Synchronization
import os

public enum CaptureError: Error, CustomStringConvertible {
    case noInput
    case setDevice(OSStatus)

    public var description: String {
        switch self {
        case .noInput: "The input device reports no usable format"
        case .setDevice(let status): "Could not select the input device (\(status))"
        }
    }
}

/// Microphone capture for one dictation at a time: 16 kHz mono Float32 chunks, in order, on the
/// stream start() returns. The device is chosen by UID and falls back to the system default. A
/// device that reconfigures mid-capture (a rate change, a hub re-enumerating, AirPods switching
/// profile) is rebuilt in place, and the stream carries on.
@MainActor
public final class MicCapture {
    public static let sampleRate = 16_000.0
    static let maxRebuildAttempts = 5

    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Capture")
    private let engine = AVAudioEngine()
    private let meter = Meter()
    private var deviceID: AudioDeviceID?
    private var running = false
    private var rebuildAttempts = 0
    private var observer: NSObjectProtocol?

    public init() {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    /// The latest buffer's peak, for the overlay's bars. 0 when not capturing.
    nonisolated public var level: Float { meter.level }

    /// `voiceProcessing` turns on Apple's echo cancellation (and its noise suppression and gain
    /// control), for meetings on laptop speakers. Dictation leaves it off.
    public func start(deviceUID: String?, voiceProcessing: Bool = false) throws -> AsyncStream<[Float]> {
        if running { _ = stop() }
        try setVoiceProcessing(voiceProcessing)
        // Always bind explicitly: the input node's device is sticky, so "system default" must
        // rebind to whatever the default is now.
        let wanted = deviceUID.flatMap { AudioInputs.device(uid: $0)?.id } ?? AudioInputs.defaultID()
        if let wanted {
            do {
                try bind(wanted)
            } catch {
                guard let fallback = AudioInputs.defaultID(), fallback != wanted else { throw error }
                log.warning("Input \(wanted, privacy: .public) unavailable, using the default input")
                try bind(fallback)
            }
        }
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
        meter.begin(continuation)
        do {
            try install()
        } catch {
            _ = meter.end()
            throw error
        }
        running = true
        rebuildAttempts = 0
        return stream
    }

    /// Stops capturing, ends the stream and says what the input delivered.
    @discardableResult
    public func stop() -> InputHealth {
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let (frames, peak) = meter.end()
        return InputHealth.classify(frames: frames, peak: peak)
    }

    private func setVoiceProcessing(_ enabled: Bool) throws {
        let input = engine.inputNode
        guard input.isVoiceProcessingEnabled != enabled else { return }
        try input.setVoiceProcessingEnabled(enabled)
        if enabled {
            // By default it ducks every other app's audio, the call included.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        // The node runs on a different audio unit now, which has no device bound yet.
        deviceID = nil
    }

    private func bind(_ id: AudioDeviceID) throws {
        guard id != deviceID else { return }
        guard let unit = engine.inputNode.audioUnit else { throw CaptureError.noInput }
        var value = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &value, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CaptureError.setDevice(status) }
        deviceID = id
    }

    private func install() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard let resampler = MonoResampler(inputRate: format.sampleRate, channels: Int(format.channelCount)) else {
            throw CaptureError.noInput
        }
        log.info("Capture \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(resampler, meter) { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        })
        engine.prepare()
        try engine.start()
    }

    // Built outside the main actor: a closure formed in an isolated context would assert that
    // isolation on the capture thread.
    nonisolated private static func tap(_ resampler: MonoResampler, _ meter: Meter,
                                        restart: @escaping @Sendable () -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            switch resampler.process(buffer) {
            case .samples(let samples, let peak): meter.deliver(samples, peak: peak)
            case .rateChanged: restart()
            case nil: break
            }
        }
    }

    private func rebuild() {
        guard running else { return }
        log.warning("Input reconfigured mid-capture, rebuilding")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try install()
            rebuildAttempts = 0
        } catch {
            if let fallback = AudioInputs.defaultID(), fallback != deviceID, (try? bind(fallback)) != nil,
               (try? install()) != nil {
                rebuildAttempts = 0
                return
            }
            // A device still settling refuses the bind for a moment; without a retry the rest of
            // the dictation is silently lost.
            guard rebuildAttempts < Self.maxRebuildAttempts else {
                log.error("Capture rebuild failed, giving up: \(error.localizedDescription, privacy: .public)")
                return
            }
            rebuildAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
    }
}

/// What the capture thread hands over: chunks to the stream, the level, and the totals the input
/// health is judged on.
final class Meter: Sendable {
    private struct State {
        var continuation: AsyncStream<[Float]>.Continuation?
        var level: Float = 0
        var peak: Float = 0
        var frames = 0
    }

    private let state = Mutex(State())

    var level: Float { state.withLock { $0.level } }

    func begin(_ continuation: AsyncStream<[Float]>.Continuation) {
        state.withLock { $0 = State(continuation: continuation) }
    }

    func deliver(_ samples: [Float], peak: Float) {
        state.withLock {
            guard let continuation = $0.continuation else { return }
            $0.level = peak
            $0.peak = max($0.peak, peak)
            $0.frames += samples.count
            continuation.yield(samples)
        }
    }

    func end() -> (frames: Int, peak: Float) {
        let ended = state.withLock { state in
            defer { state = State() }
            return state
        }
        ended.continuation?.finish()
        return (ended.frames, ended.peak)
    }
}
