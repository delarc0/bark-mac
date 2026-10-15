@testable import BarkHQ
import Foundation
import Testing

struct HQPairingTests {
    let base = "https://hq.lab37.io"

    func callback(token: String = "tok_device_1", nonce: String, base: String? = nil) -> URL {
        var components = URLComponents(string: "bark://hq-connected")!
        components.percentEncodedQuery = "token=\(HQEncoding.query(token))&nonce=\(nonce)&base=\(HQEncoding.query(base ?? self.base))"
        return components.url!
    }

    func nonce(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "nonce" }!.value!
    }

    @Test func connectURLCarriesDeviceAndAFreshNonce() throws {
        let test = TestSettings()
        defer { test.cleanUp() }
        try test.settings.setBaseURL(base + "/")
        let pairing = HQPairing(settings: test.settings)
        let url = try pairing.begin(deviceName: "Erik’s MacBook Pro & co+1")
        #expect(url.absoluteString.hasPrefix("https://hq.lab37.io/bark/connect?device=Erik%E2%80%99s%20MacBook%20Pro%20%26%20co%2B1&nonce="))
        let first = nonce(url)
        #expect(first.count == 64 && first.allSatisfy(\.isHexDigit))
        #expect(nonce(try pairing.begin(deviceName: "Mac")) != first)
        #expect(pairing.isPending)
    }

    @Test func acceptsTheMatchingCallbackOnce() throws {
        let test = TestSettings()
        defer { test.cleanUp() }
        try test.settings.setBaseURL(base)
        let pairing = HQPairing(settings: test.settings)
        let good = callback(nonce: nonce(try pairing.begin(deviceName: "Mac")))
        #expect(test.settings.status == .notConnected)

        try pairing.complete(good)
        #expect(test.tokens.all == ["hq.lab37.io": "tok_device_1"])
        #expect(test.settings.status == .connected)
        #expect(!pairing.isPending)
        #expect(throws: HQPairingError.noPairingPending) { try pairing.complete(good) }
    }

    @Test func rejectsACallbackWithNoPairingPending() throws {
        let test = TestSettings()
        defer { test.cleanUp() }
        try test.settings.setBaseURL(base)
        #expect(throws: HQPairingError.noPairingPending) {
            try HQPairing(settings: test.settings).complete(callback(nonce: String(repeating: "0", count: 64)))
        }
        #expect(test.tokens.all.isEmpty)
    }

    @Test func wrongNonceLeavesThePairingPending() throws {
        let test = TestSettings()
        defer { test.cleanUp() }
        try test.settings.setBaseURL(base)
        let pairing = HQPairing(settings: test.settings)
        let right = nonce(try pairing.begin(deviceName: "Mac"))
        let wrong = String(right.reversed())
        #expect(throws: HQPairingError.nonceMismatch) { try pairing.complete(callback(token: "tok_evil", nonce: wrong)) }
        #expect(throws: HQPairingError.nonceMismatch) { try pairing.complete(callback(nonce: String(right.dropLast()))) }
        #expect(test.tokens.all.isEmpty && pairing.isPending)
        try pairing.complete(callback(nonce: right))
        #expect(test.tokens.all == ["hq.lab37.io": "tok_device_1"])
    }

    @Test func expiresAfterTenMinutes() throws {
        let test = TestSettings(), clock = TestClock()
        defer { test.cleanUp() }
        try test.settings.setBaseURL(base)
        let pairing = HQPairing(settings: test.settings, now: { clock.now })
        let onTime = nonce(try pairing.begin(deviceName: "Mac"))
        clock.advance(600)
        try pairing.complete(callback(nonce: onTime))

        let late = nonce(try pairing.begin(deviceName: "Mac"))
        clock.advance(601)
        #expect(!pairing.isPending)
        #expect(throws: HQPairingError.expired) { try pairing.complete(callback(token: "tok_late", nonce: late)) }
        #expect(throws: HQPairingError.noPairingPending) { try pairing.complete(callback(token: "tok_late", nonce: late)) }
        #expect(test.tokens.all == ["hq.lab37.io": "tok_device_1"])
    }

    @Test func rejectsAnotherBaseAndConsumesTheNonce() throws {
        let test = TestSettings()
        defer { test.cleanUp() }
        try test.settings.setBaseURL(base)
        let pairing = HQPairing(settings: test.settings)
        let value = nonce(try pairing.begin(deviceName: "Mac"))
        #expect(throws: HQPairingError.baseMismatch) { try pairing.complete(callback(nonce: value, base: "https://evil.example")) }
        #expect(throws: HQPairingError.noPairingPending) { try pairing.complete(callback(nonce: value)) }

        let renamed = nonce(try pairing.begin(deviceName: "Mac"))
        try test.settings.setBaseURL("https://other.lab37.io")
        #expect(throws: HQPairingError.baseMismatch) { try pairing.complete(callback(nonce: renamed)) }
        #expect(test.tokens.all.isEmpty)
    }

    @Test func rejectsBadTokens() throws {
        let test = TestSettings()
        defer { test.cleanUp() }
        try test.settings.setBaseURL(base)
        let pairing = HQPairing(settings: test.settings)
        for token in ["", "tok with space", "tok\r\nX-Evil: 1", String(repeating: "a", count: 1025), "tök"] {
            let value = nonce(try pairing.begin(deviceName: "Mac"))
            #expect(throws: HQPairingError.invalidToken, "\(token.debugDescription)") { try pairing.complete(callback(token: token, nonce: value)) }
        }
        #expect(test.tokens.all.isEmpty)
    }

    @Test func rejectsMalformedCallbacks() throws {
        let test = TestSettings()
        defer { test.cleanUp() }
        try test.settings.setBaseURL(base)
        let pairing = HQPairing(settings: test.settings)
        let value = nonce(try pairing.begin(deviceName: "Mac"))
        let encodedBase = HQEncoding.query(base)
        for text in ["bark://other?token=t&nonce=\(value)&base=\(encodedBase)",
                     "barkx://hq-connected?token=t&nonce=\(value)&base=\(encodedBase)",
                     "bark://hq-connected/extra?token=t&nonce=\(value)&base=\(encodedBase)",
                     "bark://hq-connected?nonce=\(value)&base=\(encodedBase)",
                     "bark://hq-connected?token=t&token=u&nonce=\(value)&base=\(encodedBase)",
                     "bark://hq-connected?token=t&nonce=\(value)",
                     "bark://hq-connected"] {
            #expect(throws: HQPairingError.notACallback, "\(text)") { try pairing.complete(URL(string: text)!) }
        }
        #expect(pairing.isPending && test.tokens.all.isEmpty)
    }

    @Test func validatesTheBaseURL() throws {
        #expect(HQSettings.validatedBase("https://HQ.Lab37.io/") == URL(string: "https://hq.lab37.io"))
        #expect(HQSettings.validatedBase(" https://hq.lab37.io/team// ") == URL(string: "https://hq.lab37.io/team"))
        #expect(HQSettings.validatedBase("https://hq.lab37.io:8443") == URL(string: "https://hq.lab37.io:8443"))
        #expect(HQSettings.validatedBase("http://localhost:8787") == URL(string: "http://localhost:8787"))
        for bad in ["", "hq.lab37.io", "http://hq.lab37.io", "http://127.0.0.1", "ftp://hq.lab37.io", "https://",
                    "https://user:pw@hq.lab37.io", "https://hq.lab37.io?x=1", "https://hq.lab37.io#f", "bark://hq-connected"] {
            #expect(HQSettings.validatedBase(bad) == nil, "\(bad)")
        }

        let test = TestSettings()
        defer { test.cleanUp() }
        #expect(throws: HQError.invalidBaseURL) { try test.settings.setBaseURL("http://hq.lab37.io") }
        #expect(test.settings.status == .off)
        try test.settings.setBaseURL(base)
        try test.settings.storeToken("tok_device_1", for: test.settings.baseURL!)
        test.settings.deletionsSince = "2026-10-15T12:00:00Z"
        try test.settings.setBaseURL(base + "/")
        #expect(test.settings.status == .connected)
        try test.settings.setBaseURL("")
        #expect(test.settings.status == .off && test.tokens.all.isEmpty && test.settings.deletionsSince == nil)
    }

    /// Writes to the login keychain, so it only runs when asked: BARK_KEYCHAIN_TEST=1 swift test.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BARK_KEYCHAIN_TEST"] == "1"))
    func keychainRoundTrip() throws {
        let keychain = KeychainTokenStore(service: "se.lab37.bark.hq.test")
        let account = "\(UUID().uuidString.lowercased()).hq.test"
        defer { try? keychain.deleteToken(account: account) }
        #expect(try keychain.token(account: account) == nil)
        try keychain.setToken("tok_one", account: account)
        try keychain.setToken("tok_two", account: account)
        #expect(try keychain.token(account: account) == "tok_two")
        try keychain.deleteToken(account: account)
        try keychain.deleteToken(account: account)
        #expect(try keychain.token(account: account) == nil)
    }
}
