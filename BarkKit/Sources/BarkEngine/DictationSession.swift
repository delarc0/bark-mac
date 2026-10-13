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
/// (Segmenter) and each closed segment is decoded as soon as it can be, serially and unprompted.
/// finish() decodes the open tail and returns the cleaned text. Audio and text stay in memory.
public actor DictationSession {
    static let sampleRate = Segmenter.sampleRate

    private let transcriber: Transcriber
    private let vad: VadManager
    private let choice: LanguageChoice
    private let cleanup: Bool
    private let vocabulary: [String: String]
    private let wake: AsyncStream<Void>
    private let wakeUp: AsyncStream<Void>.Continuation

    /// Its closed segments wait for the language decision before any decodes.
    private var segmenter = Segmenter()
    private var route: (model: ModelRole, language: String)?
    private var detection: Detection?
    private var segments: [DictationResult.Segment] = []
    private var released = false
    private var cancelled = false
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
        segmenter.append(chunk)
        startPump()
        wakeUp.yield()
    }

    /// Abandons the dictation: no more audio is taken, queued segments are dropped, a decode in
    /// flight is left to end on its own and its text discarded. finish() then returns empty text
    /// at once. Safe to call more than once.
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        released = true
        segmenter.dropPending()
        // Lets a decode in flight skip its re-decode.
        pump?.cancel()
        wakeUp.yield()
    }

    public func finish() async -> DictationResult {
        if cancelled {
            return DictationResult(text: "", releaseToFinal: 0, segments: [], model: nil, language: nil, detection: nil)
        }
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
        guard !cancelled else { return }
        if let remainder = segmenter.remainder {
            await step(remainder)
        }
        segmenter.closeOpen()
        if route == nil, !segmenter.pending.isEmpty {
            await decide(on: segmenter.pending.flatMap(segmenter.audio))
        }
        while !segmenter.pending.isEmpty, !cancelled {
            await decode()
        }
    }

    /// Everything that can run now: Silero first, so segments close on time, then the language
    /// decision, then decodes.
    private func drain() async {
        while !cancelled {
            if let chunk = segmenter.nextChunk {
                await step(chunk)
            } else if route == nil, let evidence = languageEvidence() {
                await decide(on: evidence)
            } else if route != nil, !segmenter.ready.isEmpty {
                await decode()
            } else {
                return
            }
        }
    }

    private func step(_ chunk: [Float]) async {
        segmenter.apply(await vad.step(chunk, segmenter.state))
    }

    /// The speech so far once it reaches 1 s (auto language), nil while there is less. An explicit
    /// language needs no evidence.
    private func languageEvidence() -> [Float]? {
        if case .explicit = choice { return [] }
        let open = segmenter.openAudio
        guard segmenter.pending.reduce(open.count, { $0 + $1.count }) >= Segmenter.oneSecond else { return nil }
        return segmenter.pending.flatMap(segmenter.audio) + open
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

    private func decode() async {
        guard let route else { return }
        let clock = ContinuousClock()
        let start = clock.now
        let (range, audio) = segmenter.takeFirst()
        let speech = segmenter.speechSeconds(range)
        let (result, redecoded) = await transcriber.decodeSegment(audio, speechSeconds: speech, on: route.model, language: route.language)
        guard !cancelled else { return }
        segments.append(DictationResult.Segment(audioSeconds: Double(range.count) / Double(Self.sampleRate),
                                                speechSeconds: speech,
                                                tokens: result?.tokens ?? 0,
                                                redecoded: redecoded,
                                                decodeSeconds: (clock.now - start).seconds,
                                                text: result?.text ?? "", failed: result == nil))
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
