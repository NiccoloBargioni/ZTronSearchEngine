import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSemantic

final class HNSWIndexTests: XCTestCase {
    private let modelID = "test-model-v1"

    /// A small clustered corpus: 48 dimensions keep these tests fast.
    private func corpus(count: Int, dimensions: Int = 48, seed: UInt64 = 7) -> [(SearchableID, [Float])] {
        var shape = ClusteredCorpus.Shape.diffuse
        shape.clusterSize = 250
        shape.rank = 12
        let vectors = ClusteredCorpus(dimensions: dimensions, count: count, shape: shape, seed: seed).points(count: count, seed: seed &+ 1)
        return vectors.enumerated().map { (SearchableID("v\($0.offset)"), $0.element) }
    }

    /// Random directions: queries that belong to no topic of the corpus.
    private func queries(count: Int, dimensions: Int = 48, seed: UInt64 = 99) -> [[Float]] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { _ in generator.unitVector(dimensions) }
    }

    /// Fresh draws from the topics of `corpus(count:)`: queries like the stored vectors, but
    /// none of them stored.
    private func topicalQueries(count: Int, corpusCount: Int, dimensions: Int = 48, seed: UInt64 = 7) -> [[Float]] {
        var shape = ClusteredCorpus.Shape.diffuse
        shape.clusterSize = 250
        shape.rank = 12
        return ClusteredCorpus(dimensions: dimensions, count: corpusCount, shape: shape, seed: seed).points(count: count, seed: seed &+ 1_000)
    }

    private func build(_ entries: [(SearchableID, [Float])], dimensions: Int = 48, configuration: HNSWConfiguration = .default) async throws -> HNSWIndex {
        let store = try QuantizedVectorStore.build(from: entries, modelID: modelID, dimensions: dimensions)
        return try await HNSWIndex.build(over: store, configuration: configuration)
    }

    // MARK: Search

    func testResultsAreOrderedBestFirstAndAgreeWithTheExhaustiveSearch() async throws {
        let entries = corpus(count: 3_000)
        let index = try await build(entries)
        try await index.validateGraph()
        let count = await index.count
        XCTAssertEqual(count, 3_000)

        var agreement = 0
        for query in entries.prefix(60).map(\.1) + queries(count: 60) {
            let found = try await index.search(query, limit: 20)
            XCTAssertEqual(found.count, 20)
            XCTAssertEqual(found.map(\.similarity), found.map(\.similarity).sorted(by: >), "best first")
            XCTAssertEqual(Set(found.map(\.id)).count, 20, "no duplicates")
            for match in found { XCTAssertTrue((-1...1).contains(match.similarity)) }

            let exact = try await index.exhaustiveSearch(query, limit: 20)
            agreement += Set(found.prefix(10).map(\.id)).intersection(exact.prefix(10).map(\.id)).count
            // Whatever both return carries the same similarity: one kernel, one store.
            let exactSimilarity = Dictionary(uniqueKeysWithValues: exact.map { ($0.id, $0.similarity) })
            for match in found {
                if let reference = exactSimilarity[match.id] {
                    XCTAssertEqual(match.similarity, reference, accuracy: 1e-5)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(Double(agreement) / 1_200, 0.95)
    }

    func testAStoredVectorIsItsOwnNearestNeighbour() async throws {
        let entries = corpus(count: 1_500)
        let index = try await build(entries)
        for entry in entries.prefix(100) {
            let found = try await index.search(entry.1, limit: 1)
            XCTAssertEqual(found.first?.id, entry.0)
            XCTAssertEqual(found.first?.similarity ?? 0, 1, accuracy: 0.02)
        }
    }

    func testLimitsAndSmallIndexes() async throws {
        let query = queries(count: 1)[0]
        let empty = try HNSWIndex(modelID: modelID, dimensions: 48, quantization: .uniform(dimensions: 48))
        let nothing = try await empty.search(query)
        XCTAssertTrue(nothing.isEmpty)

        let entries = corpus(count: 9)
        for entry in entries {
            try await empty.insert(entry.0, vector: entry.1)
            let stored = await empty.count
            // A request for more than is stored returns everything, each exactly once.
            let found = try await empty.search(query, limit: 50)
            XCTAssertEqual(found.count, stored)
            XCTAssertEqual(Set(found.map(\.id)).count, stored)
        }
        let none = try await empty.search(query, limit: 0)
        XCTAssertTrue(none.isEmpty)
        let three = try await empty.search(query, limit: 3)
        XCTAssertEqual(three.count, 3)
        let exact = try await empty.exhaustiveSearch(query, limit: 3)
        XCTAssertEqual(three.map(\.id), exact.map(\.id))
        // The default is the specification's 50 neighbours.
        let large = try await build(corpus(count: 400))
        let byDefault = try await large.search(query)
        XCTAssertEqual(byDefault.count, 50)
    }

    func testTheClassicGreedyDescentIsAvailableAndStillAccurateInsideATopic() async throws {
        let entries = corpus(count: 3_000)
        let classic = try await build(entries, configuration: HNSWConfiguration(efEntry: 1))
        let wide = try await build(entries)
        var classicHits = 0
        var wideHits = 0
        for query in topicalQueries(count: 150, corpusCount: 3_000) {
            let exact = Set(try await wide.exhaustiveSearch(query, limit: 10).map(\.id))
            classicHits += Set(try await classic.search(query, limit: 10).map(\.id)).intersection(exact).count
            wideHits += Set(try await wide.search(query, limit: 10).map(\.id)).intersection(exact).count
        }
        XCTAssertGreaterThanOrEqual(Double(classicHits) / 1_500, 0.95)
        XCTAssertGreaterThanOrEqual(wideHits, classicHits)
        // The descent is a matter of search only: both indexes hold the same graph.
        let directory = try TemporaryDirectory()
        try await classic.write(graphTo: directory.file("classic.zthnsw"))
        try await wide.write(graphTo: directory.file("wide.zthnsw"))
        var classicBytes = try Data(contentsOf: directory.file("classic.zthnsw"))
        let wideBytes = try Data(contentsOf: directory.file("wide.zthnsw"))
        XCTAssertNotEqual(classicBytes, wideBytes)
        classicBytes.replaceSubrange(76..<80, with: [64, 0, 0, 0])
        XCTAssertEqual(classicBytes, wideBytes, "only the recorded efEntry differs")
    }

    func testAWiderSearchNeverFindsLess() async throws {
        let index = try await build(corpus(count: 3_000))
        var narrowHits = 0
        var wideHits = 0
        for query in queries(count: 100) {
            let exact = Set(try await index.exhaustiveSearch(query, limit: 10).map(\.id))
            narrowHits += Set(try await index.search(query, limit: 10, efSearch: 10).map(\.id)).intersection(exact).count
            wideHits += Set(try await index.search(query, limit: 10, efSearch: 400).map(\.id)).intersection(exact).count
        }
        XCTAssertGreaterThanOrEqual(wideHits, narrowHits)
        XCTAssertGreaterThanOrEqual(Double(wideHits) / 1_000, 0.99)
    }

    func testQueriesThatDoNotFitTheSpaceAreRefused() async throws {
        let index = try await build(corpus(count: 300))
        await assertThrowsAsync(.dimensionMismatch(expected: 48, found: 3)) { try await index.search([1, 0, 0]) }
        var broken = queries(count: 1)[0]
        broken[4] = .nan
        do {
            _ = try await index.search(broken)
            XCTFail("a query with a NaN must be refused")
        } catch let error as SemanticError {
            guard case .invalidVector = error else { return XCTFail("unexpected \(error)") }
        }
        await assertThrowsAsync(.dimensionMismatch(expected: 48, found: 2)) { try await index.insert("x", vector: [1, 0]) }
        let count = await index.count
        XCTAssertEqual(count, 300)
    }

    // MARK: Changes

    func testRemovedVectorsAreNeverReturnedAndStayRemoved() async throws {
        let entries = corpus(count: 2_000)
        let index = try await build(entries)
        let removed = Set(entries.indices.filter { $0 % 3 == 0 }.map { entries[$0].0 })
        for id in removed {
            let wasPresent = await index.remove(id)
            XCTAssertTrue(wasPresent)
        }
        let again = await index.remove(entries[0].0)
        XCTAssertFalse(again)
        let unknown = await index.remove("never-there")
        XCTAssertFalse(unknown)
        let count = await index.count
        let nodes = await index.nodeCount
        let tombstones = await index.tombstoneCount
        XCTAssertEqual(count, 2_000 - removed.count)
        XCTAssertEqual(nodes, 2_000)
        XCTAssertEqual(tombstones, removed.count)
        try await index.validateGraph()

        var agreement = 0
        for query in entries.prefix(80).map(\.1) {
            let found = try await index.search(query, limit: 20)
            XCTAssertEqual(found.count, 20)
            XCTAssertTrue(removed.isDisjoint(with: found.map(\.id)))
            let exact = try await index.exhaustiveSearch(query, limit: 10)
            XCTAssertTrue(removed.isDisjoint(with: exact.map(\.id)))
            agreement += Set(found.prefix(10).map(\.id)).intersection(exact.map(\.id)).count
        }
        // Tombstones remain waypoints, so the survivors are still found.
        XCTAssertGreaterThanOrEqual(Double(agreement) / 800, 0.95)
        // A removed vector, used as the query, no longer finds itself.
        let own = try await index.search(entries[0].1, limit: 5)
        XCTAssertFalse(own.contains { $0.id == entries[0].0 })
    }

    func testRemovingEverythingLeavesAnEmptyAnswerAndTheIndexUsable() async throws {
        let entries = corpus(count: 60)
        let index = try await build(entries)
        let removed = await index.remove(contentsOf: entries.map(\.0))
        XCTAssertEqual(removed.count, 60)
        let found = try await index.search(entries[0].1)
        XCTAssertTrue(found.isEmpty)
        try await index.insert("fresh", vector: entries[5].1)
        let after = try await index.search(entries[5].1)
        XCTAssertEqual(after.map(\.id), ["fresh"])
    }

    func testReplacingAVectorMovesItsItem() async throws {
        let entries = corpus(count: 1_200)
        let index = try await build(entries)
        let target = entries[10].0
        let destination = entries[700].1
        let before = try await index.search(destination, limit: 5)
        XCTAssertFalse(before.contains { $0.id == target })

        let changed = try await index.insert(target, vector: destination)
        XCTAssertTrue(changed)
        let after = try await index.search(destination, limit: 2)
        XCTAssertTrue(after.contains { $0.id == target })
        let old = try await index.search(entries[10].1, limit: 1)
        XCTAssertNotEqual(old.first?.id, target)
        let count = await index.count
        let tombstones = await index.tombstoneCount
        XCTAssertEqual(count, 1_200)
        XCTAssertEqual(tombstones, 1)

        // The same vector again changes nothing.
        let repeated = try await index.insert(target, vector: destination)
        XCTAssertFalse(repeated)
        let nodes = await index.nodeCount
        XCTAssertEqual(nodes, 1_201)
        try await index.validateGraph()
    }

    func testBulkInsertionIsAllOrNothingOnInvalidInput() async throws {
        let entries = corpus(count: 200)
        let index = try HNSWIndex(modelID: modelID, dimensions: 48, quantization: .uniform(dimensions: 48))
        var broken = entries
        broken[150].1 = [1, 2, 3]
        await assertThrowsAsync(.dimensionMismatch(expected: 48, found: 3)) { try await index.insert(contentsOf: broken) }
        let afterFailure = await index.count
        XCTAssertEqual(afterFailure, 0)

        let changed = try await index.insert(contentsOf: entries)
        XCTAssertEqual(changed, 200)
        let repeated = try await index.insert(contentsOf: entries)
        XCTAssertEqual(repeated, 0)
        let count = await index.count
        XCTAssertEqual(count, 200)
        let ids = await index.ids
        XCTAssertEqual(ids, entries.map(\.0))
    }

    func testCompactionDropsTombstonesAndKeepsTheAnswers() async throws {
        let entries = corpus(count: 1_500)
        let index = try await build(entries)
        await index.remove(contentsOf: entries.prefix(500).map(\.0))
        let compact = try await index.compacted()
        let nodes = await compact.nodeCount
        let tombstones = await compact.tombstoneCount
        let count = await compact.count
        XCTAssertEqual(nodes, 1_000)
        XCTAssertEqual(tombstones, 0)
        XCTAssertEqual(count, 1_000)
        try await compact.validateGraph()
        for query in queries(count: 30) {
            let before = try await index.exhaustiveSearch(query, limit: 10)
            let after = try await compact.exhaustiveSearch(query, limit: 10)
            XCTAssertEqual(before.map(\.id), after.map(\.id))
            let found = try await compact.search(query, limit: 10)
            XCTAssertGreaterThanOrEqual(Set(found.map(\.id)).intersection(after.map(\.id)).count, 8)
        }
    }

    func testReplacingEveryVectorKeepsTheIndexAccurate() async throws {
        let entries = corpus(count: 1_500)
        let index = try await build(entries)
        // Every item moves to the vector of another item, twice over: two thirds of the nodes
        // end up tombstoned.
        for round in 1...2 {
            let moved = entries.indices.map { (entries[$0].0, entries[($0 + 97 * round) % entries.count].1) }
            let changed = try await index.insert(contentsOf: moved)
            XCTAssertEqual(changed, 1_500)
        }
        let count = await index.count
        let nodes = await index.nodeCount
        let tombstones = await index.tombstoneCount
        XCTAssertEqual(count, 1_500)
        XCTAssertEqual(nodes, 4_500)
        XCTAssertEqual(tombstones, 3_000)
        try await index.validateGraph()

        var agreement = 0
        for query in queries(count: 80) {
            let exact = try await index.exhaustiveSearch(query, limit: 10)
            let found = try await index.search(query, limit: 10)
            XCTAssertEqual(found.count, 10)
            agreement += Set(found.map(\.id)).intersection(exact.map(\.id)).count
        }
        XCTAssertGreaterThanOrEqual(Double(agreement) / 800, 0.95)
        // Item 0 now sits where item 194 started.
        let moved = try await index.search(entries[194].1, limit: 3)
        XCTAssertTrue(moved.contains { $0.id == entries[0].0 })
    }

    func testAGraphBuiltOverAStoreWithTombstonesKeepsThemTombstoned() async throws {
        let entries = corpus(count: 800)
        var store = try QuantizedVectorStore.build(from: entries, modelID: modelID, dimensions: 48)
        for index in stride(from: 0, to: 800, by: 4) { store.remove(entries[index].0) }
        try store.upsert(entries[1].0, vector: entries[2].1)
        XCTAssertEqual(store.tombstoneCount, 201)

        // What happens when a vector file ships without its graph file.
        let index = try await HNSWIndex.build(over: store)
        let nodes = await index.nodeCount
        let tombstones = await index.tombstoneCount
        let count = await index.count
        XCTAssertEqual(nodes, store.count)
        XCTAssertEqual(tombstones, 201)
        XCTAssertEqual(count, 600)
        try await index.validateGraph()
        for query in entries.prefix(40).map(\.1) {
            let found = try await index.search(query, limit: 20)
            XCTAssertEqual(found.count, 20)
            for match in found {
                XCTAssertNotNil(store.ordinal(of: match.id), "'\(match.id)' was removed from the store")
            }
        }
    }

    func testKeepingPrunedConnectionsBuildsADenserValidGraph() async throws {
        let entries = corpus(count: 2_000)
        let sparse = try await build(entries, configuration: HNSWConfiguration(m: 8, efConstruction: 80))
        let dense = try await build(entries, configuration: HNSWConfiguration(m: 8, efConstruction: 80, keepsPrunedConnections: true))
        try await dense.validateGraph()
        var sparseLinks = 0
        var denseLinks = 0
        for node in 0..<2_000 {
            sparseLinks += await sparse.neighbours(ofRow: node, level: 0).count
            let neighbours = await dense.neighbours(ofRow: node, level: 0)
            XCTAssertLessThanOrEqual(neighbours.count, 16)
            XCTAssertEqual(Set(neighbours).count, neighbours.count)
            denseLinks += neighbours.count
        }
        XCTAssertGreaterThan(denseLinks, sparseLinks)

        // More links never hurt recall. Queries are fresh draws from the corpus's topics.
        var sparseHits = 0
        var denseHits = 0
        for query in topicalQueries(count: 200, corpusCount: 2_000) {
            let exact = try await dense.exhaustiveSearch(query, limit: 10)
            sparseHits += Set(try await sparse.search(query, limit: 10).map(\.id)).intersection(exact.map(\.id)).count
            denseHits += Set(try await dense.search(query, limit: 10).map(\.id)).intersection(exact.map(\.id)).count
        }
        XCTAssertGreaterThanOrEqual(denseHits, sparseHits - 20)
        XCTAssertGreaterThanOrEqual(Double(denseHits) / 2_000, 0.95)
    }

    // MARK: Determinism

    func testTheSameSeedGivesTheSameGraphAndTheSameAnswers() async throws {
        let entries = corpus(count: 1_500)
        let configuration = HNSWConfiguration(seed: 42)
        let first = try await build(entries, configuration: configuration)
        let second = try await build(entries, configuration: configuration)
        let directory = try TemporaryDirectory()
        try await first.write(graphTo: directory.file("first.zthnsw"))
        try await second.write(graphTo: directory.file("second.zthnsw"))
        XCTAssertEqual(try Data(contentsOf: directory.file("first.zthnsw")), try Data(contentsOf: directory.file("second.zthnsw")))
        for query in queries(count: 40) {
            let a = try await first.search(query, limit: 30)
            let b = try await second.search(query, limit: 30)
            XCTAssertEqual(a, b)
        }

        // Inserting one by one, instead of building over a store, is the same sequence of
        // operations and so the same graph.
        let incremental = try HNSWIndex(
            modelID: modelID, dimensions: 48, quantization: first.quantization, configuration: configuration
        )
        try await incremental.insert(contentsOf: entries)
        try await incremental.write(graphTo: directory.file("incremental.zthnsw"))
        XCTAssertEqual(try Data(contentsOf: directory.file("first.zthnsw")), try Data(contentsOf: directory.file("incremental.zthnsw")))

        // Another seed assigns other levels, hence another graph, that answers as well.
        let other = try await build(entries, configuration: HNSWConfiguration(seed: 43))
        try await other.write(graphTo: directory.file("other.zthnsw"))
        XCTAssertNotEqual(try Data(contentsOf: directory.file("first.zthnsw")), try Data(contentsOf: directory.file("other.zthnsw")))
        var agreement = 0
        for query in queries(count: 40) {
            let exact = try await other.exhaustiveSearch(query, limit: 10)
            agreement += Set(try await other.search(query, limit: 10).map(\.id)).intersection(exact.map(\.id)).count
        }
        XCTAssertGreaterThanOrEqual(Double(agreement) / 400, 0.95)
    }

    func testLevelsAreAGeometricDrawThatDependsOnlyOnSeedAndNode() {
        let configuration = HNSWConfiguration(m: 16, seed: 7)
        let levels = (0..<100_000).map { HNSWGraph.level(forNode: $0, configuration: configuration) }
        XCTAssertEqual(levels, (0..<100_000).map { HNSWGraph.level(forNode: $0, configuration: configuration) })
        // P(level >= k) = M^-k.
        let aboveBottom = Double(levels.filter { $0 >= 1 }.count) / 100_000
        let aboveFirst = Double(levels.filter { $0 >= 2 }.count) / 100_000
        XCTAssertEqual(aboveBottom, 1.0 / 16, accuracy: 0.005)
        XCTAssertEqual(aboveFirst, 1.0 / 256, accuracy: 0.002)
        XCTAssertLessThanOrEqual(levels.max() ?? 0, HNSWGraph.maximumLevel)

        let other = (0..<1_000).map { HNSWGraph.level(forNode: $0, configuration: HNSWConfiguration(m: 16, seed: 8)) }
        XCTAssertNotEqual(Array(levels.prefix(1_000)), other)
        // A smaller M makes taller graphs.
        let narrow = (0..<100_000).map { HNSWGraph.level(forNode: $0, configuration: HNSWConfiguration(m: 4, seed: 7)) }
        XCTAssertEqual(Double(narrow.filter { $0 >= 1 }.count) / 100_000, 0.25, accuracy: 0.01)
    }

    func testTheGraphKeepsItsInvariants() async throws {
        let entries = corpus(count: 2_500)
        let index = try await build(entries, configuration: HNSWConfiguration(m: 8, efConstruction: 60))
        try await index.validateGraph()
        var bottomLinks = 0
        for node in 0..<2_500 {
            let level = await index.level(ofRow: node)
            for layer in 0...level {
                let neighbours = await index.neighbours(ofRow: node, level: layer)
                XCTAssertLessThanOrEqual(neighbours.count, layer == 0 ? 16 : 8)
                if layer == 0 { bottomLinks += neighbours.count }
            }
        }
        // Every node but the first links to something on the bottom layer.
        XCTAssertGreaterThan(bottomLinks, 2_500 * 4)
    }

    func testConfigurationIsClampedToItsRanges() {
        let low = HNSWConfiguration(m: 0, efConstruction: 0, efSearch: 0, efEntry: 0)
        XCTAssertEqual(low.m, 2)
        XCTAssertEqual(low.efConstruction, 2)
        XCTAssertEqual(low.efSearch, 1)
        XCTAssertEqual(low.efEntry, 1)
        let high = HNSWConfiguration(m: 1_000, efConstruction: 1_000_000, efSearch: 1_000_000, efEntry: 1_000_000)
        XCTAssertEqual(high.m, 64)
        XCTAssertEqual(high.efConstruction, 4_096)
        XCTAssertEqual(high.efSearch, 4_096)
        XCTAssertEqual(high.efEntry, 4_096)
        XCTAssertEqual(HNSWConfiguration.default.m, 16)
        XCTAssertEqual(HNSWConfiguration.default.efSearch, 64)
        XCTAssertEqual(HNSWConfiguration.default.efEntry, 64)
        XCTAssertEqual(HNSWConfiguration.default.efConstruction, 200)
        XCTAssertEqual(HNSWConfiguration.defaultNeighbourCount, 50)
    }

    // MARK: Persistence

    func testPersistenceRoundTripGivesIdenticalResultsWithoutRebuilding() async throws {
        let entries = corpus(count: 3_000)
        let index = try await build(entries)
        // Persist a state that has seen every kind of change.
        await index.remove(contentsOf: entries[100..<160].map(\.0))
        try await index.insert(entries[5].0, vector: entries[900].1)
        try await index.insert("added", vector: entries[901].1)

        let directory = try TemporaryDirectory()
        let vectorsURL = directory.file("vectors.ztvec")
        let graphURL = directory.file("vectors.zthnsw")
        try await index.write(vectorsTo: vectorsURL, graphTo: graphURL)

        let store = try QuantizedVectorStore.open(vectorsURL, expecting: .init(modelID: modelID, dimensions: 48))
        let loaded = try HNSWIndex(store: store, graphAt: graphURL)
        let isMapped = await loaded.isGraphMapped
        XCTAssertTrue(isMapped, "the links are used in place from the mapped file")
        try await loaded.validateGraph()
        let loadedCount = await loaded.count
        let originalCount = await index.count
        XCTAssertEqual(loadedCount, originalCount)
        let loadedTombstones = await loaded.tombstoneCount
        XCTAssertEqual(loadedTombstones, 61)
        XCTAssertEqual(loaded.configuration, index.configuration)
        let loadedFingerprint = await loaded.storeFingerprint
        let originalFingerprint = await index.storeFingerprint
        XCTAssertEqual(loadedFingerprint, originalFingerprint)
        XCTAssertEqual(loadedFingerprint, store.fingerprint)

        let probes = entries.prefix(60).map(\.1) + queries(count: 60)
        for query in probes {
            let original = try await index.search(query, limit: 50)
            let restored = try await loaded.search(query, limit: 50)
            XCTAssertEqual(original, restored)
        }
        var stillMapped = await loaded.isGraphMapped
        XCTAssertTrue(stillMapped, "searching does not copy the links")
        // Neither does storing vectors the index already holds: core repeats its upserts on
        // every rebuild, and that must not cost a copy of the graph.
        let repeats = await loaded.vectors(for: Array(entries[200..<260].map(\.0)))
        let changed = try await loaded.insert(contentsOf: repeats)
        XCTAssertEqual(changed, 0)
        stillMapped = await loaded.isGraphMapped
        XCTAssertTrue(stillMapped, "an upsert that changes nothing does not copy the links")
        // Nor does a removal: tombstones live beside the links.
        let removedLater = await loaded.remove(entries[300].0)
        let removedOriginal = await index.remove(entries[300].0)
        XCTAssertTrue(removedLater && removedOriginal)
        stillMapped = await loaded.isGraphMapped
        XCTAssertTrue(stillMapped)

        // A change copies the links into memory, once, and both indexes keep agreeing.
        var generator = SeededGenerator(seed: 5)
        for step in 0..<40 {
            let vector = generator.unitVector(48)
            try await index.insert(SearchableID("late-\(step)"), vector: vector)
            try await loaded.insert(SearchableID("late-\(step)"), vector: vector)
        }
        let afterChange = await loaded.isGraphMapped
        XCTAssertFalse(afterChange)
        try await loaded.validateGraph()
        for query in probes.prefix(40) {
            let original = try await index.search(query, limit: 50)
            let restored = try await loaded.search(query, limit: 50)
            XCTAssertEqual(original, restored)
        }
    }

    func testAGraphWrittenAloneAttachesToItsStore() async throws {
        let entries = corpus(count: 500)
        let store = try QuantizedVectorStore.build(from: entries, modelID: modelID, dimensions: 48)
        let index = try await HNSWIndex.build(over: store)
        let directory = try TemporaryDirectory()
        try await index.write(graphTo: directory.file("graph.zthnsw"))
        // The two breadths of a search can be overridden when the file is attached; what the
        // graph was built with cannot.
        let loaded = try HNSWIndex(store: store, graphAt: directory.file("graph.zthnsw"), efSearch: 128)
        XCTAssertEqual(loaded.configuration.efSearch, 128)
        XCTAssertEqual(loaded.configuration.efEntry, 64)
        XCTAssertEqual(loaded.configuration.m, 16)
        let query = queries(count: 1)[0]
        let a = try await index.search(query, limit: 10, efSearch: 128)
        let b = try await loaded.search(query, limit: 10)
        XCTAssertEqual(a, b)
        let classic = try HNSWIndex(store: store, graphAt: directory.file("graph.zthnsw"), efEntry: 1)
        XCTAssertEqual(classic.configuration.efEntry, 1)
        XCTAssertEqual(classic.configuration.efSearch, 64)
        XCTAssertEqual(classic.configuration.efConstruction, 200)
    }

    func testAGraphFileOfAnotherStoreIsRefused() async throws {
        let entries = corpus(count: 400)
        let store = try QuantizedVectorStore.build(from: entries, modelID: modelID, dimensions: 48)
        let directory = try TemporaryDirectory()
        let graphURL = directory.file("graph.zthnsw")
        try await HNSWIndex.build(over: store).write(graphTo: graphURL)

        // Same vectors under another model id.
        let otherModel = try QuantizedVectorStore.build(from: entries, modelID: "another-model", dimensions: 48, quantization: store.quantization)
        assertThrows(.modelMismatch(expected: "another-model", found: modelID)) { try HNSWIndex(store: otherModel, graphAt: graphURL) }

        // Another dimension count.
        let narrow = try QuantizedVectorStore.build(from: corpus(count: 400, dimensions: 24), modelID: modelID, dimensions: 24)
        assertThrows(.dimensionMismatch(expected: 24, found: 48)) { try HNSWIndex(store: narrow, graphAt: graphURL) }

        // Fewer rows.
        let shorter = try QuantizedVectorStore.build(from: Array(entries.dropLast()), modelID: modelID, dimensions: 48, quantization: store.quantization)
        XCTAssertThrowsError(try HNSWIndex(store: shorter, graphAt: graphURL)) { error in
            guard case SemanticError.graphStoreMismatch = error else { return XCTFail("unexpected \(error)") }
        }

        // As many rows, other vectors.
        var changed = store
        try changed.upsert(entries[3].0, vector: entries[4].1)
        changed.remove(entries[9].0)
        try changed.upsert("extra", vector: entries[5].1)
        XCTAssertEqual(changed.count, store.count + 2)
        var same = entries
        same[7].1 = entries[8].1
        let altered = try QuantizedVectorStore.build(from: same, modelID: modelID, dimensions: 48, quantization: store.quantization)
        XCTAssertEqual(altered.count, store.count)
        XCTAssertThrowsError(try HNSWIndex(store: altered, graphAt: graphURL)) { error in
            guard case SemanticError.graphStoreMismatch = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertNoThrow(try HNSWIndex(store: store, graphAt: graphURL))
    }

    func testDamagedGraphFilesAreRefusedWithoutTrapping() async throws {
        let entries = corpus(count: 300)
        let store = try QuantizedVectorStore.build(from: entries, modelID: modelID, dimensions: 48)
        let directory = try TemporaryDirectory()
        let graphURL = directory.file("graph.zthnsw")
        try await HNSWIndex.build(over: store).write(graphTo: graphURL)
        let good = try Data(contentsOf: graphURL)

        func attach(_ data: Data) throws -> HNSWIndex {
            let url = directory.file("damaged-\(UUID().uuidString).zthnsw")
            try data.write(to: url)
            return try HNSWIndex(store: store, graphAt: url)
        }
        func assertCorrupt(_ data: Data, _ message: String, line: UInt = #line) {
            XCTAssertThrowsError(try attach(data), message, line: line) { error in
                guard case SemanticError.corruptFile = error else { return XCTFail("\(message): unexpected \(error)", line: line) }
            }
        }
        assertCorrupt(Data(), "empty file")
        assertCorrupt(good.prefix(40), "truncated header")
        assertCorrupt(good.prefix(good.count - 8), "truncated links")
        assertCorrupt(good + Data(count: 8), "trailing bytes")
        var wrongMagic = good
        wrongMagic[3] = UInt8(ascii: "X")
        assertCorrupt(wrongMagic, "wrong magic")
        var wrongM = good
        wrongM.replaceSubrange(12..<16, with: [200, 0, 0, 0])
        assertCorrupt(wrongM, "M out of range")
        var wrongEntry = good
        wrongEntry.replaceSubrange(56..<60, with: [0xFF, 0xFF, 0xFF, 0x7F])
        assertCorrupt(wrongEntry, "entry point out of range")
        var wrongBreadth = good
        wrongBreadth.replaceSubrange(76..<80, with: [0, 0, 0, 0])
        assertCorrupt(wrongBreadth, "efEntry out of range")
        var future = good
        future[4] = 9
        assertThrows(.unsupportedFormatVersion(found: 9, supported: 1)) { try attach(future) }
        XCTAssertThrowsError(try HNSWIndex(store: store, graphAt: directory.file("missing.zthnsw"))) { error in
            guard case SemanticError.io = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testALinkToANodeThatDoesNotExistFailsTheSearchInsteadOfReadingOutOfBounds() async throws {
        let entries = corpus(count: 300)
        let store = try QuantizedVectorStore.build(from: entries, modelID: modelID, dimensions: 48)
        let directory = try TemporaryDirectory()
        let graphURL = directory.file("graph.zthnsw")
        try await HNSWIndex.build(over: store).write(graphTo: graphURL)
        var data = try Data(contentsOf: graphURL)

        // Header (80 bytes), model id, levels and tombstones, each padded to 8 bytes; then the
        // bottom layer: 33 slots per node, the first of which is the count.
        func padded(_ count: Int) -> Int { (count + 7) / 8 * 8 }
        let bottomStart = 80 + padded(modelID.utf8.count) + padded(300) + padded(300 / 64 * 8 + 8)
        for node in 0..<300 {
            let firstNeighbour = bottomStart + node * 33 * 4 + 4
            data.replaceSubrange(firstNeighbour..<(firstNeighbour + 4), with: [0xFF, 0xFF, 0xFF, 0xFF])
        }
        let damagedURL = directory.file("wild.zthnsw")
        try data.write(to: damagedURL)

        // The header is intact, so the file attaches; the damage shows when a search walks it.
        let index = try HNSWIndex(store: store, graphAt: damagedURL)
        do {
            _ = try await index.search(entries[0].1)
            XCTFail("the search must fail")
        } catch let error as SemanticError {
            guard case .corruptFile = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: Cancellation

    func testASearchOnACancelledTaskThrowsAtOnce() async throws {
        let entries = corpus(count: 2_000)
        let index = try await build(entries)
        let query = entries[0].1
        let task = Task { () -> Double in
            withUnsafeCurrentTask { $0?.cancel() }
            let start = monotonicSeconds()
            do {
                _ = try await index.search(query, limit: 50, efSearch: 4_096)
                XCTFail("a cancelled search must throw")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("unexpected \(error)")
            }
            return monotonicSeconds() - start
        }
        let elapsed = await task.value
        // The specification asks for 10 ms from the next checkpoint; the bound here leaves room
        // for a busy machine to schedule the actor.
        XCTAssertLessThan(elapsed, 0.050)
        // The index is unharmed.
        let found = try await index.search(query, limit: 5)
        XCTAssertEqual(found.first?.id, entries[0].0)
    }

    /// The checkpoint inside the traversal, without the check on entry: a search that visits
    /// fewer than 64 nodes completes even on a cancelled task, a longer one is stopped.
    func testTheTraversalChecksCancellationEvery64NodeVisits() async throws {
        func search(nodes: Int) async -> Result<Int, Error> {
            let entries = corpus(count: nodes)
            let task = Task { () -> Result<Int, Error> in
                Result {
                    let store = try QuantizedVectorStore.build(from: entries, modelID: "m", dimensions: 48)
                    var graph = HNSWGraph(configuration: .default)
                    var workspace = HNSWWorkspace(dimensions: 48, width0: graph.width0)
                    try store.withRows { rows in
                        for _ in 0..<nodes {
                            try graph.insert(rows: rows, quantization: store.quantization, workspace: &workspace)
                        }
                    }
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try store.withRows { rows in
                        try entries[0].1.withUnsafeBufferPointer { query in
                            try graph.search(
                                query: query.baseAddress!, limit: 10, ef: 64,
                                rows: rows, quantization: store.quantization, workspace: &workspace
                            ).count
                        }
                    }
                }
            }
            return await task.value
        }

        // 40 nodes: at most 40 visits, the checkpoint is never reached.
        let small = await search(nodes: 40)
        XCTAssertEqual(try small.get(), 10)
        // 2,000 nodes: hundreds of visits.
        let large = await search(nodes: 2_000)
        XCTAssertThrowsError(try large.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testCancellingABuildStopsItBetweenTwoInsertions() async throws {
        let entries = corpus(count: 12_000)
        let store = try QuantizedVectorStore.build(from: entries, modelID: modelID, dimensions: 48)
        let started = monotonicSeconds()
        let task = Task { try await HNSWIndex.build(over: store) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("the build should have been cancelled long before it finished")
        } catch is CancellationError {
            // Expected.
        }
        // A whole build takes far longer than this; the bound leaves room for a busy machine.
        XCTAssertLessThan(monotonicSeconds() - started, 2)
    }
}
