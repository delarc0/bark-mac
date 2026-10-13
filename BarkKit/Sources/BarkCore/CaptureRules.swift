/// Picks the one channel of a multichannel interface that carries the voice.
///
/// Summing every channel folds in loopback of system audio, ADAT and the noise floors of unused
/// inputs, so a video playing through the same interface lands in the transcript. Mic preamps
/// occupy the first inputs and loopback sits at the end, so the rule is the LOWEST channel whose
/// running peak reaches speech level, not the loudest. It is re-evaluated on every buffer and
/// only ever moves to a lower channel: a loopback channel that is loud before anyone speaks wins
/// for a moment, then loses to the voice and can never take over again. Until any channel
/// qualifies, the caller sums all of them so a quiet first word is not lost.
public struct ChannelSelector: Sendable {
    public static let latchLevel: Float = 0.02

    public private(set) var selected: Int?
    private var peaks: [Float]

    public init(channels: Int) {
        peaks = [Float](repeating: 0, count: channels)
        selected = channels == 1 ? 0 : nil
    }

    /// The channels whose peak still matters: everything below the current choice.
    public var candidates: Range<Int> { 0 ..< (selected ?? peaks.count) }

    /// `bufferPeaks[c]` is channel c's absolute peak in the latest buffer, for c in `candidates`
    /// (other entries are ignored). Returns the channel to use, nil to sum all.
    public mutating func update(_ bufferPeaks: [Float]) -> Int? {
        for c in candidates where c < bufferPeaks.count {
            peaks[c] = max(peaks[c], bufferPeaks[c])
            if peaks[c] >= Self.latchLevel {
                selected = c
                break
            }
        }
        return selected
    }
}

/// What a finished capture says about the input, judged before anything is transcribed.
public enum InputHealth: Sendable, Equatable {
    case ok
    /// The device never delivered a callback: Bluetooth still negotiating, the engine not up yet.
    /// Transient, worth another press, not a dead microphone.
    case noCallbacks
    /// Callbacks arrived but carried digital silence. Real microphones always pick up room noise,
    /// so this is a revoked microphone grant (macOS feeds zeros rather than failing), a muted or
    /// unplugged input, or the wrong device.
    case silent

    public static let silentPeak: Float = 0.0005

    public static func classify(frames: Int, peak: Float) -> InputHealth {
        if frames == 0 { return .noCallbacks }
        return peak < silentPeak ? .silent : .ok
    }
}

/// Settings written by Bark 0.2.x that Bark2 reads from the same UserDefaults domain.
public enum LegacySettings {
    /// The 0.2.x language value (nil = Auto). 0.2.x offered "nb" for Norwegian, which is not a
    /// Whisper language token; Whisper's is "no".
    public static func language(_ stored: String?) -> LanguageChoice {
        guard let stored, !stored.isEmpty else { return .auto }
        return .explicit(stored == "nb" ? "no" : stored)
    }
}
