import BarkCore
import Foundation

/// Reads the signed-in account's calendars and the events around now, and nothing else. The
/// calendar list is cached for an hour; events are fetched fresh, all calendars in parallel.
public actor GoogleCalendar {
    /// How far around now events are asked for: a meeting started late, or one about to start.
    public static let lookBehind: TimeInterval = 3 * 3600
    public static let lookAhead: TimeInterval = 3600
    public static let maxCalendars = 10
    static let calendarListLifetime: TimeInterval = 3600
    static let maxResponseBytes = 4 << 20

    public struct Account: Sendable, Equatable {
        public let email: String
    }

    struct CalendarInfo: Sendable {
        let id: String
        let selected: Bool
        let primary: Bool
    }

    private let auth: GoogleAuth
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var calendars: (list: [CalendarInfo], fetchedAt: Date)?

    public init(auth: GoogleAuth, session: URLSession = GoogleAuth.defaultSession(), now: @escaping @Sendable () -> Date = { .now }) {
        self.auth = auth
        self.session = session
        self.now = now
    }

    /// The signed-in account, shown as "Connected as <email>".
    public func account() async throws -> Account {
        struct Entry: Decodable { let id: String }
        let entry: Entry = try await get("users/me/calendarList/primary")
        return Account(email: entry.id)
    }

    /// Every timed event on the selected calendars that could be the meeting happening now.
    public func candidates(around moment: Date? = nil) async throws -> [CalendarCandidate] {
        let moment = moment ?? now()
        let list = try await calendarList()
        let from = moment.addingTimeInterval(-Self.lookBehind), to = moment.addingTimeInterval(Self.lookAhead)
        return try await withThrowingTaskGroup(of: [CalendarCandidate].self) { group in
            for calendar in list {
                group.addTask { try await self.events(of: calendar.id, from: from, to: to) }
            }
            var all: [CalendarCandidate] = []
            for try await events in group { all += events }
            var seen: Set<String> = []
            return all.filter { seen.insert($0.id).inserted }
        }
    }

    public func forgetCalendars() {
        calendars = nil
    }

    private func calendarList() async throws -> [CalendarInfo] {
        if let calendars, now().timeIntervalSince(calendars.fetchedAt) < Self.calendarListLifetime { return calendars.list }
        struct Entry: Decodable {
            let id: String
            let selected: Bool?
            let primary: Bool?
        }
        struct Page: Decodable { let items: [Entry]? }
        let page: Page = try await get("users/me/calendarList", query: [
            "minAccessRole": "reader", "fields": "items(id,selected,primary)", "maxResults": "250",
        ])
        let list = (page.items ?? []).map { CalendarInfo(id: $0.id, selected: $0.selected ?? false, primary: $0.primary ?? false) }
        // Only what the user shows in Google Calendar, the primary calendar first.
        let shown = list.filter { $0.selected || $0.primary }.sorted { $0.primary && !$1.primary }.prefix(Self.maxCalendars)
        calendars = (Array(shown), now())
        return Array(shown)
    }

    private func events(of calendar: String, from: Date, to: Date) async throws -> [CalendarCandidate] {
        let page: GoogleEvents.Page = try await get("calendars/\(calendar)/events", query: [
            "singleEvents": "true", "orderBy": "startTime", "maxResults": "50",
            "timeMin": GoogleEncoding.time(from), "timeMax": GoogleEncoding.time(to),
            "fields": GoogleEvents.fields,
        ])
        return GoogleEvents.candidates(page)
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var components = URLComponents(url: auth.endpoints.calendarAPI.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var token = try await auth.accessToken()
        for attempt in 0 ..< 2 {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw CalendarError.transport(String(describing: error))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 401 once: the cached token died early; refreshed and tried again.
            if status == 401, attempt == 0 {
                token = try await auth.accessToken()
                continue
            }
            guard status == 200 else { throw CalendarError.server(status) }
            guard data.count <= Self.maxResponseBytes else { throw CalendarError.invalidResponse("response too large") }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw CalendarError.invalidResponse("\(path): \(error)")
            }
        }
        throw CalendarError.server(401)
    }
}

/// Google's events.list JSON, reduced to what matching needs.
enum GoogleEvents {
    static let fields = "items(id,status,summary,start,end,attendees(displayName,email,self,organizer,responseStatus,resource),"
        + "transparency,location,description,hangoutLink,conferenceData(entryPoints(uri)))"

    struct Page: Decodable {
        let items: [Event]?
    }

    struct Event: Decodable {
        let id: String
        let status: String?
        let summary: String?
        let start: Moment?
        let end: Moment?
        let attendees: [Attendee]?
        let transparency: String?
        let location: String?
        let description: String?
        let hangoutLink: String?
        let conferenceData: Conference?
    }

    struct Moment: Decodable {
        let dateTime: String?
        let date: String?
    }

    struct Attendee: Decodable {
        let displayName: String?
        let email: String?
        let isSelf: Bool?
        let organizer: Bool?
        let responseStatus: String?
        let resource: Bool?

        enum CodingKeys: String, CodingKey { case displayName, email, isSelf = "self", organizer, responseStatus, resource }
    }

    struct Conference: Decodable {
        struct EntryPoint: Decodable { let uri: String? }
        let entryPoints: [EntryPoint]?
    }

    static func candidates(_ page: Page) -> [CalendarCandidate] {
        (page.items ?? []).compactMap(candidate)
    }

    static func candidate(_ event: Event) -> CalendarCandidate? {
        guard event.status != "cancelled", let start = event.start, let end = event.end else { return nil }
        let allDay = start.dateTime == nil
        guard let from = parse(start), let to = parse(end), to > from else { return nil }
        let attendees = (event.attendees ?? []).compactMap { attendee -> CalendarAttendee? in
            guard let email = attendee.email, !email.isEmpty else { return nil }
            let name = attendee.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CalendarAttendee(name: name.isEmpty ? email : name, email: email, isSelf: attendee.isSelf ?? false,
                                    isOrganizer: attendee.organizer ?? false, response: attendee.responseStatus,
                                    isResource: attendee.resource ?? false)
        }
        let links = [event.hangoutLink].compactMap { $0 } + (event.conferenceData?.entryPoints ?? []).compactMap(\.uri)
        return CalendarCandidate(id: event.id, title: event.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                                 start: from, end: to, isAllDay: allDay, attendees: attendees, transparency: event.transparency,
                                 location: event.location, details: event.description, conferenceLinks: links)
    }

    private static func parse(_ moment: Moment) -> Date? {
        if let text = moment.dateTime {
            return (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        guard let day = moment.date else { return nil }
        return try? Date(day, strategy: Date.ISO8601FormatStyle.iso8601.year().month().day())
    }
}

enum GoogleEncoding {
    static func time(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

/// Runs `operation` for at most `seconds`; a slow calendar must never hold a meeting up.
public func withCalendarTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CalendarError.timeout
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
