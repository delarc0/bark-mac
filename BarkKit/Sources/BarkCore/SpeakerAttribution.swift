import Foundation

/// Who said what: a diarizer's speaker turns on one stream, attributed to that stream's
/// transcript segments, and the labels the user sees until they name a speaker.
public enum SpeakerAttribution {
    /// A stretch of one stream the diarizer gave to one speaker. Seconds from the stream's start.
    public struct Turn: Sendable, Equatable {
        public let speaker: Int
        public let start: Double
        public let end: Double

        public init(speaker: Int, start: Double, end: Double) {
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    /// The call's own mic: the user alone, never diarized.
    public static let userLabel = "Me"

    public static func label(_ number: Int) -> String {
        "Speaker \(number)"
    }

    /// The speaker whose turns overlap `start..<end` the most in total; nil when no turn overlaps.
    /// A tie goes to the speaker whose overlapping turn comes first.
    public static func speaker(start: Double, end: Double, in turns: [Turn]) -> Int? {
        var overlap: [Int: Double] = [:]
        var first: [Int: Double] = [:]
        for turn in turns {
            let shared = min(end, turn.end) - max(start, turn.start)
            guard shared > 0 else { continue }
            overlap[turn.speaker, default: 0] += shared
            first[turn.speaker] = min(first[turn.speaker] ?? .infinity, turn.start)
        }
        return overlap.max { a, b in
            a.value != b.value ? a.value < b.value : first[a.key]! > first[b.key]!
        }?.key
    }

    /// Numbers speakers 1...n in the order they first appear in `appearances` (one entry per
    /// segment, in time order); a speaker keeps its number when it appears again.
    public static func numbers<Key: Hashable>(inOrderOfAppearance appearances: [Key]) -> [Key: Int] {
        var numbers: [Key: Int] = [:]
        for key in appearances where numbers[key] == nil {
            numbers[key] = numbers.count + 1
        }
        return numbers
    }
}
