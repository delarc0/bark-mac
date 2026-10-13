import AVFoundation
@testable import BarkEngine
import Foundation
import MLX

/// Local models and eval clips. Tests that need them are skipped where they are absent (CI, a
/// fresh Mac); run BarkKit/scripts/dev-models.sh to install the models.
enum Fixtures {
    static let store = ModelStore()
    static let evalSets = URL.applicationSupportDirectory.appending(path: "Bark/eval/sets")

    static var generalID: String? { [ModelID.general8, ModelID.general].first(where: store.isInstalled) }
    /// Where FluidAudio cached Silero on a dev Mac.
    static let vadFolder = URL.applicationSupportDirectory.appending(path: "FluidAudio/Models/silero-vad")
    static var vadInstalled: Bool {
        FileManager.default.fileExists(atPath: vadFolder.appending(path: Transcriber.sileroModel).path)
    }
    static var modelsInstalled: Bool { generalID != nil && vadInstalled }
    static var clipsInstalled: Bool { modelsInstalled && FileManager.default.fileExists(atPath: evalSets.path) }

    /// One general-model transcriber for every test that needs one: the model is gigabytes.
    static let transcriber = Task<Transcriber, Error> {
        // swift test runs inside an .xctest bundle, where MLX does not find SwiftPM's resource
        // bundle beside it, so point MLX at the built metallib directly.
        GPU.metallib = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
            .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        let transcriber = Transcriber(general: store.folder(generalID!), swedish: nil, vad: vadFolder)
        try await transcriber.start()
        return transcriber
    }

    /// A clip of an eval set (the first one by default), 16 kHz mono float.
    static func clip(_ set: String, _ id: String? = nil) throws -> [Float] {
        let folder = evalSets.appending(path: "\(set)/clips")
        let name = try id.map { "\($0).wav" }
            ?? FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".wav") }.sorted()[0]
        let file = try AVAudioFile(forReading: folder.appending(path: name), commonFormat: .pcmFormatFloat32, interleaved: false)
        var samples: [Float] = []
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16)!
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        return samples
    }
}

private final class BundleToken {}
