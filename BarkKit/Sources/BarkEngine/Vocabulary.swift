import Foundation

/// Whisper's token table and special ids, read from a Hugging Face tokenizer.json (model.vocab
/// plus added_tokens). Lookups and the byte-level decode only: nothing here encodes text, because
/// a BPE encode is what went wrong for KB in the vendored tokenizer (S8).
public struct Vocabulary: Sendable {
    let tokens: [String?]
    let ids: [String: Int]
    let eot, sot, transcribe, translate, sotLm, sotPrev, noSpeech, noTimestamps, timestampBegin: Int

    public init(tokenizerJSON url: URL) throws {
        struct File: Decodable {
            struct Model: Decodable { let vocab: [String: Int] }
            struct Added: Decodable { let id: Int; let content: String }
            let model: Model
            let added_tokens: [Added]
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        var ids = file.model.vocab
        for added in file.added_tokens { ids[added.content] = added.id }
        var tokens = [String?](repeating: nil, count: (ids.values.max() ?? -1) + 1)
        for (token, id) in ids { tokens[id] = token }
        try self.init(tokens: tokens, ids: ids)
    }

    init(tokens: [String?], ids: [String: Int]) throws {
        self.tokens = tokens
        self.ids = ids
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
