import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSemantic

final class SemanticIndexTests: XCTestCase {
    private let dimensions = 64

    private func embed(_ text: String) -> [Float] {
        FakeEmbeddingProvider.embed(text, dimensions: dimensions)
    }

    private let catalogTexts: [(SearchableID, String)] = [
        ("tip-cat", "how to wash a cat"),
        ("tip-dog", "walking the dog in the rain"),
        ("map-city", "city centre street map"),
        ("tool-hammer", "hammer and nails tool"),
        ("game-chess", "chess board game"),
        ("image-sunset", "sunset over the sea"),
    ]

    private func catalogVectors() -> [SearchableID: [Float]] {
        Dictionary(uniqueKeysWithValues: catalogTexts.map { ($0.0, embed($0.1)) })
    }

    /// Many distinct items, for the tests that need a set past the fitting threshold.
    private func manyVectors(_ count: Int, prefix: String = "item") -> [SearchableID: [Float]] {
        var result: [SearchableID: [Float]] = [:]
        for index in 0..<count {
            result[SearchableID("\(prefix)-\(index)")] = embed("word\(index) other\(index % 17) more\(index % 5)")
        }
        return result
    }

    // MARK: Model lifecycle

    func testTheModelLoadsLazilyOnTheFirstQueryOnly() async throws {
        let provider = FakeEmbeddingProvider(dimensions: dimensions)
        let index = try SemanticIndex(provider: provider)

        // Storing, removing and searching vectors never touches the model.
        try await index.upsert(catalogVectors())
        await index.remove(["image-sunset"])
        _ = try await index.nearest(to: embed("cat"), limit: 3)
        await index.setLocale("it")
        var loads = await provider.loadCount
        XCTAssertEqual(loads, 0)

        _ = try await index.encodeQuery("cat", locale: nil)
        loads = await provider.loadCount
        XCTAssertEqual(loads, 1)
        _ = try await index.encodeQuery("dog", locale: Locale(identifier: "en"))
        _ = try await index.encodeQuery("map", locale: nil)
        loads = await provider.loadCount
        XCTAssertEqual(loads, 1, "the model stays loaded between queries")
        let texts = await provider.encodedTexts
        XCTAssertEqual(texts, ["cat", "dog", "map"], "only queries are ever encoded")
    }

    func testUnloadReleasesTheModelAndTheNextQueryReloadsIt() async throws {
        let provider = FakeEmbeddingProvider(dimensions: dimensions)
        let index = try SemanticIndex(provider: provider)
        try await index.upsert(catalogVectors())

        // Unloading a model that never loaded is harmless.
        await index.unload()
        var unloads = await provider.unloadCount
        XCTAssertEqual(unloads, 0)

        let before = try await index.encodeQuery("cat", locale: nil)
        await index.unload()
        var isLoaded = await provider.isModelLoaded
        XCTAssertFalse(isLoaded)
        unloads = await provider.unloadCount
        XCTAssertEqual(unloads, 1)

        // The vectors are unaffected: they never needed the model.
        let matches = try await index.nearest(to: before, limit: 1)
        XCTAssertEqual(matches.first?.id, "tip-cat")
        var loads = await provider.loadCount
        XCTAssertEqual(loads, 1)

        let after = try await index.encodeQuery("cat", locale: nil)
        XCTAssertEqual(before, after)
        loads = await provider.loadCount
        isLoaded = await provider.isModelLoaded
        XCTAssertEqual(loads, 2)
        XCTAssertTrue(isLoaded)
    }

    func testQueriesComeBackUnitLengthWhateverTheProviderReturns() async throws {
        let provider = FakeEmbeddingProvider(dimensions: 4)
        let index = try SemanticIndex(provider: provider)
        await provider.respond(with: [3, 0, 4, 0])
        let scaled = try await index.encodeQuery("anything", locale: nil)
        XCTAssertEqual(scaled[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(scaled[2], 0.8, accuracy: 1e-6)
        XCTAssertEqual(VectorKernels.norm(scaled), 1, accuracy: 1e-6)

        await provider.respond(with: [1, 0, 0])
        await assertThrowsAsync(.dimensionMismatch(expected: 4, found: 3)) { try await index.encodeQuery("anything", locale: nil) }
        await provider.respond(with: [0, 0, 0, 0])
        do {
            _ = try await index.encodeQuery("anything", locale: nil)
            XCTFail("a vector without direction must be refused")
        } catch let error as SemanticError {
            guard case .invalidVector = error else { return XCTFail("unexpected \(error)") }
        }

        struct ModelFailure: Error {}
        await provider.fail(with: ModelFailure())
        do {
            _ = try await index.encodeQuery("anything", locale: nil)
            XCTFail("the provider's failure must surface")
        } catch {
            XCTAssertTrue(error is ModelFailure)
        }
    }

    // MARK: Vectors

    func testNearestRanksByCosineSimilarityAcrossLanguages() async throws {
        let provider = FakeEmbeddingProvider(dimensions: dimensions)
        let index = try SemanticIndex(provider: provider)
        try await index.upsert(catalogVectors())
        let count = await index.count
        XCTAssertEqual(count, 6)

        // An Italian query finds the English item through the shared space.
        let query = try await index.encodeQuery("lavare il gatto", locale: Locale(identifier: "it"))
        let matches = try await index.nearest(to: query, limit: 6)
        XCTAssertEqual(matches.count, 6)
        XCTAssertEqual(matches.first?.id, "tip-cat")
        XCTAssertEqual(matches.map(\.similarity), matches.map(\.similarity).sorted(by: >))
        for match in matches {
            let text = try XCTUnwrap(catalogTexts.first { $0.0 == match.id }?.1)
            XCTAssertEqual(match.similarity, VectorKernels.dot(query, embed(text)), accuracy: 0.01, "similarity is the cosine")
        }
        let limited = try await index.nearest(to: query, limit: 2)
        XCTAssertEqual(limited.map(\.id), Array(matches.prefix(2).map(\.id)))
        let none = try await index.nearest(to: query, limit: 0)
        XCTAssertTrue(none.isEmpty)
    }

    func testAnEmptyIndexAnswersWithNothing() async throws {
        let index = try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: dimensions))
        let matches = try await index.nearest(to: embed("cat"), limit: 10)
        XCTAssertTrue(matches.isEmpty)
        let count = await index.count
        XCTAssertEqual(count, 0)
        try await index.upsert([:])
        await index.remove([])
        await index.remove(["never-there"])
    }

    func testUpsertAddsAndReplacesAndRemoveTakesEffect() async throws {
        let index = try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: dimensions))
        try await index.upsert(catalogVectors())
        let dogQuery = embed("dog")

        var best = try await index.nearest(to: dogQuery, limit: 1)
        XCTAssertEqual(best.first?.id, "tip-dog")

        // Replace: the chess item now talks about dogs, more than the dog tip does.
        try await index.upsert(["game-chess": embed("dog dog dog")])
        best = try await index.nearest(to: dogQuery, limit: 1)
        XCTAssertEqual(best.first?.id, "game-chess")
        var count = await index.count
        XCTAssertEqual(count, 6, "a replacement does not add an item")

        // Add.
        try await index.upsert(["tip-new": embed("feeding the dog")])
        count = await index.count
        XCTAssertEqual(count, 7)
        var contains = await index.contains("tip-new")
        XCTAssertTrue(contains)

        // Remove.
        await index.remove(["game-chess", "tip-new", "never-there"])
        count = await index.count
        XCTAssertEqual(count, 5)
        contains = await index.contains("game-chess")
        XCTAssertFalse(contains)
        let all = try await index.nearest(to: dogQuery, limit: 10)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.first?.id, "tip-dog")
        XCTAssertFalse(all.contains { $0.id == "game-chess" || $0.id == "tip-new" })

        // A removed item can come back.
        try await index.upsert(["game-chess": embed("chess board game")])
        let chess = try await index.nearest(to: embed("chess"), limit: 1)
        XCTAssertEqual(chess.first?.id, "game-chess")
    }

    func testRepeatingAnUpsertChangesNothing() async throws {
        let index = try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: dimensions))
        try await index.upsert(catalogVectors())
        try await index.upsert(catalogVectors())
        try await index.upsert(catalogVectors())
        let count = await index.count
        let tombstones = await index.tombstoneCount
        XCTAssertEqual(count, 6)
        XCTAssertEqual(tombstones, 0, "core repeats upserts on every rebuild; they must be free")
    }

    func testItemVectorsAreScaledToUnitLength() async throws {
        let index = try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: dimensions))
        var vectors = catalogVectors()
        for id in vectors.keys { vectors[id] = vectors[id]?.map { $0 * 37 } }
        try await index.upsert(vectors)
        let query = embed("cat")
        let matches = try await index.nearest(to: query.map { $0 * 5 }, limit: 1)
        XCTAssertEqual(matches.first?.id, "tip-cat")
        XCTAssertEqual(matches.first?.similarity ?? 0, VectorKernels.dot(query, embed("how to wash a cat")), accuracy: 0.01)
        let stored = await index.vector(for: "tip-cat")
        XCTAssertEqual(VectorKernels.norm(try XCTUnwrap(stored)), 1, accuracy: 0.01)
    }

    func testVectorsThatDoNotFitTheSpaceAreRefusedAndNothingIsStored() async throws {
        let provider = FakeEmbeddingProvider(dimensions: dimensions)
        let index = try SemanticIndex(provider: provider)
        try await index.upsert(catalogVectors())

        var mixed = manyVectors(10)
        mixed["broken"] = [1, 0, 0]
        await assertThrowsAsync(.dimensionMismatch(expected: dimensions, found: 3)) { try await index.upsert(mixed) }
        var count = await index.count
        XCTAssertEqual(count, 6, "an upsert is all or nothing")

        var zero = manyVectors(10)
        zero["zero"] = [Float](repeating: 0, count: dimensions)
        do {
            try await index.upsert(zero)
            XCTFail("a vector without direction must be refused")
        } catch let error as SemanticError {
            guard case .invalidVector = error else { return XCTFail("unexpected \(error)") }
        }
        count = await index.count
        XCTAssertEqual(count, 6)

        await assertThrowsAsync(.dimensionMismatch(expected: dimensions, found: 2)) { try await index.nearest(to: [1, 0], limit: 3) }
        do {
            _ = try await index.nearest(to: [Float](repeating: 0, count: dimensions), limit: 3)
            XCTFail("a query without direction must be refused")
        } catch let error as SemanticError {
            guard case .invalidVector = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testAnEmbeddingSpaceOutsideTheSupportedDimensionsIsRefused() async {
        XCTAssertThrowsError(try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: 385))) { error in
            XCTAssertEqual(error as? SemanticError, .unsupportedDimensions(385))
        }
        XCTAssertThrowsError(try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: 0))) { error in
            XCTAssertEqual(error as? SemanticError, .unsupportedDimensions(0))
        }
        XCTAssertNoThrow(try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: 384)))
    }

    func testTheSameVectorsGiveTheSameAnswersWhateverTheDictionaryOrder() async throws {
        let vectors = manyVectors(400)
        let first = try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: dimensions))
        try await first.upsert(vectors)
        // The same content assembled in another order hashes into another iteration order.
        var shuffled: [SearchableID: [Float]] = [:]
        for key in vectors.keys.sorted().reversed() { shuffled[key] = vectors[key] }
        let second = try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: dimensions))
        try await second.upsert(shuffled)
        for probe in ["word3 other3", "word250", "more2 other9"] {
            let a = try await first.nearest(to: embed(probe), limit: 20)
            let b = try await second.nearest(to: embed(probe), limit: 20)
            XCTAssertEqual(a, b)
        }
    }

    func testASetCreatedAtRuntimeFitsItsQuantizationOnceItHasEnoughVectors() async throws {
        let configuration = SemanticIndex.Configuration(quantizationSampleCount: 200)
        let index = try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: dimensions), configuration: configuration)
        let vectors = manyVectors(260)
        let ids = vectors.keys.sorted()
        let early = Dictionary(uniqueKeysWithValues: ids.prefix(50).map { ($0, vectors[$0]!) })
        let late = Dictionary(uniqueKeysWithValues: ids.dropFirst(50).map { ($0, vectors[$0]!) })

        func reconstructionError() async throws -> Float {
            var total: Float = 0
            for id in ids.prefix(50) {
                let stored = await index.vector(for: id)
                total += VectorKernels.squaredDistance(try XCTUnwrap(stored), vectors[id]!)
            }
            return total
        }

        try await index.upsert(early)
        let coarse = try await reconstructionError()
        // Removals and replacements before the refit are honoured by it.
        try await index.upsert(["gone": embed("soon removed"), ids[10]: vectors[ids[11]]!])
        await index.remove(["gone"])
        try await index.upsert([ids[10]: vectors[ids[10]]!])
        try await index.upsert(late)
        let fine = try await reconstructionError()
        // The refit quantizes the exact vectors, not their coarse codes, so the early vectors
        // gain as much as the late ones. (In 64 dimensions the fitted step is about half the
        // uniform one; in 384 it is a quarter.)
        XCTAssertLessThan(fine, coarse / 2, "the fitted ranges are more precise")
        let gone = await index.contains("gone")
        XCTAssertFalse(gone)

        let count = await index.count
        let tombstones = await index.tombstoneCount
        XCTAssertEqual(count, 260)
        XCTAssertEqual(tombstones, 0, "the refit rebuilds the set, it does not append to it")
        for id in [ids[0], ids[49], ids[50], ids[259]] {
            let best = try await index.nearest(to: vectors[id]!, limit: 1)
            XCTAssertEqual(best.first?.similarity ?? 0, 1, accuracy: 0.01)
        }
    }

    // MARK: Shipped files

    /// What a build pipeline does: quantize, build the graph, write both files.
    private func ship(_ vectors: [SearchableID: [Float]], model: String = "fake-embedding-v1", to directory: TemporaryDirectory, name: String = "vectors") async throws -> VectorSetCatalog.Files {
        let entries = vectors.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let store = try QuantizedVectorStore.build(
            from: entries, modelID: model, dimensions: dimensions, quantization: .uniform(dimensions: dimensions)
        )
        let files = VectorSetCatalog.Files(
            vectors: directory.file("\(name).ztvec"), graph: directory.file("\(name).zthnsw")
        )
        try await HNSWIndex.build(over: store).write(vectorsTo: files.vectors, graphTo: files.graph!)
        return files
    }

    func testAnIndexIsBuiltFromAShippedVectorFileAndGraphFile() async throws {
        let directory = try TemporaryDirectory()
        let vectors = manyVectors(500)
        let files = try await ship(vectors, to: directory)
        let provider = FakeEmbeddingProvider(dimensions: dimensions)
        let index = try await SemanticIndex(provider: provider, vectors: files.vectors, graph: files.graph)
        let count = await index.count
        XCTAssertEqual(count, 500)
        for probe in ["item-0", "item-123", "item-499"] {
            let best = try await index.nearest(to: vectors[SearchableID(probe)]!, limit: 1)
            XCTAssertEqual(best.first?.id, SearchableID(probe))
        }
        let loads = await provider.loadCount
        XCTAssertEqual(loads, 0, "loading shipped vectors never loads the model")

        // Runtime changes sit on top of the shipped files.
        try await index.upsert(["late": embed("a late arrival")])
        await index.remove(["item-7"])
        let late = try await index.nearest(to: embed("a late arrival"), limit: 1)
        XCTAssertEqual(late.first?.id, "late")
        let removed = await index.contains("item-7")
        XCTAssertFalse(removed)

        // Without a graph file the graph is built on device, and answers the same way.
        let rebuilt = try await SemanticIndex(provider: provider, vectors: files.vectors, graph: nil)
        let shipped = try await SemanticIndex(provider: provider, vectors: files.vectors, graph: files.graph)
        for probe in ["word3 other3", "word250 more0"] {
            let a = try await shipped.nearest(to: embed(probe), limit: 10)
            let b = try await rebuilt.nearest(to: embed(probe), limit: 10)
            XCTAssertEqual(a, b)
        }
    }

    func testShippedFilesForAnotherModelOrDimensionCountAreRefused() async throws {
        let directory = try TemporaryDirectory()
        let files = try await ship(manyVectors(40), model: "some-other-model", to: directory)
        await assertThrowsAsync(.modelMismatch(expected: "fake-embedding-v1", found: "some-other-model")) {
            try await SemanticIndex(provider: FakeEmbeddingProvider(dimensions: self.dimensions), vectors: files.vectors, graph: files.graph)
        }
        await assertThrowsAsync(.dimensionMismatch(expected: 32, found: dimensions)) {
            try await SemanticIndex(
                provider: FakeEmbeddingProvider(modelID: "some-other-model", dimensions: 32), vectors: files.vectors, graph: files.graph
            )
        }
        // A graph file that belongs to other vectors.
        let other = try await ship(manyVectors(41), model: "some-other-model", to: directory, name: "other")
        do {
            _ = try await SemanticIndex(
                provider: FakeEmbeddingProvider(modelID: "some-other-model", dimensions: dimensions), vectors: files.vectors, graph: other.graph
            )
            XCTFail("a graph of another store must be refused")
        } catch let error as SemanticError {
            guard case .graphStoreMismatch = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testSaveWritesFilesTheNextLaunchLoads() async throws {
        let directory = try TemporaryDirectory()
        let provider = FakeEmbeddingProvider(dimensions: dimensions)
        let index = try SemanticIndex(provider: provider)
        try await index.upsert(manyVectors(300))
        try await index.upsert(catalogVectors())
        await index.remove(["item-3", "tip-dog"])
        let vectorsURL = directory.file("saved.ztvec")
        let graphURL = directory.file("saved.zthnsw")
        try await index.save(vectorsTo: vectorsURL, graphTo: graphURL)

        let next = try await SemanticIndex(provider: provider, vectors: vectorsURL, graph: graphURL)
        let count = await next.count
        XCTAssertEqual(count, 304)
        for probe in ["cat", "word7 other7", "street map"] {
            let a = try await index.nearest(to: embed(probe), limit: 20)
            let b = try await next.nearest(to: embed(probe), limit: 20)
            XCTAssertEqual(a, b)
        }
        let removed = await next.contains("tip-dog")
        XCTAssertFalse(removed)

        // An index that never received a vector saves empty, valid files.
        let empty = try SemanticIndex(provider: provider)
        try await empty.save(vectorsTo: directory.file("empty.ztvec"), graphTo: directory.file("empty.zthnsw"))
        let reloaded = try await SemanticIndex(provider: provider, vectors: directory.file("empty.ztvec"), graph: directory.file("empty.zthnsw"))
        let emptyCount = await reloaded.count
        XCTAssertEqual(emptyCount, 0)
        try await reloaded.upsert(catalogVectors())
        let best = try await reloaded.nearest(to: embed("cat"), limit: 1)
        XCTAssertEqual(best.first?.id, "tip-cat")
    }

    func testCompactDropsTheTombstones() async throws {
        let index = try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: dimensions))
        let vectors = manyVectors(300)
        try await index.upsert(vectors)
        await index.remove(vectors.keys.sorted().prefix(100).map { $0 })
        var tombstones = await index.tombstoneCount
        XCTAssertEqual(tombstones, 100)
        try await index.compact()
        tombstones = await index.tombstoneCount
        let count = await index.count
        XCTAssertEqual(tombstones, 0)
        XCTAssertEqual(count, 200)
        let survivor = vectors.keys.sorted()[150]
        let best = try await index.nearest(to: vectors[survivor]!, limit: 1)
        XCTAssertEqual(best.first?.id, survivor)
    }

    // MARK: Locale sets

    private func localizedCatalog(in directory: TemporaryDirectory) async throws -> VectorSetCatalog {
        // The base set describes the items in English; the Italian set gives item "a" a
        // direction of its own, as a pipeline that embeds localized compositions would.
        let base = try await ship(["a": embed("alpha"), "b": embed("beta"), "c": embed("gamma")], to: directory, name: "vectors")
        let italian = try await ship(["a": embed("italiano"), "b": embed("beta"), "c": embed("gamma")], to: directory, name: "vectors.it")
        try Data([1, 2, 3]).write(to: directory.file("vectors.de.ztvec"))
        let discovered = try await VectorSetCatalog.discover(in: directory.url)
        let catalog = try XCTUnwrap(discovered)
        XCTAssertEqual(catalog.base, base)
        XCTAssertEqual(catalog.localized["it"], italian)
        return catalog
    }

    func testSetLocaleSwitchesVectorSetsWithBaseFallback() async throws {
        let directory = try TemporaryDirectory()
        let catalog = try await localizedCatalog(in: directory)
        let provider = FakeEmbeddingProvider(dimensions: dimensions)
        let index = try await SemanticIndex(provider: provider, catalog: catalog, languageTag: "en")
        var active = await index.activeLanguageTag
        XCTAssertNil(active, "no English set ships: base")

        func nearest(_ text: String) async throws -> SearchableID? {
            try await index.nearest(to: embed(text), limit: 1).first?.id
        }
        var found = try await nearest("alpha")
        XCTAssertEqual(found, "a")
        var italianSimilarity = try await index.nearest(to: embed("italiano"), limit: 1).first?.similarity ?? 0
        XCTAssertLessThan(italianSimilarity, 0.5)

        // The locale has a set: it is loaded.
        await index.setLocale("it-IT")
        active = await index.activeLanguageTag
        XCTAssertEqual(active, "it")
        found = try await nearest("italiano")
        XCTAssertEqual(found, "a")
        italianSimilarity = try await index.nearest(to: embed("italiano"), limit: 1).first?.similarity ?? 0
        XCTAssertEqual(italianSimilarity, 1, accuracy: 0.01)

        // No set for the locale: base.
        await index.setLocale("fr")
        active = await index.activeLanguageTag
        XCTAssertNil(active)
        found = try await nearest("alpha")
        XCTAssertEqual(found, "a")
        let similarity = try await index.nearest(to: embed("alpha"), limit: 1).first?.similarity ?? 0
        XCTAssertEqual(similarity, 1, accuracy: 0.01)

        // A set that exists but is unreadable: base stays in use.
        await index.setLocale("de")
        active = await index.activeLanguageTag
        XCTAssertNil(active)
        found = try await nearest("beta")
        XCTAssertEqual(found, "b")

        // Starting in a locale that has a set loads it right away.
        let italian = try await SemanticIndex(provider: provider, catalog: catalog, languageTag: "it")
        active = await italian.activeLanguageTag
        XCTAssertEqual(active, "it")
        let loads = await provider.loadCount
        XCTAssertEqual(loads, 0, "items are never re-embedded on device")
    }

    func testRuntimeChangesFollowALocaleSwitch() async throws {
        let directory = try TemporaryDirectory()
        let catalog = try await localizedCatalog(in: directory)
        let index = try await SemanticIndex(provider: FakeEmbeddingProvider(dimensions: dimensions), catalog: catalog, languageTag: "en")

        try await index.upsert(["d": embed("delta"), "b": embed("replaced")])
        await index.remove(["c"])
        try await index.upsert(["e": embed("epsilon")])
        await index.remove(["e"])

        for locale in ["it", "fr", "it-IT"] {
            await index.setLocale(locale)
            let count = await index.count
            XCTAssertEqual(count, 3, "locale \(locale)")
            let delta = try await index.nearest(to: embed("delta"), limit: 1)
            XCTAssertEqual(delta.first?.id, "d", "an added vector follows the switch to \(locale)")
            XCTAssertEqual(delta.first?.similarity ?? 0, 1, accuracy: 0.02)
            let replaced = try await index.nearest(to: embed("replaced"), limit: 1)
            XCTAssertEqual(replaced.first?.id, "b", "a replaced vector follows the switch to \(locale)")
            let removedC = await index.contains("c")
            let removedE = await index.contains("e")
            XCTAssertFalse(removedC, "a removal follows the switch to \(locale)")
            XCTAssertFalse(removedE)
        }
    }

    func testSetLocaleWithoutLocaleSetsIsANoOp() async throws {
        let provider = FakeEmbeddingProvider(dimensions: dimensions)
        let index = try SemanticIndex(provider: provider)
        try await index.upsert(catalogVectors())
        await index.setLocale("it")
        let active = await index.activeLanguageTag
        XCTAssertNil(active)
        let best = try await index.nearest(to: embed("cat"), limit: 1)
        XCTAssertEqual(best.first?.id, "tip-cat")
    }

    // MARK: Sync-time embedding

    func testEmbedMissingEncodesOnlyItemsWithoutAVector() async throws {
        let provider = FakeEmbeddingProvider(dimensions: dimensions)
        let index = try SemanticIndex(provider: provider)
        // Two items arrive with precomputed vectors.
        try await index.upsert(["tip-cat": embed("how to wash a cat"), "tip-dog": embed("walking the dog in the rain")])

        let embedded = try await index.embedMissing(catalogTexts + [("tip-cat", "a repeat"), ("map-city", "another repeat")])
        XCTAssertEqual(embedded, ["map-city", "tool-hammer", "game-chess", "image-sunset"])
        let texts = await provider.encodedTexts
        XCTAssertEqual(texts, ["city centre street map", "hammer and nails tool", "chess board game", "sunset over the sea"])
        let count = await index.count
        XCTAssertEqual(count, 6)

        let hammer = try await index.nearest(to: embed("hammer"), limit: 1)
        XCTAssertEqual(hammer.first?.id, "tool-hammer")
        // A precomputed vector is never overwritten by an embedding.
        let cat = try await index.nearest(to: embed("how to wash a cat"), limit: 1)
        XCTAssertEqual(cat.first?.id, "tip-cat")
        XCTAssertEqual(cat.first?.similarity ?? 0, 1, accuracy: 0.01)

        // A second pass has nothing left to do and encodes nothing.
        let again = try await index.embedMissing(catalogTexts)
        XCTAssertTrue(again.isEmpty)
        let afterSecondPass = await provider.encodedTexts
        XCTAssertEqual(afterSecondPass.count, 4)
        let loads = await provider.loadCount
        XCTAssertEqual(loads, 1)
    }

    func testEmbedMissingKeepsWhatWasEmbeddedBeforeAFailureOrACancellation() async throws {
        struct ModelFailure: Error {}
        let provider = FakeEmbeddingProvider(dimensions: dimensions)
        let index = try SemanticIndex(provider: provider)
        _ = try await index.embedMissing(Array(catalogTexts.prefix(2)))
        await provider.fail(with: ModelFailure())
        do {
            _ = try await index.embedMissing(catalogTexts)
            XCTFail("the provider's failure must surface")
        } catch {
            XCTAssertTrue(error is ModelFailure)
        }
        var count = await index.count
        XCTAssertEqual(count, 2)
        await provider.fail(with: nil)

        // Cancellation while the fourth item is being encoded: the third, embedded just before,
        // is stored, and nothing after it is.
        await provider.cancelTask(whenEncoding: catalogTexts[3].1)
        let texts = catalogTexts
        let task = Task { try await index.embedMissing(texts) }
        do {
            _ = try await task.value
            XCTFail("a cancelled pass must throw")
        } catch is CancellationError {
            // Expected.
        }
        count = await index.count
        XCTAssertEqual(count, 3, "the item embedded before the cancellation is kept")
        let kept = await index.contains(catalogTexts[2].0)
        XCTAssertTrue(kept)
        let encoded = await provider.encodedTexts
        XCTAssertFalse(encoded.contains(catalogTexts[4].1), "nothing is encoded after the cancellation")

        // The next pass picks up where the cancelled one stopped.
        await provider.cancelTask(whenEncoding: nil)
        let rest = try await index.embedMissing(catalogTexts)
        XCTAssertEqual(rest, catalogTexts[3...].map(\.0))
        count = await index.count
        XCTAssertEqual(count, 6)
    }

    // MARK: Concurrency

    func testConcurrentChangesAndSearchesLeaveAConsistentIndex() async throws {
        let index = try SemanticIndex(provider: FakeEmbeddingProvider(dimensions: dimensions))
        try await index.upsert(catalogVectors())
        let batches = (0..<8).map { manyVectors(60, prefix: "batch\($0)") }
        let query = embed("cat")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for batch in batches {
                group.addTask { try await index.upsert(batch) }
            }
            for worker in 0..<8 {
                group.addTask {
                    for _ in 0..<40 {
                        let matches = try await index.nearest(to: query, limit: 10)
                        XCTAssertEqual(matches.map(\.similarity), matches.map(\.similarity).sorted(by: >))
                        XCTAssertEqual(Set(matches.map(\.id)).count, matches.count)
                    }
                    await index.remove([SearchableID("batch\(worker)-0")])
                }
            }
            try await group.waitForAll()
        }
        // The removals raced the upserts: remove again, now that everything is stored.
        await index.remove((0..<8).map { SearchableID("batch\($0)-0") })
        let count = await index.count
        XCTAssertEqual(count, 6 + 8 * 60 - 8)
        for batch in 0..<8 {
            let id = SearchableID("batch\(batch)-31")
            let best = try await index.nearest(to: batches[batch][id]!, limit: 1)
            XCTAssertEqual(best.first?.similarity ?? 0, 1, accuracy: 0.02)
        }
    }

    // MARK: Boundary

    func testItIsInjectedIntoCoreThroughTheSemanticSearchingBoundary() async throws {
        let provider = FakeEmbeddingProvider(dimensions: dimensions)
        let semantic: any SemanticSearching = try SemanticIndex(provider: provider)
        XCTAssertEqual(semantic.modelID, "fake-embedding-v1")
        XCTAssertEqual(semantic.dimensions, dimensions)

        try await semantic.upsert(catalogVectors())
        let vector = try await semantic.encodeQuery("hund", locale: Locale(identifier: "de"))
        let matches = try await semantic.nearest(to: vector, limit: 50)
        XCTAssertEqual(matches.first?.id, "tip-dog")
        XCTAssertEqual(matches.count, 6)
        await semantic.remove(["tip-dog"])
        let after = try await semantic.nearest(to: vector, limit: 50)
        XCTAssertFalse(after.contains { $0.id == "tip-dog" })
        await semantic.setLocale("de")
        await semantic.unload()
        let unloads = await provider.unloadCount
        XCTAssertEqual(unloads, 1)
    }
}
