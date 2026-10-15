@testable import BarkHQ
import Foundation

/// A fake hq per test: requests to its unique host are answered by `respond` and recorded.
/// Swift Testing runs tests in parallel, so servers are told apart by host.
final class StubServer: @unchecked Sendable {
    struct Recorded {
        let request: URLRequest
        let body: Data?
    }

    let base: URL
    let session: URLSession
    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private var handler: @Sendable (URLRequest, Data?) -> (Int, Data) = { _, _ in (200, Data()) }
    private var location: URL?

    init() {
        base = URL(string: "https://\(UUID().uuidString.lowercased()).hq.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        StubProtocol.register(self, host: base.host()!)
    }

    var requests: [Recorded] { lock.withLock { recorded } }

    func respond(_ handler: @escaping @Sendable (URLRequest, Data?) -> (Int, Data)) {
        lock.withLock { self.handler = handler }
    }

    func respond(status: Int, json: String = "") {
        respond { _, _ in (status, Data(json.utf8)) }
    }

    func redirect(to url: URL) {
        lock.withLock { location = url }
        respond(status: 307)
    }

    var redirectLocation: URL? { lock.withLock { location } }

    fileprivate func handle(_ request: URLRequest, body: Data?) -> (Int, Data) {
        lock.withLock {
            recorded.append(Recorded(request: request, body: body))
            return handler
        }(request, body)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    static func register(_ server: StubServer, host: String) {
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
        let (status, data) = server.handle(request, body: request.httpBody ?? request.httpBodyStream.map(Self.read))
        var headers = ["Content-Type": "application/json"]
        if let location = server.redirectLocation { headers["Location"] = location.absoluteString }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if let location = server.redirectLocation {
            var redirected = request
            redirected.url = location
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
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

/// Counts every request a session tries to make, whatever its host.
final class TrapProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counted = 0
    static var count: Int { lock.withLock { counted } }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { counted += 1 }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
}

final class MemoryTokens: HQTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    func token(account: String) throws -> String? { lock.withLock { tokens[account] } }
    func setToken(_ token: String, account: String) throws { lock.withLock { tokens[account] = token } }
    func deleteToken(account: String) throws { _ = lock.withLock { tokens.removeValue(forKey: account) } }
    var all: [String: String] { lock.withLock { tokens } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Settings on a throwaway UserDefaults suite and an in-memory token store.
struct TestSettings {
    let suite = "bark-hq-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let tokens = MemoryTokens()
    let settings: HQSettings

    init() {
        defaults = UserDefaults(suiteName: suite)!
        settings = HQSettings(defaults: defaults, tokens: tokens)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}

enum Fixture {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
    static let contract = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../tasks/bark-hq-api.md").standardized

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }

    /// Parsed for comparison: key order and whitespace do not matter, values and nulls do.
    static func json(_ data: Data) throws -> NSObject {
        try JSONSerialization.jsonObject(with: data) as! NSObject
    }
}
