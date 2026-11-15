import XCTest
import ZTronSearchEngine
@testable import ZTronSearchFixtures

final class LexiconTests: XCTestCase {
    func testLexiconIsSound() {
        let problems = FixtureLexicon.validate()
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    func testSizeAndSpreadOverWordClasses() {
        XCTAssertGreaterThanOrEqual(FixtureLexicon.concepts.count, 160)
        for wordClass in FixtureWordClass.allCases {
            XCTAssertGreaterThanOrEqual(FixtureLexicon.concepts(of: wordClass).count, 20, wordClass.rawValue)
        }
        for role in FixtureConceptRole.allCases {
            XCTAssertFalse(FixtureLexicon.concepts(in: role).isEmpty, role.rawValue)
        }
        XCTAssertEqual(FixtureLexicon.languages, ["en", "it", "de", "ja"])
        for (position, concept) in FixtureLexicon.concepts.enumerated() {
            XCTAssertEqual(concept.id, position)
            XCTAssertEqual(FixtureLexicon.concept(position), concept)
        }
    }

    func testSynonymsShareNoTokenWithTheirLemma() {
        for concept in FixtureLexicon.concepts {
            XCTAssertFalse(concept.synonyms.isEmpty, concept.lemma)
            let lemma = Set(TestSupport.words(concept.lemma))
            for synonym in concept.synonyms {
                XCTAssertTrue(lemma.isDisjoint(with: TestSupport.words(synonym)), "\(concept.lemma) / \(synonym)")
                XCTAssertEqual(TestSupport.words(synonym).count, 1, "\(synonym) must be one token")
            }
        }
    }

    func testEveryFormMapsToItsConceptAndToNoOther() {
        for concept in FixtureLexicon.concepts {
            var forms = [concept.lemma] + concept.synonyms
            forms += [concept.italian, concept.german, concept.japanese]
            forms += [concept.italianForm(agreeingWith: .feminine)]
            forms += [.masculine, .feminine, .neuter].map { concept.germanForm(agreeingWith: $0) }
            for form in forms {
                XCTAssertEqual(FixtureLexicon.conceptIDs(in: form), [concept.id], "\(concept.lemma): \(form)")
            }
            XCTAssertEqual(FixtureLexicon.conceptID(forWord: concept.lemma.uppercased()), concept.id)
            XCTAssertEqual(concept.form(in: "en"), concept.lemma)
            XCTAssertEqual(concept.form(in: "ja"), concept.japanese)
        }
        XCTAssertNil(FixtureLexicon.conceptID(forWord: "zzzzq"))
    }

    func testInflectionAgreesWithTheNoun() throws {
        let frozen = try XCTUnwrap(FixtureLexicon.concepts.first { $0.lemma == "frozen" })
        XCTAssertEqual(frozen.wordClass, .adjective)
        XCTAssertEqual(frozen.italianForm(agreeingWith: .masculine), "ghiacciato")
        XCTAssertEqual(frozen.italianForm(agreeingWith: .feminine), "ghiacciata")
        XCTAssertEqual(frozen.germanForm(agreeingWith: .masculine), "gefrorener")
        XCTAssertEqual(frozen.germanForm(agreeingWith: .feminine), "gefrorene")
        XCTAssertEqual(frozen.germanForm(agreeingWith: .neuter), "gefrorenes")

        let burning = try XCTUnwrap(FixtureLexicon.concepts.first { $0.lemma == "burning" })
        XCTAssertEqual(burning.italianForm(agreeingWith: .feminine), "ardente", "adjectives in -e are invariable")

        let harbor = try XCTUnwrap(FixtureLexicon.concepts.first { $0.lemma == "harbor" })
        XCTAssertEqual(harbor.wordClass, .place)
        XCTAssertEqual(harbor.italianForm(agreeingWith: .feminine), "porto")
        XCTAssertEqual(harbor.germanForm(agreeingWith: .neuter), "Hafen")
        XCTAssertEqual(harbor.germanGender, .masculine)
    }

    func testConceptsAreFoundInMixedText() throws {
        let frozen = try XCTUnwrap(FixtureLexicon.conceptID(forWord: "frozen"))
        let harbor = try XCTUnwrap(FixtureLexicon.conceptID(forWord: "harbor"))
        XCTAssertEqual(
            FixtureLexicon.conceptIDs(in: "FROZEN harbor, icy port; Porto ghiacciato. Gefrorener Hafen: 凍った港の地図"),
            [frozen, harbor, frozen, harbor, harbor, frozen, frozen, harbor, frozen, harbor]
        )
        // Diacritics and case do not matter; digits and punctuation separate words.
        XCTAssertEqual(FixtureLexicon.conceptIDs(in: "HÖHLE hohle Höhle2"), Array(repeating: try XCTUnwrap(FixtureLexicon.conceptID(forWord: "cave")), count: 3))
        XCTAssertEqual(FixtureLexicon.conceptIDs(in: "nothing known here 12 ゼゼゼ"), [])
    }

    func testJapaneseFormsMatchLongestFirst() throws {
        let sword = try XCTUnwrap(FixtureLexicon.conceptID(forWord: "sword"))
        let dagger = try XCTUnwrap(FixtureLexicon.conceptID(forWord: "dagger"))
        let fencing = try XCTUnwrap(FixtureLexicon.conceptID(forWord: "fencing"))
        // 短剣 (dagger) and 剣術 (fencing) both contain 剣 (sword).
        XCTAssertEqual(FixtureLexicon.conceptIDs(in: "短剣と剣術と剣"), [dagger, fencing, sword])
    }

    func testTextHelpers() {
        XCTAssertEqual(FixtureText.latinTokens("Schlüssel-Sucher: Größe 12, dell'isola"), ["schlussel", "sucher", "grosse", "dell", "isola"])
        XCTAssertEqual(FixtureText.japaneseRuns("凍った港 map の地図"), ["凍った港", "の地図"])
        XCTAssertEqual(FixtureText.words("Hollow Tide 2: ZONE7"), ["hollow", "tide", "2", "zone", "7"])
        XCTAssertEqual(FixtureText.fold("Übersicht"), "ubersicht")
        XCTAssertEqual(FixtureText.editDistance("harbor", "habror"), 1)
        XCTAssertEqual(FixtureText.editDistance("harbor", "harbour"), 1)
        XCTAssertEqual(FixtureText.editDistance("frozen", "fzoren"), 2)
        XCTAssertEqual(FixtureText.editDistance("", "abc"), 3)
        XCTAssertEqual(FixtureText.allowedEdits(forLength: 2), 0)
        XCTAssertEqual(FixtureText.allowedEdits(forLength: 5), 1)
        XCTAssertEqual(FixtureText.allowedEdits(forLength: 6), 2)
        for (lhs, rhs) in [("harbor", "habror"), ("frozen", "fzoren"), ("key", "keys"), ("abc", "xyz")] {
            let distance = TestSupport.editDistance(lhs, rhs)
            XCTAssertEqual(FixtureText.editDistance(lhs, rhs), distance)
            XCTAssertEqual(FixtureText.boundedEditDistance(Array(lhs.utf8), Array(rhs.utf8), maximum: 2), distance <= 2 ? distance : nil)
        }
    }

    func testSeededGeneratorIsSplitMix64() {
        // Reference values of SplitMix64 seeded with 0 and with 1234567.
        var zero = SeededGenerator(seed: 0)
        XCTAssertEqual(zero.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(zero.next(), 0x6E78_9E6A_A1B9_65F4)
        XCTAssertEqual(zero.next(), 0x06C4_5D18_8009_454F)
        var other = SeededGenerator(seed: 1_234_567)
        XCTAssertEqual(other.next(), 6_457_827_717_110_365_317)
        XCTAssertEqual(other.next(), 3_203_168_211_198_807_973)

        var generator = SeededGenerator(seed: 99)
        for bound in [1, 2, 7, 1_000] {
            for _ in 0..<200 {
                let value = generator.index(below: bound)
                XCTAssertTrue(value >= 0 && value < bound)
            }
        }
        for _ in 0..<200 { XCTAssertTrue((3...9).contains(generator.int(in: 3...9))) }
        var a = SeededGenerator.stream(seed: 5, 1)
        var b = SeededGenerator.stream(seed: 5, 1)
        var c = SeededGenerator.stream(seed: 5, 2)
        let first = a.next()
        XCTAssertEqual(first, b.next())
        XCTAssertNotEqual(first, c.next())
        // It also works through the standard library's generic entry points.
        var standard = SeededGenerator(seed: 3)
        XCTAssertTrue((0..<10).contains(Int.random(in: 0..<10, using: &standard)))
    }
}
