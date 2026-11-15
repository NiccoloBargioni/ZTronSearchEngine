import Foundation
import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSQLite

/// The `Bundle`-backed resolver, against `.lproj` bundles written at test time.
final class BundleLocalizedStringResolverTests: XCTestCase {
    private let fixture: SearchBundleID = "fixture"

    private func makeResolver(in directory: TemporaryDirectory, developmentRegion: String? = "en") throws -> BundleLocalizedStringResolver {
        let bundle = try makeStringsBundle(in: directory.url, developmentRegion: developmentRegion, tables: [
            "en": [
                "Localizable": ["greeting": "Hello", "farewell": "Goodbye", "OK": "OK", "only.english": "English only"],
                "Catalog": ["tool.compass": "Compass", "tool.sextant": "Brass Sextant"],
            ],
            "it": [
                "Localizable": ["greeting": "Ciao", "farewell": "Arrivederci", "OK": "Va bene"],
                "Catalog": ["tool.compass": "Bussola", "tool.sextant": "Sestante di ottone", "città": "Città \"vecchia\" 🧭"],
            ],
            "de": [
                "Localizable": ["greeting": "Hallo"],
            ],
        ])
        return BundleLocalizedStringResolver(bundles: [fixture: bundle])
    }

    func testKeysResolvePerLanguageAndTable() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let resolver = try makeResolver(in: directory)

        XCTAssertEqual(resolver.string(forKey: "greeting", table: nil, bundle: fixture, language: "en"), "Hello")
        XCTAssertEqual(resolver.string(forKey: "greeting", table: nil, bundle: fixture, language: "it"), "Ciao")
        XCTAssertEqual(resolver.string(forKey: "greeting", table: nil, bundle: fixture, language: "de"), "Hallo")
        // `nil` is the `Localizable` table.
        XCTAssertEqual(resolver.string(forKey: "farewell", table: "Localizable", bundle: fixture, language: "it"), "Arrivederci")
        XCTAssertEqual(resolver.string(forKey: "tool.sextant", table: "Catalog", bundle: fixture, language: "en"), "Brass Sextant")
        XCTAssertEqual(resolver.string(forKey: "tool.sextant", table: "Catalog", bundle: fixture, language: "it"), "Sestante di ottone")
        XCTAssertEqual(resolver.string(forKey: "città", table: "Catalog", bundle: fixture, language: "it"), "Città \"vecchia\" 🧭")
    }

    func testAMissingKeyIsNilAndNeverTheKey() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let resolver = try makeResolver(in: directory)

        XCTAssertNil(resolver.string(forKey: "no.such.key", table: nil, bundle: fixture, language: "en"))
        XCTAssertNil(resolver.string(forKey: "no.such.key", table: "Catalog", bundle: fixture, language: "it"))
        XCTAssertNil(resolver.string(forKey: "", table: nil, bundle: fixture, language: "en"))
        // A language is not answered from another one: core decides how languages fall back.
        XCTAssertNil(resolver.string(forKey: "only.english", table: nil, bundle: fixture, language: "it"))
        XCTAssertNil(resolver.string(forKey: "farewell", table: nil, bundle: fixture, language: "de"))
        // The key of one table is not found in another.
        XCTAssertNil(resolver.string(forKey: "tool.compass", table: nil, bundle: fixture, language: "en"))
        XCTAssertNil(resolver.string(forKey: "greeting", table: "Catalog", bundle: fixture, language: "en"))
        XCTAssertNil(resolver.string(forKey: "greeting", table: "NoSuchTable", bundle: fixture, language: "en"))

        // A string that happens to equal its key is a string, not a missing one.
        XCTAssertEqual(resolver.string(forKey: "OK", table: nil, bundle: fixture, language: "en"), "OK")
        XCTAssertEqual(resolver.string(forKey: "OK", table: nil, bundle: fixture, language: "it"), "Va bene")
    }

    func testLanguagesListTheDevelopmentLocalizationFirst() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        // Alphabetical order would put `de` and `en` before `it`.
        let italianFirst = try makeResolver(in: directory, developmentRegion: "it")
        XCTAssertEqual(italianFirst.languages(bundle: fixture, table: nil), ["it", "de", "en"])
        // Only the languages that have the table.
        XCTAssertEqual(italianFirst.languages(bundle: fixture, table: "Catalog"), ["it", "en"])
        XCTAssertEqual(italianFirst.languages(bundle: fixture, table: "Localizable"), ["it", "de", "en"])
        XCTAssertEqual(italianFirst.languages(bundle: fixture, table: "NoSuchTable"), [])
    }

    func testLanguagesWithOtherDevelopmentRegions() throws {
        let english = try TemporaryDirectory()
        defer { english.remove() }
        XCTAssertEqual(try makeResolver(in: english, developmentRegion: "en").languages(bundle: fixture, table: nil), ["en", "de", "it"])

        // A development region that names the language of a directory under another spelling.
        let regional = try TemporaryDirectory()
        defer { regional.remove() }
        XCTAssertEqual(try makeResolver(in: regional, developmentRegion: "it_IT").languages(bundle: fixture, table: nil), ["it", "de", "en"])

        // A development region the bundle has no directory for leaves the alphabetical order.
        let absent = try TemporaryDirectory()
        defer { absent.remove() }
        XCTAssertEqual(try makeResolver(in: absent, developmentRegion: "ja").languages(bundle: fixture, table: nil), ["de", "en", "it"])
    }

    func testBaseLocalizationIsNotALanguage() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let bundle = try makeStringsBundle(in: directory.url, developmentRegion: "en", tables: [
            "Base": ["Localizable": ["greeting": "Base hello"]],
            "en": ["Localizable": ["greeting": "Hello"]],
        ])
        let resolver = BundleLocalizedStringResolver(bundles: [fixture: bundle])
        XCTAssertEqual(resolver.languages(bundle: fixture, table: nil), ["en"])
        XCTAssertNil(resolver.string(forKey: "greeting", table: nil, bundle: fixture, language: "Base"))
    }

    func testUnknownBundlesAndLanguagesResolveNothing() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let resolver = try makeResolver(in: directory)

        XCTAssertNil(resolver.string(forKey: "greeting", table: nil, bundle: "unregistered", language: "en"))
        XCTAssertEqual(resolver.languages(bundle: "unregistered", table: nil), [])
        XCTAssertNil(resolver.string(forKey: "greeting", table: nil, bundle: fixture, language: "fr"))
    }

    func testMainIsRegisteredByDefaultAndCanBeReplaced() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        // The test runner's main bundle has no such string; the id is registered all the same.
        let standard = BundleLocalizedStringResolver()
        XCTAssertNil(standard.string(forKey: "greeting", table: nil, bundle: .main, language: "en"))
        XCTAssertEqual(standard.languages(bundle: .main, table: "NoSuchTable"), [])

        let bundle = try makeStringsBundle(in: directory.url, developmentRegion: "en", tables: ["en": ["Localizable": ["greeting": "Hello"]]])
        let replaced = BundleLocalizedStringResolver(bundles: [.main: bundle])
        XCTAssertEqual(replaced.string(forKey: "greeting", table: nil, bundle: .main, language: "en"), "Hello")
        XCTAssertEqual(replaced.languages(bundle: .main, table: nil), ["en"])
    }

    /// The resolver keeps the bundle of every language, and a bundle keeps a strings table it
    /// has read. Take the files away after the first lookup: the table still answers.
    func testAStringsTableIsReadOnceAndKept() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let resolver = try makeResolver(in: directory)
        XCTAssertEqual(resolver.string(forKey: "tool.compass", table: "Catalog", bundle: fixture, language: "it"), "Bussola")

        directory.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.path))
        XCTAssertEqual(resolver.string(forKey: "tool.compass", table: "Catalog", bundle: fixture, language: "it"), "Bussola")
        XCTAssertEqual(resolver.string(forKey: "tool.sextant", table: "Catalog", bundle: fixture, language: "it"), "Sestante di ottone")
        XCTAssertNil(resolver.string(forKey: "no.such.key", table: "Catalog", bundle: fixture, language: "it"))
    }

    func testResolverIsSharedAcrossTasks() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // `Sendable` by construction: the same value is used from every task below.
        let resolver: any LocalizedStringResolving = try makeResolver(in: directory)
        let fixture = self.fixture

        let mismatches = await withTaskGroup(of: Int.self) { group in
            for task in 0..<16 {
                group.addTask {
                    var mismatches = 0
                    for round in 0..<500 {
                        let language = (task + round) % 2 == 0 ? "en" : "it"
                        let expected = language == "en" ? "Brass Sextant" : "Sestante di ottone"
                        if resolver.string(forKey: "tool.sextant", table: "Catalog", bundle: fixture, language: language) != expected { mismatches += 1 }
                        if resolver.string(forKey: "missing.\(round)", table: "Catalog", bundle: fixture, language: language) != nil { mismatches += 1 }
                        if resolver.languages(bundle: fixture, table: "Catalog") != ["en", "it"] { mismatches += 1 }
                    }
                    return mismatches
                }
            }
            return await group.reduce(0, +)
        }
        XCTAssertEqual(mismatches, 0)
    }
}
