import CoreAudio
import Foundation

/// A capture device. `uid` is stable across reboots and reconnects; `id` is not.
public struct AudioInput: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let channels: Int
    public let sampleRate: Double
}

public enum AudioInputs {
    public static func all() -> [AudioInput] {
        deviceIDs().compactMap(input).filter { $0.channels > 0 }
    }

    public static func device(uid: String) -> AudioInput? {
        all().first { $0.uid == uid }
    }

    public static func defaultInput() -> AudioInput? {
        defaultID().flatMap(input)
    }

    static func defaultID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        return systemProperty(kAudioHardwarePropertyDefaultInputDevice, into: &id) ? id : nil
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func input(_ id: AudioDeviceID) -> AudioInput? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        var rate: Float64 = 0
        _ = property(id, kAudioDevicePropertyNominalSampleRate, into: &rate)
        return AudioInput(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "Unknown",
                          channels: inputChannels(id), sampleRate: rate)
    }

    private static func systemProperty<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, into value: inout T) -> Bool {
        property(AudioObjectID(kAudioObjectSystemObject), selector, into: &value)
    }

    static func property<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
