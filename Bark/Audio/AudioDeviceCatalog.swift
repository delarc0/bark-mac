import CoreAudio
import Foundation

enum AudioDeviceCatalog {

    static func listInputs() -> [AudioDevice] {
        allDevices().filter { $0.canCapture }
    }

    static func defaultInput() -> AudioDevice? {
        guard let id = defaultInputID() else { return nil }
        return allDevices().first { $0.id == id }
    }

    static func device(withUID uid: String) -> AudioDevice? {
        allDevices().first { $0.uid == uid }
    }

    static func inputID(matching uid: String?) -> AudioDeviceID? {
        guard let uid, !uid.isEmpty else { return nil }
        return device(withUID: uid)?.id
    }

    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil, &size, &id
        )
        return status == noErr ? id : nil
    }

    private static func allDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap(makeDevice)
    }

    private static func makeDevice(id: AudioDeviceID) -> AudioDevice? {
        let name = stringProperty(id: id, selector: kAudioObjectPropertyName) ?? "Unknown"
        let uid = stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID) ?? ""
        let inputs = channelCount(id: id, scope: kAudioObjectPropertyScopeInput)
        let rate = sampleRate(id: id) ?? 0
        return AudioDevice(id: id, uid: uid, name: name, inputChannels: inputs, sampleRate: rate)
    }

    private static func stringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: CFString?
        let status = withUnsafeMutablePointer(to: &result) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = result else { return nil }
        return cf as String
    }

    private static func channelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else {
            return 0
        }
        let abl = bufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func sampleRate(id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Float64>.size)
        var rate: Float64 = 0
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else {
            return nil
        }
        return rate
    }
}
