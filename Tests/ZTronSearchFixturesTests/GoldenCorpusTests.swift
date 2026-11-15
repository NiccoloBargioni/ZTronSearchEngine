import XCTest
import ZTronSearchEngine
@testable import ZTronSearchFixtures

final class GoldenCorpusTests: XCTestCase {
    func testCorpusIsSound() {
        let problems = GoldenCorpus.validate()
        XCTAssertEqual(problems, [], problems.prefix(40).joined(separator: "\n"))
    }

    func testEveryKindHasAtLeastEightyItems() {
        for kind in CatalogKind.allCases {
            XCTAssertGreaterThanOrEqual(GoldenCorpus.entries(of: kind).count, 80, kind.rawValue)
        }
        XCTAssertEqual(GoldenCorpus.items.count, GoldenCorpus.entries.count)
        XCTAssertEqual(GoldenCorpus.items.map(\.searchID), GoldenCorpus.entries.map(\.id))
        XCTAssertEqual(GoldenCorpus.maps.map(\.searchID), GoldenCorpus.entries(of: .map).map(\.id))
        XCTAssertEqual(GoldenCorpus.tips.map(\.searchID), GoldenCorpus.entries(of: .tip).map(\.id))
        XCTAssertEqual(GoldenCorpus.tools.map(\.searchID), GoldenCorpus.entries(of: .tool).map(\.id))
        XCTAssertEqual(GoldenCorpus.games.map(\.searchID), GoldenCorpus.entries(of: .game).map(\.id))
        XCTAssertEqual(GoldenCorpus.images.map(\.searchID), GoldenCorpus.entries(of: .image).map(\.id))
        for entry in GoldenCorpus.entries {
            XCTAssertEqual(entry.item.searchKind, entry.kind)
            XCTAssertEqual(GoldenCorpus.entry(for: entry.id)?.title, entry.title)
            XCTAssertEqual(GoldenCorpus.conceptIDs(for: entry.id), entry.conceptIDs)
            XCTAssertTrue(GoldenCorpus.isGolden(entry.id))
        }
        XCTAssertNil(GoldenCorpus.entry(for: "syn-0000001"))
        XCTAssertEqual(GoldenCorpus.conceptIDs(for: "nope"), [])
    }

    func testTitlesAreUniqueAfterCaseFolding() {
        let entries = GoldenCorpus.entries
        XCTAssertEqual(Set(entries.map { $0.title.lowercased() }).count, entries.count)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        for entry in entries {
            let words = entry.title.split(separator: " ")
            XCTAssertTrue((2...4).contains(words.count), entry.title)
            XCTAssertEqual((entry.item.base as? any TitledSearchable)?.searchTitle, entry.title)
        }
        // No title is contained in another, word for word: an exact-title query has one answer.
        let sets = entries.map { Set(TestSupport.words($0.title)) }
        for (index, lhs) in sets.enumerated() {
            for rhs in sets[(index + 1)...] {
                XCTAssertFalse(lhs.isSubset(of: rhs) || rhs.isSubset(of: lhs), "\(lhs) / \(rhs)")
            }
        }
        for language in ["it", "de", "ja"] {
            let titles = entries.compactMap { $0.title(in: language)?.lowercased() }
            XCTAssertEqual(Set(titles).count, titles.count, language)
        }
    }

    func testLocalizationMix() throws {
        for kind in CatalogKind.allCases {
            let entries = GoldenCorpus.entries(of: kind)
            let full = entries.filter { $0.localizedLanguages == ["de", "it", "ja"] }
            let baseOnly = entries.filter(\.isBaseOnly)
            let partial = entries.filter { !$0.isBaseOnly && $0.localizedLanguages.count < 3 }
            XCTAssertGreaterThan(full.count * 2, entries.count, "\(kind.rawValue): a majority is fully localized")
            XCTAssertGreaterThanOrEqual(baseOnly.count, 8, "\(kind.rawValue): a deliberate minority has no localization")
            XCTAssertLessThan(baseOnly.count * 4, entries.count)
            XCTAssertFalse(partial.isEmpty, "\(kind.rawValue): some items are localized in one or two languages only")
        }
        for entry in GoldenCorpus.entries {
            let localized = try XCTUnwrap(entry.item.base as? any LocalizedSearchable)
            XCTAssertEqual(localized.searchLanguage, "en")
            XCTAssertEqual(localized.searchLocalizations.keys.sorted(), entry.localizedLanguages)
            XCTAssertEqual(entry.title(in: "en"), entry.title)
            for language in ["it", "de", "ja"] {
                let localization = localized.searchLocalizations[language]
                XCTAssertEqual(entry.isLocalized(in: language), localization != nil)
                XCTAssertEqual(entry.title(in: language), localization?.title)
                if let localization {
                    XCTAssertFalse((localization.title ?? "").isEmpty)
                    XCTAssertFalse((localization.text ?? "").isEmpty)
                    XCTAssertNotEqual(localization.title, entry.title, "a localized title must differ from the base title")
                    XCTAssertEqual(localization.keywords.count, entry.keywords.count)
                } else {
                    XCTAssertTrue(entry.surfaces(in: language).isEmpty)
                }
            }
            if entry.isBaseOnly {
                XCTAssertTrue(entry.titleConceptIDs.contains { FixtureLexicon.concept($0).isReserved })
            } else {
                XCTAssertFalse(entry.conceptIDs.contains { FixtureLexicon.concept($0).isReserved })
            }
        }
    }

    func testEveryTypeCarriesItsCapabilities() {
        for map in GoldenCorpus.maps {
            XCTAssertTrue(map.searchFilters.contains(.category(.maps)))
            XCTAssertTrue(map.searchFilters.contains { $0.key == "platform" })
            XCTAssertFalse(map.searchText.isEmpty)
        }
        XCTAssertTrue(GoldenCorpus.maps.contains { $0.searchFilters.contains { $0.key == "region" } })
        XCTAssertTrue(GoldenCorpus.maps.contains { !$0.searchFilters.contains { $0.key == "region" } })

        for tip in GoldenCorpus.tips {
            XCTAssertLessThanOrEqual(tip.createdAt, tip.updatedAt)
            XCTAssertLessThanOrEqual(tip.updatedAt, GoldenCorpus.referenceDate)
            XCTAssertNil(tip.embedding)
        }
        XCTAssertGreaterThan(Set(GoldenCorpus.tips.map(\.updatedAt)).count, 40, "tips are updated at different times")
        XCTAssertTrue(GoldenCorpus.tips.contains { $0.updatedAt > $0.createdAt })

        for tool in GoldenCorpus.tools {
            XCTAssertGreaterThanOrEqual(tool.searchKeywords.count, 2)
            XCTAssertTrue(tool.searchFilters.contains { $0.key == "category" })
            XCTAssertTrue(tool.searchFilters.contains { $0.key == "platform" })
        }
        for game in GoldenCorpus.games {
            XCTAssertFalse(game.searchKeywords.isEmpty)
            XCTAssertTrue(game.searchFilters.contains { $0.key == "region" })
            XCTAssertTrue(game.searchFilters.contains { $0.key == GoldenCorpus.genreFilterKey }, "games use the string escape hatch")
        }
        for image in GoldenCorpus.images {
            XCTAssertFalse(image.searchKeywords.isEmpty, "images carry tags")
            XCTAssertFalse((image.searchCaption ?? "").isEmpty, "images carry a caption")
        }
        let recognized = GoldenCorpus.images.filter { $0.searchOCRText != nil }
        XCTAssertGreaterThan(recognized.count, 10)
        XCTAssertLessThan(recognized.count, GoldenCorpus.images.count)

        for entry in GoldenCorpus.entries {
            XCTAssertEqual(entry.filters, GoldenQuery.filters(of: entry.item.base))
            for filter in entry.filters {
                XCTAssertEqual(CatalogFilter(key: filter.key, value: filter.value), filter, "filters round-trip through their record")
            }
            XCTAssertEqual(entry.keywords, (entry.item.base as? any KeywordSearchable)?.searchKeywords ?? [])
            XCTAssertEqual(Array(entry.conceptIDs.prefix(entry.titleConceptIDs.count)), entry.titleConceptIDs)
            XCTAssertEqual(Set(entry.conceptIDs).count, entry.conceptIDs.count)
            XCTAssertEqual(entry.keywordConceptIDs.map { FixtureLexicon.concept($0).lemma }, entry.keywords)
            XCTAssertEqual(FixtureLexicon.conceptIDs(in: entry.title), entry.titleConceptIDs)
        }
    }

    func testLocalizedSurfacesSayTheSameAsTheBase() {
        // The property the cross-language tests rely on: every language names the same concepts.
        for entry in GoldenCorpus.entries {
            let base = Set(entry.surfaces(in: "en").flatMap(FixtureLexicon.conceptIDs(in:)))
            XCTAssertEqual(base, Set(entry.conceptIDs), entry.title)
            for language in entry.localizedLanguages {
                let localized = Set(entry.surfaces(in: language).flatMap(FixtureLexicon.conceptIDs(in:)))
                XCTAssertEqual(localized, base, "\(entry.title) [\(language)]")
            }
        }
    }

    func testGoldenTextNeverUsesSynonyms() {
        // English surfaces are written with lemmas only, so a paraphrase can never match a word.
        var synonyms = Set<String>()
        for concept in FixtureLexicon.concepts { synonyms.formUnion(concept.synonyms) }
        for entry in GoldenCorpus.entries {
            for word in entry.surfaces(in: "en").flatMap(TestSupport.words) {
                XCTAssertFalse(synonyms.contains(word), "\(entry.title): \(word)")
            }
        }
    }
}
