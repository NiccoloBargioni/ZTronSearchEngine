import XCTest
import ZTronSearchFixtures

/// The lint tests of the specification: the dependency policy of section 2, the concurrency
/// rules of section 11 that the compiler cannot enforce, and the modifier rules of section 13.1.
final class LintTests: XCTestCase {
    private let root = UIFixtures.packageRoot()

    private func sources(_ target: String) -> [URL] {
        SourceLint.swiftFiles(in: root.appendingPathComponent("Sources").appendingPathComponent(target))
    }

    private func assertEmpty(_ findings: [SourceLint.Finding], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(findings.isEmpty, "\(message):\n" + findings.map(\.description).joined(separator: "\n"), file: file, line: line)
    }

    // MARK: The UI product never imports UIKit

    func testTheUIProductNeverUsesUIKit() {
        let files = sources("ZTronSearchEngineUI")
        XCTAssertGreaterThan(files.count, 5)
        assertEmpty(SourceLint.uiKitUsage(in: files), "import UIKit, UIViewRepresentable or a UI-prefixed type in ZTronSearchEngineUI")
        XCTAssertEqual(SourceLint.imports(in: files), ["SwiftUI", "Foundation", "Combine", "ZTronSearchEngine"], "SwiftUI only; Semantic is injected, never imported")
    }

    func testTheUIKitLintCatchesWhatItShould() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func findings(_ source: String) throws -> [SourceLint.Finding] {
            let file = directory.appendingPathComponent("\(UUID().uuidString).swift")
            try source.write(to: file, atomically: true, encoding: .utf8)
            return SourceLint.uiKitUsage(in: [file])
        }
        XCTAssertEqual(try findings("import UIKit\n").count, 1)
        XCTAssertEqual(try findings("struct Field: UIViewRepresentable {}\n").count, 1)
        XCTAssertEqual(try findings("let color = UIColor.red\n").count, 1)
        XCTAssertEqual(try findings("func f(_ type: UIKeyboardType) {}\n").count, 1)
        // Mentions in comments and strings are not usage, and neither are ordinary identifiers.
        XCTAssertEqual(try findings("// a clone of UISearchTextField\nlet name = \"UIKit\"\n/* UIColor */\n").count, 0)
        XCTAssertEqual(try findings("let UI = 1\nstruct UIx {}\nlet uiColor = 2\nenum GUIKind {}\n").count, 0)
        XCTAssertEqual(try findings("let text = \"\"\"\nimport UIKit\n\"\"\"\n").count, 0)
    }

    // MARK: Dependency policy

    func testCoreUsesOnlyFoundationNaturalLanguageAndAccelerate() {
        let imports = SourceLint.imports(in: sources("ZTronSearchEngine"))
        // `os` is the unified log; everything else is the framework list of section 2.
        XCTAssertEqual(imports, ["Foundation", "NaturalLanguage", "Accelerate", "os"])
    }

    func testNoProductImportsAThirdPartyPackage() {
        let allowed: Set<String> = [
            "Foundation", "NaturalLanguage", "Accelerate", "os", "SwiftUI", "Combine", "CoreML", "simd", "Dispatch", "Darwin",
            "ZTronSearchEngine",
        ]
        for target in ["ZTronSearchEngine", "ZTronSearchEngineSemantic", "ZTronSearchEngineUI"] {
            let unexpected = SourceLint.imports(in: sources(target)).subtracting(allowed)
            XCTAssertTrue(unexpected.isEmpty, "\(target) imports \(unexpected.sorted())")
        }
    }

    // MARK: Concurrency rules the compiler cannot enforce

    func testNoUncheckedSendableOutsideTheHNSWWrapper() {
        for target in ["ZTronSearchEngine", "ZTronSearchEngineUI", "ZTronSearchFixtures"] {
            assertEmpty(SourceLint.uncheckedConcurrency(in: sources(target)), "@unchecked Sendable or nonisolated(unsafe) in \(target)")
        }
        // The Semantic product may vendor a C HNSW behind one documented wrapper; a pure Swift
        // implementation needs none.
        assertEmpty(
            SourceLint.uncheckedConcurrency(in: sources("ZTronSearchEngineSemantic"), allowing: ["HNSWWrapper.swift"]),
            "@unchecked Sendable outside the HNSW wrapper"
        )
    }

    func testNothingBlocksTheCooperativePool() {
        for target in ["ZTronSearchEngine", "ZTronSearchEngineSemantic", "ZTronSearchEngineUI"] {
            assertEmpty(SourceLint.blockingCalls(in: sources(target)), "a blocking call in \(target)")
        }
    }

    func testTaskDetachedIsOnlyUsedForIndexLoadingAtUtilityPriority() {
        for target in ["ZTronSearchEngine", "ZTronSearchEngineSemantic", "ZTronSearchEngineUI"] {
            assertEmpty(SourceLint.detachedTasks(in: sources(target)), "Task.detached in \(target)")
        }
    }

    // MARK: Attachment modifiers

    func testEveryAttachmentModifierStaysUnderThirtyLines() {
        let file = root.appendingPathComponent("Sources/ZTronSearchEngineUI/ZTronAttachmentModifiers.swift")
        let lengths = SourceLint.modifierLengths(in: file)
        for name in ["zTronSearch", "zTronResults", "zTronLoadsNextPage", "zTronSuggestions", "zTronChat"] {
            let length = lengths[name]
            XCTAssertNotNil(length, "\(name) not found")
            XCTAssertLessThan(length ?? 99, 30, "\(name) is \(length ?? 0) lines")
        }
        for (name, length) in lengths where name.hasSuffix("Attachment") {
            XCTAssertLessThan(length, 30, "\(name) is \(length) lines")
        }
        XCTAssertGreaterThanOrEqual(lengths.count, 9)
    }

    func testNoModifierCreatesState() throws {
        let file = root.appendingPathComponent("Sources/ZTronSearchEngineUI/ZTronAttachmentModifiers.swift")
        let code = SourceLint.code(of: try String(contentsOf: file, encoding: .utf8))
        // State created inside a modifier lives and dies with the modified view's identity.
        XCTAssertFalse(code.contains("@State"))
        XCTAssertFalse(code.contains("@StateObject"))
    }

    func testAScreenThatReadsAModelWithoutAttachingItFailsTheLint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, _ source: String) throws -> URL {
            let file = directory.appendingPathComponent(name)
            try source.write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        let reader = try write("Rows.swift", """
            struct HostResultsList: View {
                @EnvironmentObject private var results: ZTronSearchResultsModel<CatalogSchema>
                var body: some View { List { ForEach(results.hits) { Text($0.id.rawValue) } } }
            }
            """)
        let attached = try write("Screen.swift", """
            struct SearchScreen: View {
                @StateObject private var results: ZTronSearchResultsModel<CatalogSchema>
                var body: some View { HostResultsList().zTronSearch(results, text: $text, tokens: $tokens) }
            }
            """)
        let chatReader = try write("Chat.swift", """
            struct Transcript: View {
                @EnvironmentObject private var chat: ZTronChatModel<CatalogSchema>
                var body: some View { Text(chat.transcript.last?.text ?? "") }
            }
            """)

        // The reader alone: nothing attaches the model it reads.
        let orphan = SourceLint.unattachedEnvironmentObjects(in: [reader])
        XCTAssertEqual(orphan.count, 1)
        XCTAssertEqual(orphan.first?.file, "Rows.swift")
        XCTAssertEqual(orphan.first?.line, 2)
        // With the screen that attaches it, the lint passes.
        XCTAssertTrue(SourceLint.unattachedEnvironmentObjects(in: [reader, attached]).isEmpty)
        // Each model needs its own attachment: zTronSearch does not attach a chat model.
        let chatOrphan = SourceLint.unattachedEnvironmentObjects(in: [reader, attached, chatReader])
        XCTAssertEqual(chatOrphan.map(\.file), ["Chat.swift"])
    }

    func testThePackagesOwnScreensAttachTheModelsTheyRead() {
        // Everything in the repository that builds screens: the parity host and the samples.
        var files: [URL] = []
        for directory in ["ParityHost", "Examples"] {
            files += SourceLint.swiftFiles(in: root.appendingPathComponent(directory))
        }
        assertEmpty(SourceLint.unattachedEnvironmentObjects(in: files), "a screen reads a model that nothing attaches")
    }
}
