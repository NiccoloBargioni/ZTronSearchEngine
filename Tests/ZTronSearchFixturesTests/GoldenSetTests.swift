import XCTest
import ZTronSearchEngine
@testable import ZTronSearchFixtures

final class GoldenSetTests: XCTestCase {
    private func source(_ query: GoldenQuery, file: StaticString = #filePath, line: UInt = #line) throws -> GoldenEntry {
        try XCTUnwrap(GoldenCorpus.entry(for: query.sourceID), "\(query.id) has no golden source", file: file, line: line)
    }

    // MARK: Shape of the set

    func testGoldenSetIsValid() {
        let problems = GoldenSet.validate()
        XCTAssertEqual(problems, [], problems.prefix(40).joined(separator: "\n"))

        let queries = GoldenSet.queries
        XCTAssertGreaterThanOrEqual(queries.count, 300)
        for queryClass in GoldenQueryClass.allCases {
            let ofClass = GoldenSet.queries(of: queryClass)
            XCTAssertGreaterThanOrEqual(ofClass.count, 30, queryClass.rawValue)
            XCTAssertEqual(GoldenSet.countsByClass[queryClass], ofClass.count)
            let kinds = Set(ofClass.map(\.kind))
            for kind in GoldenSet.expectedKinds(of: queryClass) {
                XCTAssertTrue(kinds.contains(kind), "\(queryClass.rawValue) has no \(kind.rawValue) query")
            }
        }
        for kind in CatalogKind.allCases {
            XCTAssertGreaterThanOrEqual(GoldenSet.countsByKind[kind] ?? 0, 30, kind.rawValue)
        }
        let languages = GoldenSet.countsByLanguage
        XCTAssertGreaterThanOrEqual(languages.count, 3)
        XCTAssertGreaterThanOrEqual(languages["ja"] ?? 0, 30, "one language is non-Latin")
        XCTAssertEqual(languages.values.reduce(0, +), queries.count)
        XCTAssertEqual(GoldenSet.countsByClass.values.reduce(0, +), queries.count)

        let classes = GoldenQueryClass.allCases.map { "\($0.rawValue)=\(GoldenSet.countsByClass[$0] ?? 0)" }.joined(separator: " ")
        let kinds = CatalogKind.allCases.map { "\($0.rawValue)=\(GoldenSet.countsByKind[$0] ?? 0)" }.joined(separator: " ")
        let tags = languages.keys.sorted().map { "\($0)=\(languages[$0] ?? 0)" }.joined(separator: " ")
        print("GOLDEN SET: \(queries.count) queries | classes: \(classes) | kinds: \(kinds) | languages: \(tags)")
    }

    func testEveryQueryIsWellFormed() throws {
        for query in GoldenSet.queries {
            XCTAssertTrue(query.id.hasPrefix(query.queryClass.rawValue + "-"), query.id)
            let entry = try source(query)
            XCTAssertEqual(query.kind, entry.kind, query.id)
            XCTAssertNotNil(query.judgments[query.sourceID], "\(query.id): the source is judged")
            XCTAssertTrue(["en", "it", "de", "ja"].contains(query.locale), query.id)
            XCTAssertTrue(["en", "it", "de", "ja"].contains(query.language), query.id)
            XCTAssertTrue(query.judgments.values.allSatisfy { (1...3).contains($0) }, query.id)
            XCTAssertEqual(query.relevantIDs.count, query.judgments.count)
            XCTAssertEqual(query.relevantIDs.first.flatMap { query.judgments[$0] }, query.judgments.values.max())

            let built = query.query
            XCTAssertEqual(built.text, query.text)
            XCTAssertEqual(built.tokens, query.tokens)
            XCTAssertNil(built.locale, "the engine is built for the locale; the query does not override it")
            XCTAssertEqual(query.hasHardConstraints, !query.tokens.isEmpty)
            if query.queryClass != .filterAndKind {
                XCTAssertTrue(query.tokens.isEmpty, query.id)
                XCTAssertNil(query.allowedIDs, query.id)
                XCTAssertFalse(query.text.isEmpty, query.id)
            }
            if ![.crossLanguage, .localizedTitle].contains(query.queryClass) {
                XCTAssertEqual(query.locale, "en", query.id)
                XCTAssertEqual(query.language, "en", query.id)
            }
        }
    }

    // MARK: Classes

    func testExactTitleQueriesAreTheTitleInAnyCasing() throws {
        let queries = GoldenSet.queries(of: .exactTitle)
        for query in queries {
            let entry = try source(query)
            XCTAssertEqual(query.text.lowercased(), entry.title.lowercased(), query.id)
            XCTAssertEqual(query.judgments, [entry.id: 3], query.id)
        }
        XCTAssertTrue(queries.contains { $0.text != $0.text.lowercased() && $0.text != $0.text.uppercased() })
        XCTAssertTrue(queries.contains { $0.text == $0.text.lowercased() })
        XCTAssertTrue(queries.contains { $0.text == $0.text.uppercased() })
    }

    func testTitlePrefixQueriesEndInsideAWord() throws {
        for query in GoldenSet.queries(of: .titlePrefix) {
            let entry = try source(query)
            let title = Array(entry.title.lowercased())
            let prefix = Array(query.text.lowercased())
            XCTAssertGreaterThanOrEqual(prefix.count, 3, query.id)
            XCTAssertLessThan(prefix.count, title.count, query.id)
            XCTAssertEqual(Array(title.prefix(prefix.count)), prefix, "\(query.id): «\(query.text)» is not a prefix of «\(entry.title)»")
            XCTAssertTrue(prefix[prefix.count - 1].isLetter && title[prefix.count].isLetter, "\(query.id) must end inside a word")
            let lastWord = query.text.split(separator: " ").last.map(String.init) ?? ""
            XCTAssertGreaterThanOrEqual(lastWord.count, 3, "\(query.id): the unfinished word has three characters or more")

            // Grade 3 for the source, grade 2 for exactly the other titles that start the same way.
            XCTAssertEqual(query.judgments[entry.id], 3, query.id)
            for other in GoldenCorpus.entries where other.id != entry.id {
                let starts = other.title.lowercased().hasPrefix(query.text.lowercased())
                XCTAssertEqual(query.judgments[other.id], starts ? 2 : nil, "\(query.id) / \(other.title)")
            }
        }
        let variants = Set(GoldenSet.queries(of: .titlePrefix).map(\.variant))
        XCTAssertEqual(variants, ["firstWord", "secondWord", "thirdWord"])
    }

    func testTypoQueriesStayWithinTheEditBudget() throws {
        var edited = 0
        var twoEdits = 0
        for query in GoldenSet.queries(of: .typo) {
            let entry = try source(query)
            XCTAssertEqual(query.judgments, [entry.id: 3], query.id)
            let typed = query.text.lowercased().split(separator: " ").map(String.init)

            if query.variant == "keyword" {
                // One word: a distinctive keyword of the source, misspelled.
                XCTAssertEqual(typed.count, 1, query.id)
                let fits = entry.keywords.contains { keyword in
                    let distance = TestSupport.editDistance(keyword, typed[0])
                    return distance >= 1 && distance <= min(TestSupport.editBudget(keyword.count), TestSupport.editBudget(typed[0].count))
                }
                XCTAssertTrue(fits, "\(query.id): «\(query.text)» is not a fair typo of a keyword of \(entry.title)")
                edited += 1
                continue
            }

            let written = entry.title.lowercased().split(separator: " ").map(String.init)
            XCTAssertEqual(typed.count, written.count, "\(query.id): a typo never splits or joins words")
            var changes = 0
            for (original, typo) in zip(written, typed) where original != typo {
                let distance = TestSupport.editDistance(original, typo)
                // The budget of the word as written and of the word as typed: the engine sees
                // only the latter.
                let budget = min(TestSupport.editBudget(original.count), TestSupport.editBudget(typo.count))
                XCTAssertLessThanOrEqual(distance, budget, "\(query.id): \(original) -> \(typo)")
                XCTAssertFalse(original.contains(where: \.isNumber), "\(query.id): digits are never edited")
                XCTAssertTrue(typo.allSatisfy { $0.isLetter && $0.isASCII }, "\(query.id): \(typo)")
                XCTAssertGreaterThanOrEqual(original.count, 3, "\(query.id): short words are never edited")
                if distance == 2 { twoEdits += 1 }
                changes += 1
            }
            XCTAssertTrue((1...2).contains(changes), "\(query.id): one or two words carry a typo")
            XCTAssertNotEqual(query.text.lowercased(), entry.title.lowercased(), query.id)
            edited += 1
        }
        XCTAssertEqual(edited, GoldenSet.queries(of: .typo).count)
        XCTAssertGreaterThan(twoEdits, 10, "the two-edit budget of long words is exercised")
        XCTAssertTrue(GoldenSet.queries(of: .typo).contains { $0.variant == "keyword" })

        // No typo is a real word of the corpus or of the lexicon: it must be corrected, not matched.
        let known = Set(GoldenCorpus.entries.flatMap(TestSupport.allWords)).union(FixtureLexicon.latinForms)
        for query in GoldenSet.queries(of: .typo) {
            let entry = try source(query)
            let written = Set(TestSupport.words(entry.title))
            for word in TestSupport.words(query.text) where !written.contains(word) {
                XCTAssertFalse(known.contains(word), "\(query.id): the typo «\(word)» is a real word")
            }
        }
    }

    func testKeywordQueriesJudgeEveryCarrier() throws {
        for query in GoldenSet.queries(of: .keyword) {
            let entry = try source(query)
            XCTAssertTrue(entry.keywords.contains(query.text), query.id)
            XCTAssertTrue([CatalogKind.tool, .game, .image].contains(query.kind), query.id)
            let keyword = TestSupport.words(query.text)
            for other in GoldenCorpus.entries {
                let carries = other.keywords.contains(query.text)
                let inTitle = keyword.allSatisfy(TestSupport.words(other.title).contains)
                XCTAssertEqual(query.judgments[other.id], carries ? (inTitle ? 3 : 2) : nil, "\(query.id) / \(other.title)")
                // Fairness: an item that does not carry the keyword does not mention it either.
                if !carries {
                    let mentioned = Set(other.surfaces(in: "en").flatMap(TestSupport.words))
                    XCTAssertFalse(keyword.allSatisfy(mentioned.contains), "\(query.id): \(other.title) mentions «\(query.text)» without carrying it")
                }
            }
        }
        let grades = Set(GoldenSet.queries(of: .keyword).flatMap(\.judgments.values))
        XCTAssertEqual(grades, [2, 3], "keyword judgments are graded")
    }

    func testParaphraseQueriesShareNoTokenWithTheirSource() throws {
        let corpusWords = Set(GoldenCorpus.entries.flatMap(TestSupport.allWords))
        for query in GoldenSet.queries(of: .paraphrase) {
            let entry = try source(query)
            let words = TestSupport.words(query.text)
            XCTAssertEqual(words.count, entry.titleConceptIDs.count, query.id)
            XCTAssertTrue(Set(words).isDisjoint(with: TestSupport.allWords(of: entry)), "\(query.id): «\(query.text)» shares a token with \(entry.title)")

            // Made only of synonyms of the concepts of the title, one per concept, in order.
            for (word, conceptID) in zip(words, entry.titleConceptIDs) {
                XCTAssertTrue(FixtureLexicon.concept(conceptID).synonyms.contains(word), "\(query.id): \(word)")
            }
            // Stronger than asked: nothing in the whole corpus is, or starts with, a query word.
            for word in words {
                XCTAssertFalse(corpusWords.contains { $0.hasPrefix(word) }, "\(query.id): «\(word)» begins a word of the corpus")
            }
            // The source cannot be reached by typo correction either.
            for word in words {
                for surfaceWord in TestSupport.allWords(of: entry) {
                    XCTAssertGreaterThan(TestSupport.editDistance(word, surfaceWord), TestSupport.editBudget(word.count), "\(query.id): \(word) ~ \(surfaceWord)")
                }
            }

            XCTAssertEqual(query.judgments[entry.id], 3)
            XCTAssertLessThanOrEqual(query.judgments.count, 10, "\(query.id): Recall@10 can reach 1")
            for other in GoldenCorpus.entries where other.id != entry.id {
                let shared = Set(entry.titleConceptIDs).intersection(other.conceptIDs).count
                XCTAssertEqual(query.judgments[other.id], shared >= 2 ? 2 : nil, "\(query.id) / \(other.title)")
            }
        }
    }

    func testCrossLanguageSourcesHaveNoSurfaceInTheQueryLanguage() throws {
        let japaneseCharacters = Set(GoldenCorpus.entries.flatMap { $0.surfaces(in: "ja") }.joined().unicodeScalars)
        var perLanguage: [String: Int] = [:]
        for query in GoldenSet.queries(of: .crossLanguage) {
            let entry = try source(query)
            perLanguage[query.language, default: 0] += 1
            XCTAssertNotEqual(query.language, "en", "\(query.id): the base language of every golden item is English")
            XCTAssertEqual(query.locale, query.language, query.id)
            XCTAssertFalse(entry.isLocalized(in: query.language), "\(query.id): \(entry.title) is localized in \(query.language)")
            XCTAssertEqual((entry.item.base as? any LocalizedSearchable)?.searchLocalizations[query.language], nil)

            // The query names concepts of the title, and only reserved ones.
            let concepts = FixtureLexicon.conceptIDs(in: query.text)
            XCTAssertEqual(concepts.count, 2, query.id)
            XCTAssertTrue(concepts.allSatisfy(entry.titleConceptIDs.contains), query.id)
            XCTAssertTrue(concepts.allSatisfy { FixtureLexicon.concept($0).isReserved }, query.id)

            // Nothing lexical leads to the source, nor to anything else in the corpus.
            if query.language == "ja" {
                for scalar in query.text.unicodeScalars where scalar != " " {
                    let katakanaWord = query.text.split(separator: " ").contains { $0.unicodeScalars.contains(scalar) && $0.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) } }
                    if !katakanaWord {
                        XCTAssertFalse(japaneseCharacters.contains(scalar), "\(query.id): \(scalar) occurs in a Japanese surface")
                    }
                }
            } else {
                let words = TestSupport.words(query.text)
                XCTAssertTrue(Set(words).isDisjoint(with: TestSupport.allWords(of: entry)), query.id)
                for word in words {
                    for surfaceWord in TestSupport.allWords(of: entry) {
                        XCTAssertFalse(surfaceWord.hasPrefix(word), "\(query.id): \(word) begins \(surfaceWord)")
                        XCTAssertGreaterThan(TestSupport.editDistance(word, surfaceWord), TestSupport.editBudget(word.count), "\(query.id): \(word) ~ \(surfaceWord)")
                    }
                }
            }

            XCTAssertEqual(query.judgments[entry.id], 3)
            for other in GoldenCorpus.entries where other.id != entry.id {
                let shared = Set(concepts).intersection(other.conceptIDs).count
                XCTAssertEqual(query.judgments[other.id], shared >= 2 ? 2 : nil, "\(query.id) / \(other.title)")
            }
        }
        for language in ["it", "de", "ja"] {
            XCTAssertGreaterThanOrEqual(perLanguage[language] ?? 0, 10, language)
        }
    }

    func testLocalizedTitleQueriesAreTheLocalizedTitle() throws {
        var perLanguage: [String: Int] = [:]
        for query in GoldenSet.queries(of: .localizedTitle) {
            let entry = try source(query)
            perLanguage[query.language, default: 0] += 1
            XCTAssertNotEqual(query.language, "en")
            XCTAssertEqual(query.locale, query.language, query.id)
            XCTAssertEqual(query.text, entry.title(in: query.language), query.id)
            XCTAssertNotEqual(query.text.lowercased(), entry.title.lowercased(), "\(query.id): the localized title differs from the base one")
            XCTAssertEqual(query.judgments, [entry.id: 3], query.id)
        }
        for language in ["it", "de", "ja"] {
            XCTAssertGreaterThanOrEqual(perLanguage[language] ?? 0, 10, language)
        }
    }

    func testConstrainedQueriesListExactlyWhatSatisfiesThem() throws {
        var variants = Set<String>()
        for query in GoldenSet.queries(of: .filterAndKind) {
            variants.insert(query.variant)
            XCTAssertFalse(query.tokens.isEmpty, query.id)
            let allowed = try XCTUnwrap(query.allowedIDs, query.id)
            XCTAssertEqual(allowed, query.allowedIDs(in: GoldenCorpus.items), query.id)
            XCTAssertTrue(Set(query.judgments.keys).isSubset(of: allowed), "\(query.id): judgments list only items that satisfy the constraints")
            XCTAssertFalse(allowed.isEmpty, query.id)

            // The same constraints, checked without the fixture's own code.
            var kinds = Set<CatalogKind>()
            var filters: [String: Set<String>] = [:]
            var phrases: [[String]] = []
            for token in query.tokens {
                switch token {
                case .kind(let kind): kinds.insert(kind)
                case .filter(let filter): filters[filter.key, default: []].insert(filter.value)
                case .phrase(let phrase): phrases.append(TestSupport.words(phrase))
                }
            }
            for entry in GoldenCorpus.entries {
                var satisfies = kinds.isEmpty || kinds.contains(entry.kind)
                for (key, values) in filters where !entry.filters.contains(where: { $0.key == key && values.contains($0.value) }) {
                    satisfies = false
                }
                for phrase in phrases {
                    let found = entry.allSurfaces.contains { surface in
                        let words = TestSupport.words(surface)
                        guard words.count >= phrase.count else { return false }
                        return (0...(words.count - phrase.count)).contains { Array(words[$0..<($0 + phrase.count)]) == phrase }
                    }
                    if !found { satisfies = false }
                }
                XCTAssertEqual(allowed.contains(entry.id), satisfies, "\(query.id) / \(entry.title)")
            }
        }
        XCTAssertEqual(variants, ["kind", "filter", "filters", "kindAndFilter", "sameKeyFilters", "kinds", "phrase", "tokensOnly"])

        let all = GoldenSet.queries(of: .filterAndKind)
        XCTAssertTrue(all.contains { $0.text.isEmpty }, "some queries are tokens only")
        XCTAssertTrue(all.contains { query in query.tokens.contains { if case .filter(.string) = $0 { return true } else { return false } } }, "the string escape hatch is exercised")
        XCTAssertTrue(all.contains { query in query.tokens.contains { if case .filter(.region) = $0 { return true } else { return false } } })
        XCTAssertTrue(all.contains { query in query.tokens.contains { if case .filter(.category) = $0 { return true } else { return false } } })
    }

    func testConstraintSemantics() {
        let tool = AnySearchable(Tool(id: "t", title: "Alpha Beta", text: "gamma delta", filters: [.platform(.ios), .category(.guides)]))
        let tip = AnySearchable(Tip(id: "p", title: "Alpha Beta", text: "gamma delta"))
        func query(_ tokens: [SearchQueryToken<CatalogSchema>]) -> GoldenQuery {
            GoldenQuery(
                id: "x", queryClass: .filterAndKind, text: "", tokens: tokens, locale: "en", language: "en",
                judgments: [:], kind: .tool, sourceID: "t", variant: "test", allowedIDs: nil
            )
        }
        XCTAssertTrue(query([]).satisfiesConstraints(tip))
        XCTAssertTrue(query([.kind(.tool)]).satisfiesConstraints(tool))
        XCTAssertFalse(query([.kind(.tool)]).satisfiesConstraints(tip))
        XCTAssertTrue(query([.kind(.tool), .kind(.tip)]).satisfiesConstraints(tip), "kinds are alternatives")
        // OR among the values of one key, AND across keys.
        XCTAssertTrue(query([.filter(.platform(.mac)), .filter(.platform(.ios))]).satisfiesConstraints(tool))
        XCTAssertFalse(query([.filter(.platform(.mac)), .filter(.platform(.tv))]).satisfiesConstraints(tool))
        XCTAssertTrue(query([.filter(.platform(.ios)), .filter(.category(.guides))]).satisfiesConstraints(tool))
        XCTAssertFalse(query([.filter(.platform(.ios)), .filter(.category(.maps))]).satisfiesConstraints(tool))
        XCTAssertFalse(query([.filter(.platform(.ios))]).satisfiesConstraints(tip), "an item without filters satisfies no filter")
        // Phrases: consecutive words of one surface.
        XCTAssertTrue(query([.phrase("alpha beta")]).satisfiesConstraints(tool))
        XCTAssertTrue(query([.phrase("Gamma, DELTA")]).satisfiesConstraints(tool))
        XCTAssertFalse(query([.phrase("beta alpha")]).satisfiesConstraints(tool))
        XCTAssertFalse(query([.phrase("beta gamma")]).satisfiesConstraints(tool), "a phrase never spans two surfaces")
        XCTAssertEqual(query([.kind(.tip)]).allowedIDs(in: [tool, tip]), ["p"])
    }

    func testValidationReportsProblems() {
        func query(_ id: String, _ queryClass: GoldenQueryClass, judgments: [SearchableID: Int], tokens: [SearchQueryToken<CatalogSchema>] = [], allowed: Set<SearchableID>? = nil) -> GoldenQuery {
            GoldenQuery(
                id: id, queryClass: queryClass, text: "text", tokens: tokens, locale: "en", language: "en",
                judgments: judgments, kind: .map, sourceID: "gold-map-001", variant: "test", allowedIDs: allowed
            )
        }
        let problems = GoldenSet.validate([
            query("a", .exactTitle, judgments: ["gold-map-001": 3]),
            query("a", .exactTitle, judgments: [:]),
            query("b", .typo, judgments: ["gold-map-001": 7, "missing": 1]),
            query("c", .filterAndKind, judgments: ["gold-map-001": 3], tokens: [.kind(.tip)], allowed: ["gold-tip-001"]),
        ])
        let text = problems.joined(separator: "\n")
        XCTAssertTrue(text.contains("only 4 queries"), text)
        XCTAssertTrue(text.contains("duplicate id a"), text)
        XCTAssertTrue(text.contains("a: no judgment"), text)
        XCTAssertTrue(text.contains("grade 7"), text)
        XCTAssertTrue(text.contains("missing is not a golden item"), text)
        XCTAssertTrue(text.contains("violates the query's constraints"), text)
        XCTAssertTrue(text.contains("exactTitle: only 2 queries"), text)
        XCTAssertTrue(text.contains("no query for kind tip"), text)
        XCTAssertTrue(text.contains("only 1 languages"), text)
        XCTAssertTrue(text.contains("no query in a non-Latin language"), text)
    }
}
