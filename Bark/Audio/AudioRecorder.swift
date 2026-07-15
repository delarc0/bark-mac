import AVFoundation
import CoreAudio
import Foundation
import os

final class AudioRecorder {

    static let targetSampleRate: Double = 16_000
    private static let preBufferSeconds: Double = 0.5

    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "AudioRecorder")
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()

    private var preBuffer: [Float] = []
    private var preBufferCapacity: Int
    private var recordingBuffer: [Float] = []
    private var recording = false
    private var currentDeviceID: AudioDeviceID?
    private var configChangeObserver: NSObjectProtocol?

    init() throws {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to build target audio format"])
        }
        targetFormat = fmt
        preBufferCapacity = Int(Self.targetSampleRate * Self.preBufferSeconds)

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    func start(deviceID: AudioDeviceID? = nil) throws {
        if engine.isRunning { stop() }

        // Always bind explicitly. The inputNode's device is sticky across sessions,
        // so a nil deviceID (System default, or an unplugged selection) must rebind
        // to the current default rather than keep the previous device.
        if let resolved = deviceID ?? AudioDeviceCatalog.defaultInputID(),
           resolved != currentDeviceID {
            do {
                try setInputDevice(resolved)
                currentDeviceID = resolved
            } catch {
                if let fallback = AudioDeviceCatalog.defaultInputID(), fallback != resolved {
                    try setInputDevice(fallback)
                    currentDeviceID = fallback
                    log.warning("Device \(resolved, privacy: .public) unavailable, fell back to default input")
                } else {
                    throw error
                }
            }
        }

        try installCapture()
        log.info("Mic stream started: target=\(Int(Self.targetSampleRate), privacy: .public)Hz")
    }

    private func installCapture() throws {
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Hardware reported sample rate 0 — device unavailable?"])
        }
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to build converter for \(hwFormat.sampleRate)Hz input"])
        }

        input.removeTap(onBus: 0)
        // The converter is captured by the tap closure rather than stored on self:
        // the render thread must never read state the main thread mutates.
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }

        engine.prepare()
        try engine.start()
    }

    private func handleConfigurationChange() {
        lock.lock()
        let wasRecording = recording
        lock.unlock()
        guard wasRecording else { return }

        log.warning("Audio configuration changed mid-recording — rebuilding capture")
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        do {
            try installCapture()
        } catch {
            if let fallback = AudioDeviceCatalog.defaultInputID(), fallback != currentDeviceID {
                do {
                    try setInputDevice(fallback)
                    currentDeviceID = fallback  // only after the bind succeeded
                    try installCapture()
                } catch {
                    log.error("Fallback capture rebuild failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if !engine.isRunning {
                log.error("Capture rebuild failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        lock.lock()
        preBuffer.removeAll(keepingCapacity: false)
        recordingBuffer.removeAll(keepingCapacity: false)
        recording = false
        lock.unlock()
        log.info("Mic stream stopped.")
    }

    func beginRecording() {
        lock.lock()
        recordingBuffer = preBuffer
        preBuffer.removeAll(keepingCapacity: true)
        recording = true
        lock.unlock()
    }

    /// Returns all samples not yet consumed by `takeChunk()`. Non-streaming callers
    /// who never call takeChunk() get the full recording; streaming callers get the tail.
    func endRecording() -> [Float] {
        lock.lock()
        let tail = recordingBuffer
        recordingBuffer = []
        recording = false
        lock.unlock()
        AudioLevelMonitor.shared.reset()
        return tail
    }

    /// Drains and returns all samples accumulated since the previous `takeChunk()`
    /// call (or `beginRecording()`). Consumed samples are freed immediately.
    func takeChunk() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard recording, !recordingBuffer.isEmpty else { return [] }
        let chunk = recordingBuffer
        recordingBuffer = []
        recordingBuffer.reserveCapacity(chunk.count)
        return chunk
    }

    // MARK: - Internal

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        guard let out = convert(buffer, using: converter) else { return }
        var peak: Float = 0
        for s in out {
            let a = abs(s)
            if a > peak { peak = a }
        }
        AudioLevelMonitor.shared.report(peak)
        lock.lock()
        defer { lock.unlock() }
        if recording {
            recordingBuffer.append(contentsOf: out)
        } else {
            preBuffer.append(contentsOf: out)
            if preBuffer.count > preBufferCapacity {
                preBuffer.removeFirst(preBuffer.count - preBufferCapacity)
            }
        }
    }

    private func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> [Float]? {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return nil
        }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error || error != nil {
            log.error("Converter error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }

        let frames = Int(out.frameLength)
        guard frames > 0, let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: frames))
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw NSError(domain: "AudioRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "inputNode has no audioUnit"])
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw NSError(domain: "AudioRecorder", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to set input device (\(status))"])
        }
    }
}

