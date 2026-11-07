@testable import BarkCalendar
import BarkCore
import Foundation
import Synchronization
import Testing

struct GoogleEventsDecodingTests {
    @Test func realisticEventsBecomeCandidates() throws {
        let page = try JSONDecoder().decode(GoogleEvents.Page.self, from: Data(try Fixture.text("events.json").utf8))
        let candidates = GoogleEvents.candidates(page)
        #expect(candidates.map(\.id) == ["weekly-1", "focus-1", "birthday-1", "fraction-1"])

        let weekly = candidates[0]
        #expect(weekly.title == "Weekly with Tegen")
        #expect(weekly.start == Date(timeIntervalSince1970: 1_800_000_000 - 600))
        #expect(weekly.end == Date(timeIntervalSince1970: 1_800_000_000 + 1800))
        #expect(!weekly.isAllDay)
        #expect(weekly.attendees.map(\.email) == ["erik@example.test", "anna@example.test", "room-3@resource.calendar.google.com", "johan@example.test"])
        #expect(weekly.attendees.map(\.name) == ["erik@example.test", "Anna Svensson", "Room 3", "Johan Berg"])
        #expect(weekly.attendees.map(\.isSelf) == [true, false, false, false])
        #expect(weekly.attendees.map(\.isOrganizer) == [false, true, false, false])
        #expect(weekly.attendees.map(\.isResource) == [false, false, true, false])
        #expect(weekly.attendees.map(\.response) == ["accepted", "accepted", "accepted", "tentative"])
        #expect(weekly.location == "https://zoom.us/j/123456")
        #expect(weekly.conferenceLinks == ["https://meet.google.com/abc-defg-hij", "https://meet.google.com/abc-defg-hij"])

        #expect(candidates[1].transparency == "transparent")
        #expect(candidates[1].attendees.isEmpty)
        #expect(candidates[2].isAllDay)
        #expect(candidates[3].start == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(candidates[3].attendees.isEmpty)
    }

    @Test func theMatcherPicksTheWeeklyFromTheFixture() throws {
        let page = try JSONDecoder().decode(GoogleEvents.Page.self, from: Data(try Fixture.text("events.json").utf8))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let zoom = CallApp(name: "Zoom", bundleIDs: ["us.zoom.xos"])
        let match = try #require(CalendarMatch.bestEvent(from: GoogleEvents.candidates(page), at: now, for: zoom))
        #expect(match.id == "weekly-1")
        #expect(match.attendees.map(\.name) == ["erik@example.test", "Anna Svensson", "Johan Berg"])
    }
}

struct GoogleCalendarTests {
    func connected(_ google: StubGoogle, clock: TestClock = TestClock()) -> GoogleCalendar {
        let auth = GoogleAuth(client: testClient, tokens: MemoryTokens("refresh-0"), endpoints: google.endpoints,
                              session: google.session, now: { clock.now })
        return GoogleCalendar(auth: auth, session: google.session, now: { clock.now })
    }

    static let calendarList = """
    {"items": [
      {"id": "erik@example.test", "summary": "erik@example.test", "selected": true, "primary": true},
      {"id": "shared@group.calendar.google.com", "summary": "LAB37 - STUDIO", "selected": true},
      {"id": "hidden@group.calendar.google.com", "summary": "Holidays", "selected": false}
    ]}
    """

    @Test func accountIsThePrimaryCalendarsID() async throws {
        let google = StubGoogle()
        google.respond { request in
            request.path.hasSuffix("/token") ? (200, tokenJSON(refresh: nil)) : (200, #"{"id": "erik@example.test", "primary": true}"#)
        }
        let calendar = connected(google)
        #expect(try await calendar.account() == GoogleCalendar.Account(email: "erik@example.test"))
        let request = try #require(google.requests.last)
        #expect(request.path.hasSuffix("/calendar/v3/users/me/calendarList/primary"))
        #expect(request.request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }

    @Test func candidatesComeFromEverySelectedCalendarAroundNow() async throws {
        let google = StubGoogle()
        let clock = TestClock()
        let events = try Fixture.text("events.json")
        google.respond { request in
            if request.path.hasSuffix("/token") { return (200, tokenJSON(refresh: nil)) }
            if request.path.hasSuffix("/calendarList") { return (200, Self.calendarList) }
            if request.path.contains("/calendars/shared@group.calendar.google.com/events") {
                return (200, #"{"items": [{"id": "weekly-1", "summary": "Duplicate", "start": {"dateTime": "2027-01-15T08:50:00+01:00"}, "end": {"dateTime": "2027-01-15T09:30:00+01:00"}}]}"#)
            }
            return (200, events)
        }
        let calendar = connected(google, clock: clock)
        let candidates = try await calendar.candidates()
        #expect(Set(candidates.map(\.id)) == ["weekly-1", "focus-1", "birthday-1", "fraction-1"])
        #expect(candidates.first { $0.id == "weekly-1" }?.title == "Weekly with Tegen")

        let paths = google.requests.map(\.path)
        #expect(paths.filter { $0.hasSuffix("/calendarList") }.count == 1)
        let eventRequests = google.requests.filter { $0.path.hasSuffix("/events") }
        #expect(eventRequests.count == 2)
        #expect(Set(eventRequests.map(\.path)) == ["/calendar/v3/calendars/erik@example.test/events",
                                                    "/calendar/v3/calendars/shared@group.calendar.google.com/events"])
        let query = try #require(eventRequests.first?.query)
        #expect(query["singleEvents"] == "true")
        #expect(query["orderBy"] == "startTime")
        #expect(query["timeMin"] == "2027-01-15T05:00:00Z")
        #expect(query["timeMax"] == "2027-01-15T09:00:00Z")
        #expect(query["fields"]?.contains("attendees(") == true)

        _ = try await calendar.candidates()
        #expect(google.requests.map(\.path).filter { $0.hasSuffix("/calendarList") }.count == 1)
        clock.advance(3601)
        _ = try await calendar.candidates()
        #expect(google.requests.map(\.path).filter { $0.hasSuffix("/calendarList") }.count == 2)
    }

    @Test func aCalendarGoogleRefusesIsSkipped() async throws {
        let google = StubGoogle()
        let events = try Fixture.text("events.json")
        google.respond { request in
            if request.path.hasSuffix("/token") { return (200, tokenJSON(refresh: nil)) }
            if request.path.hasSuffix("/calendarList") { return (200, Self.calendarList) }
            if request.path.contains("/calendars/shared@group.calendar.google.com/events") { return (403, "") }
            return (200, events)
        }
        let calendar = connected(google, clock: TestClock())
        #expect(Set(try await calendar.candidates().map(\.id)) == ["weekly-1", "focus-1", "birthday-1", "fraction-1"])
    }

    @Test func aDeadTokenOnACalendarStillFailsTheLookup() async throws {
        let google = StubGoogle()
        google.respond { request in
            if request.path.hasSuffix("/token") { return (200, tokenJSON(refresh: nil)) }
            if request.path.hasSuffix("/calendarList") { return (200, Self.calendarList) }
            return (401, "")
        }
        let calendar = connected(google, clock: TestClock())
        await #expect(throws: CalendarError.server(401)) { try await calendar.candidates() }
    }

    @Test func aDeadAccessTokenIsRefreshedOnceOn401() async throws {
        let google = StubGoogle()
        let issued = Mutex(0)
        google.respond { request in
            if request.path.hasSuffix("/token") {
                let n = issued.withLock { $0 += 1; return $0 }
                return (200, tokenJSON(access: n == 1 ? "access-dead" : "access-live", refresh: nil))
            }
            return request.request.value(forHTTPHeaderField: "Authorization") == "Bearer access-live" ? (200, #"{"id": "erik@example.test"}"#) : (401, "")
        }
        let auth = GoogleAuth(client: testClient, tokens: MemoryTokens("refresh-0"), endpoints: google.endpoints, session: google.session)
        let calendar = GoogleCalendar(auth: auth, session: google.session)
        #expect(try await calendar.account().email == "erik@example.test")
        #expect(google.requests.filter { $0.path.hasSuffix("/token") }.count == 2)
        #expect(google.requests.filter { $0.path.hasSuffix("/calendarList/primary") }.map { $0.request.value(forHTTPHeaderField: "Authorization") }
                == ["Bearer access-dead", "Bearer access-live"])
        #expect(try await auth.accessToken() == "access-live")
    }

    @Test func aSecond401IsAnError() async throws {
        let google = StubGoogle()
        google.respond { request in request.path.hasSuffix("/token") ? (200, tokenJSON(refresh: nil)) : (401, "") }
        let calendar = connected(google)
        await #expect(throws: CalendarError.server(401)) { try await calendar.account() }
    }

    @Test func serverFailuresSurfaceAsErrors() async throws {
        let google = StubGoogle()
        google.respond { request in request.path.hasSuffix("/token") ? (200, tokenJSON(refresh: nil)) : (500, "") }
        let calendar = connected(google)
        await #expect(throws: CalendarError.server(500)) { try await calendar.candidates() }
    }

    @Test func aSlowCalendarTimesOut() async throws {
        await #expect(throws: CalendarError.timeout) {
            try await withCalendarTimeout(0.05) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        #expect(try await withCalendarTimeout(1) { 2 } == 2)
    }
}
