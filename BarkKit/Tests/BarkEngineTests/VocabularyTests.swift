@testable import BarkEngine
import Foundation
import Testing

struct VocabularyTests {
    /// A toy table laid out like Whisper's: languages between <|startoftranscript|> and <|translate|>.
    static let toy = [
        "Ġhej", "Ã¥", "<|endoftext|>", "<|startoftranscript|>", "<|en|>", "<|sv|>", "<|translate|>", "<|transcribe|>",
        "<|startoflm|>", "<|startofprev|>", "<|nospeech|>", "<|notimestamps|>", "<|0.00|>",
    ]

    static func vocabulary(_ tokens: [String]) throws -> Vocabulary {
        try Vocabulary(tokens: tokens, ids: Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($1, $0) }))
    }

    @Test func byteLevelDecode() throws {
        #expect(try Self.vocabulary(Self.toy).text([0, 1]) == " hejå")
    }

    @Test func languages() throws {
        let vocabulary = try Self.vocabulary(Self.toy)
        #expect(try vocabulary.language("sv") == 5)
        #expect(vocabulary.languageCode(5) == "sv")
        #expect(vocabulary.languageTokens == 4 ..< 6)
        #expect(throws: EngineError.self) { try vocabulary.language("xx") }
        #expect(throws: EngineError.self) { try vocabulary.language("transcribe") }
    }

    @Test func missingSpecialTokenThrows() {
        #expect(throws: EngineError.self) { try Self.vocabulary(Self.toy.filter { $0 != "<|nospeech|>" }) }
    }

    @Test(.enabled(if: Fixtures.store.isInstalled(ModelID.general) && Fixtures.store.isInstalled(ModelID.swedish)),
          arguments: [ModelID.general, ModelID.swedish])
    func whisperTokenizer(_ id: String) throws {
        let vocabulary = try Vocabulary(tokenizerJSON: Fixtures.store.folder(id).appending(path: "tokenizer.json"))
        #expect(vocabulary.eot == 50257 && vocabulary.sot == 50258 && vocabulary.noSpeech == 50363)
        #expect(try vocabulary.language("en") == 50259 && vocabulary.language("sv") == 50273)
        #expect(vocabulary.languageTokens.count == 100)
        // mlx_whisper's non_speech_tokens has 82 entries on both tokenizers (S8).
        #expect(vocabulary.nonSpeech.count == 82)
        // Every byte-level token maps back to its own id.
        for id in 0 ..< vocabulary.eot {
            let bytes = vocabulary.token(id)!.unicodeScalars.map { Vocabulary.byteDecoder[$0]! }
            #expect(vocabulary.vocabId(bytes) == id)
        }
        #expect(vocabulary.text([vocabulary.vocabId(Array(" the".utf8))!]) == " the")
    }

    /// The committed fixture (eval/vocab_fixture.py): HF tokenizers ids for both tokenizers.
    /// Runs on whichever of fp16/8-bit is installed; both symlink the same tokenizer.json.
    @Test(.enabled(if: Fixtures.generalID != nil), arguments: ["swedish", "general"])
    func encodeParity(_ role: String) throws {
        let ids = ["swedish": [ModelID.swedish8, ModelID.swedish], "general": [Fixtures.generalID!]]
        guard let id = ids[role]!.first(where: Fixtures.store.isInstalled) else { return }
        struct Fixture: Decodable { let strings: [String]; let expected: [String: [[Int]]] }
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../eval/vocabulary-encode.json").standardizedFileURL
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let vocabulary = try Vocabulary(tokenizerJSON: Fixtures.store.folder(id).appending(path: "tokenizer.json"))
        for (string, expected) in zip(fixture.strings, fixture.expected[role]!) {
            #expect(vocabulary.encode(string) == expected, "\(string)")
            #expect(vocabulary.text(vocabulary.encode(string)) == string)
        }
        // Text never encodes to a special token, even one spelled out in the input.
        let specials = "<|endoftext|> och <|startofprev|>"
        #expect(vocabulary.encode(specials).allSatisfy { $0 < vocabulary.eot })
        #expect(vocabulary.text(vocabulary.encode(specials)) == specials)
    }
}
