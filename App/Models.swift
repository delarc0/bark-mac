import BarkEngine
import FluidAudio
import Foundation
import Observation
import os

/// The voice models on disk and the Transcriber running on them.
@MainActor
@Observable
final class Models {
    static let shared = Models(settings: .shared)

    enum State: Equatable {
        /// The general model is not on disk; nothing can be transcribed.
        case missing
        case loading
        case ready
        case failed(String)
    }

    // 8-bit is the default: same WER as fp16 on every P1a set at half the memory.
    static let general = ModelID.general8
    static let swedish = ModelID.swedish8

    private(set) var state = State.missing
    /// Required models that are not on disk, general first.
    private(set) var missing: [String] = []
    /// Fraction of a running download, nil when none is running.
    private(set) var download: Double?
    private(set) var downloadError: String?

    @ObservationIgnored private let store = ModelStore()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var transcriber: Transcriber?
    @ObservationIgnored private var loaded: [URL?] = []
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Models")

    init(settings: AppSettings) {
        self.settings = settings
    }

    var readyTranscriber: Transcriber? { state == .ready ? transcriber : nil }

    /// The missing models can be fetched. False while the manifests point at the placeholder
    /// host: the models are not published yet.
    var canDownload: Bool {
        manifests(missing).allSatisfy { manifest in
            manifest.files.allSatisfy { !$0.url.absoluteString.hasPrefix(ModelManifest.unpublishedBaseURL.absoluteString) }
        }
    }

    var downloadSize: String {
        ByteCountFormatter.string(fromByteCount: manifests(missing).reduce(0) { $0 + $1.bytes }, countStyle: .file)
    }

    static func size(of id: String) -> String {
        ByteCountFormatter.string(fromByteCount: ModelManifest.all.first { $0.id == id }?.bytes ?? 0, countStyle: .file)
    }

    /// Checks the disk and loads what is there.
    func load() {
        Self.installSilero()
        let required = settings.swedishModelEnabled ? [Self.general, Self.swedish] : [Self.general]
        missing = required.filter { !store.isInstalled($0) }
        guard store.isInstalled(Self.general) else {
            transcriber = nil
            loaded = []
            setState(.missing)
            return
        }
        let swedish = settings.swedishModelEnabled && store.isInstalled(Self.swedish) ? store.folder(Self.swedish) : nil
        let folders = [store.folder(Self.general), swedish]
        if folders == loaded, state == .loading || state == .ready { return }
        loaded = folders
        // A dictation in flight keeps the transcriber it started on; this one serves the next.
        let transcriber = Transcriber(general: store.folder(Self.general), swedish: swedish)
        self.transcriber = transcriber
        setState(.loading)
        Task {
            do {
                try await transcriber.start()
                guard self.transcriber === transcriber else { return }
                setState(.ready)
            } catch {
                guard self.transcriber === transcriber else { return }
                log.error("Model load failed: \(String(describing: error), privacy: .public)")
                setState(.failed(String(describing: error)))
            }
        }
    }

    /// Downloads every missing model through ModelStore, then loads.
    func downloadMissing() {
        guard download == nil, !missing.isEmpty, canDownload else { return }
        let store = store
        let manifests = manifests(missing)
        download = 0
        downloadError = nil
        Task {
            for (index, manifest) in manifests.enumerated() {
                do {
                    try await store.download(manifest) { done, total in
                        let fraction = (Double(index) + Double(done) / Double(max(total, 1))) / Double(manifests.count)
                        Task { @MainActor in if self.download != nil { self.download = fraction } }
                    }
                } catch {
                    log.error("Download of \(manifest.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    downloadError = String(describing: error)
                    break
                }
            }
            download = nil
            load()
        }
    }

    /// Waits while the general model is loading or downloading; nil when it cannot be had.
    func waitForTranscriber() async -> Transcriber? {
        while state == .loading || (state == .missing && download != nil) {
            await withCheckedContinuation { waiters.append($0) }
        }
        return readyTranscriber
    }

    private func setState(_ next: State) {
        state = next
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }

    private func manifests(_ ids: [String]) -> [ModelManifest] {
        ids.compactMap { id in ModelManifest.all.first { $0.id == id } }
    }

    /// Silero ships inside the app and is copied to where FluidAudio's VadManager looks for it,
    /// and FluidAudio is kept offline, so it is never fetched from Hugging Face at runtime.
    // shortcut: Transcriber builds VadManager() itself with FluidAudio's default folder; when
    // BarkEngine takes a VAD folder, load the bundled copy in place and drop the copy.
    static func installSilero() {
        ModelHub.offlineMode = true
        let target = URL.applicationSupportDirectory.appending(path: "FluidAudio/Models")
            .appending(path: Repo.vad.folderName).appending(path: ModelNames.VAD.sileroVadFile)
        guard !FileManager.default.fileExists(atPath: target.path),
              let bundled = Bundle.main.resourceURL?.appending(path: "silero-vad/\(ModelNames.VAD.sileroVadFile)") else { return }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled, to: target)
        } catch {
            Logger(subsystem: "se.lab37.bark.mac", category: "Models")
                .error("Silero install failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension ModelManifest {
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
}
