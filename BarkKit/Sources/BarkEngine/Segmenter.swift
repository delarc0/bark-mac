import BarkCore
import FluidAudio

/// Silero segmentation of one audio stream, shared by dictation and meetings. Segments close at
/// 0.5 s pauses and start 0.3 s before the chunk that crossed the threshold; an open segment that
/// reaches 28 s is cut, in a pause if it can be.
///
/// A segment under 1 s is never decoded alone when it has a neighbour: Silero passes breaths and
/// clicks that short, and Whisper turns them into "you" or "Thank you." (P1a). It joins the next
/// segment, or the previous one, which therefore waits until 1 s of speech follows it.
///
/// Indices count samples from the first one appended. Audio before the oldest segment still
/// needed is dropped, so a long meeting never accumulates in memory.
struct Segmenter {
    static let sampleRate = 16_000
    // A segment starts at the 256 ms chunk that crossed the threshold; FluidAudio's default 0.1 s of
    // padding cut word onsets off short clips (P1a: 0.3 s keeps them and lowers fleurs-en WER).
    // minSpeechDuration only satisfies FluidAudio's debug assert; the streaming path ignores it.
    static let config = VadSegmentationConfig(minSpeechDuration: 0.3, minSilenceDuration: 0.5, speechPadding: 0.3)
    static let chunkSize = VadManager.chunkSize
    static let padding = Int(config.speechPadding * Double(sampleRate))
    static let maxSegment = Int(SegmentCut.maxSeconds * Double(sampleRate))
    static let oneSecond = sampleRate

    /// Index of `samples[0]`.
    private var base = 0
    private var samples: [Float] = []
    private(set) var processed = 0
    private(set) var state = VadStreamState.initial()
    /// Per Silero chunk, whether it was speech.
    private var speechChunks: [Bool] = []
    private(set) var openStart: Int?
    /// Closed segments waiting to decode.
    private(set) var pending: [Range<Int>] = []

    /// Samples appended so far.
    var end: Int { base + samples.count }

    mutating func append(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
    }

    func audio(_ range: Range<Int>) -> [Float] {
        Array(samples[(range.lowerBound - base) ..< (range.upperBound - base)])
    }

    /// The next chunk for Silero, once a whole one is buffered.
    var nextChunk: [Float]? {
        end - processed >= Self.chunkSize ? audio(processed ..< processed + Self.chunkSize) : nil
    }

    /// What follows the last whole chunk: Silero's last input at the end of the audio.
    var remainder: [Float]? {
        processed < end ? audio(processed ..< end) : nil
    }

    var openAudio: [Float] {
        openStart.map { audio($0 ..< min(processed, end)) } ?? []
    }

    private var openLength: Int {
        openStart.map { min(processed, end) - $0 } ?? 0
    }

    /// The last closed segment waits while less than 1 s of speech follows it, and only while a
    /// short segment could still join it: in a meeting, silence after a turn can last minutes.
    var hasReady: Bool {
        guard let last = pending.last else { return false }
        let held = openLength < Self.oneSecond && processed - Self.padding - last.lowerBound <= Self.maxSegment
        return pending.count > (held ? 1 : 0)
    }

    /// Takes Silero's verdict on `nextChunk` (or `remainder`); nil when Silero failed.
    mutating func apply(_ result: VadStreamResult?) {
        defer { trim() }
        let chunkStart = processed
        let wasShort = openLength < Self.oneSecond
        processed += Self.chunkSize
        guard let result else {
            // Fail open: losing words is worse than decoding a chunk that holds none.
            if openStart == nil { openStart = chunkStart }
            speechChunks.append(true)
            return
        }
        state = result.state
        speechChunks.append(result.probability >= Transcriber.vadThreshold)
        if let event = result.event {
            if event.isStart {
                openStart = event.sampleIndex
            } else if let start = openStart {
                let end = max(start, min(event.sampleIndex, self.end))
                openStart = nil
                if end > start { close(start ..< end) }
            }
        }
        guard openStart != nil else { return }
        // The open segment just reached 1 s: a short segment before it joins it.
        if wasShort, openLength >= Self.oneSecond, let last = pending.last, last.count < Self.oneSecond,
           min(processed, end) - last.lowerBound <= Self.maxSegment {
            pending.removeLast()
            openStart = last.lowerBound
        }
        // Whisper sees one 30 s window: an open segment that reaches 28 s is cut, in a pause if it can be.
        if openLength >= Self.maxSegment, let start = openStart {
            let cut = start + SegmentCut.cutIndex(audio(start ..< min(processed, end)))
            pending.append(start ..< cut)
            openStart = cut
        }
    }

    /// At the end of the audio: the open segment closes where the audio ends.
    mutating func closeOpen() {
        if let start = openStart, start < end { close(start ..< end) }
        openStart = nil
    }

    /// The oldest closed segment and its audio.
    mutating func takeFirst() -> (range: Range<Int>, audio: [Float]) {
        let range = pending.removeFirst()
        let taken = (range, audio(range))
        trim()
        return taken
    }

    mutating func dropPending() {
        pending.removeAll()
    }

    /// Silero speech in the segment: its 256 ms chunks at or over the threshold.
    func speechSeconds(_ range: Range<Int>) -> Double {
        let chunk = Self.chunkSize
        let chunks = (range.lowerBound / chunk) ..< min(speechChunks.count, (range.upperBound + chunk - 1) / chunk)
        return Double(chunks.filter { speechChunks[$0] }.count * chunk) / Double(Self.sampleRate)
    }

    /// Queues a closed segment; under 1 s it joins the held segment before it.
    private mutating func close(_ range: Range<Int>) {
        if range.count < Self.oneSecond, let last = pending.last, range.upperBound - last.lowerBound <= Self.maxSegment {
            pending[pending.count - 1] = last.lowerBound ..< range.upperBound
        } else {
            pending.append(range)
        }
    }

    private mutating func trim() {
        // The next segment can start up to the speech padding before the next chunk.
        let keep = min(pending.first?.lowerBound ?? .max, openStart ?? .max, processed - Self.padding, end)
        if keep > base {
            samples.removeFirst(keep - base)
            base = keep
        }
    }
}

extension VadManager {
    /// One Silero step of a segmenter in `state`; nil when Silero failed.
    func step(_ chunk: [Float], _ state: VadStreamState) async -> VadStreamResult? {
        try? await processStreamingChunk(chunk, state: state, config: Segmenter.config)
    }
}
