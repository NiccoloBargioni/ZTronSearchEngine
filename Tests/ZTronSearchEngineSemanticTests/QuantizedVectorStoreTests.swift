import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSemantic

final class QuantizedVectorStoreTests: XCTestCase {
    private let modelID = "test-model-v1"

    private func entries(count: Int, dimensions: Int, seed: UInt64, prefix: String = "item") -> [(SearchableID, [Float])] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { (SearchableID("\(prefix)-\($0)"), generator.unitVector(dimensions)) }
    }

    // MARK: Building and looking up

    func testBuildKeepsOrderAndFindsEveryIDByBinarySearch() throws {
        let vectors = entries(count: 700, dimensions: 48, seed: 21)
        let store = try QuantizedVectorStore.build(from: vectors, modelID: modelID, dimensions: 48)
        XCTAssertEqual(store.count, 700)
        XCTAssertEqual(store.liveCount, 700)
        XCTAssertEqual(store.tombstoneCount, 0)
        XCTAssertEqual(store.modelID, modelID)
        XCTAssertEqual(store.dimensions, 48)
        XCTAssertEqual(store.ids, vectors.map(\.0))
        for (ordinal, entry) in vectors.enumerated() {
            XCTAssertEqual(store.ordinal(of: entry.0), ordinal)
            XCTAssertEqual(store.id(at: ordinal), entry.0)
        }
        XCTAssertNil(store.ordinal(of: "item-700"))
        XCTAssertNil(store.ordinal(of: ""))
        XCTAssertNil(store.ordinal(of: "item"))
        XCTAssertNil(store.id(at: 700))
        XCTAssertNil(store.id(at: -1))
        XCTAssertFalse(store.contains("missing"))
    }

    func testStoredVectorsAreWithinHalfAStepOfTheOriginals() throws {
        let vectors = entries(count: 400, dimensions: 384, seed: 22)
        let store = try QuantizedVectorStore.build(from: vectors, modelID: modelID, dimensions: 384)
        for (ordinal, entry) in vectors.enumerated() where ordinal % 7 == 0 {
            let decoded = try XCTUnwrap(store.vector(for: entry.0))
            XCTAssertEqual(decoded, store.vector(at: ordinal))
            for dimension in 0..<384 {
                let bound = store.quantization.maximumRoundTripError(dimension: dimension) * 1.001 + 1e-7
                XCTAssertLessThanOrEqual(abs(decoded[dimension] - entry.1[dimension]), bound)
            }
            XCTAssertEqual(try store.quantization.decode(try XCTUnwrap(store.codes(at: ordinal))), decoded)
        }
    }

    func testWhenAnIDRepeatsItsLastVectorWins() throws {
        var vectors = entries(count: 5, dimensions: 8, seed: 23)
        var generator = SeededGenerator(seed: 24)
        let replacement = generator.unitVector(8)
        vectors.append(("item-1", replacement))
        let quantization = try VectorQuantization.uniform(dimensions: 8)
        let store = try QuantizedVectorStore.build(from: vectors, modelID: modelID, dimensions: 8, quantization: quantization)
        XCTAssertEqual(store.count, 5)
        XCTAssertEqual(store.ordinal(of: "item-1"), 1)
        XCTAssertEqual(try XCTUnwrap(store.codes(at: 1)), try quantization.encode(replacement))
    }

    func testIDsThatArePrefixesOfEachOtherAndNonASCIIIDsResolve() throws {
        let ids: [SearchableID] = ["a", "ab", "abc", "", "tip/αβγ", "地図-1", "tip/αβ", "z"]
        var generator = SeededGenerator(seed: 25)
        let vectors = ids.map { ($0, generator.unitVector(8)) }
        let store = try QuantizedVectorStore.build(from: vectors, modelID: modelID, dimensions: 8)
        for (ordinal, id) in ids.enumerated() {
            XCTAssertEqual(store.ordinal(of: id), ordinal, "id '\(id)'")
            XCTAssertEqual(store.id(at: ordinal), id)
        }
        XCTAssertNil(store.ordinal(of: "abcd"))
        XCTAssertNil(store.ordinal(of: "tip/α"))
    }

    func testBuildRefusesVectorsThatDoNotFitTheSpace() {
        assertThrows(.dimensionMismatch(expected: 4, found: 3)) {
            try QuantizedVectorStore.build(from: [("a", [1, 0, 0])], modelID: self.modelID, dimensions: 4)
        }
        assertThrows(.unsupportedDimensions(385)) {
            try QuantizedVectorStore.build(from: [], modelID: self.modelID, dimensions: 385)
        }
        XCTAssertThrowsError(try QuantizedVectorStore.build(from: [("a", [1, .infinity, 0, 0])], modelID: modelID, dimensions: 4)) { error in
            guard case SemanticError.invalidVector = error else { return XCTFail("unexpected \(error)") }
        }
        assertThrows(.dimensionMismatch(expected: 4, found: 8)) {
            try QuantizedVectorStore(modelID: self.modelID, dimensions: 4, quantization: .uniform(dimensions: 8))
        }
    }

    // MARK: Files

    func testFileRoundTripPreservesEverything() async throws {
        let directory = try TemporaryDirectory()
        let vectors = entries(count: 600, dimensions: 384, seed: 26)
        let built = try QuantizedVectorStore.build(from: vectors, modelID: modelID, dimensions: 384)
        let url = directory.file("vectors.ztvec")
        try await built.write(to: url)

        let opened = try QuantizedVectorStore.open(url, expecting: .init(modelID: modelID, dimensions: 384))
        XCTAssertEqual(opened.modelID, built.modelID)
        XCTAssertEqual(opened.dimensions, built.dimensions)
        XCTAssertEqual(opened.quantization, built.quantization)
        XCTAssertEqual(opened.count, built.count)
        XCTAssertEqual(opened.liveCount, built.liveCount)
        XCTAssertEqual(opened.fingerprint, built.fingerprint)
        XCTAssertEqual(opened.ids, vectors.map(\.0))
        for ordinal in 0..<opened.count {
            XCTAssertEqual(opened.codes(at: ordinal), built.codes(at: ordinal))
        }
        XCTAssertEqual(opened.ordinal(of: "item-599"), 599)

        // The file is exactly header, tables and one byte per component.
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        XCTAssertGreaterThanOrEqual(size, 600 * 384)
        XCTAssertLessThan(size, 600 * 384 + 600 * 24 + 8_192)
    }

    func testOpeningMapsTheFileInsteadOfReadingIt() async throws {
        // 24,000 x 384 bytes: 9.2 MB of vectors. Opening must touch only the leading sections.
        let directory = try TemporaryDirectory()
        let count = 24_000
        var generator = SeededGenerator(seed: 27)
        let quantization = try VectorQuantization.uniform(dimensions: 384, bound: 0.3)
        var vectors: [(SearchableID, [Float])] = []
        vectors.reserveCapacity(count)
        for index in 0..<count { vectors.append((SearchableID("row-\(index)"), generator.unitVector(384))) }
        let url = directory.file("large.ztvec")
        try await QuantizedVectorStore.build(from: vectors, modelID: modelID, dimensions: 384, quantization: quantization).write(to: url)
        vectors.removeAll()

        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        let before = residentBytes()
        let store = try QuantizedVectorStore.open(url)
        let afterOpen = residentBytes()
        XCTAssertEqual(store.count, count)
        XCTAssertLessThan(afterOpen - before, fileSize / 4, "opening read \(afterOpen - before) of \(fileSize) bytes")

        // Reading rows pages them in on demand.
        XCTAssertEqual(store.id(at: count - 1), SearchableID("row-\(count - 1)"))
        XCTAssertNotNil(store.vector(at: count / 2))
        let matches = try store.nearest(to: generator.unitVector(384), limit: 5)
        XCTAssertEqual(matches.count, 5)
    }

    func testOpeningForAnotherModelOrDimensionCountThrows() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("vectors.ztvec")
        try await QuantizedVectorStore.build(from: entries(count: 20, dimensions: 32, seed: 28), modelID: modelID, dimensions: 32).write(to: url)

        assertThrows(.modelMismatch(expected: "another-model", found: modelID)) {
            try QuantizedVectorStore.open(url, expecting: .init(modelID: "another-model", dimensions: 32))
        }
        assertThrows(.dimensionMismatch(expected: 384, found: 32)) {
            try QuantizedVectorStore.open(url, expecting: .init(modelID: self.modelID, dimensions: 384))
        }
        XCTAssertNoThrow(try QuantizedVectorStore.open(url, expecting: .init(modelID: modelID, dimensions: 32)))
        XCTAssertNoThrow(try QuantizedVectorStore.open(url))
    }

    func testDamagedFilesAreRefusedWithoutTrapping() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("vectors.ztvec")
        try await QuantizedVectorStore.build(from: entries(count: 50, dimensions: 16, seed: 29), modelID: modelID, dimensions: 16).write(to: url)
        let good = try Data(contentsOf: url)

        func open(_ data: Data) throws -> QuantizedVectorStore {
            let damaged = directory.file("damaged-\(UUID().uuidString).ztvec")
            try data.write(to: damaged)
            return try QuantizedVectorStore.open(damaged)
        }
        func assertCorrupt(_ data: Data, _ message: String, line: UInt = #line) {
            XCTAssertThrowsError(try open(data), message, line: line) { error in
                guard case SemanticError.corruptFile = error else { return XCTFail("\(message): unexpected \(error)", line: line) }
            }
        }

        assertCorrupt(Data(), "empty file")
        assertCorrupt(good.prefix(20), "truncated header")
        assertCorrupt(good.prefix(good.count - 1), "truncated vectors")
        assertCorrupt(good + Data([0]), "trailing byte")
        var wrongMagic = good
        wrongMagic[0] = UInt8(ascii: "X")
        assertCorrupt(wrongMagic, "wrong magic")
        var wrongOrder = good
        wrongOrder.replaceSubrange(8..<12, with: [1, 2, 3, 4])
        assertCorrupt(wrongOrder, "wrong byte order")
        var wrongLive = good
        wrongLive[20] = 49
        assertCorrupt(wrongLive, "live count that disagrees with the tombstones")

        var future = good
        future[4] = 2
        assertThrows(.unsupportedFormatVersion(found: 2, supported: 1)) { try open(future) }
        var noDimensions = good
        noDimensions.replaceSubrange(12..<16, with: [0, 0, 0, 0])
        assertThrows(.unsupportedDimensions(0)) { try open(noDimensions) }

        XCTAssertThrowsError(try QuantizedVectorStore.open(directory.file("missing.ztvec"))) { error in
            guard case SemanticError.io = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: Changes in memory

    func testUpsertAppendsReplacesAndIgnoresRepeats() throws {
        // A uniform range of -1...1 never clamps a unit vector, so what is read back is the
        // vector that was stored, to within the quantization step.
        var store = try QuantizedVectorStore.build(
            from: entries(count: 300, dimensions: 32, seed: 30), modelID: modelID, dimensions: 32,
            quantization: .uniform(dimensions: 32)
        )
        var generator = SeededGenerator(seed: 31)
        let pristine = store.fingerprint

        // A new id is appended after the built rows.
        let fresh = generator.unitVector(32)
        let appended = try store.upsert("new-1", vector: fresh)
        XCTAssertEqual(appended, .init(ordinal: 300, replaced: nil, isUnchanged: false))
        XCTAssertEqual(store.count, 301)
        XCTAssertEqual(store.liveCount, 301)
        XCTAssertEqual(store.ordinal(of: "new-1"), 300)
        XCTAssertEqual(store.id(at: 300), "new-1")
        XCTAssertNotEqual(store.fingerprint, pristine)
        XCTAssertEqual(VectorKernels.dot(try XCTUnwrap(store.vector(for: "new-1")), fresh), 1, accuracy: 0.005)

        // Replacing a built row tombstones it and appends.
        let replacement = generator.unitVector(32)
        let replaced = try store.upsert("item-7", vector: replacement)
        XCTAssertEqual(replaced, .init(ordinal: 301, replaced: 7, isUnchanged: false))
        XCTAssertEqual(store.count, 302)
        XCTAssertEqual(store.liveCount, 301)
        XCTAssertEqual(store.tombstoneCount, 1)
        XCTAssertTrue(store.isTombstoned(7))
        XCTAssertNil(store.id(at: 7))
        XCTAssertNil(store.vector(at: 7))
        XCTAssertEqual(store.ordinal(of: "item-7"), 301)
        XCTAssertEqual(VectorKernels.dot(try XCTUnwrap(store.vector(for: "item-7")), replacement), 1, accuracy: 0.005)

        // Replacing an appended row works the same way.
        let again = generator.unitVector(32)
        XCTAssertEqual(try store.upsert("new-1", vector: again), .init(ordinal: 302, replaced: 300, isUnchanged: false))
        XCTAssertEqual(store.ordinal(of: "new-1"), 302)

        // The same vector again changes nothing.
        let before = store.fingerprint
        XCTAssertEqual(try store.upsert("new-1", vector: again), .init(ordinal: 302, replaced: nil, isUnchanged: true))
        XCTAssertEqual(try store.upsert("item-3", vector: try XCTUnwrap(store.vector(for: "item-3"))), .init(ordinal: 3, replaced: nil, isUnchanged: true))
        XCTAssertEqual(store.count, 303)
        XCTAssertEqual(store.fingerprint, before)

        XCTAssertEqual(store.ids.count, store.liveCount)
        XCTAssertEqual(Set(store.runtimeVectors().map(\.0)), ["new-1", "item-7"])
    }

    func testUpsertRefusesVectorsThatDoNotFitTheSpace() throws {
        var store = try QuantizedVectorStore(modelID: modelID, dimensions: 4, quantization: .uniform(dimensions: 4))
        assertThrows(.dimensionMismatch(expected: 4, found: 2)) { try store.upsert("a", vector: [1, 0]) }
        XCTAssertThrowsError(try store.upsert("a", vector: [1, 0, .nan, 0]))
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.isEmpty)
    }

    func testRemoveTombstonesAndAllowsReinsertion() throws {
        var store = try QuantizedVectorStore.build(from: entries(count: 40, dimensions: 16, seed: 32), modelID: modelID, dimensions: 16)
        let original = try XCTUnwrap(store.vector(for: "item-5"))
        XCTAssertEqual(store.remove("item-5"), 5)
        XCTAssertNil(store.ordinal(of: "item-5"))
        XCTAssertNil(store.vector(for: "item-5"))
        XCTAssertFalse(store.contains("item-5"))
        XCTAssertEqual(store.liveCount, 39)
        XCTAssertEqual(store.count, 40)
        XCTAssertNil(store.remove("item-5"))
        XCTAssertNil(store.remove("never-there"))
        XCTAssertFalse(store.ids.contains("item-5"))

        XCTAssertEqual(try store.upsert("item-5", vector: original).ordinal, 40)
        XCTAssertEqual(store.ordinal(of: "item-5"), 40)
        XCTAssertEqual(store.liveCount, 40)
        XCTAssertEqual(store.remove("item-5"), 40)
        XCTAssertNil(store.ordinal(of: "item-5"))
    }

    func testChangesSurviveAFileRoundTripWithStableOrdinals() async throws {
        let directory = try TemporaryDirectory()
        let first = directory.file("first.ztvec")
        try await QuantizedVectorStore.build(from: entries(count: 300, dimensions: 24, seed: 33), modelID: modelID, dimensions: 24).write(to: first)

        // Change a memory-mapped store, write it, open it again.
        var store = try QuantizedVectorStore.open(first)
        var generator = SeededGenerator(seed: 34)
        try store.upsert("item-10", vector: generator.unitVector(24))
        try store.upsert("added", vector: generator.unitVector(24))
        store.remove("item-20")
        let second = directory.file("second.ztvec")
        try await store.write(to: second)

        let reopened = try QuantizedVectorStore.open(second)
        XCTAssertEqual(reopened.count, 302)
        XCTAssertEqual(reopened.liveCount, 300)
        XCTAssertEqual(reopened.fingerprint, store.fingerprint)
        XCTAssertEqual(reopened.ordinal(of: "item-10"), 300)
        XCTAssertEqual(reopened.ordinal(of: "added"), 301)
        XCTAssertNil(reopened.ordinal(of: "item-20"))
        XCTAssertTrue(reopened.isTombstoned(10))
        XCTAssertTrue(reopened.isTombstoned(20))
        XCTAssertEqual(reopened.ids, store.ids)
        for ordinal in 0..<reopened.count {
            XCTAssertEqual(reopened.codes(at: ordinal), store.codes(at: ordinal))
        }
        // The first file is untouched.
        XCTAssertEqual(try QuantizedVectorStore.open(first).liveCount, 300)
        XCTAssertNotNil(try QuantizedVectorStore.open(first).ordinal(of: "item-20"))
    }

    func testCompactionDropsTombstonesAndRenumbers() throws {
        var store = try QuantizedVectorStore.build(from: entries(count: 300, dimensions: 16, seed: 35), modelID: modelID, dimensions: 16)
        var generator = SeededGenerator(seed: 36)
        store.remove("item-0")
        store.remove("item-299")
        try store.upsert("item-4", vector: generator.unitVector(16))
        let expected = store.ids
        let vectors = expected.map { store.vector(for: $0) }

        let compact = try store.compacted()
        XCTAssertEqual(compact.count, 298)
        XCTAssertEqual(compact.liveCount, 298)
        XCTAssertEqual(compact.tombstoneCount, 0)
        XCTAssertEqual(compact.ids, expected)
        XCTAssertEqual(compact.quantization, store.quantization)
        XCTAssertEqual(compact.ordinal(of: "item-1"), 0)
        XCTAssertEqual(compact.ordinal(of: "item-4"), 297)
        XCTAssertNil(compact.ordinal(of: "item-0"))
        XCTAssertEqual(expected.map { compact.vector(for: $0) }, vectors)
    }

    func testFingerprintIdentifiesContent() throws {
        let vectors = entries(count: 300, dimensions: 16, seed: 37)
        let one = try QuantizedVectorStore.build(from: vectors, modelID: modelID, dimensions: 16)
        let two = try QuantizedVectorStore.build(from: vectors, modelID: modelID, dimensions: 16)
        XCTAssertEqual(one.fingerprint, two.fingerprint)
        XCTAssertNotEqual(one.fingerprint, try QuantizedVectorStore.build(from: vectors, modelID: "other", dimensions: 16).fingerprint)
        XCTAssertNotEqual(one.fingerprint, try QuantizedVectorStore.build(from: Array(vectors.dropLast()), modelID: modelID, dimensions: 16).fingerprint)
        var swapped = vectors
        swapped.swapAt(0, 1)
        // The same vectors under other ordinals are another store: the graph addresses rows by ordinal.
        XCTAssertNotEqual(
            one.fingerprint,
            try QuantizedVectorStore.build(from: swapped, modelID: modelID, dimensions: 16, quantization: one.quantization).fingerprint
        )
        var changed = one
        changed.remove("item-3")
        XCTAssertNotEqual(changed.fingerprint, one.fingerprint)
    }

    // MARK: Exact search

    func testExhaustiveSearchMatchesANaiveScan() throws {
        let vectors = entries(count: 1_000, dimensions: 64, seed: 38)
        var store = try QuantizedVectorStore.build(from: vectors, modelID: modelID, dimensions: 64)
        var generator = SeededGenerator(seed: 39)
        // Appended rows and tombstones take part too.
        for index in 0..<30 { try store.upsert(SearchableID("extra-\(index)"), vector: generator.unitVector(64)) }
        store.remove("item-11")
        store.remove("extra-3")

        for _ in 0..<10 {
            let query = generator.unitVector(64)
            var expected: [(SearchableID, Float)] = []
            for id in store.ids {
                expected.append((id, VectorKernels.dot(query, try XCTUnwrap(store.vector(for: id)))))
            }
            expected.sort { $0.1 > $1.1 }
            let matches = try store.nearest(to: query, limit: 25)
            XCTAssertEqual(matches.count, 25)
            XCTAssertEqual(matches.map(\.id), expected.prefix(25).map(\.0))
            for (match, reference) in zip(matches, expected) {
                XCTAssertEqual(match.similarity, reference.1, accuracy: 1e-4)
            }
            XCTAssertFalse(matches.contains { $0.id == "item-11" || $0.id == "extra-3" })
            // Best first.
            XCTAssertEqual(matches.map(\.similarity), matches.map(\.similarity).sorted(by: >))
        }
    }

    func testExhaustiveSearchLimitsAndErrors() throws {
        let store = try QuantizedVectorStore.build(from: entries(count: 12, dimensions: 8, seed: 40), modelID: modelID, dimensions: 8)
        var generator = SeededGenerator(seed: 41)
        let query = generator.unitVector(8)
        XCTAssertEqual(try store.nearest(to: query, limit: 100).count, 12)
        XCTAssertEqual(try store.nearest(to: query, limit: 0).count, 0)
        assertThrows(.dimensionMismatch(expected: 8, found: 3)) { try store.nearest(to: [1, 0, 0], limit: 3) }
        XCTAssertThrowsError(try store.nearest(to: [.nan, 0, 0, 0, 0, 0, 0, 0], limit: 3))
        let empty = try QuantizedVectorStore(modelID: modelID, dimensions: 8, quantization: .uniform(dimensions: 8))
        XCTAssertEqual(try empty.nearest(to: query, limit: 3).count, 0)
    }

    func testAnEmptyStoreRoundTrips() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("empty.ztvec")
        try await QuantizedVectorStore(modelID: modelID, dimensions: 8, quantization: .uniform(dimensions: 8)).write(to: url)
        var store = try QuantizedVectorStore.open(url, expecting: .init(modelID: modelID, dimensions: 8))
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(try store.upsert("a", vector: [1, 0, 0, 0, 0, 0, 0, 0]).ordinal, 0)
        XCTAssertEqual(store.ordinal(of: "a"), 0)
    }
}

/// Resident size of this process, mapped file pages included.
private func residentBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
}
