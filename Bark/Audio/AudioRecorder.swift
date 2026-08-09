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

    // Touched only by the capture thread, between tap installs.
    private var selectedChannel: Int?
    private static let channelLatchLevel: Float = 0.02

    // Total converted frames seen this session, so a recording that captured
    // nothing at all is distinguishable from one that captured silence.
    private var capturedFrames = 0

    // Growing this array on the render thread means a multi-megabyte realloc
    // inside the tap callback, which overruns the IO deadline and drops audio.
    private static let reservedRecordingSeconds: Double = 180

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
        // AVAudioConverter emits pure silence (no error) when asked to downmix a
        // multichannel interface to mono — verified on a 12-channel Audient iD14,
        // every channel in, digital zero out. So mix to mono ourselves and leave
        // the converter nothing but the sample-rate change it handles correctly.
        guard let monoHWFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: hwFormat.sampleRate,
                                               channels: 1,
                                               interleaved: false) else {
            throw NSError(domain: "AudioRecorder", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to build mono format at \(hwFormat.sampleRate)Hz"])
        }
        guard let converter = AVAudioConverter(from: monoHWFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to build converter for \(hwFormat.sampleRate)Hz input"])
        }
        log.info("Capture format: \(hwFormat.sampleRate, privacy: .public)Hz \(hwFormat.channelCount, privacy: .public)ch -> mono \(Int(Self.targetSampleRate), privacy: .public)Hz")

        input.removeTap(onBus: 0)
        // Safe here: the tap is uninstalled, so no capture thread is running.
        selectedChannel = nil
        // The converter is captured by the tap closure rather than stored on self:
        // the render thread must never read state the main thread mutates.
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }

        engine.prepare()
        try engine.start()
    }

    /// Called from the capture thread, so it hops to main before touching the
    /// engine; the current buffer is dropped rather than mislabelled.
    private func requestCaptureRestart() {
        DispatchQueue.main.async { [weak self] in
            self?.handleConfigurationChange()
        }
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
        recordingBuffer.reserveCapacity(Int(Self.targetSampleRate * Self.reservedRecordingSeconds))
        preBuffer.removeAll(keepingCapacity: true)
        capturedFrames = 0
        recording = true
        lock.unlock()
    }

    /// Frames delivered by the hardware this session. Zero means the device
    /// never produced a callback, which is a different fault from silence.
    var capturedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedFrames
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
        guard let (out, peak) = convert(buffer, using: converter) else { return }
        AudioLevelMonitor.shared.report(peak)
        lock.lock()
        defer { lock.unlock() }
        capturedFrames += out.count
        if recording {
            recordingBuffer.append(contentsOf: out)
        } else {
            preBuffer.append(contentsOf: out)
            if preBuffer.count > preBufferCapacity {
                preBuffer.removeFirst(preBuffer.count - preBufferCapacity)
            }
        }
    }

    /// Reduce a multichannel interface to the one channel carrying the voice.
    ///
    /// Summing every channel would fold in whatever else the box exposes —
    /// loopback of system audio, ADAT, unconnected inputs and their noise
    /// floors — so a video playing through the same interface ends up in the
    /// transcript. Instead, latch onto the loudest channel once anything
    /// speech-level appears and stay there for the rest of the recording.
    /// Until that happens the sum is used, so a quiet opening word is never
    /// dropped while waiting to choose.
    private func mixToMono(_ input: AVAudioPCMBuffer, format: AVAudioFormat) -> (buffer: AVAudioPCMBuffer, peak: Float)? {
        let frames = Int(input.frameLength)
        guard frames > 0, let source = input.floatChannelData else { return nil }
        let channels = Int(input.format.channelCount)
        guard let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: input.frameLength),
              let dest = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = input.frameLength

        // Interleaved buffers expose one pointer holding every channel, so the
        // per-channel pointers below would read past the end of the array.
        let interleaved = input.format.isInterleaved
        let stride = interleaved ? channels : 1
        func sample(_ channel: Int, _ frame: Int) -> Float {
            interleaved ? source[0][frame * stride + channel] : source[channel][frame]
        }

        if channels == 1 {
            dest.update(from: source[0], count: frames)
        } else {
            if selectedChannel == nil {
                // Lowest qualifying channel, not the loudest: microphone
                // preamps occupy the first inputs, while loopback of system
                // audio and ADAT sit at the end. Picking by level alone would
                // latch onto music playing through the same interface and
                // transcribe that instead of the voice.
                for c in 0..<channels {
                    var p: Float = 0
                    for i in 0..<frames {
                        let a = abs(sample(c, i))
                        if a > p { p = a }
                    }
                    if p >= Self.channelLatchLevel {
                        selectedChannel = c
                        break
                    }
                }
            }

            if let channel = selectedChannel {
                for i in 0..<frames { dest[i] = sample(channel, i) }
            } else {
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += sample(c, i) }
                    dest[i] = sum
                }
            }
        }

        // Measured before the converter so a hot signal reads as hot; clamping
        // here would both distort the audio and hide the overload from the
        // level meter and the dead-input check.
        var peak: Float = 0
        for i in 0..<frames {
            let a = abs(dest[i])
            if a > peak { peak = a }
        }
        return (mono, peak)
    }

    private func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> (samples: [Float], peak: Float)? {
        // A device can change rate mid-recording; converting 48k buffers as if
        // they were still 44.1k would silently pitch-shift the tail.
        guard input.format.sampleRate == converter.inputFormat.sampleRate else {
            log.error("Input rate changed \(converter.inputFormat.sampleRate, privacy: .public) -> \(input.format.sampleRate, privacy: .public)Hz mid-capture; restarting")
            requestCaptureRestart()
            return nil
        }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return nil
        }
        guard let (mono, peak) = mixToMono(input, format: converter.inputFormat) else { return nil }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return mono
        }

        if status == .error || error != nil {
            log.error("Converter error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }

        let frames = Int(out.frameLength)
        guard frames > 0, let channel = out.floatChannelData?[0] else { return ([], peak) }
        return (Array(UnsafeBufferPointer(start: channel, count: frames)), peak)
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

