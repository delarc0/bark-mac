import Foundation
import Security

public enum HQPairingError: Error, Equatable, Sendable {
    case notConfigured
    case randomFailed
    case notACallback
    case noPairingPending
    case expired
    case nonceMismatch
    case baseMismatch
    case invalidToken
}

/// Pairing with zero typing: `begin` gives the hq page to open in the browser, hq redirects to
/// `bark://hq-connected?token=&nonce=&base=`, and `complete` checks that callback before storing the
/// token. Any app can open a bark:// URL, so a callback is only taken for a pairing this process
/// started, with its nonce, within 10 minutes, once.
public final class HQPairing: @unchecked Sendable {
    public static let lifetime: TimeInterval = 600
    public static let callbackScheme = "bark"
    public static let callbackHost = "hq-connected"

    private struct Pending {
        let nonce: String
        let base: URL
        let startedAt: Date
    }

    private let settings: HQSettings
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var pending: Pending?

    public init(settings: HQSettings, now: @escaping @Sendable () -> Date = { .now }) {
        self.settings = settings
        self.now = now
    }

    public static var defaultDeviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    public var isPending: Bool {
        lock.withLock { pending.map { now().timeIntervalSince($0.startedAt) <= Self.lifetime } ?? false }
    }

    /// Starts a pairing, replacing any pending one, and returns the URL to open in the browser.
    public func begin(deviceName: String = HQPairing.defaultDeviceName) throws -> URL {
        guard let base = settings.baseURL else { throw HQPairingError.notConfigured }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw HQPairingError.randomFailed }
        let nonce = bytes.map { String(format: "%02x", $0) }.joined()
        lock.withLock { pending = Pending(nonce: nonce, base: base, startedAt: now()) }
        var components = URLComponents(url: base.appending(path: "bark/connect"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = "device=\(HQEncoding.query(deviceName))&nonce=\(nonce)"
        return components.url!
    }

    public static func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == callbackScheme && url.host()?.lowercased() == callbackHost
    }

    /// Checks a bark://hq-connected callback and stores its token. A callback carrying the right
    /// nonce consumes the pairing whether or not the rest of it checks out.
    public func complete(_ callback: URL) throws {
        guard Self.isCallback(callback), let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              ["", "/"].contains(callback.path()) else { throw HQPairingError.notACallback }
        func single(_ name: String) throws -> String {
            let values = items.filter { $0.name == name }
            guard values.count == 1, let value = values[0].value else { throw HQPairingError.notACallback }
            return value
        }
        let token = try single("token"), nonce = try single("nonce"), base = try single("base")

        let claimed: Pending = try lock.withLock {
            guard let current = pending else { throw HQPairingError.noPairingPending }
            guard now().timeIntervalSince(current.startedAt) <= Self.lifetime else {
                pending = nil
                throw HQPairingError.expired
            }
            guard Self.constantTimeEqual(nonce, current.nonce) else { throw HQPairingError.nonceMismatch }
            pending = nil
            return current
        }
        guard HQSettings.validatedBase(base) == claimed.base, settings.baseURL == claimed.base else { throw HQPairingError.baseMismatch }
        guard Self.isValidToken(token) else { throw HQPairingError.invalidToken }
        try settings.storeToken(token, for: claimed.base)
    }

    /// Visible ASCII only, so it cannot break out of the Authorization header.
    static func isValidToken(_ token: String) -> Bool {
        (1...1024).contains(token.utf8.count) && token.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum HQEncoding {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything but RFC 3986 unreserved characters, so `+`, `&` and `=` survive.
    static func query(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
