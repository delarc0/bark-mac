import Foundation

public struct CalendarAttendee: Codable, Sendable, Equatable {
    public let name: String
    public let email: String
    public let isSelf: Bool
    public let isOrganizer: Bool
    public let response: String?
    public let isResource: Bool

    public init(name: String, email: String, isSelf: Bool = false, isOrganizer: Bool = false,
                response: String? = nil, isResource: Bool = false) {
        self.name = name
        self.email = email
        self.isSelf = isSelf
        self.isOrganizer = isOrganizer
        self.response = response
        self.isResource = isResource
    }

    enum CodingKeys: String, CodingKey {
        case name, email, isSelf = "self", isOrganizer = "organizer", response
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        email = try container.decode(String.self, forKey: .email)
        isSelf = try container.decode(Bool.self, forKey: .isSelf)
        isOrganizer = try container.decode(Bool.self, forKey: .isOrganizer)
        response = try container.decode(String?.self, forKey: .response)
        isResource = false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(email, forKey: .email)
        try container.encode(isSelf, forKey: .isSelf)
        try container.encode(isOrganizer, forKey: .isOrganizer)
        try container.encode(response, forKey: .response)
    }
}

public struct CalendarEvent: Codable, Sendable, Equatable {
    public let id: String
    public let title: String?
    public let start: Date
    public let end: Date
    public let attendees: [CalendarAttendee]

    public init(id: String, title: String?, start: Date, end: Date, attendees: [CalendarAttendee]) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
    }

    /// Everyone but the user and the rooms.
    public var others: [CalendarAttendee] { attendees.filter { !$0.isSelf && !$0.isResource } }

    /// The JSON the store keeps: ISO 8601 times, readable by any tool.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> CalendarEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CalendarEvent.self, from: data)
    }
}

extension CalendarAttendee {
    /// "Anna" for "Anna Svensson", "anna" for a bare "anna@example.test".
    public var firstName: String {
        if name.contains("@"), let local = name.split(separator: "@").first { return String(local) }
        return name.split(separator: " ").first.map(String.init) ?? name
    }
}

public struct CalendarCandidate: Sendable, Equatable {
    public let id: String
    public let title: String?
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let attendees: [CalendarAttendee]
    public let transparency: String?
    public let location: String?
    public let details: String?
    public let conferenceLinks: [String]

    public init(id: String, title: String?, start: Date, end: Date, isAllDay: Bool = false,
                attendees: [CalendarAttendee] = [], transparency: String? = nil, location: String? = nil,
                details: String? = nil, conferenceLinks: [String] = []) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.transparency = transparency
        self.location = location
        self.details = details
        self.conferenceLinks = conferenceLinks
    }

    var matchedEvent: CalendarEvent {
        CalendarEvent(id: id, title: title, start: start, end: end, attendees: attendees.filter { !$0.isResource })
    }

    var hasOtherAttendees: Bool {
        attendees.contains { !$0.isSelf && !$0.isResource }
    }
}

public enum CalendarMatch {
    public static func bestEvent(from candidates: [CalendarCandidate], at now: Date, for app: CallApp?) -> CalendarEvent? {
        candidates.filter { eligible($0, at: now) }
            .min { comesBefore($0, $1, at: now, app: app) }?
            .matchedEvent
    }

    private static func eligible(_ candidate: CalendarCandidate, at now: Date) -> Bool {
        guard !candidate.isAllDay,
              !candidate.attendees.contains(where: { $0.isSelf && $0.response == "declined" }),
              candidate.start.addingTimeInterval(-600) <= now, now <= candidate.end else { return false }
        return candidate.transparency != "transparent" || candidate.hasOtherAttendees
    }

    private static func comesBefore(_ first: CalendarCandidate, _ second: CalendarCandidate, at now: Date, app: CallApp?) -> Bool {
        let firstConference = hasFittingConference(first, app: app)
        let secondConference = hasFittingConference(second, app: app)
        if firstConference != secondConference { return firstConference }
        if first.hasOtherAttendees != second.hasOtherAttendees { return first.hasOtherAttendees }
        let firstDistance = abs(first.start.timeIntervalSince(now))
        let secondDistance = abs(second.start.timeIntervalSince(now))
        if firstDistance != secondDistance { return firstDistance < secondDistance }
        let firstDuration = first.end.timeIntervalSince(first.start)
        let secondDuration = second.end.timeIntervalSince(second.start)
        if firstDuration != secondDuration { return firstDuration < secondDuration }
        return first.id < second.id
    }

    private static func hasFittingConference(_ candidate: CalendarCandidate, app: CallApp?) -> Bool {
        guard let app else { return false }
        if app.capturesAllTabs {
            return candidate.conferenceLinks.contains { $0.lowercased().contains("meet.google.com") }
        }
        let domain: String
        if app.bundleIDs.contains("us.zoom.xos") {
            domain = "zoom.us"
        } else if app.bundleIDs.contains(where: { ["com.microsoft.teams", "com.microsoft.teams2"].contains($0) }) {
            domain = "teams.microsoft.com"
        } else {
            return false
        }
        return ([candidate.location, candidate.details].compactMap { $0 } + candidate.conferenceLinks)
            .contains { $0.lowercased().contains(domain) }
    }
}
