import BarkStore
import Foundation

/// Drains MeetingStore's outbox to hq and applies deletions made in hq. Makes no request while hq is
/// off (empty base URL) or not connected.
public actor HQUploader {
    public struct Report: Sendable, Equatable {
        public var acknowledged: [UUID] = []
        /// hq refused these for good (413 or 422); they wait for a fresh `MeetingStore.enqueue`.
        public var rejected: [UUID] = []
        /// Failed for now; retried after the backoff.
        public var retrying: [UUID] = []
        /// hq answered 401: the token is gone and nothing more is sent until the user reconnects.
        public var needsReconnect = false
    }

    /// Delay before the next try after the nth failed attempt, then every 6 h.
    public static let backoff: [TimeInterval] = [60, 300, 1800, 7200, 21_600]
    /// Marks an outbox item's last error as a permanent rejection.
    public static let rejectedPrefix = "rejected: "
    static let apiVersion = "1"
    static let maxDeletions = 10_000
    static let maxResponseBytes = 2 << 20

    private let store: MeetingStore
    private let settings: HQSettings
    private let appVersion: String
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var retryAt: [UUID: Date] = [:]
    private var draining = false
    private var drainAgain = false

    public init(store: MeetingStore, settings: HQSettings, appVersion: String, session: URLSession = HQUploader.defaultSession(),
                now: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.settings = settings
        self.appVersion = appVersion
        self.session = session
        self.now = now
    }

    /// Ephemeral: no cookies, no cache.
    public static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }

    public static func delay(afterAttempts attempts: Int) -> TimeInterval {
        backoff[min(max(attempts, 1), backoff.count) - 1]
    }

    public static func isRejected(_ item: OutboxItem) -> Bool {
        item.lastError?.hasPrefix(rejectedPrefix) ?? false
    }

    /// When the earliest backed-off meeting may be tried again, for the app's timer.
    public var nextRetry: Date? { retryAt.values.min() }

    /// Sends every pending meeting whose backoff has passed, oldest first. A call while a drain runs
    /// makes that drain go round once more and returns an empty report.
    public func drain() async -> Report {
        guard !draining else {
            drainAgain = true
            return Report()
        }
        draining = true
        defer { draining = false }
        var report = Report()
        repeat {
            drainAgain = false
            guard let base = settings.baseURL, let token = settings.token(),
                  let items = try? store.pendingOutbox() else { return report }
            for item in items where !Self.isRejected(item) {
                let id = item.meetingID
                if let at = retryAt[id], at > now() { continue }
                switch await put(id, base: base, token: token) {
                case .stored:
                    try? store.outboxAcknowledged(id)
                    retryAt[id] = nil
                    report.acknowledged.append(id)
                case .revoked:
                    settings.markNeedsReconnect()
                    report.needsReconnect = true
                    return report
                case .rejected(let message):
                    try? store.outboxFailed(id, error: Self.rejectedPrefix + message)
                    retryAt[id] = nil
                    report.rejected.append(id)
                case .retry(let message):
                    try? store.outboxFailed(id, error: message)
                    retryAt[id] = now().addingTimeInterval(Self.delay(afterAttempts: item.attempts + 1))
                    report.retrying.append(id)
                }
            }
        } while drainAgain
        return report
    }

    private enum PutResult {
        case stored, revoked, rejected(String), retry(String)
    }

    private func put(_ id: UUID, base: URL, token: String) async -> PutResult {
        let body: Data
        do {
            body = try MeetingPayload(meeting: id, store: store, appVersion: appVersion).json()
        } catch {
            return .retry("cannot read the meeting: \(error)")
        }
        var request = Self.request(base.appending(path: "api/bark/meetings/\(id.uuidString.lowercased())"), token: token)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data, status: Int
        do {
            (data, status) = try await send(request)
        } catch {
            return .retry(Self.describe(error))
        }
        switch status {
        case 200, 201: return .stored
        case 401: return .revoked
        case 413, 422: return .rejected(Self.serverMessage(data) ?? "HTTP \(status)")
        default: return .retry("HTTP \(status)")
        }
    }

    /// Deletes on this Mac the meetings deleted in hq since the last sync and returns them. A meeting
    /// still recording or transcribing is never deleted.
    @discardableResult
    public func syncDeletions() async throws -> [UUID] {
        guard let base = settings.baseURL, let token = settings.token() else { throw HQError.notConnected }
        var components = URLComponents(url: base.appending(path: "api/bark/deletions"), resolvingAgainstBaseURL: false)!
        if let since = settings.deletionsSince {
            components.percentEncodedQuery = "since=\(HQEncoding.query(since))"
        }
        var request = Self.request(components.url!, token: token)
        request.httpMethod = "GET"
        let (data, status) = try await send(request)
        if status == 401 {
            settings.markNeedsReconnect()
            throw HQError.needsReconnect
        }
        guard status == 200 else { throw HQError.server(status) }

        guard let response = try? JSONDecoder().decode(DeletionsResponse.self, from: data) else {
            throw HQError.invalidResponse("not a deletions response")
        }
        guard response.deleted.count <= Self.maxDeletions else { throw HQError.invalidResponse("too many deletions") }
        guard HQTime.parse(response.serverTime) != nil else { throw HQError.invalidResponse("server_time is not ISO 8601") }
        let ids = try response.deleted.map {
            guard let id = UUID(uuidString: $0) else { throw HQError.invalidResponse("not a meeting id") }
            return id
        }

        var deleted: [UUID] = []
        for id in ids {
            guard let meeting = try store.meeting(id), meeting.status == .done || meeting.status == .interrupted else { continue }
            try store.delete(id)
            retryAt[id] = nil
            deleted.append(id)
        }
        settings.deletionsSince = response.serverTime
        return deleted
    }

    private static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiVersion, forHTTPHeaderField: "Bark-API-Version")
        return request
    }

    /// Redirects are not followed, so the token only ever goes to the base URL the user paired with.
    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw HQError.transport("not an HTTP response") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= Self.maxResponseBytes else {
                bytes.task.cancel()
                throw HQError.invalidResponse("response too large")
            }
        }
        return (data, http.statusCode)
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? URLError { return "network error \(error.code.rawValue)" }
        if let error = error as? HQError { return "\(error)" }
        return "request failed"
    }

    /// `{"error": "..."}` from hq, cut to one printable line it is safe to show.
    static func serverMessage(_ data: Data) -> String? {
        struct Body: Decodable { let error: String }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        let line = String(String.UnicodeScalarView(body.error.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        })).trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(500))
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
