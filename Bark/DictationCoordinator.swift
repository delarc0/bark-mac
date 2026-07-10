import AppKit
import AVFoundation
import CoreAudio
import os

@MainActor
final class DictationCoordinator {
    enum State {
        case idle
        case recording
        case transcribing
    }

    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Dictation")
    let hotkey = HotkeyMonitor()
    private let recorder: AudioRecorder?
    private let transcriber: Transcriber
    private let chunker = StreamingChunker()

    private let minHoldSeconds: TimeInterval = 0.2
    private let minChunkSamples = 4_800   // 300ms at 16kHz — below this, skip
    private let maxRecordSeconds: TimeInterval = 300

    private(set) var state: State = .idle
    private var recordStartedAt: Date?
    private var chunkTasks: [Task<String, Error>] = []
    private var maxDurationTimer: Timer?
    private var sessionStreaming = false
    private var sessionLanguage: String?

    var deviceIDProvider: (() -> AudioDeviceID?)?
    var onStateChanged: ((State) -> Void)?
    var onMicPermissionDenied: (() -> Void)?

    init(recorder: AudioRecorder?, transcriber: Transcriber) {
        self.recorder = recorder
        self.transcriber = transcriber
        hotkey.onEvent = { [weak self] event in
            switch event {
            case .pressed: self?.handlePressed()
            case .released: self?.handleReleased()
            }
        }
        chunker.onChunkReady = { [weak self] in self?.flushChunk() }
    }

    @discardableResult
    func start() -> Bool {
        return hotkey.start()
    }

    func stop() {
        hotkey.stop()
    }

    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        HotkeyMonitor.hasAccessibilityPermission(prompt: prompt)
    }

    private func setState(_ next: State) {
        state = next
        onStateChanged?(next)
    }

    private func handlePressed() {
        guard let recorder else {
            log.error("Recorder unavailable on hotkey press")
            return
        }
        guard state == .idle else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            log.error("Microphone permission denied — cannot record")
            SoundService.shared.playError()
            onMicPermissionDenied?()
            return
        }

        let deviceID = deviceIDProvider?()
        do {
            try recorder.start(deviceID: deviceID)
            recorder.beginRecording()
            recordStartedAt = Date()
            chunkTasks = []
            sessionStreaming = AppSettings.shared.streamingEnabled
            sessionLanguage = AppSettings.shared.language
            if sessionStreaming {
                chunker.start()
            }
            startMaxDurationTimer()
            setState(.recording)
            SoundService.shared.playStart()
            log.info("Recording started (hold)")
        } catch {
            log.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
            SoundService.shared.playError()
        }
    }

    // A release can be swallowed by screen lock, secure input, or a system-disabled
    // event tap. Force-finish so the session cannot record unbounded.
    private func startMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxRecordSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.log.warning("Max recording duration (\(Int(self.maxRecordSeconds), privacy: .public)s) reached — forcing stop")
                self.handleReleased()
            }
        }
    }

    private func enqueueChunkTask(samples: [Float], label: String) {
        let transcriber = self.transcriber
        let language = self.sessionLanguage
        let index = chunkTasks.count
        let log = self.log
        let task = Task.detached { () throws -> String in
            let t0 = Date()
            let text = try await transcriber.transcribe(samples: samples, language: language)
            log.info("\(label, privacy: .public)[\(index, privacy: .public)] transcribed in \(Date().timeIntervalSince(t0), privacy: .public)s, samples=\(samples.count, privacy: .public)")
            return text
        }
        chunkTasks.append(task)
    }

    private func flushChunk() {
        guard let recorder else { return }
        let chunk = recorder.takeChunk()
        guard chunk.count >= minChunkSamples else {
            log.info("Chunk skipped (too short): \(chunk.count, privacy: .public) samples")
            return
        }
        enqueueChunkTask(samples: chunk, label: "Chunk")
    }

    private func handleReleased() {
        guard state == .recording, let recorder else { return }
        chunker.stop()
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil

        let held = recordStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let tail = recorder.endRecording()
        recorder.stop()
        recordStartedAt = nil

        guard held >= minHoldSeconds else {
            log.info("Tap too short (\(held, privacy: .public)s), discarded")
            chunkTasks.forEach { $0.cancel() }
            chunkTasks = []
            setState(.idle)
            return
        }

        if !sessionStreaming {
            // Legacy path: one-shot transcribe of full buffer.
            guard !tail.isEmpty else {
                log.info("No samples captured, discarded")
                setState(.idle)
                return
            }
            log.info("Recording stopped after \(held, privacy: .public)s, samples=\(tail.count, privacy: .public)")
            SoundService.shared.playStop()
            setState(.transcribing)
            PasteService.prepareSnapshot()
            runSingleShot(samples: tail)
            return
        }

        // Streaming path: final tail becomes the last chunk task.
        if tail.count >= minChunkSamples {
            enqueueChunkTask(samples: tail, label: "Tail")
        }

        guard !chunkTasks.isEmpty else {
            log.info("No chunks captured, discarded")
            setState(.idle)
            return
        }

        log.info("Recording stopped after \(held, privacy: .public)s, chunks=\(self.chunkTasks.count, privacy: .public)")
        SoundService.shared.playStop()
        setState(.transcribing)
        PasteService.prepareSnapshot()
        runStreaming(tasks: chunkTasks)
        chunkTasks = []
    }

    private func runSingleShot(samples: [Float]) {
        let transcriber = self.transcriber
        let language = self.sessionLanguage
        let log = self.log
        let timeout = Self.transcriptionTimeout(sampleCount: samples.count)
        Task.detached { [weak self] in
            let t0 = Date()
            let work = Task { try await transcriber.transcribe(samples: samples, language: language) }
            do {
                let text = try await Self.awaitWithTimeout(work, seconds: timeout)
                log.info("Transcribe elapsed: \(Date().timeIntervalSince(t0), privacy: .public)s")
                await Self.paste(text: text, log: log, onDone: { [weak self] in self?.setState(.idle) })
            } catch {
                log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { [weak self] in
                    SoundService.shared.playError()
                    self?.setState(.idle)
                }
            }
        }
    }

    private func runStreaming(tasks: [Task<String, Error>]) {
        let log = self.log
        Task.detached { [weak self] in
            let t0 = Date()
            var parts: [String] = []
            var failures = 0
            for (idx, task) in tasks.enumerated() {
                do {
                    let part = try await Self.awaitWithTimeout(task, seconds: 90)
                    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { parts.append(trimmed) }
                } catch {
                    failures += 1
                    log.error("Chunk[\(idx, privacy: .public)] failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let combined = parts.joined(separator: " ")
            log.info("Streaming concat elapsed \(Date().timeIntervalSince(t0), privacy: .public)s, chunks=\(tasks.count, privacy: .public), failed=\(failures, privacy: .public)")
            if combined.isEmpty && failures > 0 {
                await MainActor.run { [weak self] in
                    SoundService.shared.playError()
                    self?.setState(.idle)
                }
                return
            }
            await Self.paste(text: combined, log: log, onDone: { [weak self] in self?.setState(.idle) })
        }
    }

    private static func transcriptionTimeout(sampleCount: Int) -> TimeInterval {
        max(60, Double(sampleCount) / AudioRecorder.targetSampleRate * 3)
    }

    /// Resolves even if `task` hangs forever (WhisperKit offers no cancellation
    /// guarantee) — the hung task is orphaned and the app recovers to idle.
    private static func awaitWithTimeout<T: Sendable>(_ task: Task<T, Error>, seconds: TimeInterval) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce(_ resume: () -> Void) {
                let first = finished.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { resume() }
            }
            Task {
                do {
                    let value = try await task.value
                    resumeOnce { cont.resume(returning: value) }
                } catch {
                    resumeOnce { cont.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                task.cancel()
                resumeOnce {
                    cont.resume(throwing: NSError(domain: "Dictation", code: 408,
                                                  userInfo: [NSLocalizedDescriptionKey: "Transcription timed out after \(Int(seconds))s"]))
                }
            }
        }
    }

    private static func paste(text: String, log: Logger, onDone: @escaping @MainActor @Sendable () -> Void) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run {
            let settings = AppSettings.shared
            let processed = TextPostProcessor.process(
                trimmed,
                cleanup: settings.cleanupEnabled,
                vocabulary: settings.vocabulary
            )
            if !processed.isEmpty {
                PasteService.pasteAtCursor(processed)
                SoundService.shared.playDone()
            } else {
                log.info("Empty transcription, nothing to paste")
            }
            onDone()
        }
    }
}
