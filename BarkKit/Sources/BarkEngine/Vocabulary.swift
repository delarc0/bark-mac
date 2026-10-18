import Foundation

/// Whisper's token table and special ids, read from a Hugging Face tokenizer.json (model.vocab
/// plus added_tokens). Lookups and the byte-level decode, plus a byte-level BPE encode for
/// prompting; the vendored tokenizer's encode is unusable for KB (S8), so the BPE lives here.
public struct Vocabulary: Sendable {
    let tokens: [String?]
    let ids: [String: Int]
    /// model.vocab only: encode never produces special tokens from text.
    let bpeIds: [String: Int]
    /// Merge pair to rank from model.merges, the pair joined with U+0000 (no token contains it).
    let mergeRanks: [String: Int]
    let eot, sot, transcribe, translate, sotLm, sotPrev, noSpeech, noTimestamps, timestampBegin: Int

    public init(tokenizerJSON url: URL) throws {
        struct File: Decodable {
            struct Model: Decodable {
                struct Merge: Decodable {
                    let first, second: String
                    init(from decoder: any Decoder) throws {
                        let container = try decoder.singleValueContainer()
                        if let pair = try? container.decode([String].self) {
                            guard pair.count == 2 else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "merge is not a pair") }
                            (first, second) = (pair[0], pair[1])
                        } else {
                            let joined = try container.decode(String.self).split(separator: " ")
                            guard joined.count == 2 else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "merge is not a pair") }
                            (first, second) = (String(joined[0]), String(joined[1]))
                        }
                    }
                }
                let vocab: [String: Int]
                let merges: [Merge]
            }
            struct Added: Decodable { let id: Int; let content: String }
            let model: Model
            let added_tokens: [Added]
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        var ids = file.model.vocab
        for added in file.added_tokens { ids[added.content] = added.id }
        var tokens = [String?](repeating: nil, count: (ids.values.max() ?? -1) + 1)
        for (token, id) in ids { tokens[id] = token }
        var mergeRanks: [String: Int] = [:]
        for (rank, merge) in file.model.merges.enumerated() where file.model.vocab[merge.first + merge.second] != nil {
            mergeRanks[merge.first + "\0" + merge.second] = rank
        }
        try self.init(tokens: tokens, ids: ids, bpeIds: file.model.vocab, mergeRanks: mergeRanks)
    }

    init(tokens: [String?], ids: [String: Int], bpeIds: [String: Int]? = nil, mergeRanks: [String: Int] = [:]) throws {
        self.tokens = tokens
        self.ids = ids
        self.bpeIds = bpeIds ?? ids
        self.mergeRanks = mergeRanks
        func id(_ token: String) throws -> Int {
            guard let id = Self.roundTrip(token, tokens, ids) else { throw EngineError(description: "tokenizer has no \(token)") }
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

    private static func roundTrip(_ token: String, _ tokens: [String?], _ ids: [String: Int]) -> Int? {
        guard let id = ids[token], tokens.indices.contains(id), tokens[id] == token else { return nil }
        return id
    }

    public func id(_ token: String) -> Int? { Self.roundTrip(token, tokens, ids) }

    public func token(_ id: Int) -> String? { tokens.indices.contains(id) ? tokens[id] : nil }

    public func language(_ code: String) throws -> Int {
        guard let id = id("<|\(code)|>"), languageTokens.contains(id) else {
            throw EngineError(description: "unknown language \(code)")
        }
        return id
    }

    /// Whisper's language tokens sit between <|startoftranscript|> and <|translate|>.
    var languageTokens: Range<Int> { (sot + 1) ..< translate }

    /// "sv" for the id of <|sv|>.
    func languageCode(_ id: Int) -> String? {
        token(id).map { String($0.dropFirst(2).dropLast(2)) }
    }

    /// Id of a byte string that is one vocab entry: a direct lookup, which is what tiktoken does
    /// for a regex piece that is in the vocab.
    func vocabId(_ bytes: some Collection<UInt8>) -> Int? {
        id(String(String.UnicodeScalarView(bytes.map { Self.byteEncoder[Int($0)] })))
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

    /// Byte-level BPE decode, same as tiktoken. Not a tokenizer.decode with openai's
    /// clean_up_tokenization_spaces, which rewrites " ." and " 's" and so differs from mlx_whisper.
    public func text(_ ids: [Int]) -> String {
        let bytes = ids.compactMap(token).flatMap { $0.unicodeScalars.compactMap { Self.byteDecoder[$0] } }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Byte-level BPE encode, the same ids tiktoken gives mlx_whisper for an initial prompt:
    /// Whisper's regex splits the text into pieces, each piece's bytes map through the GPT-2
    /// byte-to-unicode table and merge by rank. Plain text only, never a special token, and no
    /// added prefix space (the caller adds " " itself, like mlx_whisper).
    public func encode(_ text: String) -> [Int] {
        var out: [Int] = []
        for match in Self.pieceRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            var word = text[Range(match.range, in: text)!].utf8.map { String(Self.byteEncoder[Int($0)]) }
            while word.count > 1 {
                var best = -1
                var bestRank = Int.max
                for i in 0 ..< word.count - 1 {
                    if let rank = mergeRanks[word[i] + "\0" + word[i + 1]], rank < bestRank {
                        (best, bestRank) = (i, rank)
                    }
                }
                if best < 0 { break }
                let left = word[best], right = word[best + 1]
                var next: [String] = []
                var i = 0
                while i < word.count {
                    if i < word.count - 1, word[i] == left, word[i + 1] == right {
                        next.append(left + right)
                        i += 2
                    } else {
                        next.append(word[i])
                        i += 1
                    }
                }
                word = next
            }
            out += word.map { bpeIds[$0]! }
        }
        return out
    }

    /// Whisper's pre-tokenizer split regex (the GPT-2 pattern tiktoken uses, lowercase
    /// contractions included), the same splits HF tokenizers' ByteLevel makes.
    static let pieceRegex = try! NSRegularExpression(pattern: #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#)

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
