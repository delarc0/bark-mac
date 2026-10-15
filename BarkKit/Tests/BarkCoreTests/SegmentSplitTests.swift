import BarkCore
import Testing

struct SegmentSplitTests {
    typealias Turn = SpeakerAttribution.Turn

    @Test func aChangeBetweenTwoLongStretchesIsCutAroundThePause() {
        let turns = [Turn(speaker: 0, start: 0, end: 4), Turn(speaker: 1, start: 4.6, end: 9)]
        #expect(SegmentSplit.cutWindows(start: 0, end: 9, turns: turns) == [3.75 ... 4.85])
        // Turns overlapping the change: the window straddles the overlap.
        let overlapping = [Turn(speaker: 0, start: 0, end: 4.2), Turn(speaker: 1, start: 4, end: 9)]
        #expect(SegmentSplit.cutWindows(start: 0, end: 9, turns: overlapping) == [3.75 ... 4.45])
    }

    @Test func shortInterjectionsAndOneSpeakerAreNotCut() {
        // A 0.6 s "yeah" from someone else stays with the speaker around it.
        let interjection = [Turn(speaker: 0, start: 0, end: 3), Turn(speaker: 1, start: 3.1, end: 3.7), Turn(speaker: 0, start: 3.8, end: 8)]
        #expect(SegmentSplit.cutWindows(start: 0, end: 8, turns: interjection).isEmpty)
        #expect(SegmentSplit.cutWindows(start: 0, end: 5, turns: [Turn(speaker: 2, start: 0, end: 5)]).isEmpty)
        #expect(SegmentSplit.cutWindows(start: 0, end: 5, turns: []).isEmpty)
        // Most of a long turn lies outside the segment: only the part inside counts.
        let edge = [Turn(speaker: 0, start: 0, end: 10.5), Turn(speaker: 1, start: 10.6, end: 20)]
        #expect(SegmentSplit.cutWindows(start: 10, end: 16, turns: edge).isEmpty)
        #expect(SegmentSplit.cutWindows(start: 10, end: 16, turns: edge, rule: .init(minTurn: 0.5)).count == 1)
    }

    @Test func threeSpeakersGiveTwoWindows() {
        let turns = [Turn(speaker: 0, start: 0, end: 3), Turn(speaker: 1, start: 3.5, end: 7), Turn(speaker: 0, start: 7, end: 7.5),
                     Turn(speaker: 2, start: 8, end: 12)]
        let windows = SegmentSplit.cutWindows(start: 0, end: 12, turns: turns)
        #expect(windows.count == 2)
        #expect(windows[0].contains(3.2) && windows[1].contains(7.6))
    }

    @Test func theCutGoesAtTheQuietestMoment() {
        // Loud, a dip at 4.3 s, loud again.
        let energy: [Float] = (0 ..< 900).map { $0 == 430 ? 0.001 : ($0 > 400 && $0 < 460 ? 0.01 : 0.5) }
        #expect(abs(SegmentSplit.quietest(in: 3.75 ... 4.85, energy: energy, origin: 0, hop: 0.01) - 4.3) < 1e-9)
        // All equal: the middle of the window.
        let flat = [Float](repeating: 0.2, count: 900)
        #expect(abs(SegmentSplit.quietest(in: 4 ... 5, energy: flat, origin: 0, hop: 0.01) - 4.5) < 1e-9)
        // A window past the audio falls back to its middle.
        #expect(SegmentSplit.quietest(in: 20 ... 21, energy: flat, origin: 0, hop: 0.01) == 20.5)
    }

    @Test func energyIsRMSPerHop() {
        let samples = [Float](repeating: 0, count: 1600) + [Float](repeating: 0.5, count: 1600)
        let energy = SegmentSplit.energy(samples, rate: 16_000)
        #expect(energy.count == 20)
        #expect(energy[2] == 0 && abs(energy[17] - 0.5) < 1e-6)
    }

    @Test func shortPiecesJoinTheirNeighbour() {
        #expect(SegmentSplit.pieces(start: 0, end: 9, cuts: [4.3]) == [0 ..< 4.3, 4.3 ..< 9])
        // 4.3 to 4.9 is too short: it joins the next piece.
        #expect(SegmentSplit.pieces(start: 0, end: 9, cuts: [4.3, 4.9]) == [0 ..< 4.3, 4.3 ..< 9])
        // A short last piece joins the one before it; a short first piece the one after.
        #expect(SegmentSplit.pieces(start: 0, end: 9, cuts: [8.5]) == [0 ..< 9])
        #expect(SegmentSplit.pieces(start: 0, end: 9, cuts: [0.4, 5]) == [0 ..< 5, 5 ..< 9])
        #expect(SegmentSplit.pieces(start: 0, end: 1.5, cuts: [0.7]) == [0 ..< 1.5])
        #expect(SegmentSplit.pieces(start: 2, end: 6, cuts: []) == [2 ..< 6])
    }

    @Test func piecesMustKeepTheText() {
        let whole = "so what do you think about the remote yeah I like it a lot"
        #expect(SegmentSplit.keepsText(whole: whole, pieces: ["So what do you think about the remote?", "Yeah, I like it a lot."]))
        // A piece with no words, or pieces that dropped more than a tenth of the words.
        #expect(!SegmentSplit.keepsText(whole: whole, pieces: ["So what do you think about the remote?", " "]))
        #expect(!SegmentSplit.keepsText(whole: whole, pieces: ["So what do you think?", "Yeah, I like it."]))
        #expect(SegmentSplit.keepsText(whole: whole, pieces: ["So what do you think about the remote?", "Yeah, I like it a"]))
        #expect(!SegmentSplit.keepsText(whole: whole, pieces: []))
    }
}
