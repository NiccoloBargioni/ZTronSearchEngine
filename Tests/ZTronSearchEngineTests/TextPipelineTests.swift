import XCTest
@testable import ZTronSearchEngine

/// Section 16, core correctness: Unicode and diacritic normalization, including NFKC folding and
/// width folding; and the tokenizer rules of sections 5 and 7.1.
final class TextPipelineTests: XCTestCase {
    // MARK: Normalization

    func testCaseAndDiacriticFolding() {
        XCTAssertEqual(SearchNormalizer.normalize("Résumé"), "resume")
        XCTAssertEqual(SearchNormalizer.normalize("resume"), SearchNormalizer.normalize("RÉSUMÉ"))
        XCTAssertEqual(SearchNormalizer.normalize("naïve Ångström"), "naive angstrom")
        XCTAssertEqual(SearchNormalizer.normalize("Straße"), "strasse")
    }

    func testNFKCFolding() {
        // Compatibility characters fold to their plain forms.
        XCTAssertEqual(SearchNormalizer.normalize("ﬁne"), "fine")
        XCTAssertEqual(SearchNormalizer.normalize("㎏"), "kg")
        XCTAssertEqual(SearchNormalizer.normalize("①"), "1")
        // Canonically equivalent spellings normalize to the same bytes.
        let precomposed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(Array(SearchNormalizer.normalize(precomposed).utf8), Array(SearchNormalizer.normalize(decomposed).utf8))
    }

    func testWidthFolding() {
        XCTAssertEqual(SearchNormalizer.normalize("ＡＢＣ１２３"), "abc123")
        // Halfwidth katakana folds to fullwidth.
        XCTAssertEqual(SearchNormalizer.normalize("ｶﾀｶﾅ"), SearchNormalizer.normalize("カタカナ"))
    }

    func testDotlessIFoldsInEveryLocale() {
        // Without the extra step these pairs disagree in one locale or the other.
        for locale in ["tr", "en", "az", "it"] {
            let identifier = Locale(identifier: locale)
            XCTAssertEqual(SearchNormalizer.normalize("İstanbul", locale: identifier), "istanbul", locale)
            XCTAssertEqual(SearchNormalizer.normalize("istanbul", locale: identifier), "istanbul", locale)
            XCTAssertEqual(SearchNormalizer.normalize("IŞIK", locale: identifier), SearchNormalizer.normalize("ışık", locale: identifier), locale)
        }
    }

    func testASCIIFastPathMatchesFoundation() {
        let samples = ["Hello World", "MIXED case 123", "already lower", "UPPER", "a-b_c.d", "", "Tab\tNew\nLine", "I", "TITLE"]
        for sample in samples {
            for locale in ["en", "tr", "lt", "de"] {
                let foundation = sample.precomposedStringWithCompatibilityMapping
                    .folding(options: SearchNormalizer.foldingOptions, locale: Locale(identifier: locale))
                    .replacingOccurrences(of: "\u{0131}", with: "i")
                XCTAssertEqual(SearchNormalizer.normalize(sample, locale: Locale(identifier: locale)), foundation, "\(sample) in \(locale)")
            }
        }
    }

    // MARK: Tokenization

    private func terms(_ text: String, language: String? = "en", kind: SearchToken.Kind? = nil) -> [String] {
        TokenizerSession().tokenize(text, language: language).filter { kind == nil || $0.kind == kind }.map(\.term)
    }

    func testWordsAreNormalizedAndRangesPointAtTheOriginal() {
        let text = "The Résumé of Ångström"
        let tokens = TokenizerSession().tokenize(text, language: "en")
        XCTAssertEqual(tokens.map(\.term), ["the", "resume", "of", "angstrom"])
        XCTAssertEqual(tokens.map { String(text[$0.range]) }, ["The", "Résumé", "of", "Ångström"])
    }

    func testIdentifiersAreIndexedWholeNextToTheirParts() {
        let tokens = TokenizerSession().tokenize("Use the M1911-A1 with ray_gun at example.com v1.2.3", language: "en")
        let compounds = tokens.filter { $0.kind == .compound }.map(\.term)
        XCTAssertEqual(compounds, ["m1911-a1", "ray_gun", "example.com"])
        XCTAssertTrue(tokens.filter { $0.kind == .compound }.allSatisfy(\.isExactOnly))
        let words = tokens.filter { $0.kind == .word }.map(\.term)
        XCTAssertEqual(words, ["use", "the", "m1911", "a1", "with", "ray", "gun", "at", "example", "com", "v1.2.3"])
        // Tokens that contain digits or - _ . match exactly only.
        let exactOnly = Set(tokens.filter(\.isExactOnly).map(\.term))
        XCTAssertEqual(exactOnly, ["m1911", "a1", "m1911-a1", "ray_gun", "example.com", "v1.2.3"])
    }

    func testCompoundNeedsExactlyOneConnector() {
        XCTAssertEqual(terms("well-known fact", kind: .compound), ["well-known"])
        XCTAssertEqual(terms("well - known", kind: .compound), [])
        XCTAssertEqual(terms("end. Start", kind: .compound), [])
        XCTAssertEqual(terms("a--b", kind: .compound), [])
    }

    func testAWordIsSplitAtItsApostrophes() {
        // The tokenizer keeps an elided article and its noun together; the noun has to be
        // findable on its own, in Italian and French as in an English possessive.
        let session = TokenizerSession()
        XCTAssertEqual(session.words("L'isola del tesoro", language: "it"), ["l", "isola", "del", "tesoro"])
        XCTAssertEqual(session.words("Mappa dell’isola", language: "it"), ["mappa", "dell", "isola"])
        XCTAssertEqual(session.words("L'eau d'été", language: "fr"), ["l", "eau", "d", "ete"])
        XCTAssertEqual(session.words("The harbor's gate, rock'n'roll", language: "en"), ["the", "harbor", "s", "gate", "rock", "n", "roll"])
        XCTAssertEqual(session.words("'quoted' and ''", language: nil), ["quoted", "and"])
        // Ranges still point at the original, part by part.
        let text = "dell'isola"
        let tokens = session.tokenize(text, language: "it")
        XCTAssertEqual(tokens.map { String(text[$0.range]) }, ["dell", "isola"])
        XCTAssertTrue(tokens.allSatisfy { $0.kind == .word && !$0.isCompoundPart })
    }

    func testCJKEmitsWordsAndCharacterBigrams() {
        let text = "東京タワーに行く"
        let tokens = TokenizerSession().tokenize(text, language: "ja")
        let words = tokens.filter { $0.kind == .word }.map(\.term)
        XCTAssertFalse(words.isEmpty)
        XCTAssertEqual(words.joined(), SearchNormalizer.normalize(text, language: "ja"))
        let bigrams = Set(tokens.filter { $0.kind == .bigram }.map(\.term))
        // Every adjacent pair is reachable, as a word or as a bigram.
        let all = Set(tokens.map(\.term))
        let characters = Array(text)
        for index in 0..<(characters.count - 1) {
            let pair = SearchNormalizer.normalize(String(characters[index...index + 1]), language: "ja")
            XCTAssertTrue(all.contains(pair), "missing \(pair)")
        }
        // A bigram is never emitted twice for a range a word already covers.
        XCTAssertTrue(bigrams.isDisjoint(with: Set(words.filter { $0.count == 2 }).intersection(bigrams.filter { pair in
            tokens.contains { $0.kind == .word && $0.term == pair } && tokens.filter { $0.term == pair }.count > 1
        })))
        // Latin text emits none.
        XCTAssertEqual(terms("plain latin text", kind: .bigram), [])
    }

    func testThaiEmitsBigrams() {
        XCTAssertFalse(terms("แผนที่เกม", language: "th", kind: .bigram).isEmpty)
    }

    func testOverlongTokensAreNotIndexed() {
        let blob = String(repeating: "a", count: 200)
        XCTAssertEqual(terms("short \(blob) tail"), ["short", "tail"])
    }

    // MARK: Edit distance

    func testAllowedEditsByLength() {
        XCTAssertEqual((1...8).map(EditDistance.allowedEdits(forLength:)), [0, 0, 1, 1, 1, 2, 2, 2])
    }

    func testBoundedDamerauLevenshtein() {
        XCTAssertEqual(EditDistance.bounded("mystery", "mystery", maximum: 2), 0)
        XCTAssertEqual(EditDistance.bounded("mystery", "mystry", maximum: 2), 1)      // deletion
        XCTAssertEqual(EditDistance.bounded("mystery", "mysstery", maximum: 2), 1)    // insertion
        XCTAssertEqual(EditDistance.bounded("mystery", "mistery", maximum: 2), 1)     // substitution
        XCTAssertEqual(EditDistance.bounded("mystery", "mytsery", maximum: 2), 1)     // adjacent transposition
        XCTAssertEqual(EditDistance.bounded("mystery", "mitsery", maximum: 2), 2)
        XCTAssertNil(EditDistance.bounded("mystery", "history", maximum: 1))
        XCTAssertNil(EditDistance.bounded("abc", "abcdef", maximum: 2))               // length pre-check
        XCTAssertEqual(EditDistance.bounded("", "ab", maximum: 2), 2)
    }

    func testDistanceIsComputedOnNormalizedScalars() {
        // résumé and resume are the same token before fuzzing.
        XCTAssertEqual(EditDistance.bounded(SearchNormalizer.normalize("résumé"), SearchNormalizer.normalize("resume"), maximum: 0), 0)
    }

    /// The trigram candidate generator must be lossless against brute force: every vocabulary
    /// term within the edit budget shares enough padded trigrams with the query, the one
    /// exception being looked up directly.
    func testTrigramFilterIsLossless() {
        var generator = SystemRandomNumberGenerator()
        let alphabet: [UInt32] = [97, 98, 99]  // a small alphabet forces repeats and collisions
        func random(_ length: Int) -> [UInt32] { (0..<length).map { _ in alphabet.randomElement(using: &generator)! } }
        var scratch = EditDistance.Scratch()
        for _ in 0..<4_000 {
            let length = Int.random(in: 3...9, using: &generator)
            let query = random(length)
            let other = random(Int.random(in: max(2, length - 2)...(length + 2), using: &generator))
            let budget = EditDistance.allowedEdits(forLength: length)
            guard let edits = EditDistance.bounded(query, other, maximum: budget, scratch: &scratch), edits > 0 else { continue }

            // Count the query's padded trigram positions that occur anywhere in the candidate.
            var padded: [UInt32] = [Trigram.pad, Trigram.pad] + query + [Trigram.pad, Trigram.pad]
            let candidateKeys = Set(Trigram.keys(of: other))
            var shared = 0
            for index in 0..<(padded.count - 2) where candidateKeys.contains(Trigram.key(padded[index], padded[index + 1], padded[index + 2])) {
                shared += 1
            }
            padded.removeAll()
            let threshold = max(1, length + 2 - 4 * budget)
            let isVariant = Trigram.doubleTranspositionVariant(of: query) == other
            XCTAssertTrue(shared >= threshold || isVariant, "\(query) vs \(other): \(shared) shared, threshold \(threshold)")
        }
    }

    func testDoubleTranspositionVariantSharesNoTrigram() {
        let query = EditDistance.scalars("abcdef")
        let variant = Trigram.doubleTranspositionVariant(of: query)
        XCTAssertEqual(variant, EditDistance.scalars("bacdfe"))
        XCTAssertFalse(Trigram.shareAny(Trigram.keys(of: query), Trigram.keys(of: variant!)))
        var scratch = EditDistance.Scratch()
        XCTAssertEqual(EditDistance.bounded(query, variant!, maximum: 2, scratch: &scratch), 2)
    }

    // MARK: Query parsing

    private func parse(_ text: String, phrases: [String] = []) -> ParsedQuery {
        QueryParser.parse(text: text, phrases: phrases, language: "en", minimumFuzzyLength: 3, session: TokenizerSession())
    }

    func testLastTokenIsPrefixUnlessFollowedBySpaceOrAnIdentifier() {
        XCTAssertEqual(parse("mystery bo").clauses.map(\.allowsPrefix), [false, true])
        XCTAssertEqual(parse("mystery box ").clauses.map(\.allowsPrefix), [false, false])
        XCTAssertEqual(parse("round m1911").clauses.map(\.allowsPrefix), [false, false])
        // An identifier is one exact clause; its parts are not clauses of their own.
        XCTAssertEqual(parse("use m1911-a1").clauses.map(\.term), ["use", "m1911-a1"])
        XCTAssertEqual(parse("spider-m").clauses.map(\.allowsPrefix), [false])
    }

    func testIdentifiersAndPhrasesNeverFuzzOrExpand() {
        let parsed = parse("m1911-a1 example.com \"gas mask\"", phrases: ["power switch"])
        for clause in parsed.clauses {
            XCTAssertFalse(clause.allowsFuzzy, clause.term)
            XCTAssertFalse(clause.allowsPrefix, clause.term)
        }
        XCTAssertEqual(parsed.phrases, [["gas", "mask"], ["power", "switch"]])
        XCTAssertTrue(parsed.clauses.filter(\.isRequired).map(\.term).elementsEqual(["gas", "mask", "power", "switch"]))
        XCTAssertTrue(parsed.isIdentifierOnly)
    }

    func testFuzzyEligibilityFollowsTokenLength() {
        let parsed = parse("go map mystery")
        XCTAssertEqual(parsed.clauses.map(\.allowsFuzzy), [false, true, true])
        XCTAssertEqual(parsed.longestTokenLength, 7)
    }

    func testUnbalancedQuoteStaysText() {
        let parsed = parse("\"gas ma")
        XCTAssertTrue(parsed.phrases.isEmpty)
        XCTAssertEqual(parsed.clauses.map(\.term), ["gas", "ma"])
    }
}
