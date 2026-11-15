import XCTest
import ZTronSearchEngine
@testable import ZTronSearchFixtures

/// Same seed, same output: within a process, and (through pinned checksums) across processes,
/// runs and platforms.
final class DeterminismTests: XCTestCase {
    func testSyntheticCorpusDependsOnlyOnItsSeed() {
        let first = SyntheticCorpus(seed: 42, count: 2_000).items.map(TestSupport.fingerprint)
        let second = SyntheticCorpus(seed: 42, count: 2_000).items.map(TestSupport.fingerprint)
        XCTAssertEqual(first, second)
        let other = SyntheticCorpus(seed: 43, count: 2_000).items.map(TestSupport.fingerprint)
        XCTAssertNotEqual(first, other)
        // Different seeds share ids and kinds, never content.
        let differing = zip(first, other).filter { $0 != $1 }.count
        XCTAssertEqual(differing, 2_000)
    }

    func testGoldenSetDependsOnlyOnItsSeed() {
        let first = GoldenSet.generate(seed: 7).map(TestSupport.fingerprint)
        let second = GoldenSet.generate(seed: 7).map(TestSupport.fingerprint)
        XCTAssertEqual(first, second)
        let other = GoldenSet.generate(seed: 8)
        XCTAssertNotEqual(first, other.map(TestSupport.fingerprint))
        XCTAssertEqual(GoldenSet.validate(other), [], "another seed yields another valid set")
        XCTAssertEqual(GoldenSet.generate(seed: GoldenSet.defaultSeed).map(TestSupport.fingerprint), GoldenSet.queries.map(TestSupport.fingerprint))
    }

    func testGoldenCorpusIsTheSameEveryTimeItIsBuilt() {
        var builder = GoldenCorpusBuilder()
        let rebuilt = builder.build()
        XCTAssertEqual(rebuilt.items.map(TestSupport.fingerprint), GoldenCorpus.items.map(TestSupport.fingerprint))
        XCTAssertEqual(rebuilt.entries.map(\.conceptIDs), GoldenCorpus.entries.map(\.conceptIDs))
    }

    func testEmbeddingIsAPureFunction() {
        let first = FakeEmbeddingProvider()
        let second = FakeEmbeddingProvider()
        for text in ["frozen harbor", "porto ghiacciato zuvek", "凍った港のルート", "Schlüssel-Sucher 12", ""] {
            XCTAssertEqual(first.vector(for: text).map(\.bitPattern), second.vector(for: text).map(\.bitPattern), text)
        }
        let item = GoldenCorpus.items[3]
        XCTAssertEqual(first.itemVector(for: item).map(\.bitPattern), second.itemVector(for: item).map(\.bitPattern))
    }

    /// Checksums of everything the fixtures generate, pinned. They catch what the tests above
    /// cannot: a result that depends on the process (hash seeds, dictionary order, the clock)
    /// is identical twice in one process and different in the next.
    ///
    /// Update the constants when the fixtures change on purpose; the failure message prints the
    /// new values.
    func testPinnedChecksums() {
        let lexicon = TestSupport.checksum(FixtureLexicon.concepts.map { concept in
            ([concept.role.rawValue, concept.lemma] + concept.synonyms + [concept.italian, concept.german, concept.japanese]).joined(separator: "|")
        })
        let corpus = TestSupport.checksum(GoldenCorpus.items.map(TestSupport.fingerprint))
        let queries = TestSupport.checksum(GoldenSet.queries.map(TestSupport.fingerprint))
        let synthetic = TestSupport.checksum(SyntheticCorpus(seed: 42, count: 400).items.map(TestSupport.fingerprint))
        let words = TestSupport.checksum(stride(from: 0, to: 200_000, by: 997).map(SyntheticCorpus.pseudoWord(rank:)))
        func bits(_ vector: [Float]) -> [String] { vector.map { String($0.bitPattern, radix: 16) } }
        let narrow = TestSupport.checksum(bits(FakeEmbeddingProvider().vector(for: "Frozen harbor, porto ghiacciato, 凍った港 and zuvek")))
        let wide = TestSupport.checksum(bits(FakeEmbeddingProvider(dimensions: 384).itemVector(for: GoldenCorpus.items[0])))

        let actual = [
            "lexicon": lexicon, "corpus": corpus, "queries": queries, "synthetic": synthetic, "words": words,
            "narrow": narrow, "wide": wide,
        ]
        let pinned: [String: UInt64] = [
            "lexicon": 0xAFFF_3DB8_D913_1A8C,
            "corpus": 0xB1DE_8403_70F9_CA8B,
            "queries": 0x967C_367D_913E_23E8,
            "synthetic": 0x0E93_8402_8CF0_2626,
            "words": 0x8E39_85EB_DEA0_9A67,
            "narrow": 0xF7F5_C98E_2AD6_26AD,
            "wide": 0x3EC4_9644_9452_D7BA,
        ]
        let report = actual.keys.sorted().map { "\"\($0)\": \(TestSupport.hex(actual[$0] ?? 0))" }.joined(separator: ", ")
        XCTAssertEqual(actual, pinned, "checksums are now [\(report)]")
    }
}
