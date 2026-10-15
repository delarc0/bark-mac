import Foundation

/// What a meeting starts with when the user just clicks Start: nothing to fill in.
public enum MeetingDefaults {
    /// The last meeting's language. The first time, the dictation language; Auto becomes Swedish when
    /// the Swedish model is on and English otherwise, since a meeting needs an explicit language.
    public static func language(last: String?, dictation: LanguageChoice, swedishModel: Bool) -> String {
        if let last, !last.isEmpty { return last }
        if case .explicit(let code) = dictation { return code }
        return swedishModel ? "sv" : "en"
    }
}

/// The user's pick for the next meeting's audio.
public enum MeetingModeChoice: String, Sendable, CaseIterable {
    /// A call when one is detected, otherwise in person.
    case automatic
    /// Mic plus the detected call app, or all system audio when none is detected.
    case call
    /// Mic only.
    case inPerson
}

/// What a meeting will record.
public enum MeetingCapturePlan: Sendable, Equatable {
    /// The mic and this app's processes, helpers included.
    case app(CallApp, pids: [Int32])
    /// The mic and every process's output but Bark's.
    case allSystemAudio
    /// The mic alone.
    case microphone

    public static func plan(_ choice: MeetingModeChoice, processes: [AudioProcess]) -> MeetingCapturePlan {
        let call = CallApps.likelyCall(processes).map { app in
            MeetingCapturePlan.app(app, pids: CallApps.processes(of: app, in: processes).map(\.pid))
        }
        switch choice {
        case .automatic: return call ?? .microphone
        case .call: return call ?? .allSystemAudio
        case .inPerson: return .microphone
        }
    }
}

/// Detect and offer: a call is offered once, identified by the pids holding audio input in its app,
/// and not again until it ends. Never records; it only says when to show or withdraw the offer.
public struct CallOffers: Sendable {
    public enum Change: Sendable, Equatable {
        case offer(CallApp)
        /// The offered (or recorded) call ended.
        case withdraw
        case none
    }

    private var current: Set<Int32> = []

    public init() {}

    public mutating func observe(_ processes: [AudioProcess]) -> Change {
        guard let app = CallApps.likelyCall(processes) else {
            defer { current = [] }
            return current.isEmpty ? .none : .withdraw
        }
        let live = Self.inputPids(of: app, in: processes)
        let isNew = current.isDisjoint(with: live)
        current = live
        return isNew ? .offer(app) : .none
    }

    /// A call recorded without an offer (started from the menu) must not be offered once it stops.
    public mutating func markHandled(_ processes: [AudioProcess]) {
        current = CallApps.likelyCall(processes).map { Self.inputPids(of: $0, in: processes) } ?? []
    }

    private static func inputPids(of app: CallApp, in processes: [AudioProcess]) -> Set<Int32> {
        Set(processes.filter { $0.runningInput && app.owns($0.bundleID) }.map(\.pid))
    }
}

/// How long a finished meeting's audio is kept. Transcripts and notes are always kept.
public enum AudioRetention: Int, Sendable, CaseIterable {
    case week = 7
    case month = 30
    case quarter = 90
    case forever = 0

    /// Unknown or missing stored values fall back to 30 days.
    public init(days: Int?) {
        self = days.flatMap(AudioRetention.init(rawValue:)) ?? .month
    }

    /// nil = never delete.
    public var interval: TimeInterval? {
        self == .forever ? nil : TimeInterval(rawValue) * 86_400
    }
}

/// Plain-text forms of a transcript, for lists and the clipboard.
public enum TranscriptText {
    public struct Line: Sendable, Equatable {
        public let label: String?
        public let start: Double
        public let text: String

        public init(label: String?, start: Double, text: String) {
            self.label = label
            self.start = start
            self.text = text
        }
    }

    /// m:ss under an hour, h:mm:ss from an hour; negative times read as 0.
    public static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// The first `count` words of the texts in order, with an ellipsis when there are more; nil when
    /// there are no words.
    public static func firstWords(_ texts: [String], count: Int = 8) -> String? {
        var words: [Substring] = []
        for text in texts {
            words += text.split(whereSeparator: \.isWhitespace)
            if words.count > count { break }
        }
        guard !words.isEmpty else { return nil }
        let head = words.prefix(count).joined(separator: " ")
        return words.count > count ? head + "…" : head
    }

    /// One line per segment, "[m:ss] Label: text"; lines without words are left out.
    public static func plain(_ lines: [Line]) -> String {
        lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "[\(timestamp(line.start))] " + (line.label.map { "\($0): " } ?? "") + text
        }.joined(separator: "\n")
    }
}
