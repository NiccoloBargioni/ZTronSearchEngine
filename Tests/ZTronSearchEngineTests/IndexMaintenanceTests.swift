import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// How the index keeps itself: incremental upserts, merges in tiers, deletions that adjust the
/// statistics from stored term lists, and rebuilds that touch only what changed.
final class IndexMaintenanceTests: XCTestCase {
    private func document(_ id: Int, _ text: String, title: String? = nil) -> SearchDocument {
        SearchDocument(id: SearchableID("d\(id)"), kind: "tool", title: title, text: text)
    }

    private func randomDocuments(_ count: Int, seed: UInt64, from start: Int = 0) -> [SearchDocument] {
        var corpus = RandomCorpus(seed: seed)
        return (start..<(start + count)).map { document($0, corpus.words(3..<20), title: corpus.words(1..<4)) }
    }

    private func request(_ text: String) -> LexicalRequest {
        let configuration = TestSupport.configuration()
        let prepared = SearchPipeline.prepare(
            SearchQuery<CatalogSchema>(text: text), configuration: configuration,
            languages: ResolvedLanguages(locale: Locale(identifier: "en"), configuration: configuration), session: TokenizerSession()
        )
        return SearchPipeline.request(for: prepared, profile: .default, configuration: configuration)
    }

    private func ranking(_ index: LexicalIndex, _ text: String) async throws -> [String] {
        let response = try await index.search(request(text))
        return (response.lexical + response.fuzzy).map { "\($0.id.rawValue):\($0.score)" }
    }

    // MARK: Upserts

    func testUpsertingUnchangedDocumentsChangesNothing() async {
        let index = LexicalIndex()
        let documents = randomDocuments(300, seed: 1)
        await index.upsert(documents)
        let revision = await index.revision
        let shape = await index.settledShape.map { [$0.documents, $0.deleted] }

        await index.upsert(documents)
        await index.upsert(Array(documents[40..<60]))
        let revisionAfter = await index.revision
        let shapeAfter = await index.settledShape.map { [$0.documents, $0.deleted] }
        XCTAssertEqual(revisionAfter, revision, "nothing differs from what is stored")
        XCTAssertEqual(shapeAfter, shape)

        // One document of the batch really changed: only that one is replaced.
        var batch = Array(documents[0..<50])
        batch[7] = document(7, "an entirely new body about lighthouses")
        await index.upsert(batch)
        let changed = await index.settledShape
        XCTAssertEqual(changed.map(\.deleted).reduce(0, +), 1)
        XCTAssertEqual(changed.map(\.documents).reduce(0, +), 301)
        let count = await index.count
        XCTAssertEqual(count, 300)
        let stored = await index.document(for: "d7")
        XCTAssertEqual(stored?.text, "an entirely new body about lighthouses")
    }

    func testTheSameIDTwiceInOneBatchKeepsTheLastVersion() async {
        let index = LexicalIndex()
        await index.upsert([document(1, "first version"), document(2, "another"), document(1, "second version")])
        let count = await index.count
        XCTAssertEqual(count, 2)
        let stored = await index.document(for: "d1")
        XCTAssertEqual(stored?.text, "second version")
    }

    // MARK: Tiers

    func testTiersAreFourTimesApart() {
        XCTAssertEqual([1, 3, 4, 15, 16, 63, 64, 255, 256, 100_000].map(LexicalIndex.tier(ofLiveCount:)), [0, 0, 1, 1, 2, 2, 3, 3, 4, 8])
    }

    func testSegmentsStayInTiersUnderSingleDocumentUpserts() async throws {
        let index = LexicalIndex()
        let documents = randomDocuments(400, seed: 2)
        var most = 0
        for (position, document) in documents.enumerated() {
            await index.upsert([document])
            let shape = await index.settledShape
            most = max(most, shape.count)
            // No tier ever holds four segments once an upsert has returned.
            var perTier: [Int: Int] = [:]
            for segment in shape { perTier[LexicalIndex.tier(ofLiveCount: segment.documents - segment.deleted), default: 0] += 1 }
            XCTAssertTrue(perTier.values.allSatisfy { $0 < LexicalIndex.tierFanout }, "after \(position + 1) upserts: \(shape)")
        }
        let count = await index.count
        XCTAssertEqual(count, 400)
        XCTAssertLessThanOrEqual(most, 3 * 5, "400 documents span five tiers of at most three segments")

        // Whatever the segments, the index answers like one built in one go.
        let fresh = LexicalIndex()
        await fresh.upsert(documents)
        for query in ["map", "mystery box", "harbr", "front door", "東京", "m1911-a1", "calcul"] {
            let incremental = try await ranking(index, query)
            let direct = try await ranking(fresh, query)
            XCTAssertEqual(incremental, direct, query)
        }
    }

    func testMutationsDoNotWaitForMergesAndMergesLoseNothing() async throws {
        // Batches large enough for their merges to run off the actor, with documents of the
        // segments being merged replaced and removed while the merges are under way. A merge
        // that finds one of its segments changed is dropped and tried again.
        let index = LexicalIndex()
        var expected: [SearchableID: SearchDocument] = [:]
        var corpus = RandomCorpus(seed: 21)
        var next = 0
        for round in 0..<24 {
            let batch = (0..<300).map { _ -> SearchDocument in
                defer { next += 1 }
                return document(next, corpus.words(3..<14), title: corpus.words(1..<3))
            }
            for document in batch { expected[document.id] = document }
            await index.upsert(batch)
            // No settling: the next mutations land while the merges of this batch run.
            let replaced = (0..<40).map { offset in document((round * 37 + offset * 11) % next, corpus.words(3..<14), title: "replaced \(round)") }
            for document in replaced { expected[document.id] = document }
            await index.upsert(replaced)
            let removed = (0..<15).map { offset in SearchableID("d\((round * 53 + offset * 7) % next)") }
            for id in removed { expected[id] = nil }
            await index.remove(removed)
        }
        let countBeforeSettling = await index.count
        XCTAssertEqual(countBeforeSettling, expected.count, "every mutation took effect before any merge had to finish")

        let shape = await index.settledShape
        XCTAssertEqual(shape.reduce(0) { $0 + $1.documents - $1.deleted }, expected.count)
        var perTier: [Int: Int] = [:]
        for segment in shape { perTier[LexicalIndex.tier(ofLiveCount: segment.documents - segment.deleted), default: 0] += 1 }
        XCTAssertTrue(perTier.values.allSatisfy { $0 < LexicalIndex.tierFanout }, "\(shape)")
        XCTAssertTrue(shape.allSatisfy { $0.deleted * 2 <= $0.documents }, "\(shape)")

        let fresh = LexicalIndex()
        await fresh.upsert(Array(expected.values))
        let merged = await index.statistics
        let direct = await fresh.statistics
        XCTAssertEqual(merged.documentCount, direct.documentCount)
        XCTAssertEqual(merged.totalFieldLengths, direct.totalFieldLengths)
        for query in ["map", "mystery box", "harbr", "replaced", "東京", "m1911-a1", "calcul", "front door"] {
            let incremental = try await ranking(index, query)
            let fromScratch = try await ranking(fresh, query)
            XCTAssertEqual(incremental, fromScratch, query)
        }
        for (id, document) in expected.prefix(300) {
            let stored = await index.document(for: id)
            XCTAssertEqual(stored, document)
        }
    }

    func testASegmentThatIsMostlyDeletedIsRewritten() async {
        let index = LexicalIndex()
        let documents = randomDocuments(200, seed: 3)
        await index.upsert(documents)
        var shape = await index.settledShape
        XCTAssertEqual(shape.count, 1)

        await index.remove((0..<90).map { SearchableID("d\($0)") })
        shape = await index.settledShape
        XCTAssertEqual(shape.map(\.deleted), [90], "under half deleted: the segment stays, with its deletions marked")

        await index.remove((90..<120).map { SearchableID("d\($0)") })
        shape = await index.settledShape
        XCTAssertEqual(shape.map(\.documents), [80], "more than half deleted: rewritten without them")
        XCTAssertEqual(shape.map(\.deleted), [0])
        let count = await index.count
        XCTAssertEqual(count, 80)
    }

    func testCompactFoldsTheSegmentsIntoOne() async throws {
        let index = LexicalIndex()
        let documents = randomDocuments(150, seed: 4)
        for start in stride(from: 0, to: 150, by: 7) {
            await index.upsert(Array(documents[start..<min(150, start + 7)]))
        }
        await index.remove([SearchableID("d3"), SearchableID("d77")])
        await index.settle()
        let before = await index.segmentCount
        XCTAssertGreaterThan(before, 1)
        let rankingBefore = try await ranking(index, "mystery box round")

        await index.compact()
        let shape = await index.settledShape
        XCTAssertEqual(shape.map(\.documents), [148])
        XCTAssertEqual(shape.map(\.deleted), [0])
        let rankingAfter = try await ranking(index, "mystery box round")
        XCTAssertEqual(rankingAfter, rankingBefore, "folding changes no score")
    }

    func testSavingTheSameStateTwiceWritesOnce() async throws {
        let directory = TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.ztsi")
        let index = LexicalIndex()
        await index.upsert(randomDocuments(120, seed: 5))
        try await index.save(to: url)
        let first = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try await index.save(to: url)
        let second = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(first, second, "the file already holds this state")

        await index.upsert([document(9_000, "a new document about beacons")])
        try await index.save(to: url)
        let third = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertNotEqual(second, third)
        let reloaded = LexicalIndex()
        try await reloaded.load(from: url)
        let count = await reloaded.count
        XCTAssertEqual(count, 121)
    }

    // MARK: What a segment stores

    private func segment(_ documents: [SearchDocument]) throws -> IndexSegment {
        try IndexSegment(data: SegmentBuilder.build([DocumentTokenizer.tokenize(documents)]))
    }

    /// For every document: the terms whose postings name it, read the slow way.
    private func termsByDocument(_ segment: IndexSegment) -> [[Int]] {
        segment.withView { view in
            var result = [[Int]](repeating: [], count: segment.documentCount)
            for term in 0..<segment.termCount {
                var holders = Set<Int>()
                for field in 0..<SearchField.count {
                    guard let range = view.postingRange(term: term, field: field) else { continue }
                    var offset = range.start
                    var document = -1
                    while offset < range.start + range.length {
                        document += Int(readVarint(view.postings, &offset))
                        _ = readVarint(view.postings, &offset)
                        holders.insert(document)
                    }
                }
                for document in holders { result[document].append(term) }
            }
            return result
        }
    }

    private func storedTermLists(_ segment: IndexSegment) -> [[Int]] {
        segment.withView { view in
            (0..<segment.documentCount).map { document in
                var terms: [Int] = []
                view.forEachTerm(of: document) { terms.append($0) }
                return terms
            }
        }
    }

    func testEveryDocumentsTermListIsWhatItsPostingsSay() throws {
        var corpus = RandomCorpus(seed: 6)
        let items = corpus.items(160)
        let documents = items.map { SearchProjector.project($0, locale: Locale(identifier: "en"), secondaryLanguages: ["it", "ja"]) }
        let built = try segment(documents)
        XCTAssertEqual(storedTermLists(built), termsByDocument(built))

        // And after a merge that drops documents: the lists follow the merged vocabulary.
        let other = try segment(randomDocuments(90, seed: 7, from: 10_000))
        var deleted = Bitset()
        for ordinal in stride(from: 0, to: built.documentCount, by: 3) { deleted.insert(ordinal) }
        let merged = try IndexSegment(data: SegmentMerger.merge([
            SegmentMerger.Input(segment: built, tombstones: deleted),
            SegmentMerger.Input(segment: other, tombstones: Bitset()),
        ]))
        XCTAssertEqual(merged.documentCount, built.documentCount - deleted.count + 90)
        XCTAssertEqual(storedTermLists(merged), termsByDocument(merged))
        XCTAssertTrue(storedTermLists(merged).allSatisfy { $0 == $0.sorted() && Set($0).count == $0.count })
    }

    func testTermSignaturesAreTheScalarsOfEachTerm() throws {
        var corpus = RandomCorpus(seed: 8)
        let built = try segment(corpus.items(120).map { SearchProjector.project($0, locale: Locale(identifier: "en"), secondaryLanguages: ["ja"]) })
        built.withView { view in
            for term in 0..<built.termCount {
                let text = view.termString(term)
                XCTAssertEqual(view.signature(term), TermSignature.of(EditDistance.scalars(text)), text)
            }
        }
        // Terms within k edits never differ by more than k scalars each way.
        XCTAssertTrue(TermSignature.mayBeWithin(1, TermSignature.of(EditDistance.scalars("harbor")), TermSignature.of(EditDistance.scalars("harbour"))))
        XCTAssertTrue(TermSignature.mayBeWithin(2, TermSignature.of(EditDistance.scalars("mystery")), TermSignature.of(EditDistance.scalars("mastory"))))
        XCTAssertFalse(TermSignature.mayBeWithin(2, TermSignature.of(EditDistance.scalars("mystery")), TermSignature.of(EditDistance.scalars("zombie"))))
    }

    func testAMergeIsByteForByteTheSegmentBuiltFromTheSameDocuments() throws {
        // Posting-level merging re-tokenizes nothing, and still yields exactly the segment a
        // build from the surviving documents yields: vocabulary, postings, statistics, trigram
        // index, term lists and signatures.
        let first = randomDocuments(140, seed: 9)
        let second = randomDocuments(60, seed: 10, from: 500)
        let third = randomDocuments(25, seed: 11, from: 900)
        var deleted = Bitset()
        var survivors: [SearchDocument] = []
        for (ordinal, document) in first.enumerated() {
            if ordinal % 4 == 1 { deleted.insert(ordinal) } else { survivors.append(document) }
        }
        let merged = SegmentMerger.merge([
            SegmentMerger.Input(segment: try segment(first), tombstones: deleted),
            SegmentMerger.Input(segment: try segment(second), tombstones: Bitset()),
            SegmentMerger.Input(segment: try segment(third), tombstones: Bitset()),
        ])
        let direct = SegmentBuilder.build([DocumentTokenizer.tokenize(survivors + second + third)])
        let mergedSegment = try IndexSegment(data: merged)
        let directSegment = try IndexSegment(data: direct)
        for section in SegmentFormat.Section.allCases {
            XCTAssertEqual(mergedSegment.sectionBytes(section), directSegment.sectionBytes(section), "section \(section)")
        }
        XCTAssertEqual(merged, direct)
    }

    // MARK: Locale changes

    func testALocaleChangeLeavesItemsWithoutLocalizationsAlone() async {
        // Nothing in this catalog carries a localization: its projection is the same in every
        // locale, so a locale change tokenizes nothing and keeps the segment it has.
        var corpus = RandomCorpus(seed: 12)
        let items: [AnySearchable<CatalogKind>] = (0..<700).map { AnySearchable(Tool(id: "t\($0)", title: corpus.words(1..<4), text: corpus.words(4..<20))) }
        let index = LexicalIndex()
        let service = CatalogService(index: index, configuration: TestSupport.configuration())
        await service.index(items)
        let shape = await index.settledShape.map { [$0.documents, $0.deleted] }
        XCTAssertEqual(shape, [[700, 0]])

        await service.setLocale(Locale(identifier: "it"))
        let languages = await service.resolvedLanguages
        XCTAssertEqual(languages.active, "it")
        let after = await index.settledShape.map { [$0.documents, $0.deleted] }
        XCTAssertEqual(after, shape, "no document was replaced")
        let metadata = await index.metadata
        XCTAssertEqual(metadata.localeTag, "it", "the index is now recorded as built for the new locale")
        let found = await TestSupport.final(service, "mystery")
        XCTAssertFalse(TestSupport.ids(found).isEmpty)
    }

    func testALocaleChangeYieldsTheIndexAFreshBuildWouldYield() async throws {
        var corpus = RandomCorpus(seed: 13)
        let items = corpus.items(600)
        XCTAssertTrue(items.contains(where: CatalogService.isLocalized) && items.contains(where: { !CatalogService.isLocalized($0) }))
        let localized = items.filter(CatalogService.isLocalized).count

        let changedIndex = LexicalIndex()
        let changed = CatalogService(index: changedIndex, configuration: TestSupport.configuration(locale: "en"))
        await changed.index(items)
        await changed.setLocale(Locale(identifier: "it"))
        // Only the items that carry localizations could have been replaced.
        let replaced = await changedIndex.settledShape.map(\.deleted).reduce(0, +)
        XCTAssertLessThanOrEqual(replaced, localized)

        let freshIndex = LexicalIndex()
        let fresh = CatalogService(index: freshIndex, configuration: TestSupport.configuration(locale: "it"))
        await fresh.index(items)

        let changedCount = await changedIndex.count
        let freshCount = await freshIndex.count
        XCTAssertEqual(changedCount, freshCount)
        let changedStatistics = await changedIndex.statistics
        let freshStatistics = await freshIndex.statistics
        XCTAssertEqual(changedStatistics.documentCount, freshStatistics.documentCount)
        XCTAssertEqual(changedStatistics.totalFieldLengths, freshStatistics.totalFieldLengths)
        for item in items.prefix(200) {
            let lhs = await changedIndex.document(for: item.searchID)
            let rhs = await freshIndex.document(for: item.searchID)
            XCTAssertEqual(lhs, rhs, item.searchID.rawValue)
        }
        for _ in 0..<60 {
            let query = corpus.words(1..<4)
            let lhs = await TestSupport.final(changed, query)
            let rhs = await TestSupport.final(fresh, query)
            XCTAssertEqual(lhs?.hits.map(\.id), rhs?.hits.map(\.id), query)
            XCTAssertEqual(lhs?.hits.map(\.score), rhs?.hits.map(\.score), query)
            XCTAssertEqual(lhs?.hits.map(\.matchedLanguage), rhs?.hits.map(\.matchedLanguage), query)
        }
    }

    // MARK: The semantic path

    func testRequiredPhrasesHoldForSemanticNeighboursToo() async {
        let semantic = StubSemantic()
        // The model finds four neighbours; one of them holds the phrase.
        await semantic.script("layout", ["tip-thirty", "map-harbor", "map-temple", "tool-timer"])
        let query = SearchQuery<CatalogSchema>(text: "layout", tokens: [.phrase("harbor with every door")])
        let service = await TestSupport.indexedService(TestSupport.catalog, semantic: semantic)
        let snapshots = await TestSupport.all(service, query)
        XCTAssertEqual(snapshots.map(\.phase), [.lexical, .semantic])
        for snapshot in snapshots {
            XCTAssertEqual(TestSupport.ids(snapshot), ["map-harbor"], "\(snapshot.phase)")
        }
        // Without the phrase the same neighbours all come through.
        let free = await TestSupport.final(service, SearchQuery(text: "layout"))
        XCTAssertEqual(Set(TestSupport.ids(free)), ["tip-thirty", "map-harbor", "map-temple", "tool-timer"])
    }

    func testRequiredPhrasesHoldForTheVectorsOfAScanContext() async {
        // A scan context compares the query with the vectors its items carry, by brute force.
        var near = Tip(id: "tip-near", title: "Lantern route", text: "Follow the lanterns to the north gate.")
        near.embedding = [0.5, 0.5, 0.5, 0.5]
        var far = Tip(id: "tip-far", title: "Lantern colours", text: "Blue lanterns mark the safe rooms.")
        far.embedding = [0.5, 0.5, 0.5, 0.4]
        let semantic = StubSemantic()
        let service = TestSupport.scanService([AnySearchable(near), AnySearchable(far)], semantic: semantic)
        let both = await TestSupport.all(service, SearchQuery(text: "quite unrelated words"))
        XCTAssertEqual(both.last?.phase, .semantic)
        XCTAssertEqual(Set(TestSupport.ids(both.last)), ["tip-near", "tip-far"])
        let phrased = await TestSupport.all(service, SearchQuery(text: "quite unrelated words", tokens: [.phrase("safe rooms")]))
        XCTAssertEqual(phrased.last?.phase, .semantic)
        XCTAssertEqual(TestSupport.ids(phrased.last), ["tip-far"])
    }

    func testAConstrainedQueryAsksForMoreNeighboursAndKeepsTheOnesAllowed() async {
        actor Recorder: SemanticSearching {
            nonisolated let modelID = "recorder"
            nonisolated let dimensions = 2
            private(set) var limits: [Int] = []
            let ids: [SearchableID]
            init(ids: [SearchableID]) { self.ids = ids }
            func encodeQuery(_ text: String, locale: Locale?) async throws -> [Float] { [1, 0] }
            func nearest(to vector: [Float], limit: Int) async throws -> [SemanticMatch] {
                limits.append(limit)
                return ids.prefix(limit).enumerated().map { SemanticMatch(id: $1, similarity: 0.9 - Float($0) * 0.001) }
            }
            func upsert(_ vectors: [SearchableID: [Float]]) async throws {}
            func remove(_ ids: [SearchableID]) async {}
            func unload() async {}
        }
        // 300 tools, every fourth on the Mac: the first 50 neighbours hold 13 of them.
        let items: [AnySearchable<CatalogKind>] = (0..<300).map {
            AnySearchable(Tool(id: "t\($0)", title: "Tool \($0)", text: "A plain tool.", filters: [.platform($0 % 4 == 0 ? .mac : .ios)]))
        }
        let recorder = Recorder(ids: items.map(\.searchID))
        let service = await TestSupport.indexedService(items, semantic: recorder)

        let unconstrained = await TestSupport.final(service, SearchQuery(text: "whatever else"))
        XCTAssertEqual(unconstrained?.phase, .semantic)
        let constrained = await TestSupport.final(service, SearchQuery(text: "whatever else", tokens: [.filter(.platform(.mac))]))
        let limits = await recorder.limits
        XCTAssertEqual(limits, [50, 200], "50 neighbours, four times as many when a constraint will thin them out")
        let hits = constrained?.hits ?? []
        XCTAssertEqual(hits.count, 20)
        XCTAssertTrue(hits.allSatisfy { Int($0.id.rawValue.dropFirst())! % 4 == 0 }, "no hit violates the filter")
        var wide = SearchQuery<CatalogSchema>(text: "whatever else", tokens: [.filter(.platform(.mac))])
        wide.limit = 100
        let second = await TestSupport.final(service, wide)
        XCTAssertEqual(second?.hits.count, 50, "the list fused is still at most 50 neighbours long")
    }

    func testRefusedVectorsAreReportedAndTheItemsStayFindable() async {
        actor Refusing: SemanticSearching {
            nonisolated let modelID = "refusing"
            nonisolated let dimensions = 8
            func encodeQuery(_ text: String, locale: Locale?) async throws -> [Float] { [Float](repeating: 0.3, count: 8) }
            func nearest(to vector: [Float], limit: Int) async throws -> [SemanticMatch] { [] }
            func upsert(_ vectors: [SearchableID: [Float]]) async throws { throw SearchError.unsupported("vectors of 3 dimensions, expected 8") }
            func remove(_ ids: [SearchableID]) async {}
            func unload() async {}
        }
        let recorder = DiagnosticsRecorder()
        var tip = Tip(id: "tip-vector", title: "Lantern route", text: "Follow the lanterns to the gate.")
        tip.embedding = [0.1, 0.2, 0.3]
        let service = await TestSupport.indexedService(
            [AnySearchable(tip)], configuration: TestSupport.configuration(diagnostics: recorder.sink), semantic: Refusing()
        )
        let found = await TestSupport.final(service, "lantern")
        XCTAssertEqual(TestSupport.ids(found), ["tip-vector"])
        let reported = await recorder.finish()
        XCTAssertTrue(reported.contains { diagnostic in
            if case .channelDegraded(channel: .semantic, let reason) = diagnostic { return reason.contains("refused") }
            return false
        }, "\(reported)")
    }

    func testCalibrationStartsOnlyOnceASemanticSnapshotIsOut() async {
        let semantic = StubSemantic()
        await semantic.script("harbor door", ["map-harbor", "tip-doors"])
        let reranker = StubReranker(enabled: true)
        var configuration = TestSupport.configuration()
        configuration.reranking = .auto
        let service = await TestSupport.indexedService(TestSupport.catalog, configuration: configuration, semantic: semantic, reranker: reranker)

        // A query the semantic channel does not run for: no calibration.
        _ = await TestSupport.final(service, "m1911-a1")
        var calls = await reranker.enabledCalls
        XCTAssertEqual(calls, 0)

        // The first query with a semantic snapshot starts it, and is not reranked itself.
        let first = await TestSupport.all(service, SearchQuery(text: "harbor door"))
        XCTAssertEqual(first.map(\.phase), [.lexical, .semantic])
        XCTAssertEqual(first.last?.degraded, [])
        let measured = await eventually { await reranker.enabledCalls == 1 }
        XCTAssertTrue(measured)
        let scored = await reranker.scoreCalls
        XCTAssertEqual(scored, 0)

        // From the next query on the stage runs, and the verdict is not measured again.
        let second = await eventually {
            await TestSupport.all(service, SearchQuery(text: "harbor door")).map(\.phase) == [.lexical, .semantic, .reranked]
        }
        XCTAssertTrue(second)
        calls = await reranker.enabledCalls
        XCTAssertEqual(calls, 1)
    }
}
