import BarkCore
import Foundation
import Testing

struct SegmentCutTests {
    static let rate = SegmentCut.sampleRate

    /// A 300 Hz tone (speech stand-in), with the given (start, length) spans in seconds silenced.
    static func tone(seconds: Double, gaps: [(Double, Double)] = []) -> [Float] {
        var samples = (0 ..< Int(seconds * Double(rate))).map { Float(0.3 * sin(2 * Double.pi * 300 * Double($0) / Double(rate))) }
        for (start, length) in gaps {
            let range = Int(start * Double(rate)) ..< Int((start + length) * Double(rate))
            for i in range { samples[i] = 0 }
        }
        return samples
    }

    @Test func noPauseCutsAt28Seconds() {
        #expect(SegmentCut.cutIndex(Self.tone(seconds: 28.25)) == 28 * Self.rate)
    }

    @Test func cutsInTheMiddleOfAPauseInTheLastThreeSeconds() {
        let cut = SegmentCut.cutIndex(Self.tone(seconds: 28.25, gaps: [(26.0, 0.2)]))
        #expect(abs(cut - Int(26.1 * Double(Self.rate))) <= 160)
    }

    @Test func picksTheLongestPause() {
        let cut = SegmentCut.cutIndex(Self.tone(seconds: 28.25, gaps: [(25.5, 0.08), (27.0, 0.3)]))
        #expect(abs(cut - Int(27.15 * Double(Self.rate))) <= 160)
    }

    @Test func ignoresPausesShorterThan60ms() {
        #expect(SegmentCut.cutIndex(Self.tone(seconds: 28.25, gaps: [(26.0, 0.04)])) == 28 * Self.rate)
    }

    @Test func ignoresPausesBeforeTheLastThreeSeconds() {
        #expect(SegmentCut.cutIndex(Self.tone(seconds: 28.25, gaps: [(24.0, 0.5)])) == 28 * Self.rate)
    }

    @Test func aQuietGapIsAPauseEvenWithoutDigitalSilence() {
        var samples = Self.tone(seconds: 28.25)
        let range = Int(26.5 * Double(Self.rate)) ..< Int(26.7 * Double(Self.rate))
        for i in range { samples[i] *= 0.01 } // 40 dB down, far under 5% of the median power
        let cut = SegmentCut.cutIndex(samples)
        #expect(abs(cut - Int(26.6 * Double(Self.rate))) <= 160)
    }

    @Test func cutAlwaysLeavesBothSidesNonEmptyAndUnder30Seconds() {
        for gap in stride(from: 25.3, through: 28.0, by: 0.35) {
            let samples = Self.tone(seconds: 28.25, gaps: [(gap, 0.1)])
            let cut = SegmentCut.cutIndex(samples)
            #expect(cut > 0 && cut < samples.count && cut < 30 * Self.rate)
        }
    }
}
