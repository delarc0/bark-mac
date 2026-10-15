import Foundation

/// Where a transcript segment that holds two people is cut, so each piece can be re-decoded and
/// carry its own speaker. A pause-closed segment often spans a change of speaker; the diarizer's
/// turns show where, and the cut goes at the quietest point near that change.
public enum SegmentSplit {
    public struct Rule: Sendable, Equatable {
        /// A speaker's stretch inside the segment shorter than this never causes a cut; it stays
        /// with its neighbours.
        public var minTurn: Double
        /// How far either side of a change the quietest point is looked for.
        public var search: Double
        /// A piece shorter than this joins its neighbour (the short-segment rule).
        public var minPiece: Double
        /// The pieces must hold at least this share of the whole segment's words, or it is kept
        /// whole: on AMI, splits that lost words were the ones that made WER worse.
        public var minWordShare: Double

        public init(minTurn: Double = 1.0, search: Double = 0.25, minPiece: Double = 1.0, minWordShare: Double = 0.9) {
            self.minTurn = minTurn
            self.search = search
            self.minPiece = minPiece
            self.minWordShare = minWordShare
        }
    }

    /// The windows to cut in, one per change between two speakers' stretches of at least
    /// `minTurn` inside `start..<end`; empty when the segment holds one speaker that long.
    public static func cutWindows(start: Double, end: Double, turns: [SpeakerAttribution.Turn], rule: Rule = Rule())
        -> [ClosedRange<Double>] {
        var runs = merge(turns.compactMap { turn in
            let s = max(start, turn.start), e = min(end, turn.end)
            return e > s ? SpeakerAttribution.Turn(speaker: turn.speaker, start: s, end: e) : nil
        }.sorted { $0.start < $1.start })
        runs = merge(runs.filter { $0.end - $0.start >= rule.minTurn })
        return zip(runs, runs.dropFirst()).map { a, b in
            let low = max(a.start, start, min(a.end, b.start) - rule.search)
            let high = min(b.end, end, max(a.end, b.start) + rule.search)
            return low ... max(low, high)
        }
    }

    /// The quietest moment in `window`, from `energy` (one value per `hop` seconds, the first
    /// centred at `origin`); ties go to the one nearest the window's middle.
    public static func quietest(in window: ClosedRange<Double>, energy: [Float], origin: Double, hop: Double) -> Double {
        let middle = (window.lowerBound + window.upperBound) / 2
        let first = max(0, Int(((window.lowerBound - origin) / hop).rounded(.up)))
        let last = min(energy.count - 1, Int(((window.upperBound - origin) / hop).rounded(.down)))
        guard first <= last else { return middle }
        let best = (first ... last).min { a, b in
            energy[a] != energy[b] ? energy[a] < energy[b]
                : abs(origin + Double(a) * hop - middle) < abs(origin + Double(b) * hop - middle)
        }!
        return origin + Double(best) * hop
    }

    /// RMS over `window` seconds every `hop` seconds, the first value centred on sample 0.
    public static func energy(_ samples: [Float], rate: Int, window: Double = 0.05, hop: Double = 0.01) -> [Float] {
        let half = Int(window * Double(rate)) / 2, step = max(1, Int(hop * Double(rate)))
        return stride(from: 0, to: samples.count, by: step).map { center in
            let range = max(0, center - half) ..< min(samples.count, center + half)
            guard !range.isEmpty else { return 0 }
            return (samples[range].reduce(0) { $0 + $1 * $1 } / Float(range.count)).squareRoot()
        }
    }

    /// The pieces between `cuts`; a piece under `minPiece` joins the next one, or the previous one
    /// when it is last, as the segmenter joins short segments.
    public static func pieces(start: Double, end: Double, cuts: [Double], rule: Rule = Rule()) -> [Range<Double>] {
        var bounds = [start] + cuts.filter { $0 > start && $0 < end }.sorted() + [end]
        while bounds.count > 2, let short = (0 ..< bounds.count - 1).first(where: { bounds[$0 + 1] - bounds[$0] < rule.minPiece }) {
            bounds.remove(at: short + 1 < bounds.count - 1 ? short + 1 : short)
        }
        return zip(bounds, bounds.dropFirst()).map { $0 ..< $1 }
    }

    /// Whether `pieces` may replace `whole`: every piece has words, and together they keep
    /// `minWordShare` of the whole's words.
    public static func keepsText(whole: String, pieces: [String], rule: Rule = Rule()) -> Bool {
        func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }
        return !pieces.isEmpty && pieces.allSatisfy { words($0) > 0 }
            && Double(pieces.reduce(0) { $0 + words($1) }) >= rule.minWordShare * Double(words(whole))
    }

    private static func merge(_ runs: [SpeakerAttribution.Turn]) -> [SpeakerAttribution.Turn] {
        var merged: [SpeakerAttribution.Turn] = []
        for run in runs {
            if let last = merged.last, last.speaker == run.speaker {
                merged[merged.count - 1] = SpeakerAttribution.Turn(speaker: run.speaker, start: last.start, end: max(last.end, run.end))
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}
