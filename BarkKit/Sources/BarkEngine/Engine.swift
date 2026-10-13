import Foundation
import MLX
import zlib

public struct EngineError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

public struct Transcription: Sendable {
    public let text: String
    public let tokens: Int
    public let temperature: Float
}

/// mlx_whisper.transcribe with forced language, task transcribe, without_timestamps,
/// condition_on_previous_text=False and the default fallback ladder, plus Bark's no-speech policy.
/// Language detection is its own call on the general model, never part of a decode.
/// Not thread safe (MLXArray is not): use one engine from one thread at a time.
public final class Engine: @unchecked Sendable {
    let model: Whisper
    public let vocabulary: Vocabulary
    let temperatures: [Float] = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
    let sampleLength: Int
    let suppressBlank: MLXArray
    let suppress: MLXArray
    let suppressAllowingNoSpeech: MLXArray
    let languageMask: MLXArray
    /// -inf on every text token, 0 on the timestamps.
    let textMask: MLXArray

    /// A model folder: config.json, weights.safetensors (fp16 or quantized), tokenizer.json.
    public convenience init(folder: URL) throws {
        try self.init(model: Whisper.load(folder), vocabulary: Vocabulary(tokenizerJSON: folder.appending(path: "tokenizer.json")))
    }

    init(model: Whisper, vocabulary: Vocabulary) {
        self.model = model
        self.vocabulary = vocabulary
        sampleLength = model.dims.n_text_ctx / 2
        let vocab = model.dims.n_vocab
        func mask(_ ids: Set<Int>) -> MLXArray {
            MLXArray((0 ..< vocab).map { ids.contains($0) ? -Float.infinity : 0 })
        }
        let specials: Set<Int> = [vocabulary.transcribe, vocabulary.translate, vocabulary.sot, vocabulary.sotPrev, vocabulary.sotLm]
        suppressBlank = mask([vocabulary.vocabId(Array(" ".utf8))!, vocabulary.eot])
        suppressAllowingNoSpeech = mask(vocabulary.nonSpeech.union(specials))
        suppress = mask(vocabulary.nonSpeech.union(specials).union([vocabulary.noSpeech]))
        languageMask = mask(Set(0 ..< vocab).subtracting(vocabulary.languageTokens))
        textMask = mask(Set(0 ..< vocabulary.timestampBegin))
    }

    public func transcribe(_ samples: [Float], language: String) throws -> Transcription {
        let initial = [vocabulary.sot, try vocabulary.language(language), vocabulary.transcribe, vocabulary.noTimestamps]
        // One 30 s window and no seek loop: Bark2's segmenter cuts every segment under 30 s.
        guard samples.count <= nSamples else {
            throw EngineError(description: "audio is \(Double(samples.count) / Double(sampleRate)) s; the engine decodes one 30 s window")
        }
        let features = model.encoder(model.melSegment(samples))
        // Bark policy (S1b, S1e): KB says "silence" by sampling the no-speech token, so let it through
        // on audio of 1 s or more and treat a decode that opens with it as empty. Under 1 s KB also
        // says it on real short speech, so it stays suppressed there.
        let allowNoSpeech = Double(samples.count) / Double(sampleRate) >= 1.0
        let result = decodeWithFallback(features, initial: initial, allowNoSpeech: allowNoSpeech, timestamps: false)
        let text = isSilent(result, allowNoSpeech: allowNoSpeech)
            ? "" : vocabulary.text(result.tokens.filter { $0 < vocabulary.eot }).trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcription(text: text, tokens: result.tokens.count, temperature: result.temperature)
    }

    /// mlx_whisper.transcribe with timestamps: the same fallback ladder, no-speech policy and no
    /// conditioning on earlier text, plus its seek loop, so a window that ends before the audio
    /// does carries on from its last timestamp. The re-decode for a decode that stopped short.
    /// `tokens` counts every sampled token over all windows.
    public func transcribeTimestamped(_ samples: [Float], language: String) throws -> Transcription {
        let initial = [vocabulary.sot, try vocabulary.language(language), vocabulary.transcribe]
        let mel = model.logMel(samples)
        let content = mel.dim(0) - nFrames
        var seek = 0
        var kept: [Int] = []
        var sampled = 0
        var temperature: Float = 0
        while seek < content {
            let frames = min(nFrames, content - seek)
            let features = model.encoder(model.melWindow(mel, from: seek, frames: frames))
            let allowNoSpeech = Double(frames * hopLength) / Double(sampleRate) >= 1.0
            let result = decodeWithFallback(features, initial: initial, allowNoSpeech: allowNoSpeech, timestamps: true)
            sampled += result.tokens.count
            temperature = max(temperature, result.temperature)
            if isSilent(result, allowNoSpeech: allowNoSpeech) {
                seek += frames
                continue
            }
            let window = Self.timestampedWindow(result.tokens, timestampBegin: vocabulary.timestampBegin, frames: frames)
            kept += window.kept
            seek += window.advance
        }
        let text = vocabulary.text(kept.filter { $0 < vocabulary.eot }).trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcription(text: text, tokens: sampled, temperature: temperature)
    }

    private func decodeWithFallback(_ features: MLXArray, initial: [Int], allowNoSpeech: Bool, timestamps: Bool) -> Decoded {
        func run(_ t: Float) -> Decoded {
            timestamps
                ? decodeTimestamped(features, initial: initial, temperature: t, allowNoSpeech: allowNoSpeech)
                : decode(features, initial: initial, temperature: t, allowNoSpeech: allowNoSpeech)
        }
        var result = run(0)
        for t in temperatures.dropFirst() {
            var needsFallback = result.compressionRatio > 2.4 || result.avgLogprob < -1.0
            if result.noSpeechProb > 0.6 { needsFallback = false }
            if !needsFallback { break }
            result = run(t)
        }
        return result
    }

    private func isSilent(_ result: Decoded, allowNoSpeech: Bool) -> Bool {
        (result.noSpeechProb > 0.6 && !(result.avgLogprob > -1.0))
            || (allowNoSpeech && result.tokens.first == vocabulary.noSpeech)
    }

    /// transcribe()'s reading of one timestamped window of `frames` mel frames: the tokens it
    /// keeps, and how far to seek. Consecutive timestamps close segments; an unfinished last
    /// segment is dropped and the next window starts at its opening timestamp. A segment whose
    /// start and end timestamps are equal is cleared. The seek always moves forward.
    static func timestampedWindow(_ tokens: [Int], timestampBegin: Int, frames: Int) -> (kept: [Int], advance: Int) {
        let isTimestamp = tokens.map { $0 >= timestampBegin }
        let singleEnding = isTimestamp.count >= 2 && Array(isTimestamp.suffix(2)) == [false, true]
        var slices = isTimestamp.indices.dropLast().filter { isTimestamp[$0] && isTimestamp[$0 + 1] }.map { $0 + 1 }
        guard !slices.isEmpty else { return (tokens, frames) }
        if singleEnding { slices.append(tokens.count) }
        var kept: [Int] = []
        var last = 0
        for slice in slices {
            let segment = tokens[last ..< slice]
            if segment.first != segment.last { kept += segment }
            last = slice
        }
        // mel frames per timestamp step (0.02 s): N_FRAMES / n_audio_ctx.
        let advance = singleEnding ? frames : (tokens[last - 1] - timestampBegin) * 2
        return (kept, advance > 0 ? advance : frames)
    }

    /// OpenAI whisper's ApplyTimestampRules as an additive mask for the next token after `sampled`.
    /// mlx_whisper 0.4.3 collects positions instead of token values for the "timestamps never
    /// decrease" rule, which makes it a no-op; this is the intended rule.
    static func timestampMask(after sampled: [Int], timestampBegin: Int, eot: Int, noTimestamps: Int, vocab: Int,
                              maxInitialTimestamp: Int = 50) -> [Float] {
        var mask = [Float](repeating: 0, count: vocab)
        func block(_ range: Range<Int>) {
            for i in range.clamped(to: 0 ..< vocab) { mask[i] = -.infinity }
        }
        mask[noTimestamps] = -.infinity
        let lastWasTimestamp = (sampled.last ?? -1) >= timestampBegin
        let penultimateWasTimestamp = sampled.count < 2 || sampled[sampled.count - 2] >= timestampBegin
        if lastWasTimestamp {
            if penultimateWasTimestamp { block(timestampBegin ..< vocab) } else { block(0 ..< eot) }
        }
        if let lastTimestamp = sampled.last(where: { $0 >= timestampBegin }) {
            // Never decrease, and a segment that just opened must not close at the same time.
            block(timestampBegin ..< (lastWasTimestamp && !penultimateWasTimestamp ? lastTimestamp : lastTimestamp + 1))
        }
        if sampled.isEmpty {
            block(0 ..< timestampBegin)
            block((timestampBegin + maxInitialTimestamp + 1) ..< vocab)
        }
        return mask
    }

    /// mlx_whisper detect_language: one decoder step on [sot] after encoding, softmax over the
    /// language-token logits only. Ranked, most probable first. Uses the first 30 s.
    public func detectLanguage(_ samples: [Float]) -> [(language: String, probability: Double)] {
        let features = model.encoder(model.melSegment(samples))
        let (logits, _) = model.decoder(MLXArray([Int32(vocabulary.sot)]).expandedDimensions(axis: 0), xa: features, cache: nil)
        let probabilities = softmax(logits[0, 0].asType(.float32) + languageMask, axis: -1)
        let values = probabilities.asArray(Float.self)
        return vocabulary.languageTokens
            .compactMap { id in vocabulary.languageCode(id).map { ($0, Double(values[id])) } }
            .sorted { $0.1 > $1.1 }
    }

    struct Decoded {
        let tokens: [Int]
        let avgLogprob: Double
        let noSpeechProb: Float
        let compressionRatio: Double
        let temperature: Float
    }

    /// mlx_whisper DecodingTask.run, greedy (or sampled at t > 0), batch 1. Like the Python loop,
    /// the next step is queued before the current token is read back, so the GPU never idles.
    private func decode(_ features: MLXArray, initial: [Int], temperature: Float, allowNoSpeech: Bool) -> Decoded {
        let suppress = allowNoSpeech ? suppressAllowingNoSpeech : suppress
        func sample(_ logits: MLXArray, first: Bool) -> (MLXArray, MLXArray) {
            var logits = logits + suppress
            if first { logits = logits + suppressBlank }
            let next = temperature == 0 ? argMax(logits, axis: -1) : categorical(logits / temperature)
            let logprob = (logits - logSumExp(logits, axis: -1, keepDims: true))[next]
            return (next, logprob)
        }

        let (preLogits, firstCache) = model.decoder(MLXArray(initial.map(Int32.init)).expandedDimensions(axis: 0), xa: features, cache: nil)
        let logits = preLogits[0].asType(.float32)
        let noSpeechProb = softmax(logits[0], axis: -1)[vocabulary.noSpeech]
        var cache = firstCache
        var pending = sample(logits[initial.count - 1], first: true)
        asyncEval(pending.0, pending.1, noSpeechProb)

        var sampled: [Int] = []
        var sumLogprob: Float = 0
        for step in 0 ..< sampleLength {
            var upcoming: (MLXArray, MLXArray)?
            if step < sampleLength - 1 {
                let (stepLogits, nextCache) = model.decoder(pending.0.reshaped(1, 1), xa: features, cache: cache)
                cache = nextCache
                upcoming = sample(stepLogits[0, 0].asType(.float32), first: false)
                asyncEval(upcoming!.0, upcoming!.1)
            }
            let token = pending.0.item(Int.self)
            sumLogprob += pending.1.item(Float.self)
            if token == vocabulary.eot { break }
            sampled.append(token)
            guard let upcoming else { break }
            pending = upcoming
        }

        let text = vocabulary.text(sampled.filter { $0 < vocabulary.timestampBegin }).trimmingCharacters(in: .whitespacesAndNewlines)
        return Decoded(tokens: sampled,
                       avgLogprob: Double(sumLogprob) / Double(sampled.count + 1),
                       noSpeechProb: noSpeechProb.item(Float.self),
                       compressionRatio: compressionRatio(text),
                       temperature: temperature)
    }
}

extension Engine {
    /// The timestamped decode: one token per step, because the timestamp rules for the next token
    /// depend on the one just sampled (the plain decode overlaps the two).
    private func decodeTimestamped(_ features: MLXArray, initial: [Int], temperature: Float, allowNoSpeech: Bool) -> Decoded {
        let suppress = allowNoSpeech ? suppressAllowingNoSpeech : suppress
        let begin = vocabulary.timestampBegin
        let vocab = model.dims.n_vocab
        var sampled: [Int] = []
        var sumLogprob: Float = 0
        var noSpeechProb: Float = 0
        var cache: [BlockCache]?
        var input = initial
        for step in 0 ..< sampleLength {
            let (out, nextCache) = model.decoder(MLXArray(input.map(Int32.init)).expandedDimensions(axis: 0), xa: features, cache: cache)
            cache = nextCache
            let all = out[0].asType(.float32)
            if step == 0 { noSpeechProb = softmax(all[0], axis: -1)[vocabulary.noSpeech].item(Float.self) }
            var logits = all[all.dim(0) - 1] + suppress
            if step == 0 { logits = logits + suppressBlank }
            logits = logits + MLXArray(Self.timestampMask(after: sampled, timestampBegin: begin, eot: vocabulary.eot,
                                                          noTimestamps: vocabulary.noTimestamps, vocab: vocab))
            // If the timestamps together are likelier than any text token, sample a timestamp.
            let logprobs = logits - logSumExp(logits, axis: -1, keepDims: true)
            let timestampLikelier = logSumExp(logprobs[begin...], axis: -1) .> logprobs[..<begin].max()
            logits = which(timestampLikelier, logits + textMask, logits)
            let next = temperature == 0 ? argMax(logits, axis: -1) : categorical(logits / temperature)
            let token = next.item(Int.self)
            sumLogprob += (logits - logSumExp(logits, axis: -1, keepDims: true))[next].item(Float.self)
            if token == vocabulary.eot { break }
            sampled.append(token)
            input = [token]
        }
        let text = vocabulary.text(sampled.filter { $0 < begin }).trimmingCharacters(in: .whitespacesAndNewlines)
        return Decoded(tokens: sampled,
                       avgLogprob: Double(sumLogprob) / Double(sampled.count + 1),
                       noSpeechProb: noSpeechProb,
                       compressionRatio: compressionRatio(text),
                       temperature: temperature)
    }
}

/// zlib (level 6, like Python's zlib.compress) ratio of the UTF-8 bytes.
func compressionRatio(_ text: String) -> Double {
    let bytes = Array(text.utf8)
    var size = compressBound(uLong(bytes.count))
    var out = [UInt8](repeating: 0, count: Int(size))
    guard compress(&out, &size, bytes, uLong(bytes.count)) == Z_OK, size > 0 else { return 0 }
    return Double(bytes.count) / Double(size)
}
