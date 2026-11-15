import XCTest
@testable import ZTronSearchEngineSemantic

final class UnigramTokenizerTests: XCTestCase {
    /// A hand-made SentencePiece vocabulary in the XLM-R layout; the id of a piece is its position.
    static let pieces: [(piece: String, score: Double)] = [
        ("<s>", 0), ("<pad>", 0), ("</s>", 0), ("<unk>", 0),                 // 0-3
        ("▁", -2.0), ("▁hello", -3.0), ("▁world", -3.5), ("▁he", -4.0),      // 4-7
        ("llo", -4.5), ("▁h", -6.0), ("e", -5.0), ("l", -5.0),               // 8-11
        ("o", -5.0), ("▁wor", -4.0), ("ld", -4.0), ("▁w", -6.0),             // 12-15
        ("or", -5.5), ("d", -5.0), ("▁new", -3.0), ("▁york", -3.2),          // 16-19
        ("▁newyork", -9.0), ("s", -4.0), ("▁cat", -3.0), ("▁ca", -5.0),      // 20-23
        ("t", -4.5), ("▁gatto", -4.0), ("▁città", -4.0), ("▁e", -5.5),       // 24-27
        ("york", -3.0),                                                      // 28
    ]

    private func tokenizer() throws -> UnigramTokenizer {
        try UnigramTokenizer(pieces: Self.pieces, unknownTokenID: 3, padTokenID: 1, template: .roberta(bos: 0, eos: 2))
    }

    func testWordsGetAMetaspaceAndTheBestScoringSegmentation() throws {
        let tokenizer = try tokenizer()
        // One piece beats any way of spelling the word out of smaller ones.
        XCTAssertEqual(tokenizer.tokenize("hello world"), [5, 6])
        XCTAssertEqual(tokenizer.tokenize("cat"), [22])
        // Viterbi, not greedy: "▁new" + "york" (-6.0) beats the single piece "▁newyork" (-9.0).
        XCTAssertEqual(tokenizer.tokenize("newyork"), [18, 28])
        // And where the only way is to spell it out, the best spelling wins:
        // "▁wor" + "d" (-9.0) against "▁w" + "or" + "d" (-16.5).
        XCTAssertEqual(tokenizer.tokenize("word"), [13, 17])
        XCTAssertEqual(tokenizer.tokenize("worlds"), [6, 21])
        // "▁he" + "llo" + "s" is not chosen when "▁hello" + "s" exists.
        XCTAssertEqual(tokenizer.tokenize("hellos"), [5, 21])
        XCTAssertEqual(tokenizer.tokenize("new york"), [18, 19])
    }

    func testCharactersWithoutAPieceBecomeOneUnknownPerRun() throws {
        let tokenizer = try tokenizer()
        // The marker is a piece of its own; the snowman is not.
        XCTAssertEqual(tokenizer.tokenize("hello ☃"), [5, 4, 3])
        XCTAssertEqual(tokenizer.tokenize("☃☃☃"), [4, 3], "a run of unknown characters is one unknown token")
        XCTAssertEqual(tokenizer.tokenize("☃ ☃"), [4, 3, 4, 3], "runs do not merge across words")
        // An unknown in the middle: "▁" + unknown "H" + "e" + "llo".
        XCTAssertEqual(tokenizer.tokenize("Hello"), [4, 3, 10, 8])
        // Known pieces on both sides of an unknown run.
        XCTAssertEqual(tokenizer.tokenize("cat☃☃s"), [22, 3, 21])
        XCTAssertEqual(tokenizer.unknownTokenID, 3)
    }

    func testTextIsNormalizedLikeSentencePiece() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.tokenize("  hello \t\n   world  "), [5, 6])
        // NFKC: full-width letters, and a combining accent composed into the piece's spelling.
        XCTAssertEqual(tokenizer.tokenize("ｈｅｌｌｏ"), [5])
        XCTAssertEqual(tokenizer.tokenize("citta\u{300}"), [26])
        XCTAssertEqual(tokenizer.tokenize("città"), [26])
        // No-break and zero-width spaces separate words; control characters vanish.
        XCTAssertEqual(tokenizer.tokenize("hello\u{00A0}world"), [5, 6])
        XCTAssertEqual(tokenizer.tokenize("hello\u{200B}world"), [5, 6])
        XCTAssertEqual(tokenizer.tokenize("hel\u{7}lo"), [5])
        // A marker typed by the user is a space, not a way to forge a word boundary piece.
        XCTAssertEqual(tokenizer.tokenize("hello▁world"), [5, 6])
        XCTAssertEqual(tokenizer.tokenize(""), [])
        XCTAssertEqual(tokenizer.tokenize(" \n "), [])
    }

    func testSpecialTokensSpelledInTheTextAreOrdinaryText() throws {
        let tokenizer = try tokenizer()
        // "</s>" and "<s>" are in the vocabulary with the best score there is; text must not
        // reach them. "▁" + unknown "</" + "s" + unknown ">", and likewise for "<s>".
        XCTAssertEqual(tokenizer.tokenize("hello </s> <s> world"), [5, 4, 3, 21, 3, 4, 3, 21, 3, 6])
        // "▁" + unknown "<pa" + "d" + unknown "><unk>".
        XCTAssertEqual(tokenizer.tokenize("<pad><unk>"), [4, 3, 17, 3])
    }

    func testSingleTextAndPairsFollowTheTemplate() throws {
        let tokenizer = try tokenizer()
        let single = tokenizer.encode("hello world", maxLength: 8)
        XCTAssertEqual(single.inputIDs, [0, 5, 6, 2, 1, 1, 1, 1])
        XCTAssertEqual(single.attentionMask, [1, 1, 1, 1, 0, 0, 0, 0])
        XCTAssertEqual(single.tokenTypeIDs, [Int32](repeating: 0, count: 8))
        XCTAssertEqual(single.tokenCount, 4)

        // <s> A </s></s> B </s>
        let pair = tokenizer.encode(pair: "hello", "world", maxLength: 8)
        XCTAssertEqual(pair.inputIDs, [0, 5, 2, 2, 6, 2, 1, 1])
        XCTAssertEqual(pair.attentionMask, [1, 1, 1, 1, 1, 1, 0, 0])
        XCTAssertEqual(pair.tokenTypeIDs, [Int32](repeating: 0, count: 8))

        // Four special tokens leave four of eight: the query keeps its one, the passage three.
        let cut = tokenizer.encode(pair: "hello", "world world world world world world", maxLength: 8)
        XCTAssertEqual(cut.inputIDs, [0, 5, 2, 2, 6, 6, 6, 2])
        XCTAssertEqual(cut.tokenCount, 8)

        let window = tokenizer.encode(pair: "hello", String(repeating: "world ", count: 400))
        XCTAssertEqual(window.inputIDs.count, 128)
        XCTAssertEqual(Array(window.inputIDs.prefix(5)), [0, 5, 2, 2, 6])
        XCTAssertEqual(window.inputIDs.last, 2)
    }

    func testALongWordIsSegmentedInLinearTime() throws {
        let tokenizer = try tokenizer()
        let word = String(repeating: "hello", count: 4_000)
        let start = monotonicSeconds()
        let ids = tokenizer.tokenize(word)
        XCTAssertLessThan(monotonicSeconds() - start, 2)
        // "▁hello" once, then "he" is not a piece: "e" + "llo" (-9.5) is the best spelling of each repeat.
        XCTAssertEqual(ids.count, 1 + 3_999 * 3)
        XCTAssertEqual(Array(ids.prefix(4)), [5, 3, 10, 8])
    }

    func testInvalidVocabulariesAreRefused() {
        XCTAssertThrowsError(try UnigramTokenizer(pieces: [], unknownTokenID: 0, padTokenID: 0, template: .roberta(bos: 0, eos: 0)))
        XCTAssertThrowsError(try UnigramTokenizer(pieces: Self.pieces, unknownTokenID: 99, padTokenID: 1, template: .roberta(bos: 0, eos: 2)))
        XCTAssertThrowsError(try UnigramTokenizer(pieces: Self.pieces, unknownTokenID: 3, padTokenID: 99, template: .roberta(bos: 0, eos: 2)))
        XCTAssertThrowsError(try UnigramTokenizer(pieces: [("a", .nan)], unknownTokenID: 0, padTokenID: 0, template: .roberta(bos: 0, eos: 0)))
    }
}
