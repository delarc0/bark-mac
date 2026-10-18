@testable import BarkCalendar
import Foundation

/// A fake Google per test: requests to its unique host are answered by `respond` and recorded.
/// Swift Testing runs tests in parallel, so servers are told apart by host.
final class StubGoogle: @unchecked Sendable {
    struct Recorded {
        let request: URLRequest
        let body: String
        var path: String { request.url?.path() ?? "" }
        var query: [String: String] {
            Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                       uniquingKeysWith: { first, _ in first })
        }
        var form: [String: String] {
            Dictionary(body.split(separator: "&").map { pair -> (String, String) in
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                return (parts[0], parts.count > 1 ? parts[1] : "")
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    let base: URL
    let endpoints: GoogleEndpoints
    let session: URLSession
    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private var handler: @Sendable (Recorded) -> (Int, String) = { _ in (200, "{}") }

    init() {
        base = URL(string: "https://\(UUID().uuidString.lowercased()).google.test")!
        var endpoints = GoogleEndpoints()
        endpoints.authorization = base.appending(path: "auth")
        endpoints.token = base.appending(path: "token")
        endpoints.revoke = base.appending(path: "revoke")
        endpoints.calendarAPI = base.appending(path: "calendar/v3")
        self.endpoints = endpoints
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        StubProtocol.register(self, host: base.host()!)
    }

    var requests: [Recorded] { lock.withLock { recorded } }

    func respond(_ handler: @escaping @Sendable (Recorded) -> (Int, String)) {
        lock.withLock { self.handler = handler }
    }

    fileprivate func handle(_ request: URLRequest, body: Data?) -> (Int, String) {
        let recorded = Recorded(request: request, body: body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        return lock.withLock {
            self.recorded.append(recorded)
            return handler
        }(recorded)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubGoogle] = [:]

    static func register(_ server: StubGoogle, host: String) {
        lock.withLock { servers[host] = server }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let server = Self.lock.withLock({ Self.servers[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, body) = server.handle(request, body: request.httpBody ?? request.httpBodyStream.map(Self.read))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return data }
            data.append(buffer, count: count)
        }
    }
}

final class MemoryTokens: CalendarTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(_ token: String? = nil) { stored = token }
    func token() throws -> String? { lock.withLock { stored } }
    func setToken(_ token: String) throws { lock.withLock { stored = token } }
    func deleteToken() throws { lock.withLock { stored = nil } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

let testClient = GoogleClient(id: "123456789-abcdefghij.apps.googleusercontent.com")!

enum Fixture {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }
}

func tokenJSON(access: String = "access-1", refresh: String? = "refresh-1", expiresIn: Int = 3599) -> String {
    var fields = ["\"access_token\": \"\(access)\"", "\"expires_in\": \(expiresIn)", "\"token_type\": \"Bearer\""]
    if let refresh { fields.append("\"refresh_token\": \"\(refresh)\"") }
    return "{\(fields.joined(separator: ", "))}"
}
