import AppKit
import AuthenticationServices
import BarkCalendar
import BarkCore
import Foundation
import Observation
import os

/// The Google Calendar connection as Settings and the notebook show it, and the one question the
/// app asks it: which event is this meeting? Off entirely when the app carries no client id.
@MainActor
@Observable
final class CalendarLink {
    enum Status: Equatable {
        case off
        case notConnected
        case connected(String?)
    }

    static let accountKey = "bark2.calendar.account"
    /// A meeting start never waits longer than this for the calendar.
    static let matchTimeout: TimeInterval = 5
    static let offerTimeout: TimeInterval = 3

    private(set) var status: Status = .off
    private(set) var connecting = false
    /// The sign-in problem to show, if any.
    private(set) var problem: String?

    @ObservationIgnored private let auth: GoogleAuth?
    @ObservationIgnored private let calendar: GoogleCalendar?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var browser: ASWebAuthenticationSession?
    @ObservationIgnored private let anchor = Anchor()
    @ObservationIgnored private let log = Logger(subsystem: "se.lab37.bark.mac", category: "Calendar")

    static var bundledClient: GoogleClient? {
        GoogleClient(id: Bundle.main.infoDictionary?["BarkGoogleClientID"] as? String ?? "")
    }

    init(client: GoogleClient? = CalendarLink.bundledClient, tokens: any CalendarTokenStore = KeychainRefreshTokenStore(),
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let client {
            let auth = GoogleAuth(client: client, tokens: tokens)
            self.auth = auth
            calendar = GoogleCalendar(auth: auth)
        } else {
            auth = nil
            calendar = nil
        }
        refresh()
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// Shown while the calendar can be connected but is not.
    var offersConnect: Bool { status == .notConnected }

    func refresh() {
        guard let auth else {
            status = .off
            return
        }
        status = auth.isConnected ? .connected(defaults.string(forKey: Self.accountKey)) : .notConnected
    }

    /// Opens Google's sign-in in the browser; the redirect comes back on the app's own scheme.
    func connect() {
        guard let auth, !connecting else { return }
        connecting = true
        problem = nil
        Task {
            let flow: GoogleAuth.Flow
            do {
                flow = try await auth.begin()
            } catch {
                return failed("Signing in to Google did not start. Try again.", error)
            }
            let session = ASWebAuthenticationSession(url: flow.url, callbackURLScheme: auth.client.callbackScheme) { [weak self] url, error in
                Task { @MainActor in self?.returned(url, error) }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = anchor
            browser = session
            if !session.start() { failed("Signing in to Google did not start. Try again.", nil) }
        }
    }

    private func returned(_ url: URL?, _ error: (any Error)?) {
        browser = nil
        guard let auth else { return }
        if let error {
            let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            return cancelled ? cancel() : failed("Signing in to Google did not finish. Try again.", error)
        }
        guard let url else { return cancel() }
        Task {
            do {
                try await auth.complete(url)
            } catch CalendarError.denied(let reason) {
                return reason == "access_denied" ? cancel() : failed("Google did not allow the sign-in. Try again.", CalendarError.denied(reason))
            } catch {
                return failed("Signing in to Google did not finish. Try again.", error)
            }
            connecting = false
            status = .connected(nil)
            log.info("Google Calendar connected")
            await loadAccount()
        }
    }

    private func cancel() {
        connecting = false
        problem = nil
    }

    private func failed(_ message: String, _ error: (any Error)?) {
        connecting = false
        problem = message
        if let error { log.error("Google sign-in failed: \(String(describing: error), privacy: .public)") }
    }

    private func loadAccount() async {
        guard let calendar else { return }
        do {
            let account = try await calendar.account()
            defaults.set(account.email, forKey: Self.accountKey)
            if isConnected { status = .connected(account.email) }
        } catch {
            log.error("Reading the Google account failed: \(String(describing: error), privacy: .public)")
        }
    }

    func disconnect() {
        guard let auth else { return }
        browser?.cancel()
        browser = nil
        connecting = false
        problem = nil
        defaults.removeObject(forKey: Self.accountKey)
        status = .notConnected
        Task {
            await auth.disconnect()
            await calendar?.forgetCalendars()
        }
    }

    /// The event the meeting happening now belongs to, if the calendar is connected and answers in
    /// time. Never throws: a meeting is simply untitled when the calendar cannot say.
    func match(for app: CallApp?, at moment: Date = .now, timeout: TimeInterval = CalendarLink.matchTimeout) async -> CalendarEvent? {
        guard let calendar, isConnected else { return nil }
        do {
            let candidates = try await withCalendarTimeout(timeout) { try await calendar.candidates(around: moment) }
            let match = CalendarMatch.bestEvent(from: candidates, at: moment, for: app)
            log.info("Calendar: \(candidates.count, privacy: .public) events around now, \(match == nil ? "no match" : "matched", privacy: .public)")
            return match
        } catch CalendarError.disconnected {
            log.warning("Google revoked Bark's calendar access")
            defaults.removeObject(forKey: Self.accountKey)
            status = .notConnected
            problem = "Google signed Bark out of your calendar. Connect it again."
            return nil
        } catch {
            log.error("Calendar lookup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The sign-in sheet needs a window to hang off; a menu bar app may have none open.
    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        }
    }
}
