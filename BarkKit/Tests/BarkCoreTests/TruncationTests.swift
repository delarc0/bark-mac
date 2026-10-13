import BarkCore
import Testing

/// Speech seconds and token counts measured on P1a segments.
struct TruncationTests {
    @Test(arguments: [(24.6, 21), (18.7, 21), (7.9, 13)])
    func cutShortLongEnglishDecodesAreCaught(_ speech: Double, _ tokens: Int) {
        #expect(Truncation.isTruncated(speechSeconds: speech, tokens: tokens, language: "en"))
    }

    @Test(arguments: [(18.4, 36, "en"), (16.4, 33, "en"), (25.6, 55, "en"), (9.7, 27, "sv"), (10.0, 27, "sv"), (25.6, 89, "sv")])
    func slowestCompleteDecodesAreNot(_ speech: Double, _ tokens: Int, _ language: String) {
        #expect(!Truncation.isTruncated(speechSeconds: speech, tokens: tokens, language: language))
    }

    @Test func shortSpeechNeverCounts() {
        #expect(!Truncation.isTruncated(speechSeconds: 4.9, tokens: 1, language: "en"))
        #expect(Truncation.isTruncated(speechSeconds: 5.0, tokens: 1, language: "en"))
    }

    @Test func swedishHasItsOwnFloorAndOtherLanguagesTheLowest() {
        #expect(Truncation.isTruncated(speechSeconds: 10, tokens: 22, language: "sv"))
        #expect(!Truncation.isTruncated(speechSeconds: 10, tokens: 22, language: "en"))
        #expect(!Truncation.isTruncated(speechSeconds: 10, tokens: 18, language: "de"))
        #expect(Truncation.isTruncated(speechSeconds: 10, tokens: 17, language: "de"))
    }
}
