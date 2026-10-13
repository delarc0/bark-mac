/// A decode that stopped before its audio did. Whisper without timestamps can end a long segment
/// early and drop the rest (P1a.1: long-en, where a much quieter recording follows a loud one), so
/// a segment with a lot of speech and few decoded tokens is re-decoded with timestamps.
public enum Truncation {
    public static let minimumSpeechSeconds = 5.0
    /// Fewest decoded tokens per second of Silero speech for a complete decode. Calibrated on every
    /// P1a 8-bit set: en 1.8 sits between the cut-short long-en decodes (0.85 to 1.64) and the
    /// slowest complete one (1.95); sv saw no cut-short decode and takes half its median (4.66),
    /// under the slowest complete one (2.72).
    static let tokensPerSecond: [String: Double] = ["sv": 2.3, "en": 1.8]
    /// Languages without a calibration use the lowest floor, so they re-decode least.
    static var defaultTokensPerSecond: Double { tokensPerSecond.values.min()! }

    public static func isTruncated(speechSeconds: Double, tokens: Int, language: String) -> Bool {
        speechSeconds >= minimumSpeechSeconds
            && Double(tokens) / speechSeconds < tokensPerSecond[language, default: defaultTokensPerSecond]
    }
}
