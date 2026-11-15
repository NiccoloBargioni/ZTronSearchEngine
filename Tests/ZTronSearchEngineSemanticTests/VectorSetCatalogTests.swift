import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSemantic

/// Per-locale vector sets with base fallback (specification section 5, rule 8).
final class VectorSetCatalogTests: XCTestCase {
    private func files(_ name: String) -> VectorSetCatalog.Files {
        .init(vectors: URL(fileURLWithPath: "/sets/\(name).ztvec"), graph: URL(fileURLWithPath: "/sets/\(name).zthnsw"))
    }

    func testResolutionFollowsTheFieldFallbackChain() {
        let catalog = VectorSetCatalog(
            base: files("vectors"),
            localized: ["it": files("it"), "de-CH": files("de-CH"), "de": files("de"), "pt-BR": files("pt-BR"), "zh-Hans": files("zh-Hans")]
        )
        // Exact tag.
        XCTAssertEqual(catalog.resolve("it").languageTag, "it")
        XCTAssertEqual(catalog.resolve("de-CH").languageTag, "de-CH")
        XCTAssertEqual(catalog.resolve("de_CH").languageTag, "de-CH")
        XCTAssertEqual(catalog.resolve("de-ch").languageTag, "de-CH")
        // Language match.
        XCTAssertEqual(catalog.resolve("it-IT").languageTag, "it")
        XCTAssertEqual(catalog.resolve("it_IT@calendar=gregorian").languageTag, "it")
        XCTAssertEqual(catalog.resolve("de-AT").languageTag, "de")
        XCTAssertEqual(catalog.resolve("zh-Hans-CN").languageTag, "zh-Hans")
        // A regional set serves its language when it is the only one of that language.
        XCTAssertEqual(catalog.resolve("pt-PT").languageTag, "pt-BR")
        // Base fallback.
        XCTAssertNil(catalog.resolve("fr").languageTag)
        XCTAssertEqual(catalog.resolve("fr").files, files("vectors"))
        XCTAssertNil(catalog.resolve("fr-CA").languageTag)
        XCTAssertNil(catalog.resolve(nil).languageTag)
        XCTAssertNil(catalog.resolve("").languageTag)
        XCTAssertEqual(catalog.resolve("it-IT").files, files("it"))
    }

    func testACatalogWithoutLocalizedSetsAlwaysResolvesToBase() {
        let catalog = VectorSetCatalog(base: files("vectors"))
        XCTAssertEqual(catalog.resolve("it"), .init(languageTag: nil, files: files("vectors")))
    }

    func testDiscoveryReadsTheNamingConvention() async throws {
        let directory = try TemporaryDirectory()
        for name in ["vectors.ztvec", "vectors.zthnsw", "vectors.it.ztvec", "vectors.it.zthnsw", "vectors.de-CH.ztvec",
                     "vectors..ztvec", "other.ztvec", "vectors.fr.zthnsw", "notes.txt"] {
            try Data([1]).write(to: directory.file(name))
        }
        let discovered = try await VectorSetCatalog.discover(in: directory.url)
        let catalog = try XCTUnwrap(discovered)
        XCTAssertEqual(catalog.base.vectors.lastPathComponent, "vectors.ztvec")
        XCTAssertEqual(catalog.base.graph?.lastPathComponent, "vectors.zthnsw")
        XCTAssertEqual(Set(catalog.localized.keys), ["it", "de-CH"])
        XCTAssertEqual(catalog.localized["it"]?.graph?.lastPathComponent, "vectors.it.zthnsw")
        // A set without a graph file is still a set; the graph is then built on device.
        XCTAssertNotNil(catalog.localized["de-CH"])
        XCTAssertNil(catalog.localized["de-CH"]?.graph)

        let discoveredOther = try await VectorSetCatalog.discover(in: directory.url, name: "other")
        let other = try XCTUnwrap(discoveredOther)
        XCTAssertTrue(other.localized.isEmpty)
        XCTAssertNil(other.base.graph)
        let missing = try await VectorSetCatalog.discover(in: directory.url, name: "absent")
        XCTAssertNil(missing)
    }

    func testOpenStoreLoadsTheActiveLocaleSetWithBaseFallback() async throws {
        let directory = try TemporaryDirectory()
        var generator = SeededGenerator(seed: 51)
        let quantization = try VectorQuantization.uniform(dimensions: 8)
        func write(_ name: String, ids: [SearchableID], model: String = "m") async throws {
            let vectors = ids.map { ($0, generator.unitVector(8)) }
            try await QuantizedVectorStore.build(from: vectors, modelID: model, dimensions: 8, quantization: quantization)
                .write(to: directory.file(name))
        }
        try await write("vectors.ztvec", ids: ["base-1", "base-2"])
        try await write("vectors.it.ztvec", ids: ["it-1"])
        try await write("vectors.de.ztvec", ids: ["de-1"], model: "another-model")
        try Data([0, 1, 2]).write(to: directory.file("vectors.es.ztvec"))
        let discovered = try await VectorSetCatalog.discover(in: directory.url)
        let catalog = try XCTUnwrap(discovered)
        let expectation = QuantizedVectorStore.Expectation(modelID: "m", dimensions: 8)

        let italian = try catalog.openStore(for: "it-IT", expecting: expectation)
        XCTAssertEqual(italian.resolution.languageTag, "it")
        XCTAssertEqual(italian.store.ids, ["it-1"])

        // No set for the locale: base.
        let french = try catalog.openStore(for: "fr", expecting: expectation)
        XCTAssertNil(french.resolution.languageTag)
        XCTAssertEqual(french.store.ids, ["base-1", "base-2"])

        // A set that exists but cannot be used (another model, unreadable): base.
        let german = try catalog.openStore(for: "de", expecting: expectation)
        XCTAssertNil(german.resolution.languageTag)
        XCTAssertEqual(german.store.ids, ["base-1", "base-2"])
        XCTAssertEqual(try catalog.openStore(for: "es", expecting: expectation).store.ids, ["base-1", "base-2"])

        // Only an unusable base set is an error.
        assertThrows(.modelMismatch(expected: "x", found: "m")) {
            try catalog.openStore(for: "fr", expecting: .init(modelID: "x", dimensions: 8))
        }
    }
}
