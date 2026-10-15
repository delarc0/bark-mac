import AppKit
import BarkHQ
import BarkStore
import Foundation
import Observation
import os

/// The hq connection as Settings shows it, and the trigger for uploads and deletions sync.
@MainActor
@Observable
final class HQLink {
    private(set) var status: HQSettings.Status = .off
    private(set) var host: String?
    /// The pairing or address problem to show, if any.
    private(set) var problem: String?
    /// The address field under Advanced.
    var baseText = ""
    /// The browser was sent to hq to approve this Mac and has not answered yet.
    private(set) var awaitingApproval = false

    @ObservationIgnored private let settings: HQSettings
    @ObservationIgnored private let pairing: HQPairing
    @ObservationIgnored private let uploader: HQUploader?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private let log = Logger(subsystem: "se.lab37.bark.mac", category: "HQ")

    init(store: MeetingStore?) {
        let settings = HQSettings()
        self.settings = settings
        pairing = HQPairing(settings: settings)
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        uploader = store.map { HQUploader(store: $0, settings: settings, appVersion: version) }
        baseText = settings.baseURL?.absoluteString ?? ""
        refresh()
    }

    var isPairing: Bool { awaitingApproval && pairing.isPending && status != .connected }

    func refresh() {
        status = settings.status
        host = settings.baseURL?.host()
    }

    /// Opens hq's approval page in the browser; hq answers through bark://hq-connected.
    func connect() {
        guard applyBase() else { return }
        do {
            NSWorkspace.shared.open(try pairing.begin())
            awaitingApproval = true
            problem = nil
        } catch {
            log.error("Pairing could not start: \(String(describing: error), privacy: .public)")
            problem = "Set the hq address under Advanced first."
        }
    }

    /// Saves the address field when it changed. False when it is not a valid address.
    @discardableResult
    func applyBase() -> Bool {
        guard baseText.trimmingCharacters(in: .whitespacesAndNewlines) != (settings.baseURL?.absoluteString ?? "") else { return true }
        do {
            try settings.setBaseURL(baseText)
            baseText = settings.baseURL?.absoluteString ?? ""
            problem = nil
            refresh()
            return true
        } catch {
            problem = "The hq address must start with https://."
            return false
        }
    }

    /// The bark://hq-connected callback. False when the URL is not one.
    func handle(_ url: URL) -> Bool {
        guard HQPairing.isCallback(url) else { return false }
        awaitingApproval = false
        do {
            try pairing.complete(url)
            problem = nil
            log.info("Connected to hq")
            refresh()
            sync()
        } catch {
            log.error("Pairing callback refused: \(String(describing: error), privacy: .public)")
            problem = "Connecting to hq did not finish. Click Connect to hq to try again."
            refresh()
        }
        return true
    }

    func disconnect() {
        settings.disconnect()
        awaitingApproval = false
        retryTimer?.invalidate()
        retryTimer = nil
        refresh()
    }

    /// Sends what the outbox holds and applies deletions made in hq. Does nothing unless connected.
    func sync() {
        guard let uploader, settings.status == .connected else { return }
        guard !syncing else {
            syncAgain = true
            return
        }
        syncing = true
        Task {
            repeat {
                syncAgain = false
                let report = await uploader.drain()
                if !report.acknowledged.isEmpty || !report.rejected.isEmpty {
                    log.info("hq: \(report.acknowledged.count, privacy: .public) sent, \(report.rejected.count, privacy: .public) refused")
                }
                if !report.rejected.isEmpty { MeetingLibrary.shared.notifyChanged() }
                if !report.needsReconnect {
                    do {
                        if !(try await uploader.syncDeletions()).isEmpty { MeetingLibrary.shared.notifyChanged() }
                    } catch {
                        log.error("hq deletions sync failed: \(String(describing: error), privacy: .public)")
                    }
                }
            } while syncAgain
            syncing = false
            refresh()
            schedule(await uploader.nextRetry)
        }
    }

    private func schedule(_ date: Date?) {
        retryTimer?.invalidate()
        retryTimer = nil
        guard let date else { return }
        let timer = Timer(fire: max(date, .now.addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }
}
