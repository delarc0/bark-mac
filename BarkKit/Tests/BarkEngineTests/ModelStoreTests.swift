@testable import BarkEngine
import Foundation
import Synchronization
import Testing

struct ModelStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "bark-store-\(UUID().uuidString)")

    /// Source files served over file:// and a manifest for them.
    func source(_ contents: [String: String]) throws -> ModelManifest {
        let served = root.appending(path: "served")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        var files: [ModelManifest.File] = []
        for (name, text) in contents.sorted(by: { $0.key < $1.key }) {
            let url = served.appending(path: name)
            try Data(text.utf8).write(to: url)
            files.append(.init(name: name, url: url, sha256: try ModelStore.sha256(of: url), size: Int64(text.utf8.count)))
        }
        return ModelManifest(id: "test-model", files: files)
    }

    @Test func downloadsVerifiesAndInstalls() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try source(["config.json": "{}", "weights.safetensors": String(repeating: "w", count: 100_000), "tokenizer.json": "[]"])
        let store = ModelStore(root: root.appending(path: "Models"))
        #expect(!store.isInstalled("test-model"))
        let last = Mutex<(Int64, Int64)>((0, 0))
        try await store.download(manifest) { done, total in last.withLock { $0 = (done, total) } }
        #expect(store.isInstalled("test-model"))
        #expect(last.withLock { $0 } == (100_004, 100_004))
        let installed = try FileManager.default.contentsOfDirectory(atPath: store.folder("test-model").path)
        #expect(Set(installed) == Set(ModelStore.files))
        #expect(try String(contentsOf: store.folder("test-model").appending(path: "config.json"), encoding: .utf8) == "{}")
    }

    @Test func wrongChecksumIsRejectedAndLeavesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try source(["config.json": "{}"])
        let file = good.files[0]
        let bad = ModelManifest(id: good.id, files: [.init(name: file.name, url: file.url, sha256: String(repeating: "0", count: 64), size: file.size)])
        let store = ModelStore(root: root.appending(path: "Models"))
        await #expect(throws: EngineError.self) { try await store.download(bad) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder(good.id).path).isEmpty)
    }

    @Test func missingSourceThrows() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = ModelManifest(id: "gone", files: [.init(name: "config.json", url: root.appending(path: "nope.json"), sha256: "", size: 2)])
        await #expect(throws: (any Error).self) { try await ModelStore(root: root).download(manifest) }
    }

    @Test func fileOfTheRightSizeIsNotFetchedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try source(["config.json": "{}"])
        let store = ModelStore(root: root.appending(path: "Models"))
        try await store.download(manifest)
        try FileManager.default.removeItem(at: manifest.files[0].url)
        try await store.download(manifest) // the source is gone, so this only passes if nothing is fetched
        #expect(FileManager.default.fileExists(atPath: store.folder("test-model").appending(path: "config.json").path))
    }

    @Test func manifestsCoverEveryModelOnThePlaceholder() {
        #expect(Set(ModelManifest.all.map(\.id)) == [ModelID.swedish, ModelID.swedish8, ModelID.general, ModelID.general8])
        for manifest in ModelManifest.all {
            #expect(manifest.files.map(\.name).sorted() == ModelStore.files.sorted())
            #expect(manifest.files.allSatisfy { $0.url.host() == "models.invalid" && $0.sha256.count == 64 })
        }
    }

    /// Sizes only: hashing the installed gigabytes on every test run is too slow.
    @Test(.enabled(if: Fixtures.store.isInstalled(ModelID.general)))
    func installedModelsMatchTheirManifests() throws {
        for manifest in ModelManifest.all where Fixtures.store.isInstalled(manifest.id) {
            for file in manifest.files {
                let path = Fixtures.store.folder(manifest.id).appending(path: file.name).resolvingSymlinksInPath().path
                #expect(try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 == file.size)
            }
        }
    }
}
