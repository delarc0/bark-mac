import Foundation
import MLX
import WhisperKit
import zlib

struct EngineError: Error, CustomStringConvertible {
    let description: String
}

/// Whisper's special ids and text, read from a HF tokenizer.json folder.
struct WhisperTokens {
    let tokenizer: TokenizerWrapper
    let eot, sot, transcribe, translate, sotLm, sotPrev, noSpeech, noTimestamps, timestampBegin: Int

    init(_ tokenizer: TokenizerWrapper) throws {
        self.tokenizer = tokenizer
        func id(_ token: String) throws -> Int {
            // convertTokenToId answers unknown strings with the unk id, so check the round trip.
            guard let id = tokenizer.convertTokenToId(token), tokenizer.convertIdToToken(id) == token else {
                throw EngineError(description: "tokenizer has no \(token)")
            }
            return id
        }
        eot = try id("<|endoftext|>")
        sot = try id("<|startoftranscript|>")
        transcribe = try id("<|transcribe|>")
        translate = try id("<|translate|>")
        sotLm = try id("<|startoflm|>")
        sotPrev = try id("<|startofprev|>")
        noSpeech = try id("<|nospeech|>")
        noTimestamps = try id("<|notimestamps|>")
        timestampBegin = try id("<|0.00|>")
    }

    func language(_ code: String) throws -> Int {
        guard let id = tokenizer.convertTokenToId("<|\(code)|>"), tokenizer.convertIdToToken(id) == "<|\(code)|>" else {
            throw EngineError(description: "unknown language \(code)")
        }
        return id
    }

    /// Id of a byte string that is one vocab entry. A direct lookup, not encode(): the vendored
    /// ByteLevel pre-tokenizer prefixes a space to every piece when add_prefix_space is set, as
    /// KB's tokenizer.json does, so its encode() is not tiktoken's.
    func vocabId(_ bytes: some Collection<UInt8>) -> Int? {
        let token = String(String.UnicodeScalarView(bytes.map { Self.byteEncoder[Int($0)] }))
        guard let id = tokenizer.convertTokenToId(token), tokenizer.convertIdToToken(id) == token else { return nil }
        return id
    }

    /// mlx_whisper Tokenizer.non_speech_tokens. Every symbol here is one GPT-2 regex piece, and
    /// tiktoken emits a piece that is a vocab entry as one token.
    var nonSpeech: Set<Int> {
        let singles: [String] = "\"#()*+/:;<=>@[\\]^_`{|}~「」『』".map(String.init)
        let multis: [String] = "<< >> <<< >>> -- --- -( -[ (' (\" (( )) ((( ))) [[ ]] {{ }} ♪♪ ♪♪♪".split(separator: " ").map(String.init)
        let miscellaneous: [String] = "♩♪♫♬♭♮♯".map(String.init)
        var result: Set<Int> = [vocabId(Array(" -".utf8))!, vocabId(Array(" '".utf8))!]
        for symbol in singles + multis + miscellaneous {
            for piece in [symbol, " " + symbol].map({ Array($0.utf8) }) {
                if let id = vocabId(piece) {
                    result.insert(id)
                } else if miscellaneous.contains(symbol) {
                    // BPE's first token for these 3-byte symbols is their longest prefix in the vocab.
                    if let id = (1 ..< piece.count).reversed().lazy.compactMap({ vocabId(piece.prefix($0)) }).first {
                        result.insert(id)
                    }
                }
            }
        }
        return result
    }

    /// Byte-level BPE decode, same as tiktoken. Not tokenizer.decode: openai's tokenizer_config sets
    /// clean_up_tokenization_spaces, which rewrites " ." and " 's" and so differs from mlx_whisper.
    func text(_ ids: [Int]) -> String {
        let bytes = ids.compactMap(tokenizer.convertIdToToken).flatMap { $0.unicodeScalars.compactMap { Self.byteDecoder[$0] } }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// GPT-2's bytes_to_unicode, indexed by byte.
    static let byteEncoder: [Unicode.Scalar] = {
        let printable = Array(33 ... 126) + Array(161 ... 172) + Array(174 ... 255)
        var shifted = 256
        return (0 ..< 256).map { b in
            if printable.contains(b) { return Unicode.Scalar(UInt8(b)) }
            defer { shifted += 1 }
            return Unicode.Scalar(UInt32(shifted))!
        }
    }()
    static let byteDecoder: [Unicode.Scalar: UInt8] =
        Dictionary(uniqueKeysWithValues: byteEncoder.enumerated().map { ($1, UInt8($0)) })
}

struct Transcription {
    let text: String
    let tokens: Int
    let temperature: Float
}

/// mlx_whisper.transcribe with forced language, task transcribe, without_timestamps,
/// condition_on_previous_text=False and the default fallback ladder, plus Bark's no-speech policy.
final class Engine {
    let model: Whisper
    let tokens: WhisperTokens
    let initial: [Int]
    let temperatures: [Float] = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
    let sampleLength: Int
    let suppressBlank: MLXArray
    let suppress: MLXArray
    let suppressAllowingNoSpeech: MLXArray

    init(model: Whisper, tokens: WhisperTokens, language: String) throws {
        self.model = model
        self.tokens = tokens
        // Language is always given: Bark2 never runs detection here.
        initial = [tokens.sot, try tokens.language(language), tokens.transcribe, tokens.noTimestamps]
        sampleLength = model.dims.n_text_ctx / 2
        let vocab = model.dims.n_vocab
        func mask(_ ids: Set<Int>) -> MLXArray {
            MLXArray((0 ..< vocab).map { ids.contains($0) ? -Float.infinity : 0 })
        }
        let specials: Set<Int> = [tokens.transcribe, tokens.translate, tokens.sot, tokens.sotPrev, tokens.sotLm]
        suppressBlank = mask([tokens.vocabId(Array(" ".utf8))!, tokens.eot])
        suppressAllowingNoSpeech = mask(tokens.nonSpeech.union(specials))
        suppress = mask(tokens.nonSpeech.union(specials).union([tokens.noSpeech]))
    }

    func transcribe(_ samples: [Float]) throws -> Transcription {
        // shortcut: one 30 s window and no seek loop, upgrade when Bark2 sends segments longer than 30 s.
        guard samples.count <= nSamples else {
            throw EngineError(description: "audio is \(Double(samples.count) / Double(sampleRate)) s; mlx-eval decodes one 30 s window")
        }
        let features = model.encoder(model.melSegment(samples))
        // Bark policy (S1b, S1e): KB says "silence" by sampling the no-speech token, so let it through
        // on audio of 1 s or more and treat a decode that opens with it as empty. Under 1 s KB also
        // says it on real short speech, so it stays suppressed there.
        let allowNoSpeech = Double(samples.count) / Double(sampleRate) >= 1.0
        var result = decode(features, temperature: 0, allowNoSpeech: allowNoSpeech)
        for t in temperatures.dropFirst() {
            var needsFallback = result.compressionRatio > 2.4 || result.avgLogprob < -1.0
            if result.noSpeechProb > 0.6 { needsFallback = false }
            if !needsFallback { break }
            result = decode(features, temperature: t, allowNoSpeech: allowNoSpeech)
        }
        let silent = (result.noSpeechProb > 0.6 && !(result.avgLogprob > -1.0))
            || (allowNoSpeech && result.tokens.first == tokens.noSpeech)
        let text = silent ? "" : tokens.text(result.tokens.filter { $0 < tokens.eot }).trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcription(text: text, tokens: result.tokens.count, temperature: result.temperature)
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
    private func decode(_ features: MLXArray, temperature: Float, allowNoSpeech: Bool) -> Decoded {
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
        let noSpeechProb = softmax(logits[0], axis: -1)[tokens.noSpeech]
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
            if token == tokens.eot { break }
            sampled.append(token)
            guard let upcoming else { break }
            pending = upcoming
        }

        let text = tokens.text(sampled.filter { $0 < tokens.timestampBegin }).trimmingCharacters(in: .whitespacesAndNewlines)
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
