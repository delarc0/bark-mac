import BarkCore
import BarkEngine
import BarkStore
import Foundation
import UserNotifications
import os

/// The meetings on this Mac and the chores around them: recovery, speakers, audio retention and hq.
@MainActor
final class MeetingLibrary {
    static let shared = MeetingLibrary()

    /// Posted when meetings were added, finished, recovered or deleted outside the Meetings window.
    static let changed = Notification.Name("se.lab37.bark.meetingsChanged")

    /// nil when the store cannot be opened (a store from a newer Bark, a full disk); meetings are off.
    let store: MeetingStore?
    let hq: HQLink
    private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Meetings")
    private var retentionTimer: Timer?
    /// nil when the bundled models are missing; meetings then wait with speakers pending.
    private let diarizer: MeetingDiarizer?
    private var diarizing: Task<Void, Never>?
    private var diarizingMeeting: UUID?
    private var diarizeAgain = false

    private init() {
        var store: MeetingStore?
        do {
            store = try MeetingStore()
        } catch {
            log.error("Meeting store unavailable: \(String(describing: error), privacy: .public)")
        }
        self.store = store
        hq = HQLink(store: store)
        let models = Bundle.main.resourceURL!.appending(path: "speaker-diarization")
        diarizer = MeetingDiarizer.modelsPresent(in: models) ? MeetingDiarizer(models: models) : nil
    }

    /// Once per launch, before a meeting can start: what a crash or quit left unfinished is listed
    /// now, so a meeting started a moment later is never mistaken for one.
    func launch(models: Models, settings: AppSettings) {
        guard let store else { return }
        let unfinished = (try? store.unfinished()) ?? []
        let log = log
        Task.detached {
            do {
                try store.archiveLeftovers()
            } catch {
                log.error("Archiving leftover audio failed: \(String(describing: error), privacy: .public)")
            }
        }
        expireAudio(settings)
        // A menu bar app runs for weeks; retention is applied daily, not only at launch.
        let timer = Timer(timeInterval: 86_400, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireAudio(settings) }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
        do {
            let cut = try store.failInterruptedDiarization()
            if cut > 0 { log.warning("\(cut, privacy: .public) speaker passes were cut short and are not retried") }
        } catch {
            log.error("Reading speaker passes failed: \(String(describing: error), privacy: .public)")
        }
        if !unfinished.isEmpty {
            Task { await recover(unfinished, models: models) }
        }
        diarize()
        hq.sync()
    }

    /// Finds the speakers of every done meeting still waiting for them, one meeting at a time in
    /// the background. Each one is sent to hq again with its speakers.
    func diarize() {
        guard let store, let diarizer else { return }
        guard diarizing == nil else {
            diarizeAgain = true
            return
        }
        diarizing = Task {
            repeat {
                diarizeAgain = false
                for meeting in (try? store.pendingDiarization()) ?? [] {
                    diarizingMeeting = meeting.id
                    let failure = await Task.detached(priority: .utility) { () -> String? in
                        do {
                            try await diarizer.run(meeting.id, store: store)
                            return nil
                        } catch {
                            return String(describing: error)
                        }
                    }.value
                    diarizingMeeting = nil
                    if let failure {
                        log.error("Speakers of meeting \(meeting.id, privacy: .public) failed: \(failure, privacy: .public)")
                    }
                    notifyChanged()
                    hq.sync()
                }
            } while diarizeAgain
            diarizing = nil
        }
    }

    /// A speaker pass cut short by quitting runs again at the next launch.
    func willTerminate() {
        guard let store, let id = diarizingMeeting else { return }
        try? store.setDiarization(id, .pending)
    }

    func notifyChanged() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func expireAudio(_ settings: AppSettings) {
        guard let store, let retention = settings.audioRetention.interval else { return }
        let log = log
        Task.detached {
            do {
                let expired = try store.deleteExpiredAudio(retention: retention)
                if !expired.isEmpty { log.info("Deleted the audio of \(expired.count, privacy: .public) old meetings") }
            } catch {
                log.error("Audio retention failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func recover(_ meetings: [Meeting], models: Models) async {
        guard let store, let transcriber = await models.waitForTranscriber() else {
            log.warning("\(meetings.count, privacy: .public) unfinished meetings wait for a voice model")
            return
        }
        var recovered = 0
        for meeting in meetings {
            do {
                let result = try await MeetingSession.recover(meeting.id, store: store, transcriber: transcriber)
                log.info("Recovered meeting \(meeting.id, privacy: .public): \(result.segments, privacy: .public) segments")
                recovered += 1
            } catch {
                log.error("Recovering meeting \(meeting.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        guard recovered > 0 else { return }
        notifyChanged()
        hq.sync()
        diarize()
        await notifyRecovered(recovered)
    }

    /// Provisional authorization: delivered quietly to Notification Center, never a prompt.
    private func notifyRecovered(_ count: Int) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.provisional])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "Meeting recovered" : "\(count) meetings recovered"
        content.body = "Bark finished transcribing what was recorded before it stopped. Open Meetings in the Bark menu to read it."
        content.interruptionLevel = .passive
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
