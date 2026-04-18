import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let sampleRate: Double

    var canCapture: Bool { inputChannels > 0 }
}
