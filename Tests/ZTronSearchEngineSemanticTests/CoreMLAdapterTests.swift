import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSemantic

/// A sequence model scripted by a closure: stands in for Core ML.
private final class ScriptedModel: SequenceModelRunning {
    private let run: @Sendable (ModelInputBatch) throws -> [ModelOutputRow]

    init(_ run: @escaping @Sendable (ModelInputBatch) throws -> [ModelOutputRow]) {
        self.run = run
    }

    func predict(_ batch: ModelInputBatch) throws -> [ModelOutputRow] {
        try run(batch)
    }
}

private struct ScriptFailure: Error, Equatable {
    var message: String
}

/// The label of the dispatch queue the caller is running on.
private func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}

/// The adapters with everything but the `MLModel` call: tokenizer selection, batch assembly,
/// the one batched call, pooling, scoring, lazy loading, unloading and the size budget.
final class CoreMLAdapterTests: XCTestCase {
    private let megabyte: Int64 = 1_048_576
    private let modelURL = URL(fileURLWithPath: "/models/Model.mlmodelc")

    private func wordPiece() throws -> WordPieceTokenizer {
        try WordPieceTokenizer(vocabulary: WordPieceTokenizerTests.vocabulary)
    }

    private func loader(
        footprint: Int64 = 30 * 1_048_576,
        tokenizer: any TextTokenizing,
        model: @escaping @Sendable (ModelInputBatch) throws -> [ModelOutputRow]
    ) -> SequenceModelLoader {
        SequenceModelLoader(
            footprint: { _ in footprint },
            tokenizer: { _, _ in tokenizer },
            model: { _, _, _, _, _ in ScriptedModel(model) }
        )
    }

    /// Token embeddings of 8 dimensions: token `t` at any position is the unit vector of axis
    /// `t % 8`; padding positions hold garbage that a correct pooling never reads.
    private static func tokenEmbeddings(_ batch: ModelInputBatch) -> [ModelOutputRow] {
        (0..<batch.rowCount).map { row in
            var values = [Float](repeating: 0, count: batch.sequenceLength * 8)
            let ids = Array(batch.inputIDs(row: row))
            let mask = Array(batch.attentionMask(row: row))
            for position in 0..<batch.sequenceLength {
                if mask[position] == 0 {
                    for axis in 0..<8 { values[position * 8 + axis] = 1_000 }
                } else {
                    values[position * 8 + Int(ids[position]) % 8] = 1
                }
            }
            return ModelOutputRow(shape: [1, batch.sequenceLength, 8], values: values)
        }
    }

    /// What mean pooling and normalization must make of ``tokenEmbeddings(_:)`` for `ids`.
    private func expectedVector(for ids: [Int32]) -> [Float] {
        var histogram = [Float](repeating: 0, count: 8)
        for id in ids { histogram[Int(id) % 8] += 1 }
        VectorKernels.normalize(&histogram)
        return histogram
    }

    private func embeddingConfiguration(
        dimensions: Int = 8,
        pooling: EmbeddingPoolingStrategy = .automatic,
        queryPrefix: String = "",
        sizeBudget: Int64 = SemanticLimits.embeddingModelBudget,
        releasesTokenizerOnUnload: Bool = true
    ) -> CoreMLEmbeddingProvider.Configuration {
        .init(
            modelURL: modelURL, modelID: "embedding-test", dimensions: dimensions, pooling: pooling,
            queryPrefix: queryPrefix, sizeBudget: sizeBudget, releasesTokenizerOnUnload: releasesTokenizerOnUnload
        )
    }

    // MARK: Embedding provider

    func testEncodingTokenizesPoolsUnderTheMaskAndNormalizes() async throws {
        let tokenizer = try wordPiece()
        let provider = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(),
            loader: loader(tokenizer: tokenizer) { batch in
                guard batch.rowCount == 1, batch.sequenceLength == 128 else { throw ScriptFailure(message: "one window of 128 tokens expected") }
                return Self.tokenEmbeddings(batch)
            }
        )
        XCTAssertEqual(provider.modelID, "embedding-test")
        XCTAssertEqual(provider.dimensions, 8)

        for text in ["the cat sat on the mat", "Hello, world!", "", String(repeating: "the cat ", count: 300)] {
            let vector = try await provider.encode(text, locale: Locale(identifier: "en"))
            // [CLS] tokens [SEP], cut to the 128-token window.
            let ids = Array(tokenizer.encode(text).inputIDs.prefix(tokenizer.encode(text).tokenCount))
            let expected = expectedVector(for: ids)
            XCTAssertEqual(vector.count, 8)
            XCTAssertEqual(VectorKernels.norm(vector), 1, accuracy: 1e-5, "unit length")
            for axis in 0..<8 {
                XCTAssertEqual(vector[axis], expected[axis], accuracy: 1e-5, "text '\(text.prefix(20))' axis \(axis)")
            }
        }
    }

    func testAPooledOutputIsOnlyNormalizedAndTheFirstTokenCanBeAskedFor() async throws {
        let tokenizer = try wordPiece()
        let pooled = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(dimensions: 4),
            loader: loader(tokenizer: tokenizer) { _ in [ModelOutputRow(shape: [1, 4], values: [0, 6, 0, 8])] }
        )
        let vector = try await pooled.encode("the cat", locale: nil)
        XCTAssertEqual(vector, [0, 0.6, 0, 0.8])

        // "the" is id 5; the first token is [CLS], id 2.
        let first = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(pooling: .firstToken),
            loader: loader(tokenizer: tokenizer, model: Self.tokenEmbeddings)
        )
        let cls = try await first.encode("the the the the", locale: nil)
        XCTAssertEqual(cls, [0, 0, 1, 0, 0, 0, 0, 0])
    }

    func testTheQueryPrefixIsEncodedWithTheQuery() async throws {
        let tokenizer = try wordPiece()
        let provider = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(queryPrefix: "hello , "),
            loader: loader(tokenizer: tokenizer, model: Self.tokenEmbeddings)
        )
        let vector = try await provider.encode("the cat", locale: nil)
        let ids = tokenizer.encode("hello , the cat")
        let expected = expectedVector(for: Array(ids.inputIDs.prefix(ids.tokenCount)))
        for axis in 0..<8 { XCTAssertEqual(vector[axis], expected[axis], accuracy: 1e-5) }
        let plain = expectedVector(for: Array(tokenizer.encode("the cat").inputIDs.prefix(4)))
        XCTAssertNotEqual(expected, plain)
    }

    func testTheModelLoadsLazilyAndReloadsAfterUnload() async throws {
        let tokenizer = try wordPiece()
        let provider = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(),
            loader: loader(tokenizer: tokenizer, model: Self.tokenEmbeddings)
        )
        var loads = await provider.loadCount
        var isLoaded = await provider.isLoaded
        XCTAssertEqual(loads, 0, "creating the provider loads nothing")
        XCTAssertFalse(isLoaded)
        await provider.unload()

        let first = try await provider.encode("the cat", locale: nil)
        _ = try await provider.encode("the mat", locale: nil)
        _ = try await provider.encode("hello", locale: nil)
        loads = await provider.loadCount
        isLoaded = await provider.isLoaded
        var predictions = await provider.predictionCount
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(isLoaded)
        XCTAssertEqual(predictions, 3)

        await provider.unload()
        isLoaded = await provider.isLoaded
        XCTAssertFalse(isLoaded)
        let again = try await provider.encode("the cat", locale: nil)
        XCTAssertEqual(first, again)
        loads = await provider.loadCount
        predictions = await provider.predictionCount
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(predictions, 4)
    }

    func testAModelOverItsBudgetIsRefusedBeforeAnythingIsLoaded() async throws {
        let tokenizer = try wordPiece()
        // 81 MB against the 80 MB budget of the embedding model.
        let provider = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(),
            loader: SequenceModelLoader(
                footprint: { _ in 81 * 1_048_576 },
                tokenizer: { _, _ in throw ScriptFailure(message: "the tokenizer must not be read") },
                model: { _, _, _, _, _ in throw ScriptFailure(message: "the model must not be loaded") }
            )
        )
        await assertThrowsAsync(.modelOverBudget(bytes: 81 * megabyte, budget: 80 * megabyte)) { try await provider.encode("the cat", locale: nil) }
        let loads = await provider.loadCount
        XCTAssertEqual(loads, 0)

        // Exactly on budget loads.
        let onBudget = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(),
            loader: loader(footprint: 80 * megabyte, tokenizer: tokenizer, model: Self.tokenEmbeddings)
        )
        _ = try await onBudget.encode("the cat", locale: nil)
        // And the budget is configurable.
        let tight = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(sizeBudget: 10 * megabyte),
            loader: loader(footprint: 30 * megabyte, tokenizer: tokenizer, model: Self.tokenEmbeddings)
        )
        await assertThrowsAsync(.modelOverBudget(bytes: 30 * megabyte, budget: 10 * megabyte)) { try await tight.encode("the cat", locale: nil) }
        XCTAssertEqual(SemanticLimits.embeddingModelBudget, 80 * megabyte)
        XCTAssertEqual(SemanticLimits.rerankerModelBudget, 60 * megabyte)
    }

    func testTheBudgetIsCheckedAgainstTheFilesOnDisk() async throws {
        // A stand-in for a compiled model: a directory of files, 1,200 bytes in all.
        let directory = try TemporaryDirectory()
        let model = directory.file("Embedding.mlmodelc")
        try FileManager.default.createDirectory(at: model.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try Data(count: 700).write(to: model.appendingPathComponent("weights/weight.bin"))
        try Data(count: 500).write(to: model.appendingPathComponent("model.mil"))
        XCTAssertEqual(try FileAccess.footprintBlocking(of: model), 1_200)
        XCTAssertEqual(try FileAccess.footprintBlocking(of: model.appendingPathComponent("model.mil")), 500)

        // The real loader: over budget is refused first, whatever else is wrong with the model.
        let over = CoreMLEmbeddingProvider(configuration: .init(modelURL: model, modelID: "m", dimensions: 8, sizeBudget: 1_000))
        await assertThrowsAsync(.modelOverBudget(bytes: 1_200, budget: 1_000)) { try await over.encode("the cat", locale: nil) }

        // Within budget, the next thing missing is the tokenizer...
        let within = CoreMLEmbeddingProvider(configuration: .init(modelURL: model, modelID: "m", dimensions: 8, sizeBudget: 2_000))
        do {
            _ = try await within.encode("the cat", locale: nil)
            XCTFail("a model without a tokenizer must not load")
        } catch let error as SemanticError {
            guard case .tokenizerUnavailable = error else { return XCTFail("unexpected \(error)") }
        }
        // ...and with a tokenizer next to it, Core ML refuses the stand-in: an error, not a crash.
        try Data((WordPieceTokenizerTests.vocabulary.joined(separator: "\n")).utf8).write(to: directory.file("vocab.txt"))
        do {
            _ = try await within.encode("the cat", locale: nil)
            XCTFail("a directory that is not a compiled model must not load")
        } catch let error as SemanticError {
            guard case .modelUnavailable = error else { return XCTFail("unexpected \(error)") }
        }
        let loads = await within.loadCount
        XCTAssertEqual(loads, 0)

        // A model that is not there at all.
        let missing = CoreMLEmbeddingProvider(configuration: .init(modelURL: directory.file("Missing.mlmodelc"), modelID: "m", dimensions: 8))
        do {
            _ = try await missing.encode("the cat", locale: nil)
            XCTFail("a missing model must not load")
        } catch let error as SemanticError {
            guard case .io = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testTheTokenizerIsKeptOrReleasedWithTheModelAsConfigured() async throws {
        func provider(releasing: Bool, in directory: TemporaryDirectory) -> CoreMLEmbeddingProvider {
            // The real tokenizer loader, reading the files of `directory`; a scripted model.
            CoreMLEmbeddingProvider(
                configuration: .init(
                    modelURL: directory.file("Embedding.mlmodelc"), modelID: "m", dimensions: 8,
                    tokenizerDirectory: directory.url, releasesTokenizerOnUnload: releasing
                ),
                loader: SequenceModelLoader(
                    footprint: { _ in 1 },
                    tokenizer: SequenceModelLoader.coreML.tokenizer,
                    model: { _, _, _, _, _ in ScriptedModel(Self.tokenEmbeddings) }
                )
            )
        }
        for releasing in [true, false] {
            let directory = try TemporaryDirectory()
            try TokenizerLoaderTests.unigramTokenizerJSON().write(to: directory.file("tokenizer.json"))
            let provider = provider(releasing: releasing, in: directory)
            _ = try await provider.encode("hello world", locale: nil)
            await provider.unload()
            // With the files gone, only a retained tokenizer can still encode.
            try FileManager.default.removeItem(at: directory.file("tokenizer.json"))
            if releasing {
                do {
                    _ = try await provider.encode("hello world", locale: nil)
                    XCTFail("the tokenizer was released and its files are gone")
                } catch let error as SemanticError {
                    guard case .tokenizerUnavailable = error else { return XCTFail("unexpected \(error)") }
                }
            } else {
                _ = try await provider.encode("hello world", locale: nil)
                let loads = await provider.loadCount
                XCTAssertEqual(loads, 2, "the model itself was released and loaded again")
            }
        }
    }

    func testAModelOfAnotherWidthOrWithABrokenOutputIsRefused() async throws {
        let tokenizer = try wordPiece()
        let wide = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(dimensions: 384),
            loader: loader(tokenizer: tokenizer, model: Self.tokenEmbeddings)
        )
        await assertThrowsAsync(.dimensionMismatch(expected: 384, found: 8)) { try await wide.encode("the cat", locale: nil) }

        let outputs: [@Sendable (ModelInputBatch) throws -> [ModelOutputRow]] = [
            { _ in [] },
            { batch in Self.tokenEmbeddings(batch) + Self.tokenEmbeddings(batch) },
            { _ in [ModelOutputRow(shape: [1, 8], values: [Float](repeating: 0, count: 8))] },
            { _ in [ModelOutputRow(shape: [1, 2, 2, 2], values: [Float](repeating: 1, count: 8))] },
        ]
        for output in outputs {
            let provider = CoreMLEmbeddingProvider(configuration: embeddingConfiguration(), loader: loader(tokenizer: tokenizer, model: output))
            do {
                _ = try await provider.encode("the cat", locale: nil)
                XCTFail("a broken output must be refused")
            } catch let error as SemanticError {
                guard case .unexpectedModelOutput = error else { return XCTFail("unexpected \(error)") }
            }
        }
        // A failure inside the model surfaces as it is.
        let failing = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(),
            loader: loader(tokenizer: tokenizer) { _ in throw ScriptFailure(message: "inference failed") }
        )
        do {
            _ = try await failing.encode("the cat", locale: nil)
            XCTFail("the model's failure must surface")
        } catch {
            XCTAssertEqual(error as? ScriptFailure, ScriptFailure(message: "inference failed"))
        }
    }

    func testEncodingOnACancelledTaskDoesNotLoadTheModel() async throws {
        let provider = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(),
            loader: loader(tokenizer: try wordPiece(), model: Self.tokenEmbeddings)
        )
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await provider.encode("the cat", locale: nil)
                return false
            } catch {
                return error is CancellationError
            }
        }
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
        let loads = await provider.loadCount
        XCTAssertEqual(loads, 0)
    }

    func testLoadingAndPredictionRunOnTheAdaptersOwnQueueNotTheCooperativePool() async throws {
        let tokenizer = try wordPiece()
        let embeddingQueue = "com.ztron.searchengine.semantic.embedding-model"
        let provider = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(),
            loader: SequenceModelLoader(
                footprint: { _ in
                    guard currentQueueLabel() == embeddingQueue else { throw ScriptFailure(message: "sized on \(currentQueueLabel())") }
                    return 1
                },
                tokenizer: { _, _ in
                    guard currentQueueLabel() == embeddingQueue else { throw ScriptFailure(message: "tokenizer read on \(currentQueueLabel())") }
                    return tokenizer
                },
                model: { _, _, _, _, _ in
                    guard currentQueueLabel() == embeddingQueue else { throw ScriptFailure(message: "loaded on \(currentQueueLabel())") }
                    return ScriptedModel { batch in
                        guard currentQueueLabel() == embeddingQueue else { throw ScriptFailure(message: "predicted on \(currentQueueLabel())") }
                        return Self.tokenEmbeddings(batch)
                    }
                }
            )
        )
        _ = try await provider.encode("the cat", locale: nil)

        let rerankQueue = "com.ztron.searchengine.semantic.cross-encoder"
        let reranker = CoreMLCrossEncoder(
            configuration: .init(modelURL: modelURL, modelID: "reranker-test"),
            loader: SequenceModelLoader(
                footprint: { _ in 1 },
                tokenizer: { _, _ in tokenizer },
                model: { _, _, _, _, _ in
                    guard currentQueueLabel() == rerankQueue else { throw ScriptFailure(message: "loaded on \(currentQueueLabel())") }
                    return ScriptedModel { batch in
                        guard currentQueueLabel() == rerankQueue else { throw ScriptFailure(message: "predicted on \(currentQueueLabel())") }
                        return (0..<batch.rowCount).map { _ in ModelOutputRow(shape: [1, 1], values: [1]) }
                    }
                }
            )
        )
        _ = try await reranker.scores(query: "the cat", passages: ["the mat"])
    }

    func testItIsAnEmbeddingProviderForTheSemanticIndex() async throws {
        let tokenizer = try wordPiece()
        let provider: any EmbeddingProvider = CoreMLEmbeddingProvider(
            configuration: embeddingConfiguration(),
            loader: loader(tokenizer: tokenizer, model: Self.tokenEmbeddings)
        )
        let index = try SemanticIndex(provider: provider)
        XCTAssertEqual(index.modelID, "embedding-test")
        XCTAssertEqual(index.dimensions, 8)
        let embedded = try await index.embedMissing([("a", "the cat sat"), ("b", "hello world"), ("c", "on the mat")])
        XCTAssertEqual(embedded, ["a", "b", "c"])
        let query = try await index.encodeQuery("hello world", locale: nil)
        let best = try await index.nearest(to: query, limit: 1)
        XCTAssertEqual(best.first?.id, "b")
        await index.unload()
    }

    // MARK: Cross-encoder

    /// A relevance model that counts, per pair, the passage tokens that also occur in the query.
    private static func overlapScores(_ batch: ModelInputBatch) -> [ModelOutputRow] {
        (0..<batch.rowCount).map { row in
            let ids = Array(batch.inputIDs(row: row))
            let types = Array(batch.tokenTypeIDs(row: row))
            let mask = Array(batch.attentionMask(row: row))
            var query: Set<Int32> = []
            var overlap: Float = 0
            for position in 0..<batch.sequenceLength where mask[position] == 1 && ids[position] > 4 {
                if types[position] == 0 {
                    query.insert(ids[position])
                } else if query.contains(ids[position]) {
                    overlap += 1
                }
            }
            return ModelOutputRow(shape: [1, 1], values: [overlap])
        }
    }

    private func crossEncoder(
        sizeBudget: Int64 = SemanticLimits.rerankerModelBudget,
        footprint: Int64 = 40 * 1_048_576,
        model: @escaping @Sendable (ModelInputBatch) throws -> [ModelOutputRow] = CoreMLAdapterTests.overlapScores
    ) throws -> CoreMLCrossEncoder {
        CoreMLCrossEncoder(
            configuration: .init(modelURL: modelURL, modelID: "reranker-test", sizeBudget: sizeBudget),
            loader: loader(footprint: footprint, tokenizer: try wordPiece(), model: model)
        )
    }

    func testEveryPairIsScoredInOneBatchedCall() async throws {
        let reranker = try crossEncoder { batch in
            // Sixteen pairs, each in its own 128-token window, in a single call.
            guard batch.rowCount == 16, batch.sequenceLength == 128 else {
                throw ScriptFailure(message: "\(batch.rowCount) rows of \(batch.sequenceLength) tokens")
            }
            return Self.overlapScores(batch)
        }
        let passages = (0..<16).map { index in
            String(repeating: "the cat ", count: index) + String(repeating: "hello world ", count: 16 - index)
        }
        let scores = try await reranker.scores(query: "the cat sat", passages: passages)
        XCTAssertEqual(scores, (0..<16).map { Float(2 * $0) }, "one score per passage, in order")
        let predictions = await reranker.predictionCount
        let loads = await reranker.loadCount
        XCTAssertEqual(predictions, 1, "one batched call")
        XCTAssertEqual(loads, 1)
    }

    func testEachPairIsTruncatedToTheWindowWithTheQueryIntact() async throws {
        let reranker = try crossEncoder { batch in
            (0..<batch.rowCount).map { row in
                let ids = Array(batch.inputIDs(row: row))
                let types = Array(batch.tokenTypeIDs(row: row))
                let tokens = Array(batch.attentionMask(row: row)).reduce(0, +)
                // [CLS] the cat sat [SEP], then the passage in segment 1 up to the closing [SEP].
                let queryIsWhole = Array(ids.prefix(5)) == [2, 5, 6, 7, 3]
                let closes = ids[Int(tokens) - 1] == 3 && types[Int(tokens) - 1] == 1
                return ModelOutputRow(shape: [1, 1], values: [queryIsWhole && closes ? Float(tokens) : -1])
            }
        }
        let scores = try await reranker.scores(
            query: "the cat sat",
            passages: ["on the mat", String(repeating: "the mat ", count: 400), ""]
        )
        XCTAssertEqual(scores, [9, 128, 6])
    }

    func testTwoLogitModelsAreScoredByTheirMargin() async throws {
        let reranker = try crossEncoder { batch in
            (0..<batch.rowCount).map { ModelOutputRow(shape: [1, 2], values: [1, Float($0) * 2]) }
        }
        let scores = try await reranker.scores(query: "the cat", passages: ["a", "b", "c"])
        XCTAssertEqual(scores, [-1, 1, 3])
    }

    func testNoPassagesMeansNoScoresAndNoModel() async throws {
        let reranker = try crossEncoder()
        let scores = try await reranker.scores(query: "the cat", passages: [])
        XCTAssertTrue(scores.isEmpty)
        let loads = await reranker.loadCount
        XCTAssertEqual(loads, 0)
    }

    func testTheCrossEncoderLoadsLazilyUnloadsAndRefusesAModelOverBudget() async throws {
        let reranker = try crossEncoder()
        var loads = await reranker.loadCount
        XCTAssertEqual(loads, 0)
        _ = try await reranker.scores(query: "the cat", passages: ["the mat"])
        _ = try await reranker.scores(query: "the cat", passages: ["the mat", "hello"])
        loads = await reranker.loadCount
        XCTAssertEqual(loads, 1)
        await reranker.unload()
        var isLoaded = await reranker.isLoaded
        XCTAssertFalse(isLoaded)
        _ = try await reranker.scores(query: "the cat", passages: ["the mat"])
        loads = await reranker.loadCount
        isLoaded = await reranker.isLoaded
        XCTAssertEqual(loads, 2)
        XCTAssertTrue(isLoaded)

        // 61 MB against the 60 MB budget of the reranker.
        let heavy = CoreMLCrossEncoder(
            configuration: .init(modelURL: modelURL, modelID: "reranker-test"),
            loader: SequenceModelLoader(
                footprint: { _ in 61 * 1_048_576 },
                tokenizer: { _, _ in throw ScriptFailure(message: "the tokenizer must not be read") },
                model: { _, _, _, _, _ in throw ScriptFailure(message: "the model must not be loaded") }
            )
        )
        await assertThrowsAsync(.modelOverBudget(bytes: 61 * megabyte, budget: 60 * megabyte)) {
            try await heavy.scores(query: "the cat", passages: ["the mat"])
        }
        let heavyLoads = await heavy.loadCount
        XCTAssertEqual(heavyLoads, 0)
    }

    func testAnOutputThatDoesNotMatchThePairsIsRefused() async throws {
        let short = try crossEncoder { _ in [ModelOutputRow(shape: [1, 1], values: [1])] }
        do {
            _ = try await short.scores(query: "the cat", passages: ["a", "b"])
            XCTFail("one score for two pairs must be refused")
        } catch let error as SemanticError {
            guard case .unexpectedModelOutput = error else { return XCTFail("unexpected \(error)") }
        }
        let wide = try crossEncoder { batch in (0..<batch.rowCount).map { _ in ModelOutputRow(shape: [1, 3], values: [1, 2, 3]) } }
        do {
            _ = try await wide.scores(query: "the cat", passages: ["a"])
            XCTFail("three logits are not a relevance score")
        } catch let error as SemanticError {
            guard case .unexpectedModelOutput = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testOnItsOwnTheCrossEncoderIsNeverEnabledUnderAuto() async throws {
        let reranker: any Reranking = try crossEncoder()
        XCTAssertEqual(reranker.modelID, "reranker-test")
        let enabled = await reranker.isEnabled()
        XCTAssertFalse(enabled, "only a calibration verdict enables the stage")
        // Core's default `invalidateCalibration` is a no-op for a model without a gate.
        await reranker.invalidateCalibration()
        let scores = try await reranker.scores(query: "the cat", passages: ["the cat"])
        XCTAssertEqual(scores, [2])
        await reranker.unload()
    }

    func testComputeUnitsMapOntoCoreML() {
        XCTAssertEqual(ModelComputeUnits.all.coreML, .all)
        XCTAssertEqual(ModelComputeUnits.cpuOnly.coreML, .cpuOnly)
        XCTAssertEqual(ModelComputeUnits.cpuAndGPU.coreML, .cpuAndGPU)
        if #available(macOS 13.0, iOS 16.0, *) {
            XCTAssertEqual(ModelComputeUnits.cpuAndNeuralEngine.coreML, .cpuAndNeuralEngine)
        } else {
            XCTAssertEqual(ModelComputeUnits.cpuAndNeuralEngine.coreML, .all)
        }
        let names = ModelFeatureNames()
        XCTAssertEqual(names.inputIDs, "input_ids")
        XCTAssertEqual(names.attentionMask, "attention_mask")
        XCTAssertEqual(names.tokenTypeIDs, "token_type_ids")
        XCTAssertNil(names.output)
        let configuration = CoreMLEmbeddingProvider.Configuration(modelURL: modelURL, modelID: "m", dimensions: 384)
        XCTAssertEqual(configuration.computeUnits, .all)
        XCTAssertEqual(configuration.sequenceLength, 128)
        XCTAssertEqual(configuration.sizeBudget, 80 * megabyte)
        XCTAssertEqual(CoreMLCrossEncoder.Configuration(modelURL: modelURL, modelID: "r").sizeBudget, 60 * megabyte)
    }
}
