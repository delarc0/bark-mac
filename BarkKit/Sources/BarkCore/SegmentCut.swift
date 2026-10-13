/// Where to cut an open speech segment that reached `maxSeconds`, so no segment reaches Whisper's
/// 30 s window. A cut inside a word costs accuracy (S1d), so it goes in a pause when there is one.
public enum SegmentCut {
    public static let sampleRate = 16_000
    public static let maxSeconds = 28.0
    public static let windowSeconds = 3.0
    static let frame = 160 // 10 ms
    static let minPauseFrames = 6 // 60 ms

    /// `segment` holds the open segment's samples (at least `maxSeconds` of them). Returns the cut
    /// index into it: the middle of the longest pause of 60 ms or more in its last 3 s, else 28 s.
    public static func cutIndex(_ segment: [Float]) -> Int {
        let window = max(0, segment.count - Int(windowSeconds * Double(sampleRate))) ..< segment.count
        return pause(segment, in: window) ?? min(segment.count, Int(maxSeconds * Double(sampleRate)))
    }

    /// Middle of the longest run of 10 ms frames under 5% of the window's median frame power, if
    /// that run lasts 60 ms: a gap between words, not a stop closure.
    static func pause(_ samples: [Float], in range: Range<Int>) -> Int? {
        let power = stride(from: range.lowerBound, to: range.upperBound - frame, by: frame).map { a in
            samples[a ..< (a + frame)].reduce(0) { $0 + $1 * $1 }
        }
        guard !power.isEmpty else { return nil }
        let quiet = power.sorted()[power.count / 2] * 0.05
        var best = 0 ..< 0, run = 0
        for (i, p) in power.enumerated() {
            run = p < quiet ? run + 1 : 0
            if run > best.count { best = (i + 1 - run) ..< (i + 1) }
        }
        guard best.count >= minPauseFrames else { return nil }
        return range.lowerBound + (best.lowerBound + best.upperBound) / 2 * frame
    }
}
