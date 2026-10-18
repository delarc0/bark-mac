import CryptoKit
import Foundation
import Security

public enum CalendarError: Error, Equatable, Sendable {
    case notConfigured
    case notConnected
    /// Google refused the refresh token: the user revoked access or it expired. Connect again.
    case disconnected
    case randomFailed
    case notACallback
    case noSignInPending
    case stateMismatch
    case denied(String)
    case keychain(OSStatus)
    case server(Int)
    case invalidResponse(String)
    case transport(String)
    case timeout
}

/// Where the refresh token lives. The app uses the Keychain; tests use memory.
public protocol CalendarTokenStore: Sendable {
    func token() throws -> String?
    func setToken(_ token: String) throws
    func deleteToken() throws
}

/// One generic password in the login keychain.
public struct KeychainRefreshTokenStore: CalendarTokenStore {
    public static let service = "se.lab37.bark.google"
    static let account = "refresh-token"

    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
    }

    public func token() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CalendarError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String) throws {
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Bark Google Calendar"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CalendarError.keychain(status) }
    }

    public func deleteToken() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CalendarError.keychain(status) }
    }
}

/// RFC 7636: a verifier the browser never sees, its S256 challenge in the sign-in URL.
public enum PKCE {
    public static func verifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CalendarError.randomFailed }
        return base64URL(Data(bytes))
    }

    public static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Google's iOS-type OAuth client: a public id, no secret, redirect on the reversed-id scheme.
public struct GoogleClient: Sendable, Equatable {
    public static let idSuffix = ".apps.googleusercontent.com"

    public let id: String

    /// nil for an empty or malformed id: the calendar feature is then off.
    public init?(id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(Self.idSuffix), trimmed.count > Self.idSuffix.count else { return nil }
        self.id = trimmed
    }

    public var callbackScheme: String {
        "com.googleusercontent.apps." + id.dropLast(Self.idSuffix.count)
    }

    public var redirectURI: String { callbackScheme + ":/oauth2redirect" }
}

public struct GoogleEndpoints: Sendable {
    public var authorization = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public var token = URL(string: "https://oauth2.googleapis.com/token")!
    public var revoke = URL(string: "https://oauth2.googleapis.com/revoke")!
    public var calendarAPI = URL(string: "https://www.googleapis.com/calendar/v3")!

    public init() {}
}

/// Sign-in and tokens. `begin` gives the URL for the browser sheet, `complete` takes the callback,
/// `accessToken` keeps a short-lived token in memory and refreshes it from the Keychain's refresh
/// token. A callback is only taken for a sign-in this process started, with its state, once.
public actor GoogleAuth {
    public static let scopes = [
        "https://www.googleapis.com/auth/calendar.events.readonly",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    ]
    /// Refreshed this long before Google's expiry, so a token never dies mid-request.
    static let refreshMargin: TimeInterval = 60

    public struct Flow: Sendable, Equatable {
        public let url: URL
        let state: String
        let verifier: String
    }

    private struct Access {
        let token: String
        let expiresAt: Date
    }

    public nonisolated let client: GoogleClient
    let endpoints: GoogleEndpoints
    private nonisolated let tokens: any CalendarTokenStore
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var pending: Flow?
    private var access: Access?

    public init(client: GoogleClient, tokens: any CalendarTokenStore = KeychainRefreshTokenStore(),
                endpoints: GoogleEndpoints = GoogleEndpoints(), session: URLSession = GoogleAuth.defaultSession(),
                now: @escaping @Sendable () -> Date = { .now }) {
        self.client = client
        self.tokens = tokens
        self.endpoints = endpoints
        self.session = session
        self.now = now
    }

    /// Ephemeral: no cookies, no cache.
    public static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    /// Synchronous: the Keychain answers at once, so the UI knows its state at launch.
    public nonisolated var isConnected: Bool {
        ((try? tokens.token()) ?? nil) != nil
    }

    /// Starts a sign-in, replacing any pending one.
    public func begin() throws -> Flow {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CalendarError.randomFailed }
        let state = bytes.map { String(format: "%02x", $0) }.joined()
        let verifier = try PKCE.verifier()
        var components = URLComponents(url: endpoints.authorization, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: client.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        let flow = Flow(url: components.url!, state: state, verifier: verifier)
        pending = flow
        return flow
    }

    public nonisolated func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == client.callbackScheme.lowercased()
    }

    /// Takes the browser's callback, exchanges its code and stores the refresh token.
    public func complete(_ callback: URL) async throws {
        guard isCallback(callback), let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw CalendarError.notACallback
        }
        guard let flow = pending else { throw CalendarError.noSignInPending }
        pending = nil
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == flow.state else { throw CalendarError.stateMismatch }
        if let error = value("error") { throw CalendarError.denied(error) }
        guard let code = value("code"), !code.isEmpty else { throw CalendarError.notACallback }
        let response = try await tokenRequest([
            "client_id": client.id, "code": code, "code_verifier": flow.verifier,
            "grant_type": "authorization_code", "redirect_uri": client.redirectURI,
        ])
        guard let refresh = response.refreshToken, !refresh.isEmpty else {
            throw CalendarError.invalidResponse("no refresh token")
        }
        try tokens.setToken(refresh)
        access = Access(token: response.accessToken, expiresAt: now().addingTimeInterval(response.expiresIn))
    }

    /// A token good for at least a minute, refreshed when needed.
    public func accessToken() async throws -> String {
        if let access, access.expiresAt > now().addingTimeInterval(Self.refreshMargin) { return access.token }
        guard let refresh = try tokens.token() else { throw CalendarError.notConnected }
        let response: TokenResponse
        do {
            response = try await tokenRequest(["client_id": client.id, "refresh_token": refresh, "grant_type": "refresh_token"])
        } catch CalendarError.denied(let reason) where reason == "invalid_grant" {
            try? tokens.deleteToken()
            access = nil
            throw CalendarError.disconnected
        }
        access = Access(token: response.accessToken, expiresAt: now().addingTimeInterval(response.expiresIn))
        return response.accessToken
    }

    /// Forgets the tokens; Google is told, best effort.
    public func disconnect() async {
        pending = nil
        access = nil
        if let refresh = try? tokens.token() {
            var request = URLRequest(url: endpoints.revoke)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.form(["token": refresh]).utf8)
            _ = try? await session.data(for: request)
        }
        try? tokens.deleteToken()
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval
        let refreshToken: String?

        enum CodingKeys: String, CodingKey { case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token" }
    }

    private struct TokenError: Decodable {
        let error: String
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: endpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.form(fields).utf8)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CalendarError.transport(String(describing: error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if let failure = try? JSONDecoder().decode(TokenError.self, from: data) { throw CalendarError.denied(failure.error) }
            throw CalendarError.server(status)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw CalendarError.invalidResponse("token response: \(error)")
        }
    }

    static func form(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}
