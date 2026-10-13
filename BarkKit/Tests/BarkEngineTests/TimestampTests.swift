@testable import BarkEngine
import Testing

/// The timestamped re-decode's pure parts, on a toy vocabulary: timestamps start at 100.
private let begin = 100
private func t(_ step: Int) -> Int { begin + step }

struct TimestampTests {
    static func window(_ tokens: [Int], frames: Int = 3000) -> (kept: [Int], advance: Int) {
        Engine.timestampedWindow(tokens, timestampBegin: begin, frames: frames)
    }

    @Test func finishedWindowKeepsEverythingAndConsumesTheWindow() {
        let tokens = [t(0), 1, 2, t(250), t(250), 3, t(400)]
        let window = Self.window(tokens, frames: 1200)
        #expect(window.kept == tokens)
        #expect(window.advance == 1200)
    }

    @Test func unfinishedSegmentIsDroppedAndSeekGoesToItsStart() {
        // "1" ends at 5.00 s; "2" opens at 5.00 s and never closes: re-decode from 5.00 s.
        let window = Self.window([t(0), 1, t(250), t(250), 2])
        #expect(window.kept == [t(0), 1, t(250)])
        #expect(window.advance == 500) // 250 steps of 0.02 s = 500 mel frames of 10 ms
    }

    @Test func noConsecutivePairKeepsAllAndConsumesTheWindow() {
        let window = Self.window([t(0), 1, 2, t(370)], frames: 900)
        #expect(window.kept == [t(0), 1, 2, t(370)])
        #expect(window.advance == 900)
    }

    @Test func instantaneousSegmentsAreCleared() {
        let window = Self.window([t(20), t(20), t(20), 1, t(60)])
        #expect(window.kept == [t(20), 1, t(60)])
    }

    @Test func seekNeverStandsStill() {
        #expect(Self.window([t(0), t(0), 1], frames: 700).advance == 700)
    }

    static func mask(after sampled: [Int]) -> [Float] {
        Engine.timestampMask(after: sampled, timestampBegin: begin, eot: 50, noTimestamps: 60, vocab: 300)
    }

    @Test func firstTokenIsATimestampWithinOneSecond() {
        let mask = Self.mask(after: [])
        #expect((0 ..< begin).allSatisfy { mask[$0] == -.infinity })
        #expect((begin ... t(50)).allSatisfy { mask[$0] == 0 })
        #expect((t(51) ..< 300).allSatisfy { mask[$0] == -.infinity })
    }

    @Test func afterTextAndATimestampComesATimestampOrTheEnd() {
        let mask = Self.mask(after: [t(3), 5, t(30)])
        #expect(mask[5] == -.infinity && mask[49] == -.infinity)
        #expect(mask[50] == 0) // end of text
        #expect(mask[t(29)] == -.infinity && mask[t(30)] == 0) // the next segment may start where this one ended
        #expect(mask[60] == -.infinity) // never <|notimestamps|>
    }

    @Test func afterAPairComesText() {
        let mask = Self.mask(after: [t(3), 5, t(30), t(30)])
        #expect((begin ..< 300).allSatisfy { mask[$0] == -.infinity })
        #expect(mask[5] == 0)
    }

    @Test func timestampsNeverGoBackAndSegmentsHaveLength() {
        let mask = Self.mask(after: [t(3), 5])
        #expect(mask[t(3)] == -.infinity && mask[t(4)] == 0)
        #expect(mask[5] == 0)
    }
}
