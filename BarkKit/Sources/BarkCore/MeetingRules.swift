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

    public static func plan(_ choice: MeetingModeChoice, processes: [AudioProcess],
                            appName: (Int32) -> String? = { _ in nil }) -> MeetingCapturePlan {
        let call = CallApps.likelyCall(processes, appName: appName).map { app in
            MeetingCapturePlan.app(app, pids: CallApps.processes(of: app, in: processes).map(\.pid))
        }
        switch choice {
        case .automatic: return call ?? .microphone
        case .call: return call ?? .allSystemAudio
        case .inPerson: return .microphone
        }
    }
}

/// Offers known calls at once and unknown calls after two polls, once per input pid set until withdrawal.
public struct CallOffers: Sendable {
    public enum Change: Sendable, Equatable {
        case offer(CallApp)
        /// The offered (or recorded) call ended.
        case withdraw
        case none
    }

    private var current: Set<Int32> = []
    private var pendingUnknown: String?

    public init() {}

    public mutating func observe(_ processes: [AudioProcess], appName: (Int32) -> String? = { _ in nil }) -> Change {
        let found = CallApps.likelyCall(processes, appName: appName)
        let unknown = Self.unknownRoot(found)
        let confirmed = unknown != nil && unknown == pendingUnknown
        pendingUnknown = unknown
        guard let app = found, unknown == nil || confirmed else {
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
        let app = CallApps.likelyCall(processes)
        current = app.map { Self.inputPids(of: $0, in: processes) } ?? []
        pendingUnknown = Self.unknownRoot(app)
    }

    private static func inputPids(of app: CallApp, in processes: [AudioProcess]) -> Set<Int32> {
        Set(processes.filter { $0.runningInput && app.owns($0.bundleID) }.map(\.pid))
    }

    private static func unknownRoot(_ app: CallApp?) -> String? {
        guard let app, app.bundleIDs.count == 1, CallApps.app(bundleID: app.bundleIDs[0]) == nil else { return nil }
        return app.bundleIDs[0].lowercased()
    }
}

/// Whether the call a meeting records has ended: its app has held no audio input for a while.
/// Polled like CallOffers. `ended` is reported once; input coming back reports `resumed` and starts
/// over. `shouldStop` is for a meeting nobody answered for: the room is not recorded for hours.
public struct CallEnd: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case none, ended, resumed
    }

    public static let offerAfter: TimeInterval = 30
    public static let stopAfter: TimeInterval = 600

    private let app: CallApp
    private let offerAfter: TimeInterval
    private let stopAfter: TimeInterval
    private var silentSince: Date?
    private var ended = false

    public init(app: CallApp, offerAfter: TimeInterval = CallEnd.offerAfter, stopAfter: TimeInterval = CallEnd.stopAfter) {
        self.app = app
        self.offerAfter = offerAfter
        self.stopAfter = stopAfter
    }

    public var hasEnded: Bool { ended }

    public mutating func observe(_ processes: [AudioProcess], at now: Date) -> Change {
        let live = processes.contains { $0.runningInput && app.owns($0.bundleID) }
        if live {
            silentSince = nil
            guard ended else { return .none }
            ended = false
            return .resumed
        }
        let since = silentSince ?? now
        silentSince = since
        guard !ended, now.timeIntervalSince(since) >= offerAfter else { return .none }
        ended = true
        return .ended
    }

    /// True once the call has been over for `stopAfter`.
    public func shouldStop(at now: Date) -> Bool {
        guard ended, let since = silentSince else { return false }
        return now.timeIntervalSince(since) >= stopAfter
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

    /// The whole meeting as Markdown for pasting elsewhere: title, a meta line (already formatted
    /// by the caller), the notes as typed, the transcript. Empty parts are left out.
    public static func markdown(title: String, meta: [String], notes: String?, lines: [Line]) -> String {
        var parts = ["# " + title.trimmingCharacters(in: .whitespacesAndNewlines)]
        let meta = meta.filter { !$0.isEmpty }
        if !meta.isEmpty { parts.append(meta.joined(separator: " · ")) }
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            parts.append("## Notes\n\n" + notes)
        }
        let transcript = plain(lines)
        if !transcript.isEmpty { parts.append("## Transcript\n\n" + transcript) }
        return parts.joined(separator: "\n\n") + "\n"
    }
}
