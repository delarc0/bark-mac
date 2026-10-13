import BarkCore
import FluidAudio
import Foundation

public struct DictationResult: Sendable {
    public struct Segment: Sendable {
        public let audioSeconds: Double
        /// Silero speech in the segment: its 256 ms chunks at or over the threshold.
        public let speechSeconds: Double
        public let tokens: Int
        /// The plain decode stopped short (BarkCore Truncation) and this is the timestamped re-decode.
        public let redecoded: Bool
        public let decodeSeconds: Double
        public let text: String
        /// The decode timed out or threw; its text is lost and the session went on without it.
        public let failed: Bool
    }

    public let text: String
    /// From finish() being called to the final text.
    public let releaseToFinal: Double
    public let segments: [Segment]
    /// nil when no speech was found.
    public let model: ModelRole?
    public let language: String?
    /// The detection that routed this dictation (auto language only).
    public let detection: Detection?
}

/// One dictation, one key press. Feed 16 kHz mono samples while recording; Silero closes segments
/// at 0.5 s pauses and each closed segment is decoded as soon as it can be, serially and
/// unprompted. finish() decodes the open tail and returns the cleaned text. Audio and text stay
/// in memory.
///
/// A segment under 1 s is never decoded alone when it has a neighbour: Silero passes breaths and
/// clicks that short, and Whisper turns them into "you" or "Thank you." (P1a). It joins the next
/// segment, or the previous one, which therefore waits until 1 s of speech follows it.
public actor DictationSession {
    static let sampleRate = 16_000
    // A segment starts at the 256 ms chunk that crossed the threshold; FluidAudio's default 0.1 s of
    // padding cut word onsets off short clips (P1a: 0.3 s keeps them and lowers fleurs-en WER).
    // minSpeechDuration only satisfies FluidAudio's debug assert; the streaming path ignores it.
    static let segmentation = VadSegmentationConfig(minSpeechDuration: 0.3, minSilenceDuration: 0.5, speechPadding: 0.3)
    static let maxSegment = Int(SegmentCut.maxSeconds * Double(sampleRate))
    static let oneSecond = sampleRate

    private let transcriber: Transcriber
    private let vad: VadManager
    private let choice: LanguageChoice
    private let cleanup: Bool
    private let vocabulary: [String: String]
    private let wake: AsyncStream<Void>
    private let wakeUp: AsyncStream<Void>.Continuation

    private var samples: [Float] = []
    private var processed = 0
    private var vadState = VadStreamState.initial()
    /// Per Silero chunk, whether it was speech.
    private var speechChunks: [Bool] = []
    private var openStart: Int?
    /// Closed segments waiting to decode. Before the language is decided they all wait for it.
    private var pending: [Range<Int>] = []
    private var route: (model: ModelRole, language: String)?
    private var detection: Detection?
    private var segments: [DictationResult.Segment] = []
    private var released = false
    private var pump: Task<Void, Never>?

    init(transcriber: Transcriber, vad: VadManager, choice: LanguageChoice, cleanup: Bool, vocabulary: [String: String]) {
        self.transcriber = transcriber
        self.vad = vad
        self.choice = choice
        self.cleanup = cleanup
        self.vocabulary = vocabulary
        (wake, wakeUp) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func feed(_ chunk: [Float]) {
        guard !released else { return }
        samples.append(contentsOf: chunk)
        startPump()
        wakeUp.yield()
    }

    public func finish() async -> DictationResult {
        let clock = ContinuousClock()
        let release = clock.now
        released = true
        startPump()
        wakeUp.yield()
        await pump?.value
        let text = TextCleanup.process(segments.map(\.text), cleanup: cleanup, vocabulary: vocabulary)
        let decoded = segments.isEmpty ? nil : route
        return DictationResult(text: text, releaseToFinal: (clock.now - release).seconds, segments: segments,
                               model: decoded?.model, language: decoded?.language, detection: detection)
    }

    private func startPump() {
        if pump == nil { pump = Task { await run() } }
    }

    private func run() async {
        for await _ in wake {
            await drain()
            if released { break }
        }
        if processed < samples.count {
            await step(Array(samples[processed...]))
        }
        if let start = openStart, start < samples.count {
            close(start ..< samples.count)
        }
        openStart = nil
        if route == nil, !pending.isEmpty {
            await decide(on: pending.flatMap { samples[$0] })
        }
        while !pending.isEmpty {
            await decode(pending.removeFirst())
        }
    }

    /// Everything that can run now: Silero first, so segments close on time, then the language
    /// decision, then decodes.
    private func drain() async {
        while true {
            if samples.count - processed >= VadManager.chunkSize {
                await step(Array(samples[processed ..< processed + VadManager.chunkSize]))
            } else if route == nil, let evidence = languageEvidence() {
                await decide(on: evidence)
            } else if route != nil, pending.count > (lastIsHeld ? 1 : 0) {
                await decode(pending.removeFirst())
            } else {
                return
            }
        }
    }

    private var openLength: Int {
        openStart.map { min(processed, samples.count) - $0 } ?? 0
    }

    /// The last closed segment waits while less than 1 s of speech follows it.
    private var lastIsHeld: Bool { openLength < Self.oneSecond }

    private func step(_ chunk: [Float]) async {
        let chunkStart = processed
        let wasShort = openLength < Self.oneSecond
        processed += VadManager.chunkSize
        guard let result = try? await vad.processStreamingChunk(chunk, state: vadState, config: Self.segmentation) else {
            // Fail open: losing dictated words is worse than decoding a chunk that holds none.
            if openStart == nil { openStart = chunkStart }
            speechChunks.append(true)
            return
        }
        vadState = result.state
        speechChunks.append(result.probability >= Transcriber.vadThreshold)
        if let event = result.event {
            if event.isStart {
                openStart = event.sampleIndex
            } else if let start = openStart {
                let end = max(start, min(event.sampleIndex, samples.count))
                openStart = nil
                if end > start { close(start ..< end) }
            }
        }
        guard openStart != nil else { return }
        // The open segment just reached 1 s: a short segment before it joins it.
        if wasShort, openLength >= Self.oneSecond, let last = pending.last, last.count < Self.oneSecond,
           min(processed, samples.count) - last.lowerBound <= Self.maxSegment {
            pending.removeLast()
            openStart = last.lowerBound
        }
        // Whisper sees one 30 s window: an open segment that reaches 28 s is cut, in a pause if it can be.
        if openLength >= Self.maxSegment, let start = openStart {
            let cut = start + SegmentCut.cutIndex(Array(samples[start ..< min(processed, samples.count)]))
            pending.append(start ..< cut)
            openStart = cut
        }
    }

    /// Queues a closed segment; under 1 s it joins the held segment before it.
    private func close(_ range: Range<Int>) {
        if range.count < Self.oneSecond, let last = pending.last, range.upperBound - last.lowerBound <= Self.maxSegment {
            pending[pending.count - 1] = last.lowerBound ..< range.upperBound
        } else {
            pending.append(range)
        }
    }

    /// The speech so far once it reaches 1 s (auto language), nil while there is less. An explicit
    /// language needs no evidence.
    private func languageEvidence() -> [Float]? {
        if case .explicit = choice { return [] }
        let open = openStart.map { samples[$0 ..< min(processed, samples.count)] } ?? []
        guard pending.reduce(open.count, { $0 + $1.count }) >= Self.oneSecond else { return nil }
        return pending.flatMap { samples[$0] } + open
    }

    /// Decides model and language once and pins them for this dictation.
    private func decide(on speech: [Float]) async {
        if case .auto = choice, let top = try? await transcriber.detectLanguage(speech).first {
            detection = Detection(language: top.language, probability: top.probability,
                                  audioSeconds: Double(speech.count) / Double(Self.sampleRate))
        }
        let decision = Routing.route(choice, detection: detection, remembered: await transcriber.remembered)
        await transcriber.remember(decision.remembered)
        // No detection and nothing remembered: prefill English, as WhisperKit did.
        route = (await transcriber.available(decision.model), decision.language ?? "en")
    }

    private func decode(_ range: Range<Int>) async {
        guard let route else { return }
        let clock = ContinuousClock()
        let start = clock.now
        let audio = Array(samples[range])
        let speech = speechSeconds(range)
        var result = try? await transcriber.transcribe(audio, on: route.model, language: route.language)
        var redecoded = false
        if let plain = result, Truncation.isTruncated(speechSeconds: speech, tokens: plain.tokens, language: route.language),
           let full = try? await transcriber.transcribeTimestamped(audio, on: route.model, language: route.language) {
            result = full
            redecoded = true
        }
        segments.append(DictationResult.Segment(audioSeconds: Double(range.count) / Double(Self.sampleRate),
                                                speechSeconds: speech,
                                                tokens: result?.tokens ?? 0,
                                                redecoded: redecoded,
                                                decodeSeconds: (clock.now - start).seconds,
                                                text: result?.text ?? "", failed: result == nil))
    }

    private func speechSeconds(_ range: Range<Int>) -> Double {
        let chunk = VadManager.chunkSize
        let chunks = (range.lowerBound / chunk) ..< min(speechChunks.count, (range.upperBound + chunk - 1) / chunk)
        return Double(chunks.filter { speechChunks[$0] }.count * chunk) / Double(Self.sampleRate)
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
