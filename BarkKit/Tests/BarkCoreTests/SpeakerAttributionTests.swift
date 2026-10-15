import BarkCore
import Testing

struct SpeakerAttributionTests {
    typealias Turn = SpeakerAttribution.Turn

    @Test func largestTotalOverlapWins() {
        let turns = [Turn(speaker: 0, start: 0, end: 4), Turn(speaker: 1, start: 4, end: 7), Turn(speaker: 0, start: 7, end: 8)]
        // 3 s of speaker 1 against 1 s + 0.5 s of speaker 0.
        #expect(SpeakerAttribution.speaker(start: 3, end: 7.5, in: turns) == 1)
        // Two turns of speaker 0 add up: 1 s + 1 s against 1.5 s of speaker 1.
        let split = [Turn(speaker: 0, start: 0, end: 2), Turn(speaker: 1, start: 2, end: 3.5), Turn(speaker: 0, start: 3.5, end: 10)]
        #expect(SpeakerAttribution.speaker(start: 1, end: 4.5, in: split) == 0)
        #expect(SpeakerAttribution.speaker(start: 0.5, end: 1.5, in: turns) == 0)
    }

    @Test func noOverlapIsUnknown() {
        let turns = [Turn(speaker: 0, start: 0, end: 4), Turn(speaker: 1, start: 6, end: 9)]
        #expect(SpeakerAttribution.speaker(start: 4, end: 6, in: turns) == nil)
        #expect(SpeakerAttribution.speaker(start: 12, end: 14, in: turns) == nil)
        #expect(SpeakerAttribution.speaker(start: 1, end: 2, in: []) == nil)
    }

    @Test func overlappingSpeechTieGoesToWhoeverSpokeFirst() {
        let turns = [Turn(speaker: 1, start: 2, end: 6), Turn(speaker: 0, start: 4, end: 9)]
        #expect(SpeakerAttribution.speaker(start: 4, end: 6, in: turns) == 1)
        #expect(SpeakerAttribution.speaker(start: 4, end: 6, in: turns.reversed()) == 1)
    }

    @Test func numbersFollowFirstAppearance() {
        #expect(SpeakerAttribution.numbers(inOrderOfAppearance: ["them#3", "room#0", "them#3", "them#1"])
            == ["them#3": 1, "room#0": 2, "them#1": 3])
        #expect(SpeakerAttribution.numbers(inOrderOfAppearance: [Int]()).isEmpty)
        #expect(SpeakerAttribution.label(2) == "Speaker 2")
    }
}
