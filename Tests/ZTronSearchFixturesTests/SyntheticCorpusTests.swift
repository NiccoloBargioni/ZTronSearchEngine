import XCTest
import ZTronSearchEngine
@testable import ZTronSearchFixtures

final class SyntheticCorpusTests: XCTestCase {
    private static let sample = SyntheticCorpus(seed: 11, count: 5_000)

    private func localizations(_ item: AnySearchable<CatalogKind>) -> [String: SearchLocalization] {
        (item.base as? any LocalizedSearchable)?.searchLocalizations ?? [:]
    }

    func testIdsNeverCollideWithGoldenIds() {
        let corpus = Self.sample
        let ids = corpus.items.map(\.searchID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy(SyntheticCorpus.isSynthetic))
        XCTAssertTrue(ids.allSatisfy { !GoldenCorpus.isGolden($0) })
        XCTAssertTrue(Set(ids).isDisjoint(with: GoldenCorpus.entries.map(\.id)))
        XCTAssertTrue(GoldenCorpus.entries.allSatisfy { !SyntheticCorpus.isSynthetic($0.id) })
        XCTAssertEqual(ids.first, "syn-0000000")
        XCTAssertEqual(ids.last, "syn-0004999")

        let combined = SyntheticCorpus.combined(seed: 11, count: 500)
        XCTAssertEqual(combined.count, GoldenCorpus.items.count + 500)
        XCTAssertEqual(Set(combined.map(\.searchID)).count, combined.count)
        XCTAssertEqual(Array(combined.prefix(GoldenCorpus.items.count)).map(\.searchID), GoldenCorpus.items.map(\.searchID))
        XCTAssertEqual(combined.last?.searchID, "syn-0000499")
        XCTAssertTrue(SyntheticCorpus(seed: 1, count: 0).items.isEmpty)
        XCTAssertTrue(SyntheticCorpus(seed: 1, count: -5).items.isEmpty)
    }

    func testKindsAreSpreadEvenly() {
        let corpus = Self.sample
        let counts = Dictionary(grouping: corpus.items, by: \.searchKind).mapValues(\.count)
        for kind in CatalogKind.allCases { XCTAssertEqual(counts[kind], 1_000, kind.rawValue) }
        XCTAssertEqual(corpus.maps.count, 1_000)
        XCTAssertEqual(corpus.tips.count, 1_000)
        XCTAssertEqual(corpus.tools.count, 1_000)
        XCTAssertEqual(corpus.games.count, 1_000)
        XCTAssertEqual(corpus.images.count, 1_000)
        XCTAssertEqual(corpus.count, 5_000)
        XCTAssertEqual(corpus.seed, 11)
    }

    func testTextsHaveRealisticShapes() throws {
        let corpus = Self.sample
        var titleLengths = Set<Int>()
        var keywordCounts = Set<Int>()
        var bodyWords = 0
        var shortest = Int.max
        var longest = 0
        for item in corpus.items {
            let title = try XCTUnwrap((item.base as? any TitledSearchable)?.searchTitle)
            let titleWords = title.split(separator: " ").count
            XCTAssertTrue((2...5).contains(titleWords), title)
            titleLengths.insert(titleWords)

            let words = item.searchText.split(separator: " ").count
            XCTAssertTrue((20...80).contains(words), "\(item.searchID): \(words) words")
            bodyWords += words
            shortest = min(shortest, words)
            longest = max(longest, words)
            XCTAssertTrue(item.searchText.hasSuffix("."))
            XCTAssertTrue(item.searchText.first?.isUppercase ?? false)

            if let keyworded = item.base as? any KeywordSearchable {
                XCTAssertTrue((0...6).contains(keyworded.searchKeywords.count))
                keywordCounts.insert(keyworded.searchKeywords.count)
            }
        }
        XCTAssertEqual(titleLengths, [2, 3, 4, 5])
        XCTAssertEqual(keywordCounts, [0, 1, 2, 3, 4, 5, 6])
        let mean = Double(bodyWords) / Double(corpus.items.count)
        XCTAssertTrue((45...55).contains(mean), "mean body length \(mean)")
        XCTAssertLessThanOrEqual(shortest, 24)
        XCTAssertGreaterThanOrEqual(longest, 76)
    }

    func testEveryTypeCarriesItsCapabilities() {
        let corpus = Self.sample
        for map in corpus.maps {
            XCTAssertTrue(map.searchFilters.contains(.category(.maps)))
            XCTAssertTrue(map.searchFilters.contains { $0.key == "platform" })
        }
        for tip in corpus.tips {
            XCTAssertLessThanOrEqual(tip.createdAt, tip.updatedAt)
            XCTAssertLessThanOrEqual(tip.updatedAt, GoldenCorpus.referenceDate)
        }
        XCTAssertGreaterThan(Set(corpus.tips.map(\.updatedAt)).count, 300)
        for tool in corpus.tools {
            XCTAssertEqual(Set(tool.searchFilters.map(\.key)), ["category", "platform"])
        }
        for game in corpus.games {
            XCTAssertEqual(Set(game.searchFilters.map(\.key)), ["platform", "region", GoldenCorpus.genreFilterKey])
        }
        for image in corpus.images {
            XCTAssertFalse((image.searchCaption ?? "").isEmpty)
        }
        let recognized = corpus.images.filter { $0.searchOCRText != nil }.count
        XCTAssertTrue((150...350).contains(recognized), "\(recognized) images with recognized text")
        XCTAssertGreaterThan(Set(corpus.tools.flatMap { $0.searchFilters.map(\.value) }).count, 6)
    }

    func testAFractionOfItemsIsLocalized() {
        let corpus = Self.sample
        let localized = corpus.items.filter { !localizations($0).isEmpty }
        XCTAssertTrue((750...1_250).contains(localized.count), "\(localized.count) of 5000 localized")
        var perLanguage: [String: Int] = [:]
        for item in localized {
            let all = localizations(item)
            XCTAssertTrue(Set(all.keys).isSubset(of: ["it", "de", "ja"]))
            for (language, localization) in all {
                perLanguage[language, default: 0] += 1
                XCTAssertFalse((localization.title ?? "").isEmpty)
                XCTAssertFalse((localization.text ?? "").isEmpty)
                if language == "ja" {
                    XCTAssertTrue((localization.title ?? "").unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) }, "Japanese titles are katakana")
                    XCTAssertTrue((localization.text ?? "").hasSuffix("。"))
                }
            }
        }
        for language in ["it", "de", "ja"] {
            XCTAssertGreaterThan(perLanguage[language] ?? 0, 300, language)
        }
        XCTAssertTrue(localized.contains { localizations($0).count == 1 })
        XCTAssertTrue(localized.contains { localizations($0).count == 3 })
    }

    func testDistractorsCompeteOnCommonWordsOnly() throws {
        let corpus = Self.sample
        var synonyms = Set<String>()
        var lemmas = Set<String>()
        var reservedTranslations = Set<String>()
        var reservedJapanese: [String] = []
        for concept in FixtureLexicon.concepts {
            synonyms.formUnion(concept.synonyms)
            lemmas.insert(concept.lemma)
            if concept.isReserved {
                reservedTranslations.insert(FixtureText.fold(concept.italian))
                reservedTranslations.insert(FixtureText.fold(concept.german))
                reservedJapanese.append(concept.japanese)
            }
        }
        let lexicon = FixtureLexicon.latinForms
        var lemmaHits = 0
        var bodyWords = 0
        for item in corpus.items {
            // Titles and keywords: pseudo-words only, so no distractor matches a golden title,
            // starts with a golden prefix or carries a golden keyword.
            let title = try XCTUnwrap((item.base as? any TitledSearchable)?.searchTitle)
            let keywords = (item.base as? any KeywordSearchable)?.searchKeywords ?? []
            for word in FixtureText.latinTokens(title) + keywords.flatMap(FixtureText.latinTokens) {
                XCTAssertFalse(lexicon.contains(word), "\(item.searchID): «\(word)» is a lexicon word")
            }
            // Bodies: lemmas, never synonyms.
            for word in FixtureText.latinTokens(item.searchText) {
                bodyWords += 1
                if lemmas.contains(word) { lemmaHits += 1 }
                XCTAssertFalse(synonyms.contains(word), "\(item.searchID): synonym «\(word)»")
            }
            // Localizations: never a translation of a reserved concept.
            for (language, localization) in localizations(item) {
                let surfaces = [localization.title, localization.text, localization.caption].compactMap { $0 } + localization.keywords
                for word in surfaces.flatMap(FixtureText.latinTokens) {
                    XCTAssertFalse(reservedTranslations.contains(word), "\(item.searchID) [\(language)]: «\(word)»")
                    XCTAssertFalse(synonyms.contains(word), "\(item.searchID) [\(language)]: synonym «\(word)»")
                }
                if language == "ja" {
                    for surface in surfaces {
                        for form in reservedJapanese {
                            XCTAssertFalse(surface.contains(form), "\(item.searchID): «\(form)»")
                        }
                    }
                }
            }
        }
        let share = Double(lemmaHits) / Double(bodyWords)
        XCTAssertTrue((0.03...0.08).contains(share), "share of lexicon words in bodies: \(share)")
    }

    func testDistractorsShareWordsWithGoldenItemsButNeverAMeaning() {
        // What a distractor is embedded from names no concept at all: its lexicon words sit
        // past the description. So no distractor is near a golden query in the fake space.
        let provider = FakeEmbeddingProvider()
        var mentioning = 0
        for item in Self.sample.items {
            XCTAssertEqual(FixtureLexicon.conceptIDs(in: provider.composition(for: item)), [], item.searchID.rawValue)
            if !FixtureLexicon.conceptIDs(in: item.searchText).isEmpty { mentioning += 1 }
        }
        XCTAssertGreaterThan(mentioning, Self.sample.items.count / 2, "most distractors do mention lexicon words")

        // The nearest distractors to a golden query are no nearer than chance allows, while the
        // golden item it means is close.
        let wide = FakeEmbeddingProvider(dimensions: 384)
        let query = wide.vector(for: "icy port itinerary")
        let golden = FakeEmbeddingProvider.cosine(query, wide.itemVector(for: GoldenCorpus.items[0]))
        let nearest = Self.sample.items.map { FakeEmbeddingProvider.cosine(query, wide.itemVector(for: $0)) }.max() ?? 0
        XCTAssertGreaterThan(golden, 0.7)
        XCTAssertLessThan(nearest, 0.35)
    }

    func testSemanticQueriesFindNothingLexicalAmongDistractors() {
        // Every word and every Japanese character a distractor is written with, in any language.
        var words = Set<String>()
        var japanese = Set<Unicode.Scalar>()
        for item in Self.sample.items {
            for surface in GoldenQuery.surfaces(of: item.base) {
                words.formUnion(FixtureText.latinTokens(surface))
                for run in FixtureText.japaneseRuns(surface) { japanese.formUnion(run.unicodeScalars) }
            }
        }
        for query in GoldenSet.queries where query.queryClass == .paraphrase || query.queryClass == .crossLanguage {
            if query.language == "ja" {
                for word in query.text.split(separator: " ") {
                    let scalars = Array(word.unicodeScalars)
                    if scalars.allSatisfy({ (0x30A0...0x30FF).contains($0.value) }) {
                        // Katakana: no pair of its characters occurs in a distractor.
                        let surfaces = Self.sample.items.flatMap { GoldenQuery.surfaces(of: $0.base) }
                        for (first, second) in zip(scalars, scalars.dropFirst()) {
                            let pair = String(String.UnicodeScalarView([first, second]))
                            XCTAssertFalse(surfaces.contains { $0.contains(pair) }, "\(query.id): «\(pair)»")
                        }
                    } else {
                        XCTAssertTrue(japanese.isDisjoint(with: scalars), "\(query.id): «\(word)» shares a character with a distractor")
                    }
                }
            } else {
                for word in FixtureText.latinTokens(query.text) {
                    XCTAssertFalse(words.contains { $0.hasPrefix(word) }, "\(query.id): «\(word)» is, or begins, a word of a distractor")
                }
            }
        }
    }

    func testNoPseudoWordStartsLikeALexiconWord() {
        let vocabulary = SyntheticVocabulary.shared
        XCTAssertEqual(SyntheticCorpus.pseudoWordCount, 200_000)
        var prefixes = Set<String>()
        for form in FixtureLexicon.latinForms { prefixes.insert(String(form.prefix(3))) }
        var seen = Set<String>()
        seen.reserveCapacity(SyntheticVocabulary.latinCount)
        for rank in 0..<SyntheticVocabulary.latinCount {
            let word = vocabulary.latinWord(rank: rank)
            XCTAssertTrue(seen.insert(word).inserted, "\(word) appears twice")
            if prefixes.contains(String(word.prefix(3))) {
                XCTFail("\(word) starts like a lexicon word")
                break
            }
            if rank < 2_000 || rank % 997 == 0 {
                XCTAssertTrue(word.count >= 4 && word.allSatisfy { $0.isASCII && $0.isLowercase }, word)
            }
        }
        XCTAssertEqual(SyntheticCorpus.pseudoWord(rank: 0), vocabulary.latinWord(rank: 0))
        // Frequent words are short, rare words longer.
        let head = (0..<1_000).map { vocabulary.latinWord(rank: $0).count }.reduce(0, +)
        let tail = (199_000..<200_000).map { vocabulary.latinWord(rank: $0).count }.reduce(0, +)
        XCTAssertLessThan(head, tail)

        var kana = Set<String>()
        for rank in 0..<SyntheticVocabulary.kanaCount {
            let word = vocabulary.kanaWord(rank: rank)
            XCTAssertTrue(kana.insert(word).inserted, "\(word) appears twice")
        }
    }

    func testWordFrequenciesFollowAZipfLaw() {
        // The most frequent pseudo-word is far more common than the hundredth, which is far
        // more common than the ten-thousandth.
        var counts: [String: Int] = [:]
        for item in Self.sample.items {
            for word in FixtureText.latinTokens(item.searchText) { counts[word, default: 0] += 1 }
        }
        let first = counts[SyntheticCorpus.pseudoWord(rank: 0)] ?? 0
        let hundredth = counts[SyntheticCorpus.pseudoWord(rank: 99)] ?? 0
        let rare = counts[SyntheticCorpus.pseudoWord(rank: 9_999)] ?? 0
        XCTAssertGreaterThan(first, 5 * max(1, hundredth))
        XCTAssertGreaterThan(hundredth, 5 * max(1, rare))
        XCTAssertGreaterThan(counts.count, 40_000, "5,000 items already hold tens of thousands of distinct terms")
    }

    func testACorpusIsTheBeginningOfALargerOne() {
        let small = SyntheticCorpus(seed: 11, count: 300)
        XCTAssertEqual(small.items.map(TestSupport.fingerprint), Self.sample.items.prefix(300).map(TestSupport.fingerprint))
        for index in [0, 7, 299, 4_321] {
            XCTAssertEqual(
                TestSupport.fingerprint(SyntheticCorpus.item(seed: 11, index: index)),
                TestSupport.fingerprint(Self.sample.items[index])
            )
        }
    }

    func testHundredThousandItemsGenerateQuickly() {
        _ = SyntheticVocabulary.shared
        let start = Date()
        let corpus = SyntheticCorpus(seed: 2_026, count: 100_000)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(corpus.items.count, 100_000)
        XCTAssertLessThan(elapsed, 20, "100,000 items took \(elapsed) s")

        // Distinct terms of the base surfaces: the vocabulary an English index would hold.
        var terms = Set<UInt64>()
        var tokens = 0
        for item in corpus.items {
            var text = item.searchText
            if let titled = item.base as? any TitledSearchable { text += " " + titled.searchTitle }
            if let keyworded = item.base as? any KeywordSearchable { text += " " + keyworded.searchKeywords.joined(separator: " ") }
            FixtureText.scan(text) { piece in
                if case .latin(let bytes) = piece {
                    terms.insert(FixtureText.hash(bytes))
                    tokens += 1
                }
            }
        }
        XCTAssertTrue((150_000...210_000).contains(terms.count), "\(terms.count) distinct terms")
        print(String(format: "SYNTHETIC CORPUS: 100,000 items in %.2f s; %d distinct terms over %d tokens", elapsed, terms.count, tokens))
    }
}
