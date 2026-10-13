import BarkCore
import Testing

struct TextCleanupTests {
    @Test func stripsFillersAndCapitalisesTheNewFirstWord() {
        #expect(TextCleanup.process(["um, testing this. uh it works"]) == "Testing this. It works")
    }

    @Test func collapsesWhitespaceAndSpaceBeforePunctuation() {
        #expect(TextCleanup.process(["hello   world ,  again ."]) == "Hello world, again.")
    }

    @Test func capitalisesSwedishLetters() {
        #expect(TextCleanup.process(["det är klart. återkom sen! öppna?"]) == "Det är klart. Återkom sen! Öppna?")
    }

    @Test(arguments: ["bl.a.", "t.ex.", "m.m.", "o.s.v.", "d.v.s.", "e.g.", "i.e.", "etc.", "vs.", "ca."])
    func noCapitalAfterAbbreviation(_ abbreviation: String) {
        #expect(TextCleanup.process(["vi har \(abbreviation) några saker kvar"]) == "Vi har \(abbreviation) några saker kvar")
    }

    @Test func abbreviationInParenthesesAndUpperCase() {
        #expect(TextCleanup.process(["frukt (t.ex. äpplen) och Bl.a. päron"]) == "Frukt (t.ex. äpplen) och Bl.a. päron")
    }

    @Test func stillCapitalisesAfterOrdinaryWords() {
        #expect(TextCleanup.process(["det tog ca. tio minuter. sedan gick vi"]) == "Det tog ca. tio minuter. Sedan gick vi")
    }

    @Test func stripsSpecialTokensAndStrayFragments() {
        #expect(TextCleanup.process(["<|sv|>hej <|nospeech|>där"]) == "Hej där")
        #expect(TextCleanup.process(["<|"]) == "")
        #expect(TextCleanup.process(["kongressen <| anslog"]) == "Kongressen anslog")
        #expect(TextCleanup.process(["<|0.00|>", "ja"], cleanup: false) == "ja")
    }

    @Test func joinsSegmentsWithSingleSpaces() {
        #expect(TextCleanup.process(["  första delen.", "", " andra delen ", "\n"]) == "Första delen. Andra delen")
        #expect(TextCleanup.process(["a", "b"], cleanup: false) == "a b")
        #expect(TextCleanup.process([]) == "")
    }

    @Test func vocabularyIsWholeWordCaseInsensitiveLongestFirst() {
        let vocabulary = ["lab": "LAB", "lab 37": "LAB37", "cost": "$5 \\o/"]
        #expect(TextCleanup.process(["lab 37 and the lab. labrador cost"], vocabulary: vocabulary)
            == "LAB37 and the LAB. Labrador $5 \\o/")
    }

    @Test func cleanupOffKeepsRawText() {
        #expect(TextCleanup.process(["um  hello. world"], cleanup: false) == "um  hello. world")
    }
}
