import BarkCore
import Foundation
import Testing

struct CalendarMatchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func attendee(_ name: String = "Anna Example", email: String = "anna@example.test", self isSelf: Bool = false,
                  response: String? = "accepted", resource: Bool = false) -> CalendarAttendee {
        CalendarAttendee(name: name, email: email, isSelf: isSelf, isOrganizer: false, response: response, isResource: resource)
    }

    func candidate(_ id: String, start: TimeInterval = -300, duration: TimeInterval = 3_600,
                   attendees: [CalendarAttendee] = [], allDay: Bool = false, transparency: String? = nil,
                   location: String? = nil, details: String? = nil, links: [String] = []) -> CalendarCandidate {
        CalendarCandidate(id: id, title: "Title \(id)", start: now.addingTimeInterval(start),
                          end: now.addingTimeInterval(start + duration), isAllDay: allDay, attendees: attendees,
                          transparency: transparency, location: location, details: details, conferenceLinks: links)
    }

    @Test func eventStartingExactlyTenMinutesFromNowMatches() {
        let event = candidate("early", start: 600)
        #expect(CalendarMatch.bestEvent(from: [event], at: now, for: nil)?.id == "early")
    }

    @Test func eventStartingAfterTheEarlyWindowDoesNotMatch() {
        let event = candidate("late", start: 601)
        #expect(CalendarMatch.bestEvent(from: [event], at: now, for: nil) == nil)
    }

    @Test func eventEndingNowMatches() {
        let event = candidate("ending", start: -3_600, duration: 3_600)
        #expect(CalendarMatch.bestEvent(from: [event], at: now, for: nil)?.id == "ending")
    }

    @Test func allDayEventDoesNotMatch() {
        let event = candidate("all-day", attendees: [attendee()], allDay: true)
        #expect(CalendarMatch.bestEvent(from: [event], at: now, for: nil) == nil)
    }

    @Test func eventDeclinedBySelfDoesNotMatch() {
        let event = candidate("declined", attendees: [attendee(self: true, response: "declined"), attendee()])
        #expect(CalendarMatch.bestEvent(from: [event], at: now, for: nil) == nil)
    }

    @Test func eventDeclinedBySomeoneElseMatches() {
        let event = candidate("other-declined", attendees: [attendee(self: true), attendee(response: "declined")])
        #expect(CalendarMatch.bestEvent(from: [event], at: now, for: nil)?.id == "other-declined")
    }

    @Test func transparentEventWithoutOtherAttendeesDoesNotMatch() {
        let event = candidate("free", attendees: [attendee(self: true)], transparency: "transparent")
        #expect(CalendarMatch.bestEvent(from: [event], at: now, for: nil) == nil)
    }

    @Test func transparentEventWithOtherAttendeesMatches() {
        let event = candidate("busy", attendees: [attendee(self: true), attendee()], transparency: "transparent")
        #expect(CalendarMatch.bestEvent(from: [event], at: now, for: nil)?.id == "busy")
    }

    @Test func resourceRoomIsNotAnotherAttendee() {
        let event = candidate("room-only", attendees: [attendee(self: true), attendee(resource: true)], transparency: "transparent")
        #expect(CalendarMatch.bestEvent(from: [event], at: now, for: nil) == nil)
    }

    @Test func matchedEventExcludesResourceRooms() throws {
        let event = candidate("people", attendees: [attendee(self: true), attendee(), attendee(resource: true)])
        let match = try #require(CalendarMatch.bestEvent(from: [event], at: now, for: nil))
        #expect(match.attendees.map(\.name) == ["Anna Example", "Anna Example"])
        #expect(match.attendees.map(\.isSelf) == [true, false])
    }

    @Test func meetLinkRanksFirstForBrowserCall() {
        let browser = CallApp(name: "Google Chrome", bundleIDs: ["com.google.Chrome"], capturesAllTabs: true)
        let attendees = candidate("attendees", attendees: [attendee()])
        let meet = candidate("meet", links: ["https://meet.google.com/abc-defg-hij"])
        #expect(CalendarMatch.bestEvent(from: [attendees, meet], at: now, for: browser)?.id == "meet")
    }

    @Test func zoomLinkInLocationRanksFirstForZoom() {
        let zoom = CallApp(name: "Zoom", bundleIDs: ["us.zoom.xos"])
        let meet = candidate("meet", attendees: [attendee()], links: ["https://meet.google.com/abc-defg-hij"])
        let event = candidate("zoom", location: "https://zoom.us/j/123456")
        #expect(CalendarMatch.bestEvent(from: [meet, event], at: now, for: zoom)?.id == "zoom")
    }

    @Test func zoomLinkInDescriptionOrConferenceDataRanksFirstForZoom() {
        let zoom = CallApp(name: "Zoom", bundleIDs: ["us.zoom.xos"])
        for event in [candidate("description", details: "Join https://zoom.us/j/123456"),
                      candidate("conference", links: ["https://zoom.us/j/123456"])] {
            #expect(CalendarMatch.bestEvent(from: [candidate("other"), event], at: now, for: zoom)?.id == event.id)
        }
    }

    @Test func teamsLinkRanksFirstForTeams() {
        let teams = CallApp(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2"])
        let event = candidate("teams", details: "https://teams.microsoft.com/l/meetup-join/example")
        #expect(CalendarMatch.bestEvent(from: [candidate("other", attendees: [attendee()]), event], at: now, for: teams)?.id == "teams")
    }

    @Test func conferenceLinkForAnotherAppDoesNotRank() {
        let zoom = CallApp(name: "Zoom", bundleIDs: ["us.zoom.xos"])
        let attendees = candidate("attendees", attendees: [attendee()])
        let meet = candidate("meet", links: ["https://meet.google.com/abc-defg-hij"])
        #expect(CalendarMatch.bestEvent(from: [meet, attendees], at: now, for: zoom)?.id == "attendees")
    }

    @Test func attendeesOutrankAnEventWithoutAttendees() {
        let closer = candidate("closer", start: -10)
        let people = candidate("people", start: -300, attendees: [attendee()])
        #expect(CalendarMatch.bestEvent(from: [closer, people], at: now, for: nil)?.id == "people")
    }

    @Test func closestStartWinsWithinTheSameRank() {
        let earlier = candidate("earlier", start: -300)
        let closer = candidate("closer", start: -30)
        #expect(CalendarMatch.bestEvent(from: [earlier, closer], at: now, for: nil)?.id == "closer")
    }

    @Test func shorterEventWinsAStartTie() {
        let longer = candidate("longer", start: -600, duration: 1_800)
        let shorter = candidate("shorter", start: -600, duration: 1_200)
        #expect(CalendarMatch.bestEvent(from: [longer, shorter], at: now, for: nil)?.id == "shorter")
    }

    @Test func noRecordedAppIgnoresConferenceLinks() {
        let meet = candidate("meet", links: ["https://meet.google.com/abc-defg-hij"])
        let people = candidate("people", attendees: [attendee()])
        #expect(CalendarMatch.bestEvent(from: [meet, people], at: now, for: nil)?.id == "people")
    }

    @Test func eventJSONRoundTripsWithISOTimes() throws {
        let event = CalendarEvent(id: "evt", title: "Weekly", start: now, end: now.addingTimeInterval(1800),
                                  attendees: [attendee("Erik", email: "erik@example.test", self: true), attendee()])
        let data = try event.encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("\"start\":\"2027-01-15T08:00:00Z\""))
        #expect(try CalendarEvent.decode(data) == event)
        #expect(event.others.map(\.name) == ["Anna Example"])
    }

    @Test func firstNamesComeFromTheNameOrTheEmail() {
        #expect(attendee("Anna Svensson").firstName == "Anna")
        #expect(attendee("anna@example.test").firstName == "anna")
        #expect(attendee("Cher").firstName == "Cher")
    }

    @Test func storedAttendeeEncodingOmitsResourceFlag() throws {
        let data = try JSONEncoder().encode(attendee(resource: true))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["name"] as? String == "Anna Example")
        #expect(object["email"] as? String == "anna@example.test")
        #expect(object["self"] as? Bool == false)
        #expect(object["organizer"] as? Bool == false)
        #expect(object["response"] as? String == "accepted")
        #expect(object["resource"] == nil && object["isResource"] == nil)
    }
}
