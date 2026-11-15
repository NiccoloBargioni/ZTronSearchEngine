import XCTest
import ZTronSearchEngine
@testable import ZTronSearchFixtures

final class FakeEmbeddingTests: XCTestCase {
    private func norm(_ vector: [Float]) -> Float {
        vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }

    private func cosine(_ provider: FakeEmbeddingProvider, _ lhs: String, _ rhs: String) -> Float {
        FakeEmbeddingProvider.cosine(provider.vector(for: lhs), provider.vector(for: rhs))
    }

    // MARK: Provider

    func testVectorsHaveTheConfiguredDimensionAndUnitLength() {
        let provider = FakeEmbeddingProvider()
        XCTAssertEqual(provider.dimensions, 64)
        XCTAssertEqual(FakeEmbeddingProvider.defaultDimensions, 64)
        XCTAssertEqual(FakeEmbeddingProvider(dimensions: 384).dimensions, 384)
        XCTAssertEqual(FakeEmbeddingProvider(dimensions: 10_000).dimensions, 384, "the specification caps the space at 384 dimensions")
        XCTAssertEqual(FakeEmbeddingProvider(dimensions: 1).dimensions, 8)
        XCTAssertNotEqual(FakeEmbeddingProvider(dimensions: 128).modelID, provider.modelID)
        XCTAssertFalse(provider.recognizesPartialWords)

        for dimensions in [8, 64, 100, 128, 384] {
            let sized = FakeEmbeddingProvider(dimensions: dimensions)
            for text in ["Frozen Harbor Route", "porto ghiacciato", "凍った港のルート", "zzz qqq", "", "   ", "12 34", "!?"] {
                let vector = sized.vector(for: text)
                XCTAssertEqual(vector.count, dimensions)
                XCTAssertEqual(norm(vector), 1, accuracy: 1e-5, "«\(text)» at \(dimensions)")
            }
            let last = FixtureLexicon.concepts.count - 1
            for concept in [0, 1, min(dimensions - 1, last), min(dimensions, last), last] {
                XCTAssertEqual(norm(sized.conceptVector(for: concept)), 1, accuracy: 1e-5, "concept \(concept) at \(dimensions)")
            }
        }
    }

    func testEveryLanguageAndSynonymLandsInTheSamePlace() {
        for dimensions in [64, 384] {
            let provider = FakeEmbeddingProvider(dimensions: dimensions)
            let english = provider.vector(for: "frozen harbor")
            for other in ["icy port", "glacial haven", "Porto ghiacciato", "Gefrorener Hafen", "凍った港", "HARBOR, frozen!", "gefrorene hafen"] {
                XCTAssertEqual(FakeEmbeddingProvider.cosine(english, provider.vector(for: other)), 1, accuracy: 1e-5, other)
            }
            // Word order does not matter; repeating a word weighs it more.
            XCTAssertEqual(cosine(provider, "frozen harbor", "harbor frozen"), 1, accuracy: 1e-5)
            XCTAssertLessThan(cosine(provider, "frozen harbor", "frozen frozen frozen harbor"), 0.95)
            // Related texts are closer than unrelated ones.
            XCTAssertGreaterThan(cosine(provider, "frozen harbor", "frozen tower"), cosine(provider, "frozen harbor", "burning tower") + 0.2)
            XCTAssertEqual(cosine(provider, "frozen harbor", "frozen tower"), 0.5, accuracy: dimensions == 384 ? 1e-4 : 0.2)
        }
    }

    func testConceptVectorsAreOrthonormalWhereTheSpaceAllows() {
        let wide = FakeEmbeddingProvider(dimensions: 384)
        let count = FixtureLexicon.concepts.count
        XCTAssertLessThanOrEqual(count, 384, "the whole lexicon fits in 384 dimensions")
        for (lhs, rhs) in [(0, 1), (0, count - 1), (17, 200), (100, 101), (63, 64), (250, 251)] {
            XCTAssertEqual(FakeEmbeddingProvider.cosine(wide.conceptVector(for: lhs), wide.conceptVector(for: rhs)), 0, accuracy: 1e-5)
        }
        for id in [0, 63, 64, count - 1] {
            XCTAssertEqual(norm(wide.conceptVector(for: id)), 1, accuracy: 1e-5)
        }
        // At 64 dimensions concepts are orthogonal inside each group of 64, and nearly so across.
        let narrow = FakeEmbeddingProvider()
        XCTAssertEqual(FakeEmbeddingProvider.cosine(narrow.conceptVector(for: 0), narrow.conceptVector(for: 63)), 0, accuracy: 1e-5)
        XCTAssertEqual(FakeEmbeddingProvider.cosine(narrow.conceptVector(for: 64), narrow.conceptVector(for: 127)), 0, accuracy: 1e-5)
        var worst: Float = 0
        for lhs in 0..<64 {
            for rhs in 64..<count {
                worst = max(worst, abs(FakeEmbeddingProvider.cosine(narrow.conceptVector(for: lhs), narrow.conceptVector(for: rhs))))
            }
        }
        XCTAssertLessThan(worst, 0.75)
        XCTAssertGreaterThan(worst, 0, "64 dimensions cannot hold the whole lexicon orthogonally")
        // Any dimension works, not only powers of two: 100 is 64 + 32 + 4.
        let odd = FakeEmbeddingProvider(dimensions: 100)
        for (lhs, rhs) in [(0, 1), (0, 63), (63, 64), (64, 95), (95, 96), (96, 99), (0, 99)] {
            XCTAssertEqual(FakeEmbeddingProvider.cosine(odd.conceptVector(for: lhs), odd.conceptVector(for: rhs)), 0, accuracy: 1e-5, "\(lhs)/\(rhs)")
        }
    }

    func testUnknownWordsAddOnlyASmallComponent() {
        let provider = FakeEmbeddingProvider()
        XCTAssertGreaterThan(cosine(provider, "frozen harbor", "the frozen harbor of zzzq"), 0.9)
        XCTAssertLessThan(cosine(provider, "frozen harbor", "the frozen harbor of zzzq"), 1)
        XCTAssertNotEqual(provider.vector(for: "zzzq"), provider.vector(for: "qqqz"))
        XCTAssertEqual(provider.vector(for: "zzzq"), provider.vector(for: "ZZZQ!"))
        XCTAssertNotEqual(provider.vector(for: "ザルコ"), provider.vector(for: "ザルケ"))
        // No letters at all: a fixed unit vector, the same for every such text.
        XCTAssertEqual(provider.vector(for: ""), provider.vector(for: "12 + 7"))
        // The weight is configurable.
        let heavy = FakeEmbeddingProvider(unknownTokenWeight: 1)
        XCTAssertLessThan(
            FakeEmbeddingProvider.cosine(heavy.vector(for: "frozen"), heavy.vector(for: "frozen zzzq")),
            cosine(provider, "frozen", "frozen zzzq")
        )
    }

    func testItemCompositionFollowsTheSpecification() throws {
        let provider = FakeEmbeddingProvider()
        let tool = Tool(id: "t", title: "Potion Calculator", text: "Handy utility. " + String(repeating: "filler ", count: 40), keywords: ["calculator", "strategy"])
        let composition = provider.composition(for: tool)
        XCTAssertTrue(composition.hasPrefix("tool Potion Calculator calculator strategy Handy utility."), composition)
        XCTAssertEqual(composition.split(separator: " ").count, 1 + 2 + 2 + provider.shortDescriptionWordLimit, "the description is cut to its first words")
        XCTAssertEqual(provider.composition(for: AnySearchable(tool)), composition, "an erased item composes like the item itself")

        let map = MapItem(id: "m", title: "Frozen Harbor", text: "Interactive map.")
        XCTAssertEqual(provider.composition(for: map), "map Frozen Harbor Interactive map.")

        // One rule for every kind: type, title, tags, short description, caption.
        let tip = Tip(id: "p", title: "Fishing Basics", text: "Practical advice about fishing.")
        XCTAssertEqual(provider.composition(for: tip), "tip Fishing Basics Practical advice about fishing.")
        let image = ImageItem(id: "i", title: "Golden Lantern", altText: "Alt text.", tags: ["sunset", "lamp"], caption: "The golden lantern.", ocrText: "ZONE 7")
        XCTAssertEqual(provider.composition(for: AnySearchable(image)), "image Golden Lantern sunset lamp Alt text. The golden lantern.")
        // Only the beginning of a long text is described; what follows does not reach the vector.
        let long = Tip(id: "l", title: "Long", text: String(repeating: "zuvek ", count: 30) + "frozen harbor")
        XCTAssertEqual(FixtureLexicon.conceptIDs(in: provider.composition(for: long)), [])
        XCTAssertEqual(provider.itemVector(for: long), provider.itemVector(for: Tip(id: "l", title: "Long", text: String(repeating: "zuvek ", count: 30))))

        XCTAssertEqual(provider.itemVector(for: tool), provider.vector(for: composition))
        let vectors = provider.itemVectors(for: [AnySearchable(tool), AnySearchable(map)])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors["m"], provider.itemVector(for: map))

        // Localizations never enter the composition: item vectors come from the base surface.
        let entry = try XCTUnwrap(GoldenCorpus.entries.first { !$0.isBaseOnly })
        let itemComposition = provider.composition(for: entry.item)
        for language in entry.localizedLanguages {
            XCTAssertFalse(itemComposition.contains(try XCTUnwrap(entry.title(in: language))))
        }
    }

    func testEmbeddedAttachesVectorsWhereTheTypeCarriesOne() {
        let provider = FakeEmbeddingProvider()
        let items = Array(GoldenCorpus.items.prefix(84)) + [GoldenCorpus.items[84], GoldenCorpus.items[GoldenCorpus.items.count - 1]]
        let embedded = provider.embedded(items)
        XCTAssertEqual(embedded.map(\.searchID), items.map(\.searchID))
        for (original, item) in zip(items, embedded) {
            let vector = (item.base as? any EmbeddableSearchable)?.embedding
            switch item.searchKind {
            case .tip, .image:
                XCTAssertEqual(vector, provider.itemVector(for: original))
            default:
                XCTAssertNil(vector, "\(item.searchKind.rawValue) cannot carry a vector")
            }
        }
    }

    func testPartialWordsAreRecognizedOnlyWhenAsked() {
        let strict = FakeEmbeddingProvider()
        let tolerant = FakeEmbeddingProvider(recognizesPartialWords: true)
        XCTAssertEqual(strict.modelID, tolerant.modelID, "the space is the same; only queries are read differently")
        XCTAssertEqual(strict.queryVector(for: "froz harb"), strict.vector(for: "froz harb"))
        XCTAssertEqual(tolerant.vector(for: "froz harb"), strict.vector(for: "froz harb"), "item text is never guessed at")
        XCTAssertEqual(tolerant.queryVector(for: "frozen harbor"), strict.vector(for: "frozen harbor"))

        let target = strict.vector(for: "frozen harbor")
        XCTAssertLessThan(FakeEmbeddingProvider.cosine(strict.queryVector(for: "froz harb"), target), 0.5)
        XCTAssertEqual(FakeEmbeddingProvider.cosine(tolerant.queryVector(for: "froz harb"), target), 1, accuracy: 1e-5, "a beginning counts as the word")
        XCTAssertGreaterThan(FakeEmbeddingProvider.cosine(tolerant.queryVector(for: "frozne harbro"), target), 0.99, "a typo counts as the nearest word")
        XCTAssertEqual(tolerant.queryVector(for: "zzzq"), strict.vector(for: "zzzq"), "a word near nothing stays noise")
        XCTAssertEqual(tolerant.queryVector(for: "fr"), strict.vector(for: "fr"), "two letters are too few to guess from")
    }

    /// The property the semantic gates rely on: by cosine alone, the source of a paraphrase or
    /// cross-language query is among the ten nearest golden items.
    func testSourceIsAmongTheTenNearestItemsOfSemanticQueries() {
        for dimensions in [64, 384] {
            let provider = FakeEmbeddingProvider(dimensions: dimensions)
            let vectors = GoldenCorpus.entries.map { (id: $0.id, vector: provider.itemVector(for: $0.item)) }
            for queryClass in [GoldenQueryClass.paraphrase, .crossLanguage] {
                let queries = GoldenSet.queries(of: queryClass)
                var inTopTen = 0
                var first = 0
                var relevantInTopTen = 0
                var relevant = 0
                for query in queries {
                    let encoded = provider.queryVector(for: query.text)
                    let ranked = vectors
                        .map { (id: $0.id, similarity: FakeEmbeddingProvider.cosine(encoded, $0.vector)) }
                        .sorted { $0.similarity != $1.similarity ? $0.similarity > $1.similarity : $0.id < $1.id }
                        .map(\.id)
                    let position = ranked.firstIndex(of: query.sourceID) ?? ranked.count
                    if position < 10 { inTopTen += 1 }
                    if position == 0 { first += 1 }
                    relevant += query.judgments.count
                    relevantInTopTen += ranked.prefix(10).filter { query.judgments[$0] != nil }.count
                }
                let rate = Double(inTopTen) / Double(queries.count)
                print(String(
                    format: "FAKE EMBEDDING d=%d %@: source in top 10 for %.1f%% (top 1 for %.1f%%) of %d queries; %.1f%% of all judged items in top 10",
                    dimensions, queryClass.rawValue, rate * 100, Double(first) / Double(queries.count) * 100, queries.count,
                    Double(relevantInTopTen) / Double(relevant) * 100
                ))
                XCTAssertGreaterThanOrEqual(rate, 0.9, "\(queryClass.rawValue) at \(dimensions) dimensions")
            }
        }
    }

    // MARK: Searcher

    func testNearestIsBruteForceCosine() async throws {
        let provider = FakeEmbeddingProvider()
        let searcher = FakeSemanticSearcher(provider: provider)
        XCTAssertEqual(searcher.modelID, provider.modelID)
        XCTAssertEqual(searcher.dimensions, 64)
        let items = Array(GoldenCorpus.items.prefix(200))
        let vectors = provider.itemVectors(for: items)
        try await searcher.upsert(vectors)
        let count = await searcher.count
        XCTAssertEqual(count, 200)

        let query = try await searcher.encodeQuery("icy port itinerary", locale: Locale(identifier: "en"))
        XCTAssertEqual(query, provider.vector(for: "icy port itinerary"))
        let matches = try await searcher.nearest(to: query, limit: 25)
        let expected = vectors
            .map { (id: $0.key, similarity: FakeEmbeddingProvider.cosine(query, $0.value)) }
            .sorted { $0.similarity != $1.similarity ? $0.similarity > $1.similarity : $0.id < $1.id }
        XCTAssertEqual(matches.count, 25)
        XCTAssertEqual(matches.map(\.id), expected.prefix(25).map(\.id))
        for (match, reference) in zip(matches, expected) {
            XCTAssertEqual(match.similarity, reference.similarity, accuracy: 1e-5)
        }
        XCTAssertEqual(matches.first?.id, "gold-map-001", "Frozen Harbor Route is what the paraphrase means")
        XCTAssertTrue(zip(matches, matches.dropFirst()).allSatisfy { $0.similarity >= $1.similarity })

        let everything = try await searcher.nearest(to: query, limit: 1_000)
        XCTAssertEqual(everything.count, 200)
        let nothing = try await searcher.nearest(to: query, limit: 0)
        XCTAssertTrue(nothing.isEmpty)
        // A query that is not unit length is normalized first.
        let scaled = try await searcher.nearest(to: query.map { $0 * 7 }, limit: 5)
        XCTAssertEqual(scaled.map(\.id), Array(matches.prefix(5)).map(\.id))
    }

    func testUpsertReplacesAndRemoveDeletes() async throws {
        let provider = FakeEmbeddingProvider()
        let searcher = FakeSemanticSearcher(provider: provider)
        let harbor = provider.vector(for: "frozen harbor")
        let tower = provider.vector(for: "ancient tower")
        try await searcher.upsert(["a": harbor, "b": tower, "c": provider.vector(for: "silent forest")])
        var best = try await searcher.nearest(to: harbor, limit: 1)
        XCTAssertEqual(best.first?.id, "a")
        XCTAssertEqual(best.first?.similarity ?? 0, 1, accuracy: 1e-5)

        // Replace: "a" now means the tower, "b" the harbor. Vectors need not be unit length.
        try await searcher.upsert(["a": tower.map { $0 * 3 }, "b": harbor])
        best = try await searcher.nearest(to: harbor, limit: 1)
        XCTAssertEqual(best.first?.id, "b")
        var count = await searcher.count
        XCTAssertEqual(count, 3)

        await searcher.remove(["b", "missing"])
        best = try await searcher.nearest(to: harbor, limit: 3)
        XCTAssertEqual(Set(best.map(\.id)), ["a", "c"])
        count = await searcher.count
        XCTAssertEqual(count, 2)
        let stillThere = await searcher.contains("a")
        let gone = await searcher.contains("b")
        XCTAssertTrue(stillThere)
        XCTAssertFalse(gone)
        await searcher.remove(["a", "c"])
        let empty = try await searcher.nearest(to: harbor, limit: 3)
        XCTAssertTrue(empty.isEmpty)

        // Ties break by id, whatever the insertion order.
        try await searcher.upsert(["z": harbor, "m": harbor, "b": harbor])
        let tied = try await searcher.nearest(to: harbor, limit: 3)
        XCTAssertEqual(tied.map(\.id), ["b", "m", "z"])

        // Dimensions are checked, and a rejected batch stores nothing.
        do {
            try await searcher.upsert(["ok": harbor, "bad": [1, 2, 3]])
            XCTFail("a vector of the wrong dimension must be rejected")
        } catch let error as FakeSemanticError {
            XCTAssertEqual(error, .dimensionMismatch(expected: 64, found: 3))
        }
        count = await searcher.count
        XCTAssertEqual(count, 3)
        do {
            _ = try await searcher.nearest(to: [1, 0], limit: 3)
            XCTFail("a query of the wrong dimension must be rejected")
        } catch let error as FakeSemanticError {
            XCTAssertEqual(error, .dimensionMismatch(expected: 64, found: 2))
        }

        // The convenience embeds and stores without counting as an upsert call.
        let upsertsBefore = await searcher.upsertCallCount
        await searcher.index(Array(GoldenCorpus.items.prefix(10)))
        count = await searcher.count
        let upsertsAfter = await searcher.upsertCallCount
        XCTAssertEqual(count, 13)
        XCTAssertEqual(upsertsAfter, upsertsBefore)
    }

    func testHooksAndCounters() async throws {
        let searcher = FakeSemanticSearcher()
        var encodes = await searcher.encodeCallCount
        XCTAssertEqual(encodes, 0)

        _ = try await searcher.encodeQuery("frozen harbor", locale: nil)
        _ = try await searcher.nearest(to: FakeEmbeddingProvider().vector(for: "frozen"), limit: 5)
        await searcher.unload()
        await searcher.unload()
        await searcher.setLocale("it")
        await searcher.remove([])
        try await searcher.upsert([:])
        encodes = await searcher.encodeCallCount
        let nearest = await searcher.nearestCallCount
        let unloads = await searcher.unloadCallCount
        let removes = await searcher.removeCallCount
        let upserts = await searcher.upsertCallCount
        let texts = await searcher.encodedQueries
        let locales = await searcher.localeTags
        XCTAssertEqual([encodes, nearest, unloads, removes, upserts], [1, 1, 2, 1, 1])
        XCTAssertEqual(texts, ["frozen harbor"])
        XCTAssertEqual(locales, ["it"])

        // Delay: the answer comes no sooner than asked.
        await searcher.setEncodeDelay(nanoseconds: 80_000_000)
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await searcher.encodeQuery("slow", locale: nil)
        XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds - start, 70_000_000)

        // A delayed call can be cancelled, and then throws CancellationError.
        await searcher.setEncodeDelay(nanoseconds: 5_000_000_000)
        let task = Task { try await searcher.encodeQuery("never", locale: nil) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled encode must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await searcher.setEncodeDelay(nanoseconds: 0)

        // Failure switch.
        await searcher.setShouldThrow(true)
        do {
            _ = try await searcher.encodeQuery("boom", locale: nil)
            XCTFail("the fake was asked to throw")
        } catch let error as FakeSemanticError {
            XCTAssertEqual(error, .scripted)
        }
        do {
            _ = try await searcher.nearest(to: [Float](repeating: 0, count: 64), limit: 1)
            XCTFail("the fake was asked to throw")
        } catch let error as FakeSemanticError {
            XCTAssertEqual(error, .scripted)
        }
        await searcher.setShouldThrow(false)
        _ = try await searcher.encodeQuery("fine again", locale: nil)

        encodes = await searcher.encodeCallCount
        XCTAssertEqual(encodes, 5, "calls are counted when they start, failed and cancelled ones included")
        await searcher.resetCounters()
        encodes = await searcher.encodeCallCount
        let forgotten = await searcher.encodedQueries
        XCTAssertEqual(encodes, 0)
        XCTAssertTrue(forgotten.isEmpty)
    }

    func testSearcherUsesPartialWordsOfItsProvider() async throws {
        let strict = FakeSemanticSearcher()
        let tolerant = FakeSemanticSearcher(provider: FakeEmbeddingProvider(recognizesPartialWords: true))
        let items = GoldenCorpus.items
        await strict.index(items)
        await tolerant.index(items)
        let typed = "frozne harbro rout"
        let strictMatches = try await strict.nearest(to: try await strict.encodeQuery(typed, locale: nil), limit: 1)
        let tolerantMatches = try await tolerant.nearest(to: try await tolerant.encodeQuery(typed, locale: nil), limit: 1)
        XCTAssertEqual(tolerantMatches.first?.id, "gold-map-001")
        XCTAssertNotEqual(strictMatches.first?.id, "gold-map-001")
    }

    // MARK: Reranker

    func testRerankerScoresConceptOverlapByDefault() async throws {
        let reranker = FakeReranker()
        XCTAssertEqual(reranker.modelID, "fake-lexicon-reranker-v1")
        let passages = ["Porto ghiacciato", "Antica torre", "Frozen Tower\nThe frozen tower.", "凍った港のルート", "", "zzzq"]
        let scores = try await reranker.scores(query: "frozen harbor", passages: passages)
        XCTAssertEqual(scores, [1, 0, 0.5, 1, 0, 0])
        XCTAssertEqual(scores, FakeReranker.overlapScores(query: "frozen harbor", passages: passages))
        // Words the lexicon does not know count as themselves.
        XCTAssertEqual(FakeReranker.overlapScores(query: "icy zuvek", passages: ["Zuvek harbor", "frozen", "frozen ZUVEK"]), [0.5, 0.5, 1])
        XCTAssertEqual(FakeReranker.overlapScores(query: "12 !", passages: ["frozen", "harbor"]), [0, 0])
        XCTAssertEqual(FakeReranker.overlapScores(query: "frozen", passages: []), [])

        let calls = await reranker.scoresCallCount
        let lastQuery = await reranker.lastQuery
        let lastPassages = await reranker.lastPassages
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(lastQuery, "frozen harbor")
        XCTAssertEqual(lastPassages, passages)
    }

    func testRerankerHooks() async throws {
        let reranker = FakeReranker(modelID: "custom", isEnabled: false)
        XCTAssertEqual(reranker.modelID, "custom")
        var enabled = await reranker.isEnabled()
        XCTAssertFalse(enabled)
        await reranker.setEnabled(true)
        enabled = await reranker.isEnabled()
        XCTAssertTrue(enabled)

        // Scripted scores come back as they are, even when their count is wrong.
        await reranker.setScriptedScores([0.9, 0.1])
        var scores = try await reranker.scores(query: "anything", passages: ["a", "b", "c"])
        XCTAssertEqual(scores, [0.9, 0.1])
        // A scoring function is used when nothing is scripted.
        await reranker.setScriptedScores(nil)
        await reranker.setScoring { _, passages in passages.map { Float($0.count) } }
        scores = try await reranker.scores(query: "anything", passages: ["a", "bbb"])
        XCTAssertEqual(scores, [1, 3])
        await reranker.setScoring(nil)
        scores = try await reranker.scores(query: "frozen", passages: ["frozen"])
        XCTAssertEqual(scores, [1])

        await reranker.setDelay(nanoseconds: 60_000_000)
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await reranker.scores(query: "frozen", passages: ["frozen"])
        XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds - start, 50_000_000)
        await reranker.setDelay(nanoseconds: 0)

        await reranker.setShouldThrow(true)
        do {
            _ = try await reranker.scores(query: "frozen", passages: ["frozen"])
            XCTFail("the fake was asked to throw")
        } catch let error as FakeSemanticError {
            XCTAssertEqual(error, .scripted)
        }
        await reranker.setShouldThrow(false)

        await reranker.invalidateCalibration()
        await reranker.unload()
        await reranker.unload()
        let scoreCalls = await reranker.scoresCallCount
        let gateCalls = await reranker.isEnabledCallCount
        let invalidations = await reranker.invalidateCalibrationCallCount
        let unloads = await reranker.unloadCallCount
        XCTAssertEqual([scoreCalls, gateCalls, invalidations, unloads], [5, 2, 1, 2])
        await reranker.resetCounters()
        let afterReset = await reranker.scoresCallCount
        XCTAssertEqual(afterReset, 0)
    }

    func testFakesFitTheCoreBoundaries() {
        // Compile-time check: the fakes can be handed to the core as its boundaries.
        let semantic: any SemanticSearching = FakeSemanticSearcher()
        let reranker: any Reranking = FakeReranker()
        XCTAssertEqual(semantic.dimensions, 64)
        XCTAssertFalse(reranker.modelID.isEmpty)
    }
}
