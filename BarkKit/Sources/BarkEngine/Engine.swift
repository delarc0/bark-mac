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
        var result = decode(features, initial: initial, temperature: 0, allowNoSpeech: allowNoSpeech)
        for t in temperatures.dropFirst() {
            var needsFallback = result.compressionRatio > 2.4 || result.avgLogprob < -1.0
            if result.noSpeechProb > 0.6 { needsFallback = false }
            if !needsFallback { break }
            result = decode(features, initial: initial, temperature: t, allowNoSpeech: allowNoSpeech)
        }
        let silent = (result.noSpeechProb > 0.6 && !(result.avgLogprob > -1.0))
            || (allowNoSpeech && result.tokens.first == vocabulary.noSpeech)
        let text = silent ? "" : vocabulary.text(result.tokens.filter { $0 < vocabulary.eot }).trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcription(text: text, tokens: result.tokens.count, temperature: result.temperature)
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

/// zlib (level 6, like Python's zlib.compress) ratio of the UTF-8 bytes.
func compressionRatio(_ text: String) -> Double {
    let bytes = Array(text.utf8)
    var size = compressBound(uLong(bytes.count))
    var out = [UInt8](repeating: 0, count: Int(size))
    guard compress(&out, &size, bytes, uLong(bytes.count)) == Z_OK, size > 0 else { return 0 }
    return Double(bytes.count) / Double(size)
}
