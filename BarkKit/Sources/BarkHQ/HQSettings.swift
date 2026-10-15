import Foundation
import Security

public enum HQError: Error, Equatable, Sendable {
    case invalidBaseURL
    case notConnected
    case needsReconnect
    case keychain(OSStatus)
    case server(Int)
    case invalidResponse(String)
    case transport(String)
}

/// Where the device token lives. The app uses the Keychain; tests use memory.
public protocol HQTokenStore: Sendable {
    func token(account: String) throws -> String?
    func setToken(_ token: String, account: String) throws
    func deleteToken(account: String) throws
}

/// A generic password per hq host in the login keychain.
public struct KeychainTokenStore: HQTokenStore {
    public let service: String

    public init(service: String = HQSettings.keychainService) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func token(account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw HQError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String, account: String) throws {
        let data = Data(token.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Bark hq device token"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HQError.keychain(status) }
    }

    public func deleteToken(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HQError.keychain(status) }
    }
}

/// The hq connection. The base URL is empty by default: the feature is off and Bark never phones home.
public final class HQSettings: Sendable {
    public static let keychainService = "se.lab37.bark.hq"
    static let baseKey = "bark2.hq.baseURL"
    static let sinceKey = "bark2.hq.deletionsSince"
    static let reconnectKey = "bark2.hq.needsReconnect"

    public enum Status: Sendable, Equatable {
        case off, notConnected, connected, needsReconnect
    }

    // UserDefaults is documented thread-safe but not marked Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let tokens: any HQTokenStore

    public init(defaults: UserDefaults = .standard, tokens: any HQTokenStore = KeychainTokenStore()) {
        self.defaults = defaults
        self.tokens = tokens
    }

    /// https with a host, or http://localhost for a dev server; no credentials, query or fragment.
    /// Returns the normalized form (lowercase scheme and host, no trailing slash), or nil.
    public static func validatedBase(_ text: String) -> URL? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              scheme == "https" || (scheme == "http" && host == "localhost") else { return nil }
        var normalized = URLComponents()
        normalized.scheme = scheme
        normalized.host = host
        normalized.port = components.port
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        normalized.percentEncodedPath = path
        return normalized.url
    }

    /// nil = off.
    public var baseURL: URL? {
        defaults.string(forKey: Self.baseKey).flatMap(Self.validatedBase)
    }

    /// An empty text turns hq off. Changing the base forgets the old host's token and deletion cursor.
    public func setBaseURL(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let new: URL?
        if trimmed.isEmpty {
            new = nil
        } else {
            guard let url = Self.validatedBase(trimmed) else { throw HQError.invalidBaseURL }
            new = url
        }
        guard new != baseURL else { return }
        disconnect()
        defaults.set(new?.absoluteString, forKey: Self.baseKey)
    }

    public var status: Status {
        guard baseURL != nil else { return .off }
        if token() != nil { return .connected }
        return defaults.bool(forKey: Self.reconnectKey) ? .needsReconnect : .notConnected
    }

    /// Forgets the token and the deletion cursor. Revoking the device is done in hq.
    public func disconnect() {
        if let account = baseURL?.host() { try? tokens.deleteToken(account: account) }
        defaults.removeObject(forKey: Self.sinceKey)
        defaults.removeObject(forKey: Self.reconnectKey)
    }

    func token() -> String? {
        guard let account = baseURL?.host() else { return nil }
        return (try? tokens.token(account: account)) ?? nil
    }

    func storeToken(_ token: String, for base: URL) throws {
        guard let account = base.host() else { throw HQError.invalidBaseURL }
        try tokens.setToken(token, account: account)
        defaults.removeObject(forKey: Self.reconnectKey)
    }

    /// hq answered 401: the token was revoked.
    func markNeedsReconnect() {
        if let account = baseURL?.host() { try? tokens.deleteToken(account: account) }
        defaults.set(true, forKey: Self.reconnectKey)
    }

    /// The server time of the last deletions sync, sent back verbatim as the next `since`.
    var deletionsSince: String? {
        get { defaults.string(forKey: Self.sinceKey) }
        set { defaults.set(newValue, forKey: Self.sinceKey) }
    }
}
