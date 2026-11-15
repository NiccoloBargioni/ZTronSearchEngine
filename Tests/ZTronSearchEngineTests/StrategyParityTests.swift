import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// Section 16, search contexts: "Scan and indexed strategies rank the same documents identically
/// (property test over random corpora up to 500 documents)"; and section 9, snapshot rule 9:
/// "Indexing is incremental: upsert and remove take effect for the next query without a rebuild".
final class StrategyParityTests: XCTestCase {
    private func service(_ items: [AnySearchable<CatalogKind>], strategy: SearchStrategy, locale: String, secondary: SecondaryLanguages) -> CatalogService {
        CatalogService(
            context: SearchContext(id: SearchContextID(strategy == .scan ? "scan" : "indexed"), sources: [.memory(items)], strategy: strategy, indexStorage: .inMemory),
            configuration: TestSupport.configuration(locale: locale, secondary: secondary)
        )
    }

    func testScanAndIndexedRankIdentically() async {
        var compared = 0
        var nonEmpty = 0
        for seed in 0..<36 {
            var corpus = RandomCorpus(seed: UInt64(seed))
            let size = [1, 7, 40, 120, 333, 500][seed % 6]
            let items = corpus.items(size)
            let locale = ["en", "it", "ja"][seed % 3]
            let secondary: SecondaryLanguages = seed % 2 == 0 ? .none : .explicit(["de", "ja"])
            let scan = service(items, strategy: .scan, locale: locale, secondary: secondary)
            let indexed = service(items, strategy: .indexed, locale: locale, secondary: secondary)
            let scanUsesScan = await scan.usesScanStrategy
            let indexedUsesScan = await indexed.usesScanStrategy
            XCTAssertTrue(scanUsesScan)
            XCTAssertFalse(indexedUsesScan)

            for _ in 0..<40 {
                let query = corpus.query()
                let lhs = RankingFingerprint(await TestSupport.final(scan, query))
                let rhs = RankingFingerprint(await TestSupport.final(indexed, query))
                XCTAssertEqual(lhs, rhs, "seed \(seed), \(size) documents, query '\(query.text)' tokens \(query.tokens)\n scan:    \(lhs)\n indexed: \(rhs)")
                compared += 1
                if !lhs.ids.isEmpty { nonEmpty += 1 }
            }
        }
        // The property is only worth something if most queries actually return hits.
        XCTAssertGreaterThan(Double(nonEmpty) / Double(compared), 0.6, "\(nonEmpty) of \(compared) queries returned hits")
    }

    /// After any sequence of upserts and removals the index answers exactly like one built from
    /// the live documents alone: same ids, same scores.
    func testIncrementalIndexingEqualsAFreshIndex() async {
        for seed in 100..<112 {
            var corpus = RandomCorpus(seed: UInt64(seed))
            let incremental = CatalogService(index: LexicalIndex(), configuration: TestSupport.configuration())
            var live: [String: AnySearchable<CatalogKind>] = [:]
            var nextID = 0

            for step in 0..<30 {
                switch corpus.random.int(0..<10) {
                case 0..<5:
                    // New documents, in batches from one to a few hundred.
                    let count = [1, 1, 2, 5, 17, 64, 200][corpus.random.int(0..<7)]
                    var batch: [AnySearchable<CatalogKind>] = []
                    for _ in 0..<count {
                        let id = "doc-\(nextID)"
                        nextID += 1
                        let item = corpus.item(id: id)
                        batch.append(item)
                        live[id] = item
                    }
                    await incremental.index(batch)
                case 5..<8:
                    // Replace existing documents with new content under the same ids.
                    let ids = Array(live.keys.sorted().shuffled(using: &corpus.random).prefix(corpus.random.int(1..<40)))
                    var batch: [AnySearchable<CatalogKind>] = []
                    for id in ids {
                        let item = corpus.item(id: id)
                        batch.append(item)
                        live[id] = item
                    }
                    await incremental.index(batch)
                default:
                    let ids = Array(live.keys.sorted().shuffled(using: &corpus.random).prefix(corpus.random.int(1..<60)))
                    for id in ids { live[id] = nil }
                    await incremental.remove(ids.map { SearchableID($0) })
                }

                guard step % 5 == 4 else { continue }
                let fresh = await TestSupport.indexedService(live.keys.sorted().compactMap { live[$0] })
                let incrementalCount = await incremental.count
                XCTAssertEqual(incrementalCount, live.count, "seed \(seed) step \(step)")
                for _ in 0..<25 {
                    let query = corpus.query()
                    let lhs = RankingFingerprint(await TestSupport.final(incremental, query))
                    let rhs = RankingFingerprint(await TestSupport.final(fresh, query))
                    XCTAssertEqual(lhs, rhs, "seed \(seed) step \(step), \(live.count) live, query '\(query.text)' tokens \(query.tokens)\n incremental: \(lhs)\n fresh:       \(rhs)")
                }
            }
        }
    }

    /// The same documents persisted and memory-mapped again answer identically.
    func testPersistedIndexAnswersLikeTheOneInMemory() async throws {
        var corpus = RandomCorpus(seed: 7)
        let items = corpus.items(400)
        let index = LexicalIndex()
        let original = CatalogService(index: index, configuration: TestSupport.configuration())
        await original.index(Array(items.prefix(250)))
        await original.index(Array(items.suffix(150)))
        await original.remove((0..<30).map { SearchableID("doc-\($0)") })
        var queries: [CatalogQuery] = []
        var before: [RankingFingerprint] = []
        for _ in 0..<40 {
            let query = corpus.query()
            queries.append(query)
            before.append(RankingFingerprint(await TestSupport.final(original, query)))
        }

        let directory = TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.ztsi")
        try await index.save(to: url)
        let segments = await index.segmentCount
        XCTAssertEqual(segments, 1, "saving compacts to one segment")

        let reloaded = LexicalIndex()
        try await reloaded.load(from: url)
        let reloadedCount = await reloaded.count
        XCTAssertEqual(reloadedCount, 370)
        let restored = CatalogService(index: reloaded, configuration: TestSupport.configuration())
        for (query, expected) in zip(queries, before) {
            let after = RankingFingerprint(await TestSupport.final(restored, query))
            XCTAssertEqual(after, expected, "query '\(query.text)'")
            // The service that saved now reads from the mapped file too.
            let stillSame = RankingFingerprint(await TestSupport.final(original, query))
            XCTAssertEqual(stillSame, expected, "query '\(query.text)' after save")
        }
    }

    func testVersionMismatchDiscardsTheFile() async throws {
        let directory = TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.ztsi")
        let index = LexicalIndex()
        await index.upsert([SearchDocument(id: "a", kind: "tool", text: "hello world")])
        try await index.save(to: url)

        // A file written by another projection version: byte 8 of the header is the version.
        var bytes = try Data(contentsOf: url)
        bytes[8] = bytes[8] &+ 1
        try bytes.write(to: url)

        let other = LexicalIndex()
        do {
            try await other.load(from: url)
            XCTFail("a mismatching file must not load")
        } catch let error as SearchError {
            guard case .versionMismatch = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "any mismatch discards the file")
        let count = await other.count
        XCTAssertEqual(count, 0)
    }

    func testMetadataMismatchDiscardsTheFile() async throws {
        let directory = TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.ztsi")
        let index = LexicalIndex()
        await index.setMetadata(IndexMetadata(localeTag: "en", embeddingModelID: "model-a"))
        await index.upsert([SearchDocument(id: "a", kind: "tool", text: "hello world")])
        try await index.save(to: url)

        for expected in [
            IndexMetadata(localeTag: "en", embeddingModelID: "model-b"),   // another embedding model
            IndexMetadata(localeTag: "it", embeddingModelID: "model-a"),   // another locale
        ] {
            try await index.save(to: url)
            do {
                try await LexicalIndex().load(from: url, expecting: expected)
                XCTFail("a mismatching file must not load")
            } catch let error as SearchError {
                guard case .versionMismatch = error else { return XCTFail("unexpected error \(error)") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        try await index.save(to: url)
        try await LexicalIndex().load(from: url, expecting: IndexMetadata(localeTag: "en", embeddingModelID: "model-a"))
    }

    func testCorruptFileIsRejected() async throws {
        let directory = TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("garbage.ztsi")
        try Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
        do {
            try await LexicalIndex().load(from: url)
            XCTFail("garbage must not load")
        } catch is SearchError {
            // expected
        }
    }
}
