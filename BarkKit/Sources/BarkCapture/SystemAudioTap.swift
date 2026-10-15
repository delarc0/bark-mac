import AVFoundation
import BarkCore
import CoreAudio
import Foundation
import os

public enum TapError: Error, CustomStringConvertible {
    case noProcess
    case createTap(OSStatus)
    case noOutputDevice
    case createDevice(OSStatus)
    case format
    case start(OSStatus)

    public var description: String {
        switch self {
        case .noProcess: "None of the processes to tap is known to the audio system"
        case .createTap(let status): "Could not create the system audio tap (\(status))"
        case .noOutputDevice: "There is no output device to clock the tap"
        case .createDevice(let status): "Could not create the tap's audio device (\(status))"
        case .format: "The tap reports no usable format"
        case .start(let status): "Could not start the tap (\(status))"
        }
    }
}

/// The other side of a call: a Core Audio process tap on the call app's processes, or on every
/// process but Bark, read through a private aggregate device and delivered like MicCapture, as
/// 16 kHz mono Float32 chunks in order on the stream start() returns. Core Audio mixes the tap down
/// to mono, so a speaker panned to one side by spatial audio keeps full level; MonoResampler only
/// converts the rate.
/// A change of output device or rate rebuilds the aggregate device and the stream carries on.
/// Without the system audio grant, macOS feeds the tap digital zero rather than failing.
@MainActor
public final class SystemAudioTap {
    public enum Target: Sendable, Equatable {
        /// These processes: a call app and its helpers (CallApps.processes).
        case processes([pid_t])
        /// Every process's output except Bark's own.
        case global
    }

    static let maxRebuildAttempts = 5

    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Tap")
    private let meter = Meter()
    private let queue = DispatchQueue(label: "se.lab37.bark.tap", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUID = ""
    private var target: Target?
    private var tapped: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapListeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    private var rebuildPending = false
    private var rebuildAttempts = 0

    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    public init() {}

    isolated deinit {
        teardown()
        _ = meter.end()
    }

    /// The latest buffer's peak. 0 when not capturing.
    nonisolated public var level: Float { meter.level }

    /// Whether the tapped processes report that they are playing audio (any process but Bark for a
    /// global tap). Digital zero from the tap while this is true is a missing grant (TapSilence).
    public var targetIsPlaying: Bool {
        switch target {
        case .processes: tapped.contains(where: AudioApps.isRunningOutput)
        case .global: AudioApps.running().contains { $0.pid != getpid() && $0.runningOutput }
        case nil: false
        }
    }

    public func start(_ target: Target) throws -> AsyncStream<[Float]> {
        if self.target != nil { stop() }
        let description: CATapDescription
        switch target {
        case .processes(let pids):
            tapped = pids.compactMap(AudioApps.processObject)
            guard !tapped.isEmpty else { throw TapError.noProcess }
            description = CATapDescription(monoMixdownOfProcesses: tapped)
            // A helper that exits and comes back mid-call (a browser's audio service) rejoins the tap.
            description.isProcessRestoreEnabled = true
        case .global:
            tapped = []
            description = CATapDescription(monoGlobalTapButExcludeProcesses: AudioApps.processObject(pid: getpid()).map { [$0] } ?? [])
        }
        description.name = "Bark"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.createTap(status) }
        tapID = tap
        tapUID = description.uuid.uuidString
        self.target = target

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
        meter.begin(continuation)
        do {
            try build()
        } catch {
            teardown()
            _ = meter.end()
            throw error
        }
        rebuildAttempts = 0
        tapListeners = [listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
                        listen(tapID, kAudioTapPropertyFormat)]
        return stream
    }

    /// Stops the tap, destroys its device and the tap itself, ends the stream and says what the
    /// tap delivered.
    @discardableResult
    public func stop() -> InputHealth {
        teardown()
        let (frames, peak) = meter.end()
        return InputHealth.classify(frames: frames, peak: peak)
    }

    /// The aggregate device holding the tap, clocked by the current output device, and its IOProc.
    private func build() throws {
        guard let outputUID = Self.defaultOutputUID() else { throw TapError.noOutputDevice }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bark Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Off so the IOProc runs while the call is quiet too: silence still counts samples.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr else { throw TapError.createDevice(status) }
        aggregateID = aggregate

        var stream = AudioStreamBasicDescription()
        guard AudioInputs.property(tapID, kAudioTapPropertyFormat, into: &stream) else { throw TapError.format }
        // The device delivers the tap at its own rate (drift compensation resamples to it).
        var rate: Float64 = 0
        if AudioInputs.property(aggregate, kAudioDevicePropertyNominalSampleRate, into: &rate), rate > 0 {
            stream.mSampleRate = rate
        }
        guard let format = AVAudioFormat(streamDescription: &stream), format.commonFormat == .pcmFormatFloat32,
              let resampler = MonoResampler(inputRate: format.sampleRate, channels: Int(format.channelCount)) else {
            throw TapError.format
        }
        log.info("Tap \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, Self.ioBlock(format, resampler, meter))
        guard status == noErr, let proc else { throw TapError.start(status) }
        procID = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { throw TapError.start(status) }
        deviceListeners = [listen(aggregate, kAudioDevicePropertyNominalSampleRate)]
    }

    // Built outside the main actor: a closure formed in an isolated context would assert that
    // isolation on the IO thread.
    nonisolated private static func ioBlock(_ format: AVAudioFormat, _ resampler: MonoResampler, _ meter: Meter) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  case .samples(let samples, let peak) = resampler.process(buffer) else { return }
            meter.deliver(samples, peak: peak)
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Listener {
        let address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block = Self.listenerBlock { [weak self] in self?.scheduleRebuild() }
        var registered = address
        AudioObjectAddPropertyListenerBlock(object, &registered, .main, block)
        return Listener(object: object, address: address, block: block)
    }

    nonisolated private static func listenerBlock(_ action: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in MainActor.assumeIsolated { action() } }
    }

    private func remove(_ listeners: inout [Listener]) {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, .main, listener.block)
        }
        listeners = []
    }

    /// A route change fires several notifications in a row; one rebuild covers them.
    private func scheduleRebuild() {
        guard target != nil, !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                self?.rebuildPending = false
                self?.rebuild()
            }
        }
    }

    private func rebuild() {
        guard target != nil else { return }
        log.warning("Output route changed under the tap, rebuilding its device")
        destroyDevice()
        do {
            try build()
            rebuildAttempts = 0
        } catch {
            destroyDevice()
            // Gives up after a few tries; the call capture then reports the gap.
            guard rebuildAttempts < Self.maxRebuildAttempts else {
                log.error("Tap rebuild failed, giving up: \(String(describing: error), privacy: .public)")
                return
            }
            rebuildAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
    }

    private func destroyDevice() {
        remove(&deviceListeners)
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func teardown() {
        target = nil
        tapped = []
        remove(&tapListeners)
        destroyDevice()
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioDeviceID(0)
        guard AudioInputs.property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                   into: &device), device != kAudioObjectUnknown else { return nil }
        return AudioInputs.string(device, kAudioDevicePropertyDeviceUID)
    }
}
