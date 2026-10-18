import BarkCore
@testable import BarkHQ
@testable import BarkStore
import Foundation
import Testing

struct HQUploaderTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "bark-hq-\(UUID().uuidString)")
    let fixtureID = "3f2b6c1e-8a4d-4f7e-9b1a-2c5d6e7f8a90"

    /// The meeting in Fixtures/meeting-v1.json, plus a segment with no words that must not be sent.
    func fixtureMeeting(_ store: MeetingStore) throws -> UUID {
        let start = try Date("2026-10-15T09:00:00Z", strategy: .iso8601)
        let id = try store.createMeeting(language: "sv", mode: .call, title: "Weekly sync", startedAt: start).id
        let anna = try store.addSpeaker("SPEAKER_1", to: id)
        try store.nameSpeaker(anna, "Anna")
        _ = try store.addSpeaker("SPEAKER_2", to: id)
        let model = "kb-whisper-large-8bit"
        try store.addSegment(Segment(stream: .me, start: 0.84, end: 4.2, text: "Hej, hör ni mig?", model: model, language: "sv"), to: id)
        try store.addSegment(Segment(stream: .them, start: 3.9, end: 8.25, text: "Ja, vi hör dig bra.", model: model, language: "sv",
                                     speakerID: anna), to: id)
        try store.addSegment(Segment(stream: .them, start: 8.4, end: 8.9, text: " ", model: model, language: "sv"), to: id)
        try store.addSegment(Segment(stream: .them, start: 9.1, end: 12.6, text: "Ska vi börja med budgeten?", model: model,
                                     language: "sv", speakerID: anna), to: id)
        try store.setNotes(id, "Budget: fråga om Q4.\nSkicka offert på fredag.")
        try store.addGap(id, at: 1520.5, reason: "sleep")
        let event = CalendarEvent(id: "7q3k9v2m1p8d4s6f0a5h2j7n1b", title: "Weekly sync", start: start, end: start.addingTimeInterval(45 * 60),
                                  attendees: [CalendarAttendee(name: "Erik", email: "erik@example.test", isSelf: true, isOrganizer: true, response: "accepted"),
                                              CalendarAttendee(name: "Anna Svensson", email: "anna@example.test", response: "accepted")])
        try store.setCalendarEvent(id, try event.encoded())
        try store.finish(id, endedAt: start.addingTimeInterval(42 * 60 + 10))
        return id
    }

    @Test func aMeetingWithoutACalendarEventSendsNull() async throws {
        let test = TestSettings(), server = StubServer()
        defer { test.cleanUp(); try? FileManager.default.removeItem(at: root) }
        try connected(server, test)
        let store = try MeetingStore(root: root)
        let id = try store.createMeeting(language: "en", mode: .inPerson).id
        try store.finish(id, endedAt: .now)
        server.respond(status: 201)
        _ = await HQUploader(store: store, settings: test.settings, appVersion: "1.0.0 (42)", session: server.session).drain()
        let body = try #require(server.requests.first?.body)
        #expect(String(decoding: body, as: UTF8.self).contains("\"calendar_event\":null"))
    }

    func connected(_ server: StubServer, _ test: TestSettings) throws {
        try test.settings.setBaseURL(server.base.absoluteString)
        try test.settings.storeToken("tok_device_1", for: server.base)
    }

    @Test func payloadMatchesTheContractExample() async throws {
        let test = TestSettings(), server = StubServer()
        defer { test.cleanUp(); try? FileManager.default.removeItem(at: root) }
        try connected(server, test)
        let store = try MeetingStore(root: root)
        let id = try fixtureMeeting(store)
        server.respond(status: 201)

        let report = await HQUploader(store: store, settings: test.settings, appVersion: "1.0.0 (42)", session: server.session).drain()
        #expect(report == HQUploader.Report(acknowledged: [id]))
        #expect(try store.pendingOutbox().isEmpty)

        let sent = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(sent.request.httpMethod == "PUT")
        #expect(sent.request.url == server.base.appending(path: "api/bark/meetings/\(id.uuidString.lowercased())"))
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_device_1")
        #expect(sent.request.value(forHTTPHeaderField: "Bark-API-Version") == "1")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let expected = try Fixture.text("meeting-v1.json").replacingOccurrences(of: fixtureID, with: id.uuidString.lowercased())
        #expect(try Fixture.json(#require(sent.body)) == Fixture.json(Data(expected.utf8)))
    }

    @Test func contractDocumentShowsTheFixtures() throws {
        let contract = try String(contentsOf: Fixture.contract, encoding: .utf8)
        for name in ["meeting-v1.json", "deletions-v1.json"] {
            #expect(contract.contains(try Fixture.text(name).trimmingCharacters(in: .whitespacesAndNewlines)), "\(name)")
        }
    }

    @Test func rePushingTheSameMeetingReplacesIt() async throws {
        let test = TestSettings(), server = StubServer()
        defer { test.cleanUp(); try? FileManager.default.removeItem(at: root) }
        try connected(server, test)
        let store = try MeetingStore(root: root)
        let id = try fixtureMeeting(store)
        let stored = Stored()
        server.respond { request, body in (stored.put(request.url!.path(), body!) ? 201 : 200, Data()) }
        let uploader = HQUploader(store: store, settings: test.settings, appVersion: "1.0.0 (42)", session: server.session)

        #expect(await uploader.drain().acknowledged == [id])
        try store.setTitle(id, "Weekly sync, renamed")
        try store.enqueue(id)
        #expect(await uploader.drain().acknowledged == [id])
        #expect(server.requests.map(\.request.url) == [server.requests[0].request.url, server.requests[0].request.url])
        #expect(stored.count == 1)
        #expect(String(decoding: try #require(stored.latest), as: UTF8.self).contains("renamed"))
        #expect(await uploader.drain() == HQUploader.Report())
        #expect(server.requests.count == 2)
    }

    @Test func speakersFoundAfterTheUploadAreSentAgain() async throws {
        let test = TestSettings(), server = StubServer()
        defer { test.cleanUp(); try? FileManager.default.removeItem(at: root) }
        try connected(server, test)
        let store = try MeetingStore(root: root)
        let id = try store.createMeeting(language: "sv", mode: .call).id
        let mine = try store.addSegment(Segment(stream: .me, start: 0, end: 2, text: "Hej", model: "kb", language: "sv"), to: id)
        let theirs = try store.addSegment(Segment(stream: .them, start: 2, end: 5, text: "Hallå", model: "kb", language: "sv"), to: id)
        try store.finish(id, endedAt: .now)
        server.respond(status: 201)
        let uploader = HQUploader(store: store, settings: test.settings, appVersion: "1", session: server.session)
        #expect(await uploader.drain().acknowledged == [id])

        func sent() throws -> (speakers: [[String: String?]], segments: [String?]) {
            let data = try #require(server.requests.last?.body)
            let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let speakers = (body["speakers"] as? [[String: Any]] ?? []).map { $0.mapValues { $0 as? String } }
            let segments = (body["segments"] as? [[String: Any]] ?? []).map { $0["speaker"] as? String }
            return (speakers, segments)
        }
        #expect(try sent().speakers.isEmpty && sent().segments == [nil, nil])

        try store.saveSpeakers(id, labels: ["Me", "Speaker 1"], assignments: [mine: 0, theirs: 1])
        #expect(await uploader.drain().acknowledged == [id])
        #expect(try sent().speakers == [["label": "Me", "name": nil], ["label": "Speaker 1", "name": nil]])
        #expect(try sent().segments == ["Me", "Speaker 1"])

        let anna = try #require(try store.speakers(id).last)
        try store.nameSpeaker(anna.id, "Anna")
        try store.enqueue(id)
        #expect(await uploader.drain().acknowledged == [id])
        #expect(try sent().speakers == [["label": "Me", "name": nil], ["label": "Speaker 1", "name": "Anna"]])
        #expect(try sent().segments == ["Me", "Speaker 1"])
        #expect(server.requests.count == 3)
    }

    @Test func queuedAgainDuringTheUploadIsSentAgain() async throws {
        let test = TestSettings(), server = StubServer()
        defer { test.cleanUp(); try? FileManager.default.removeItem(at: root) }
        try connected(server, test)
        let store = try MeetingStore(root: root)
        let id = try fixtureMeeting(store)
        let before = try #require(try store.outboxItem(id)).generation
        // The user renames the meeting while its PUT is in flight.
        server.respond { _, _ in
            try? store.setTitle(id, "Renamed mid-upload")
            try? store.enqueue(id)
            return (201, Data())
        }
        let uploader = HQUploader(store: store, settings: test.settings, appVersion: "1", session: server.session)

        #expect(await uploader.drain() == HQUploader.Report())
        #expect(try store.pendingOutbox() == [
            OutboxItem(meetingID: id, state: .pending, generation: before + 1, attempts: 0, lastError: nil, lastAttemptAt: nil),
        ])

        server.respond(status: 200)
        #expect(await uploader.drain().acknowledged == [id])
        #expect(String(decoding: try #require(server.requests.last?.body), as: UTF8.self).contains("Renamed mid-upload"))
        #expect(try store.outboxItem(id)?.state == .acknowledged && store.outboxItem(id)?.generation == before + 1)
    }

    @Test func backsOffPerMeeting() async throws {
        let test = TestSettings(), server = StubServer(), clock = TestClock()
        defer { test.cleanUp(); try? FileManager.default.removeItem(at: root) }
        try connected(server, test)
        let store = try MeetingStore(root: root)
        let id = try fixtureMeeting(store)
        server.respond(status: 503)
        let uploader = HQUploader(store: store, settings: test.settings, appVersion: "1", session: server.session, now: { clock.now })

        #expect(await uploader.drain().retrying == [id])
        for (attempt, delay) in [60.0, 300, 1800, 7200, 21_600, 21_600].enumerated() {
            let item = try #require(try store.pendingOutbox().first)
            #expect(item.attempts == attempt + 1 && item.lastError == "HTTP 503" && item.lastAttemptAt == clock.now)
            #expect(await uploader.nextRetry == clock.now.addingTimeInterval(delay))
            clock.advance(delay - 1)
            #expect(await uploader.drain() == HQUploader.Report())
            // A relaunch keeps the backoff: it is read from the store.
            let relaunched = HQUploader(store: try MeetingStore(root: root), settings: test.settings, appVersion: "1",
                                        session: server.session, now: { clock.now })
            #expect(await relaunched.drain() == HQUploader.Report())
            #expect(server.requests.count == attempt + 1)
            clock.advance(1)
            #expect(await uploader.drain().retrying == [id])
            #expect(server.requests.count == attempt + 2)
        }

        server.respond(status: 200)
        clock.advance(21_600)
        #expect(await uploader.drain().acknowledged == [id])
        #expect(await uploader.nextRetry == nil)
    }

    @Test func unauthorizedStopsEverythingUntilReconnected() async throws {
        let test = TestSettings(), server = StubServer()
        defer { test.cleanUp(); try? FileManager.default.removeItem(at: root) }
        try connected(server, test)
        let store = try MeetingStore(root: root)
        let first = try fixtureMeeting(store), second = try fixtureMeeting(store)
        server.respond(status: 401, json: #"{"error":"revoked"}"#)
        let uploader = HQUploader(store: store, settings: test.settings, appVersion: "1", session: server.session)

        #expect(await uploader.drain() == HQUploader.Report(needsReconnect: true))
        #expect(server.requests.count == 1)
        #expect(test.settings.status == .needsReconnect)
        #expect(test.tokens.all.isEmpty)
        #expect(try store.pendingOutbox().map(\.meetingID) == [first, second])
        #expect(try store.pendingOutbox().allSatisfy { $0.attempts == 0 && $0.lastError == nil })

        #expect(await uploader.drain() == HQUploader.Report())
        await #expect(throws: HQError.notConnected) { try await uploader.syncDeletions() }
        #expect(server.requests.count == 1)

        try test.settings.storeToken("tok_device_2", for: server.base)
        #expect(test.settings.status == .connected)
        server.respond(status: 201)
        #expect(await uploader.drain().acknowledged == [first, second])
    }

    @Test func permanentRejectionIsNotRetried() async throws {
        let test = TestSettings(), server = StubServer(), clock = TestClock()
        defer { test.cleanUp(); try? FileManager.default.removeItem(at: root) }
        try connected(server, test)
        let store = try MeetingStore(root: root)
        let id = try fixtureMeeting(store)
        server.respond(status: 422, json: #"{"error":"meeting.mode:\n unknown\u0007"}"#)
        let uploader = HQUploader(store: store, settings: test.settings, appVersion: "1", session: server.session, now: { clock.now })

        #expect(await uploader.drain().rejected == [id])
        #expect(try store.pendingOutbox().isEmpty)
        let item = try #require(try store.rejectedOutbox().first)
        #expect(item.meetingID == id && item.lastError == "meeting.mode:  unknown")
        clock.advance(7 * 86_400)
        #expect(await uploader.drain() == HQUploader.Report())
        #expect(await uploader.nextRetry == nil)
        #expect(server.requests.count == 1)

        server.respond(status: 413)
        try store.enqueue(id)
        #expect(await uploader.drain().rejected == [id])
        #expect(try store.outboxItem(id)?.state == .rejected && store.outboxItem(id)?.lastError == "HTTP 413")
        #expect(server.requests.count == 2)
    }

    @Test func redirectsAreNotFollowed() async throws {
        let test = TestSettings(), server = StubServer(), elsewhere = StubServer()
        defer { test.cleanUp(); try? FileManager.default.removeItem(at: root) }
        try connected(server, test)
        let store = try MeetingStore(root: root)
        let id = try fixtureMeeting(store)
        server.redirect(to: elsewhere.base.appending(path: "api/bark/meetings/\(id.uuidString.lowercased())"))
        let uploader = HQUploader(store: store, settings: test.settings, appVersion: "1", session: server.session)
        #expect(await uploader.drain().retrying == [id])
        #expect(elsewhere.requests.isEmpty)
    }

    @Test func syncsDeletions() async throws {
        let test = TestSettings(), server = StubServer()
        defer { test.cleanUp(); try? FileManager.default.removeItem(at: root) }
        try connected(server, test)
        let store = try MeetingStore(root: root)
        let done = try fixtureMeeting(store), kept = try fixtureMeeting(store)
        let recording = try store.createMeeting(language: "en", mode: .inPerson).id
        let unknown = UUID()
        let answer = """
            {"deleted": ["\(done.uuidString.lowercased())", "\(unknown.uuidString)", "\(recording.uuidString.lowercased())"],
             "server_time": "2026-10-15T12:00:00.250+02:00"}
            """
        server.respond(status: 200, json: answer)
        let uploader = HQUploader(store: store, settings: test.settings, appVersion: "1", session: server.session)

        #expect(try await uploader.syncDeletions() == [done])
        #expect(try store.meeting(done) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.folder(done).path))
        #expect(try store.meeting(kept) != nil && store.meeting(recording) != nil)
        let firstURL = try #require(server.requests.first?.request.url)
        #expect(firstURL.path() == server.base.appending(path: "api/bark/deletions").path() && firstURL.query() == nil)
        #expect(server.requests.first?.request.httpMethod == "GET")
        #expect(server.requests.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_device_1")

        server.respond(status: 200, json: try Fixture.text("deletions-v1.json"))
        #expect(try await uploader.syncDeletions().isEmpty)
        #expect(server.requests.last?.request.url?.query(percentEncoded: true) == "since=2026-10-15T12%3A00%3A00.250%2B02%3A00")
        #expect(test.settings.deletionsSince == "2026-10-15T12:00:00Z")

        for bad in [#"{"deleted": ["not-a-uuid"], "server_time": "2026-10-16T00:00:00Z"}"#,
                    #"{"deleted": [], "server_time": "yesterday"}"#,
                    #"{"deleted": "all"}"#] {
            server.respond(status: 200, json: bad)
            await #expect(throws: HQError.self) { try await uploader.syncDeletions() }
        }
        #expect(try store.meeting(kept) != nil)
        #expect(test.settings.deletionsSince == "2026-10-15T12:00:00Z")

        server.respond(status: 401)
        await #expect(throws: HQError.needsReconnect) { try await uploader.syncDeletions() }
        #expect(test.settings.status == .needsReconnect)
    }

    @Test func offMeansNoRequestEver() async throws {
        let test = TestSettings()
        defer { test.cleanUp(); try? FileManager.default.removeItem(at: root) }
        try test.tokens.setToken("tok_device_1", account: "hq.lab37.io")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrapProtocol.self]
        let store = try MeetingStore(root: root)
        _ = try fixtureMeeting(store)
        #expect(test.settings.baseURL == nil && test.settings.status == .off)
        let uploader = HQUploader(store: store, settings: test.settings, appVersion: "1",
                                  session: URLSession(configuration: configuration))

        #expect(await uploader.drain() == HQUploader.Report())
        await #expect(throws: HQError.notConnected) { try await uploader.syncDeletions() }
        #expect(throws: HQPairingError.notConfigured) { try HQPairing(settings: test.settings).begin(deviceName: "Mac") }
        #expect(TrapProtocol.count == 0)
        #expect(try store.pendingOutbox().first?.attempts == 0)
    }
}

/// hq's side of an idempotent PUT: one meeting per path, the last body wins.
private final class Stored: @unchecked Sendable {
    private let lock = NSLock()
    private var meetings: [String: Data] = [:]
    private var last: Data?

    /// True when the path is new.
    func put(_ path: String, _ body: Data) -> Bool {
        lock.withLock {
            last = body
            return meetings.updateValue(body, forKey: path) == nil
        }
    }

    var count: Int { lock.withLock { meetings.count } }
    var latest: Data? { lock.withLock { last } }
}
