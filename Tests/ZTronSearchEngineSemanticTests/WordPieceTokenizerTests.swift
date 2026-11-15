import XCTest
@testable import ZTronSearchEngineSemantic

final class WordPieceTokenizerTests: XCTestCase {
    /// A hand-made vocabulary; the id of a piece is its position.
    static let vocabulary = [
        "[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]",          // 0-4
        "the", "cat", "sat", "on", "mat",                      // 5-9
        "##s", "play", "##ing", "##ed", "un",                  // 10-14
        "##believ", "##able", ",", ".", "!",                   // 15-19
        "hello", "world", "cafe", "resume", "中",               // 20-24
        "国", "##a", "map", "##2", "a",                         // 25-29
        "##b", "##c", "naive", "é", "caf",                     // 30-34
        "##é", "Hello", "ab", "##bc",                          // 35-38
    ]

    private func tokenizer(_ options: WordPieceTokenizer.Options = .init()) throws -> WordPieceTokenizer {
        try WordPieceTokenizer(vocabulary: Self.vocabulary, options: options)
    }

    func testWordsSplitIntoTheLongestPieces() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.tokenize("The cats sat on the mat."), [5, 6, 10, 7, 8, 5, 9, 18])
        XCTAssertEqual(tokenizer.tokenize("playing played"), [11, 12, 11, 13])
        XCTAssertEqual(tokenizer.tokenize("unbelievable"), [14, 15, 16])
        // Greedy longest match: "ab" + "##c", never "a" + "##bc".
        XCTAssertEqual(tokenizer.tokenize("abc"), [37, 31])
        XCTAssertEqual(tokenizer.tokenize("map2"), [27, 28])
    }

    func testAWordThatCannotBeSpelledIsUnknownAsAWhole() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.tokenize("xyz"), [1])
        // "cat" matches, the rest does not: the whole word is unknown, not "cat" + unknown.
        XCTAssertEqual(tokenizer.tokenize("catx the"), [1, 5])
        // A continuation piece never starts a word.
        XCTAssertEqual(tokenizer.tokenize("ing"), [1])
        XCTAssertEqual(tokenizer.unknownTokenID, 1)
    }

    func testPunctuationAndIdeographsStandAlone() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.tokenize("hello, world!"), [20, 17, 21, 19])
        XCTAssertEqual(tokenizer.tokenize("hello,world.the"), [20, 17, 21, 18, 5])
        XCTAssertEqual(tokenizer.tokenize("中国"), [24, 25])
        XCTAssertEqual(tokenizer.tokenize("map中the"), [27, 24, 5])
    }

    func testLowercasingAndAccentStrippingFollowTheOptions() throws {
        let uncased = try tokenizer()
        XCTAssertEqual(uncased.tokenize("Café RÉSUMÉ Naïve"), [22, 23, 32])
        XCTAssertEqual(uncased.tokenize("HELLO"), [20])

        // A cased model keeps case and accents.
        let cased = try tokenizer(.init(lowercase: false))
        XCTAssertEqual(cased.tokenize("Hello hello"), [36, 20])
        XCTAssertEqual(cased.tokenize("café"), [34, 35])
        XCTAssertEqual(cased.tokenize("THE"), [1])

        // Lowercase but keep accents.
        let accented = try tokenizer(.init(lowercase: true, stripAccents: false))
        XCTAssertEqual(accented.tokenize("CAFÉ"), [34, 35])
        // Keep case but strip accents.
        let stripped = try tokenizer(.init(lowercase: false, stripAccents: true))
        XCTAssertEqual(stripped.tokenize("café Hello"), [22, 36])
    }

    func testControlCharactersAndWhitespaceAreCleaned() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.tokenize("the\tcat\u{0}\nsat\u{00A0}on \u{200B}the\r\nmat"), [5, 6, 7, 8, 5, 9])
        XCTAssertEqual(tokenizer.tokenize(""), [])
        XCTAssertEqual(tokenizer.tokenize("  \n\t "), [])
    }

    func testAnOverlongWordIsUnknown() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.tokenize(String(repeating: "a", count: 101)), [1])
        let short = try self.tokenizer(.init(maxCharactersPerWord: 3))
        XCTAssertEqual(short.tokenize("cat cats"), [6, 1])
    }

    func testSpecialTokensSpelledInTheTextAreOrdinaryText() throws {
        let tokenizer = try tokenizer()
        let ids = tokenizer.tokenize("the [SEP] cat [CLS] [PAD]")
        XCTAssertFalse(ids.contains(3))
        XCTAssertFalse(ids.contains(2))
        XCTAssertFalse(ids.contains(0))
        XCTAssertEqual(ids.filter { $0 == 5 || $0 == 6 }, [5, 6])
    }

    func testSingleTextIsWrappedTruncatedAndPadded() throws {
        let tokenizer = try tokenizer()
        let short = tokenizer.encode("the cat", maxLength: 8)
        XCTAssertEqual(short.inputIDs, [2, 5, 6, 3, 0, 0, 0, 0])
        XCTAssertEqual(short.attentionMask, [1, 1, 1, 1, 0, 0, 0, 0])
        XCTAssertEqual(short.tokenTypeIDs, [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(short.tokenCount, 4)

        // Truncation keeps the head of the text and both special tokens.
        let long = tokenizer.encode("the cat sat on the mat", maxLength: 5)
        XCTAssertEqual(long.inputIDs, [2, 5, 6, 7, 3])
        XCTAssertEqual(long.attentionMask, [1, 1, 1, 1, 1])
        XCTAssertEqual(long.tokenCount, 5)

        // The default window is the 128 tokens of the specification.
        let window = tokenizer.encode(String(repeating: "the cat ", count: 200))
        XCTAssertEqual(window.inputIDs.count, 128)
        XCTAssertEqual(window.tokenCount, 128)
        XCTAssertEqual(window.inputIDs.first, 2)
        XCTAssertEqual(window.inputIDs.last, 3)
        let empty = tokenizer.encode("")
        XCTAssertEqual(empty.tokenCount, 2)
        XCTAssertEqual(empty.inputIDs.count, 128)
        XCTAssertEqual(Array(empty.inputIDs.prefix(3)), [2, 3, 0])
    }

    func testAPairIsWrappedWithSegmentsAndTruncatedLongestFirst() throws {
        let tokenizer = try tokenizer()
        let pair = tokenizer.encode(pair: "the cat", "sat on the mat", maxLength: 12)
        XCTAssertEqual(pair.inputIDs, [2, 5, 6, 3, 7, 8, 5, 9, 3, 0, 0, 0])
        XCTAssertEqual(pair.tokenTypeIDs, [0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0])
        XCTAssertEqual(pair.attentionMask, [1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0])
        XCTAssertEqual(pair.tokenCount, 9)

        // Five tokens of budget for a pair of two and four: the passage gives way.
        let cut = tokenizer.encode(pair: "the cat", "sat on the mat", maxLength: 8)
        XCTAssertEqual(cut.inputIDs, [2, 5, 6, 3, 7, 8, 5, 3])
        XCTAssertEqual(cut.tokenTypeIDs, [0, 0, 0, 0, 1, 1, 1, 1])
        XCTAssertEqual(cut.tokenCount, 8)

        let window = tokenizer.encode(pair: "the cat", String(repeating: "mat ", count: 500))
        XCTAssertEqual(window.inputIDs.count, 128)
        XCTAssertEqual(Array(window.inputIDs.prefix(5)), [2, 5, 6, 3, 9])
        XCTAssertEqual(window.inputIDs.last, 3)
        XCTAssertEqual(window.tokenCount, 128)
    }

    func testAVocabularyWithoutItsSpecialTokensIsRefused() {
        XCTAssertThrowsError(try WordPieceTokenizer(vocabulary: ["the", "cat"])) { error in
            guard case SemanticError.tokenizerUnavailable = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertThrowsError(try WordPieceTokenizer(vocabulary: ["[UNK]", "[PAD]", "[CLS]", "the"])) { error in
            guard case SemanticError.tokenizerUnavailable = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertNoThrow(try WordPieceTokenizer(
            vocabulary: ["<unk>", "<pad>", "<cls>", "<sep>", "the"],
            options: .init(unknownToken: "<unk>", classifierToken: "<cls>", separatorToken: "<sep>", padToken: "<pad>")
        ))
    }

    func testTheTemplateAndPaddingComeFromTheVocabulary() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.template, .bert(cls: 2, sep: 3))
        XCTAssertEqual(tokenizer.padTokenID, 0)
        XCTAssertEqual(tokenizer.vocabularySize, 39)
    }
}

final class PairTruncationTests: XCTestCase {
    /// The reference rule, step by step: drop a token from the longer text, from the second on a tie.
    private func reference(_ first: Int, _ second: Int, _ budget: Int) -> (Int, Int) {
        var first = first
        var second = second
        while first + second > budget {
            if first > second { first -= 1 } else { second -= 1 }
        }
        return (first, second)
    }

    func testTheClosedFormMatchesTheStepwiseRuleEverywhere() {
        for first in 0...14 {
            for second in 0...14 {
                for budget in 0...16 {
                    let kept = PairTruncation.lengths(first: first, second: second, budget: budget)
                    let expected = reference(first, second, budget)
                    XCTAssertEqual(kept.first, expected.0, "first \(first) second \(second) budget \(budget)")
                    XCTAssertEqual(kept.second, expected.1, "first \(first) second \(second) budget \(budget)")
                    XCTAssertLessThanOrEqual(kept.first + kept.second, budget)
                }
            }
        }
    }

    func testAShortQueryIsNeverCutForALongPassage() {
        // The rerank stage: 128 tokens less three special tokens.
        let kept = PairTruncation.lengths(first: 6, second: 400, budget: 125)
        XCTAssertEqual(kept.first, 6)
        XCTAssertEqual(kept.second, 119)
        let both = PairTruncation.lengths(first: 300, second: 400, budget: 125)
        XCTAssertEqual(both.first, 63)
        XCTAssertEqual(both.second, 62)
        let fits = PairTruncation.lengths(first: 6, second: 40, budget: 125)
        XCTAssertEqual(fits.first, 6)
        XCTAssertEqual(fits.second, 40)
        let negative = PairTruncation.lengths(first: -3, second: 4, budget: -1)
        XCTAssertEqual(negative.first, 0)
        XCTAssertEqual(negative.second, 0)
    }
}
