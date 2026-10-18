@testable import BarkCalendar
import Foundation
import Testing

struct PKCETests {
    @Test func verifierIsLongEnoughAndURLSafe() throws {
        let verifier = try PKCE.verifier()
        #expect(verifier.count == 43)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(verifier.allSatisfy { allowed.contains($0) })
        #expect(try PKCE.verifier() != verifier)
    }

    @Test func challengeMatchesTheRFC7636Vector() {
        #expect(PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
}

struct GoogleClientTests {
    @Test func redirectIsTheReversedClientID() {
        #expect(testClient.callbackScheme == "com.googleusercontent.apps.123456789-abcdefghij")
        #expect(testClient.redirectURI == "com.googleusercontent.apps.123456789-abcdefghij:/oauth2redirect")
    }

    @Test func emptyOrForeignIDsTurnTheFeatureOff() {
        #expect(GoogleClient(id: "") == nil)
        #expect(GoogleClient(id: "  ") == nil)
        #expect(GoogleClient(id: "abc") == nil)
        #expect(GoogleClient(id: ".apps.googleusercontent.com") == nil)
    }
}

struct GoogleAuthTests {
    func callback(_ flow: GoogleAuth.Flow, state: String? = nil, code: String? = "code-1", error: String? = nil) -> URL {
        var components = URLComponents(string: testClient.redirectURI)!
        var items = [URLQueryItem(name: "state", value: state ?? flow.state)]
        if let code { items.append(URLQueryItem(name: "code", value: code)) }
        if let error { items.append(URLQueryItem(name: "error", value: error)) }
        components.queryItems = items
        return components.url!
    }

    @Test func signInURLCarriesPKCEStateAndScopes() async throws {
        let google = StubGoogle()
        let auth = GoogleAuth(client: testClient, tokens: MemoryTokens(), endpoints: google.endpoints, session: google.session)
        let flow = try await auth.begin()
        let query = Dictionary((URLComponents(url: flow.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        #expect(flow.url.absoluteString.hasPrefix(google.endpoints.authorization.absoluteString + "?"))
        #expect(query["client_id"] == testClient.id)
        #expect(query["redirect_uri"] == testClient.redirectURI)
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == PKCE.challenge(flow.verifier))
        #expect(query["state"] == flow.state)
        #expect(flow.state.count == 64)
        #expect(query["scope"] == GoogleAuth.scopes.joined(separator: " "))
        #expect(query["prompt"] == "consent")
        #expect(auth.isCallback(callback(flow)))
        #expect(!auth.isCallback(URL(string: "bark://hq-connected")!))
    }

    @Test func completeExchangesTheCodeWithTheVerifierAndStoresTheRefreshToken() async throws {
        let google = StubGoogle()
        let tokens = MemoryTokens()
        let auth = GoogleAuth(client: testClient, tokens: tokens, endpoints: google.endpoints, session: google.session)
        google.respond { _ in (200, tokenJSON()) }
        let flow = try await auth.begin()
        try await auth.complete(callback(flow))
        let request = try #require(google.requests.first)
        #expect(request.path == "/token")
        #expect(request.request.httpMethod == "POST")
        #expect(request.form["code"] == "code-1")
        #expect(request.form["code_verifier"] == flow.verifier)
        #expect(request.form["client_id"] == testClient.id)
        #expect(request.form["grant_type"] == "authorization_code")
        #expect(request.form["redirect_uri"] == testClient.redirectURI)
        #expect(request.form["client_secret"] == nil)
        #expect(try tokens.token() == "refresh-1")
        #expect(await auth.isConnected)
        #expect(try await auth.accessToken() == "access-1")
        #expect(google.requests.count == 1)
    }

    @Test func wrongStateOrNoSignInIsRefusedAndConsumesTheSignIn() async throws {
        let google = StubGoogle()
        let auth = GoogleAuth(client: testClient, tokens: MemoryTokens(), endpoints: google.endpoints, session: google.session)
        let flow = try await auth.begin()
        let stray = GoogleAuth(client: testClient, tokens: MemoryTokens(), endpoints: google.endpoints, session: google.session)
        await #expect(throws: CalendarError.noSignInPending) { try await stray.complete(callback(flow)) }
        await #expect(throws: CalendarError.stateMismatch) { try await auth.complete(callback(flow, state: "someone-elses")) }
        await #expect(throws: CalendarError.noSignInPending) { try await auth.complete(callback(flow)) }
        #expect(google.requests.isEmpty)
        #expect(await !auth.isConnected)
    }

    @Test func aDeniedSignInIsReportedWithoutARequest() async throws {
        let google = StubGoogle()
        let auth = GoogleAuth(client: testClient, tokens: MemoryTokens(), endpoints: google.endpoints, session: google.session)
        let flow = try await auth.begin()
        await #expect(throws: CalendarError.denied("access_denied")) {
            try await auth.complete(callback(flow, code: nil, error: "access_denied"))
        }
        #expect(google.requests.isEmpty)
    }

    @Test func accessTokenIsRefreshedAMinuteBeforeExpiry() async throws {
        let google = StubGoogle()
        let clock = TestClock()
        let auth = GoogleAuth(client: testClient, tokens: MemoryTokens("refresh-0"), endpoints: google.endpoints,
                              session: google.session, now: { clock.now })
        google.respond { request in (200, tokenJSON(access: "access-\(request.form["refresh_token"] ?? "?")", refresh: nil, expiresIn: 3600)) }
        #expect(try await auth.accessToken() == "access-refresh-0")
        clock.advance(3000)
        #expect(try await auth.accessToken() == "access-refresh-0")
        clock.advance(600)
        #expect(try await auth.accessToken() == "access-refresh-0")
        #expect(google.requests.count == 2)
        let refresh = google.requests[1]
        #expect(refresh.form["grant_type"] == "refresh_token")
        #expect(refresh.form["refresh_token"] == "refresh-0")
        #expect(refresh.form["client_secret"] == nil)
    }

    @Test func invalidGrantDisconnectsInsteadOfLooping() async throws {
        let google = StubGoogle()
        let tokens = MemoryTokens("refresh-dead")
        let auth = GoogleAuth(client: testClient, tokens: tokens, endpoints: google.endpoints, session: google.session)
        google.respond { _ in (400, #"{"error": "invalid_grant", "error_description": "Token has been expired or revoked."}"#) }
        await #expect(throws: CalendarError.disconnected) { try await auth.accessToken() }
        #expect(try tokens.token() == nil)
        await #expect(throws: CalendarError.notConnected) { try await auth.accessToken() }
        #expect(google.requests.count == 1)
    }

    @Test func otherTokenFailuresKeepTheRefreshToken() async throws {
        let google = StubGoogle()
        let tokens = MemoryTokens("refresh-0")
        let auth = GoogleAuth(client: testClient, tokens: tokens, endpoints: google.endpoints, session: google.session)
        google.respond { _ in (503, "") }
        await #expect(throws: CalendarError.server(503)) { try await auth.accessToken() }
        #expect(try tokens.token() == "refresh-0")
    }

    @Test func disconnectRevokesAndForgets() async throws {
        let google = StubGoogle()
        let tokens = MemoryTokens("refresh-0")
        let auth = GoogleAuth(client: testClient, tokens: tokens, endpoints: google.endpoints, session: google.session)
        await auth.disconnect()
        let request = try #require(google.requests.first)
        #expect(request.path == "/revoke")
        #expect(request.form["token"] == "refresh-0")
        #expect(try tokens.token() == nil)
        #expect(await !auth.isConnected)
    }
}
