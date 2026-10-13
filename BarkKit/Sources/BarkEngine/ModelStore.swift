import CryptoKit
import Foundation
import Synchronization

/// One downloadable model: the files of a model folder, each with its checksum.
public struct ModelManifest: Sendable, Codable, Equatable {
    public struct File: Sendable, Codable, Equatable {
        public let name: String
        public let url: URL
        public let sha256: String
        public let size: Int64

        public init(name: String, url: URL, sha256: String, size: Int64) {
            self.name = name
            self.url = url
            self.sha256 = sha256
            self.size = size
        }
    }

    public let id: String
    public let files: [File]

    public init(id: String, files: [File]) {
        self.id = id
        self.files = files
    }
}

/// Model ids. The folders dev-models.sh links, and what the manifests download.
public enum ModelID {
    public static let swedish = "kb-whisper-large"
    public static let swedish8 = "kb-whisper-large-8bit"
    public static let general = "whisper-large-v3"
    public static let general8 = "whisper-large-v3-8bit"
}

extension ModelManifest {
    // shortcut: no published model repo yet, fill in when Erik publishes. Every manifest URL is
    // built on this placeholder, so a download fails until it is replaced.
    public static let unpublishedBaseURL = URL(string: "https://models.invalid/bark")!

    /// Checksums of the local conversions dev-models.sh installs; publishing uploads exactly these.
    public static let all: [ModelManifest] = [
        manifest(ModelID.swedish, [
            ("config.json", 269, "34982ce6ae286095000f82ae9583b3431639e8b092bf60c961f203745e6500e3"),
            ("weights.safetensors", 3_083_280_590, "9e43496e226b98e418a6b0063407ed07fdcf78189793858a682566754340f862"),
            ("tokenizer.json", 3_931_383, "d06d0c877b5143ccdcb761407d5650b18a6afc33f9261fcb7e0dd44acbc1c262"),
        ]),
        manifest(ModelID.swedish8, [
            ("config.json", 342, "5b01488ca81d15986a4298672891f71d7fe7b850fba001380c0050bb55b0e01f"),
            ("weights.safetensors", 1_644_895_305, "828524977f6fdb2be4ec1e233d5e01901d8c241e5874b4e60e66ae56a6b87fe2"),
            ("tokenizer.json", 3_931_383, "d06d0c877b5143ccdcb761407d5650b18a6afc33f9261fcb7e0dd44acbc1c262"),
        ]),
        manifest(ModelID.general, [
            ("config.json", 269, "34982ce6ae286095000f82ae9583b3431639e8b092bf60c961f203745e6500e3"),
            ("weights.safetensors", 3_083_275_757, "005ebcab7856d650f7a38b2c800eed8db62ab9c5c03e5155be5ff859a01e0bec"),
            ("tokenizer.json", 2_480_617, "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
        ]),
        manifest(ModelID.general8, [
            ("config.json", 342, "5b01488ca81d15986a4298672891f71d7fe7b850fba001380c0050bb55b0e01f"),
            ("weights.safetensors", 1_644_890_702, "18a98e89d86e32a7f89e710c9f50ef6ea4069c659c402d3daa353034e2e302c6"),
            ("tokenizer.json", 2_480_617, "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
        ]),
    ]

    static func manifest(_ id: String, _ files: [(name: String, size: Int64, sha256: String)]) -> ModelManifest {
        ModelManifest(id: id, files: files.map {
            File(name: $0.name, url: unpublishedBaseURL.appending(path: "\(id)/\($0.name)"), sha256: $0.sha256, size: $0.size)
        })
    }
}

/// Models on disk: ~/Library/Application Support/Bark/Models/<id>/ holding config.json,
/// weights.safetensors and tokenizer.json.
public struct ModelStore: Sendable {
    public static let files = ["config.json", "weights.safetensors", "tokenizer.json"]
    public let root: URL

    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Bark/Models")
    }

    public init(root: URL = ModelStore.defaultRoot) {
        self.root = root
    }

    public func folder(_ id: String) -> URL {
        root.appending(path: id, directoryHint: .isDirectory)
    }

    /// Every model file is present. Checksums are verified at download, not on every launch.
    public func isInstalled(_ id: String) -> Bool {
        Self.files.allSatisfy { FileManager.default.fileExists(atPath: folder(id).appending(path: $0).path) }
    }

    /// Downloads every file of the manifest that is missing or the wrong size: each to
    /// <file>.partial, checked against its sha256 and size, then moved into place. `progress` gets
    /// bytes done and total across the manifest.
    public func download(_ manifest: ModelManifest, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let folder = folder(manifest.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = manifest.files.reduce(0) { $0 + $1.size }
        var done: Int64 = 0
        for file in manifest.files {
            let destination = folder.appending(path: file.name)
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == file.size {
                done += file.size
                progress(done, total)
                continue
            }
            let partial = folder.appending(path: file.name + ".partial")
            try? FileManager.default.removeItem(at: partial)
            let before = done
            try await Downloader.fetch(file.url, to: partial) { bytes in progress(before + bytes, total) }
            let size = Int64(try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
            let digest = try Self.sha256(of: partial)
            guard size == file.size, digest == file.sha256.lowercased() else {
                try? FileManager.default.removeItem(at: partial)
                throw EngineError(description: "\(manifest.id)/\(file.name): got \(size) bytes, sha256 \(digest); expected \(file.size), \(file.sha256)")
            }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            done += file.size
            progress(done, total)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One URLSession download into a given file, reporting bytes written.
final class Downloader: NSObject, URLSessionDownloadDelegate, Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let state = Mutex<(continuation: CheckedContinuation<Void, Error>?, moveError: Error?)>((nil, nil))

    private init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = Downloader(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { continuation in
            delegate.state.withLock { $0.continuation = continuation }
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    // The temporary file is deleted when this returns, so it is moved here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200 ..< 300).contains(status) {
            state.withLock { $0.moveError = EngineError(description: "HTTP \(status) for \(downloadTask.originalRequest?.url?.absoluteString ?? "?")") }
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            state.withLock { $0.moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, moveError) = state.withLock { state in
            defer { state.continuation = nil }
            return (state.continuation, state.moveError)
        }
        if let error = error ?? moveError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
