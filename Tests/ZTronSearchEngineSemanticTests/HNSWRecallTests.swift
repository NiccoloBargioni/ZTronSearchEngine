import Accelerate
import XCTest
import ZTronSearchEngine
import ZTronSearchFixtures
@testable import ZTronSearchEngineSemantic

/// The acceptance gate of the ANN stage (specification sections 15.1 and 16): recall@10 of at
/// least 0.95 against brute force on 1,000 sampled queries, with M = 16, efSearch = 64, top 50.
///
/// Recall is measured twice. Against the exhaustive search of the same INT8 store it isolates
/// the graph, which is what the specification asks. Against the exhaustive search of the
/// original `Float` vectors it also charges the index for what quantization loses, which is
/// what a user sees. Both must clear the gate.
final class HNSWRecallTests: XCTestCase {
    struct Measurement {
        var recallAgainstStore = 0.0
        var recallAgainstFloat = 0.0
        /// Exhaustive INT8 against exhaustive `Float`: what quantization alone costs.
        var quantizationRecall = 0.0
        var intrinsicDimension = 0.0
        var buildSeconds = 0.0
        /// Searches run back to back: the index stays in the processor's caches.
        var warmP50 = 0.0
        var warmP95 = 0.0
        /// Searches separated by scans of the whole corpus, which evict the index from the
        /// caches: closer to a query typed after a pause.
        var coldP50 = 0.0
        var coldP95 = 0.0
        var vectorFileBytes = 0
        var graphFileBytes = 0
    }

    private var isLargeRunRequested: Bool {
        ProcessInfo.processInfo.environment["ZTRON_SEMANTIC_LARGE"] == "1"
    }

    func testRecallAt10On20kDiffuseTopics() async throws {
        let measurement = try await measure(count: 20_000, shape: .diffuse)
        XCTAssertGreaterThanOrEqual(measurement.recallAgainstStore, 0.95)
        XCTAssertGreaterThanOrEqual(measurement.recallAgainstFloat, 0.95)
    }

    func testRecallAt10On20kTightTopics() async throws {
        let measurement = try await measure(count: 20_000, shape: .tight)
        XCTAssertGreaterThanOrEqual(measurement.recallAgainstStore, 0.95)
        XCTAssertGreaterThanOrEqual(measurement.recallAgainstFloat, 0.95)
    }

    /// The reference corpus size of the specification. A debug build needs about two minutes
    /// per corpus, so these run on request: `ZTRON_SEMANTIC_LARGE=1 swift test -c release`.
    func testRecallAt10On100kDiffuseTopics() async throws {
        try XCTSkipUnless(isLargeRunRequested, "set ZTRON_SEMANTIC_LARGE=1 to run")
        let measurement = try await measure(count: 100_000, shape: .diffuse)
        XCTAssertGreaterThanOrEqual(measurement.recallAgainstStore, 0.95)
        XCTAssertGreaterThanOrEqual(measurement.recallAgainstFloat, 0.95)
        // Specification section 15.2: 40 MB of vectors, 20 MB of graph.
        XCTAssertLessThanOrEqual(measurement.vectorFileBytes, 40 * 1_048_576)
        XCTAssertLessThanOrEqual(measurement.graphFileBytes, 20 * 1_048_576)
    }

    func testRecallAt10On100kTightTopics() async throws {
        try XCTSkipUnless(isLargeRunRequested, "set ZTRON_SEMANTIC_LARGE=1 to run")
        let measurement = try await measure(count: 100_000, shape: .tight)
        XCTAssertGreaterThanOrEqual(measurement.recallAgainstStore, 0.95)
        XCTAssertGreaterThanOrEqual(measurement.recallAgainstFloat, 0.95)
    }

    /// A query between two topics has its nearest neighbours in both. The classic search enters
    /// the bottom layer at one node, finds the neighbours of one topic and misses the other's;
    /// the descent with several entry points (``HNSWConfiguration/efEntry``) finds both.
    func testQueriesBetweenTwoTopicsAreAnsweredThroughSeveralEntryPoints() async throws {
        let dimensions = 384
        let count = 20_000
        let corpus = ClusteredCorpus(dimensions: dimensions, count: count, shape: .diffuse, seed: 0xC0FFEE)
        var entries: [(SearchableID, [Float])] = []
        for (index, vector) in corpus.points(count: count, seed: 1).enumerated() {
            entries.append((SearchableID("v\(index)"), vector))
        }
        // The normalized sum of two fresh points of different topics.
        let fresh = corpus.points(count: 1_000, seed: 4)
        var queries: [[Float]] = []
        for index in 0..<500 {
            var sum = fresh[index]
            let partner = fresh[500 + (index * 7 + 3) % 500]
            vDSP_vadd(sum, 1, partner, 1, &sum, 1, vDSP_Length(dimensions))
            VectorKernels.normalize(&sum)
            queries.append(sum)
        }

        let store = try QuantizedVectorStore.build(from: entries, modelID: "synthetic", dimensions: dimensions)
        entries.removeAll()
        let index = try await HNSWIndex.build(over: store)
        XCTAssertEqual(index.configuration.efEntry, 64)
        // The same graph, searched the classic way.
        let directory = try TemporaryDirectory()
        try await index.write(graphTo: directory.file("graph.zthnsw"))
        let classic = try HNSWIndex(store: store, graphAt: directory.file("graph.zthnsw"), efEntry: 1)

        var hits = 0
        var classicHits = 0
        for query in queries {
            let exact = Set(try await index.exhaustiveSearch(query, limit: 10).map(\.id))
            hits += Set(try await index.search(query, limit: 50).prefix(10).map(\.id)).intersection(exact).count
            classicHits += Set(try await classic.search(query, limit: 50).prefix(10).map(\.id)).intersection(exact).count
        }
        let recall = Double(hits) / Double(queries.count * 10)
        let classicRecall = Double(classicHits) / Double(queries.count * 10)
        print(String(
            format: "HNSW gate | queries between two topics, diffuse topics %d x %d, %d queries, efSearch=64 top-50 | "
                + "recall@10 vs INT8 brute force %.4f with efEntry=64, %.4f with the classic greedy descent (efEntry=1)",
            count, dimensions, queries.count, recall, classicRecall
        ))
        XCTAssertGreaterThanOrEqual(recall, 0.90)
        XCTAssertGreaterThan(recall, classicRecall + 0.10)
    }

    /// Not a gate: isotropic Gaussian topics have an intrinsic dimension no embedding model
    /// produces. The run documents how recall falls with intrinsic dimension at the
    /// specification's fixed `efSearch`, and that a wider search recovers it.
    func testRecallOnIsotropicTopicsIsReportedAndRecoversWithBreadth() async throws {
        try XCTSkipUnless(isLargeRunRequested, "set ZTRON_SEMANTIC_LARGE=1 to run")
        let narrow = try await measure(count: 20_000, shape: .isotropic)
        let wide = try await measure(count: 20_000, shape: .isotropic, efSearch: 256)
        XCTAssertGreaterThan(narrow.intrinsicDimension, 60)
        XCTAssertGreaterThan(wide.recallAgainstStore, narrow.recallAgainstStore)
        XCTAssertGreaterThanOrEqual(wide.recallAgainstStore, 0.95)
    }

    private func measure(
        count: Int,
        shape: ClusteredCorpus.Shape,
        queryCount: Int = 1_000,
        efSearch: Int? = nil
    ) async throws -> Measurement {
        let dimensions = 384
        let configuration = HNSWConfiguration.default
        let corpus = ClusteredCorpus(dimensions: dimensions, count: count, shape: shape, seed: 0xC0FFEE)
        let vectors = corpus.points(count: count, seed: 1)
        // Queries are fresh draws from the same topics, never stored vectors.
        let queries = corpus.points(count: queryCount, seed: 2)

        var entries: [(SearchableID, [Float])] = []
        entries.reserveCapacity(count)
        for (index, vector) in vectors.enumerated() { entries.append((SearchableID("v\(index)"), vector)) }
        let store = try QuantizedVectorStore.build(from: entries, modelID: "synthetic", dimensions: dimensions)
        entries.removeAll()

        var measurement = Measurement()
        let buildStart = monotonicSeconds()
        let index = try await HNSWIndex.build(over: store, configuration: configuration)
        measurement.buildSeconds = monotonicSeconds() - buildStart
        try await index.validateGraph()

        // Exact answers over the original floats: one matrix-vector product per query.
        var matrix = [Float](repeating: 0, count: count * dimensions)
        matrix.withUnsafeMutableBufferPointer { buffer in
            for (row, vector) in vectors.enumerated() {
                vector.withUnsafeBufferPointer { source in
                    (buffer.baseAddress! + row * dimensions).update(from: source.baseAddress!, count: dimensions)
                }
            }
        }
        var scores = [Float](repeating: 0, count: count)

        // Latency, searches back to back.
        var warm: [Double] = []
        warm.reserveCapacity(queryCount)
        for query in queries {
            let start = monotonicSeconds()
            _ = try await index.search(query, limit: 50, efSearch: efSearch)
            warm.append(monotonicSeconds() - start)
        }

        // Recall, and latency again: the two exhaustive scans between searches empty the caches.
        var latencies: [Double] = []
        latencies.reserveCapacity(queryCount)
        var hitsAgainstStore = 0
        var hitsAgainstFloat = 0
        var hitsQuantization = 0
        var intrinsicDimension = 0.0
        for query in queries {
            let start = monotonicSeconds()
            let found = try await index.search(query, limit: 50, efSearch: efSearch)
            latencies.append(monotonicSeconds() - start)
            XCTAssertEqual(found.count, 50)
            let approximate = Set(found.prefix(10).map(\.id))

            let exactStore = Set(try await index.exhaustiveSearch(query, limit: 10).map(\.id))

            vDSP_mmul(matrix, 1, query, 1, &scores, 1, vDSP_Length(count), 1, vDSP_Length(dimensions))
            var best = TopMatches(limit: 20)
            scores.withUnsafeBufferPointer { buffer in
                for row in 0..<count where best.accepts(buffer[row]) {
                    best.insert(ordinal: row, similarity: buffer[row])
                }
            }
            let nearest = best.sorted()
            let exactFloat = Set(nearest.prefix(10).map { SearchableID("v\($0.ordinal)") })

            // Levina-Bickel maximum-likelihood estimate from the 20 exact neighbours.
            let radii = nearest.map { Double(max(1e-9, 2 - 2 * $0.similarity)).squareRoot() }
            var logSum = 0.0
            for radius in radii.dropLast() { logSum += log(radii[radii.count - 1] / radius) }
            intrinsicDimension += Double(radii.count - 1) / max(logSum, 1e-9)

            hitsAgainstStore += approximate.intersection(exactStore).count
            hitsAgainstFloat += approximate.intersection(exactFloat).count
            hitsQuantization += exactStore.intersection(exactFloat).count
        }
        measurement.recallAgainstStore = Double(hitsAgainstStore) / Double(queryCount * 10)
        measurement.recallAgainstFloat = Double(hitsAgainstFloat) / Double(queryCount * 10)
        measurement.quantizationRecall = Double(hitsQuantization) / Double(queryCount * 10)
        measurement.intrinsicDimension = intrinsicDimension / Double(queryCount)
        measurement.warmP50 = quantile(warm, 0.50)
        measurement.warmP95 = quantile(warm, 0.95)
        measurement.coldP50 = quantile(latencies, 0.50)
        measurement.coldP95 = quantile(latencies, 0.95)
        // The specification allows the reference device 5 ms at 100,000 vectors (p95). Off that
        // device the budget is divided by how much slower the device is: necessary for the
        // gate, not sufficient. A debug build is given the unscaled budget.
        #if DEBUG
        let allowed = PerformanceBudget.nearestNeighbours
        #else
        let allowed = ReferenceDevice.scaled(PerformanceBudget.nearestNeighbours)
        #endif
        XCTAssertLessThan(measurement.coldP95, allowed, "top-50 search, cache-cold p95")

        let directory = try TemporaryDirectory()
        let vectorsURL = directory.file("vectors.ztvec")
        let graphURL = directory.file("vectors.zthnsw")
        try await index.write(vectorsTo: vectorsURL, graphTo: graphURL)
        measurement.vectorFileBytes = (try FileManager.default.attributesOfItem(atPath: vectorsURL.path)[.size] as? NSNumber)?.intValue ?? 0
        measurement.graphFileBytes = (try FileManager.default.attributesOfItem(atPath: graphURL.path)[.size] as? NSNumber)?.intValue ?? 0

        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print(String(
            format: "HNSW gate | %@ topics (LID %.0f) %d x %d, %d queries, M=%d efConstruction=%d efSearch=%d efEntry=%d top-50, %@ build | "
                + "recall@10 vs INT8 brute force %.4f, vs Float brute force %.4f (quantization alone %.4f) | "
                + "top-50 search back to back p50 %.3f ms, p95 %.3f ms; cache-cold p50 %.3f ms, p95 %.3f ms | "
                + "build %.1f s | vector file %.1f MB, graph file %.1f MB",
            shape.name, measurement.intrinsicDimension, count, dimensions, queryCount,
            configuration.m, configuration.efConstruction, efSearch ?? configuration.efSearch, configuration.efEntry, build,
            measurement.recallAgainstStore, measurement.recallAgainstFloat, measurement.quantizationRecall,
            measurement.warmP50 * 1_000, measurement.warmP95 * 1_000, measurement.coldP50 * 1_000, measurement.coldP95 * 1_000,
            measurement.buildSeconds,
            Double(measurement.vectorFileBytes) / 1_048_576, Double(measurement.graphFileBytes) / 1_048_576
        ))
        return measurement
    }
}
