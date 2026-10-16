import AppKit
import BarkCore
import CoreAudio
import Foundation

/// The processes the audio system knows about, for call detection and for building a tap. Reading
/// them needs no permission.
public enum AudioApps {
    public static func running() -> [AudioProcess] {
        processObjects().compactMap(process)
    }

    /// The likely call app right now, if any.
    public static func likelyCall() -> CallApp? {
        CallApps.likelyCall(running(), appName: localizedName(forPID:))
    }

    public static func localizedName(forPID pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        return AudioInputs.property(object, kAudioProcessPropertyIsRunningOutput, into: &running) && running != 0
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func process(_ object: AudioObjectID) -> AudioProcess? {
        var pid: pid_t = -1
        guard AudioInputs.property(object, kAudioProcessPropertyPID, into: &pid), pid > 0 else { return nil }
        var input: UInt32 = 0
        _ = AudioInputs.property(object, kAudioProcessPropertyIsRunningInput, into: &input)
        return AudioProcess(objectID: object, pid: pid,
                            bundleID: AudioInputs.string(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 },
                            runningInput: input != 0, runningOutput: isRunningOutput(object))
    }
}
