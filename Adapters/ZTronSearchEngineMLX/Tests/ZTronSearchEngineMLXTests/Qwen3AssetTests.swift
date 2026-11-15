import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineMLX

final class Qwen3AssetTests: XCTestCase {
    private typealias File = ModelAssetManifest.File
    private typealias ManifestError = ModelAssetManifest.ManifestError

    // Stand-ins for the two checksums that only the files themselves can provide. They are
    // well-formed test values, not the real SHA-256 of any file.
    private let fixtureConfigSHA256 = String(repeating: "0", count: 63) + "1"
    private let fixtureTokenizerConfigSHA256 = String(repeating: "0", count: 63) + "2"

    /// The verified manifest with every SHA-256 filled in, the way the pinning script writes it.
    private func completeManifest(
        revision: String = Qwen3Asset.revision,
        transform: (File) -> File = { $0 }
    ) -> ModelAssetManifest {
        let files = Qwen3Asset.verifiedManifest.files.map { file -> File in
            let sha256: String?
            switch file.name {
            case "config.json": sha256 = fixtureConfigSHA256
            case "tokenizer_config.json": sha256 = fixtureTokenizerConfigSHA256
            default: sha256 = file.sha256
            }
            return transform(File(name: file.name, byteCount: file.byteCount, sha256: sha256, gitBlobSHA1: file.gitBlobSHA1))
        }
        return ModelAssetManifest(id: Qwen3Asset.id, repository: Qwen3Asset.repository, revision: revision, files: files)
    }

    private func assertThrows<T>(
        _ expected: ManifestError,
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? ManifestError, expected, file: file, line: line)
        }
    }

    // MARK: - The verified manifest

    func testVerifiedManifestDecodes() throws {
        let manifest = try ModelAssetManifest(json: Data(Qwen3Asset.verifiedManifestJSON.utf8))
        XCTAssertEqual(manifest, Qwen3Asset.verifiedManifest)
        XCTAssertEqual(manifest.id, "qwen3-1.7b-4bit")
        XCTAssertEqual(manifest.repository, "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertEqual(manifest.files.map(\.name), ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])
        XCTAssertNoThrow(try manifest.validate())
    }

    func testRevisionIsAPinnedCommit() {
        let revision = Qwen3Asset.verifiedManifest.revision
        XCTAssertEqual(revision, Qwen3Asset.revision)
        XCTAssertNotEqual(revision, "main")
        XCTAssertEqual(revision.count, 40)
        XCTAssertTrue(revision.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testByteCounts() {
        let sizes = Dictionary(uniqueKeysWithValues: Qwen3Asset.verifiedManifest.files.map { ($0.name, $0.byteCount) })
        XCTAssertEqual(sizes["model.safetensors"], 968_080_210)
        XCTAssertEqual(sizes["tokenizer.json"], 11_422_654)
        XCTAssertEqual(sizes["tokenizer_config.json"], 9_706)
        XCTAssertEqual(sizes["config.json"], 937)
        XCTAssertEqual(Qwen3Asset.verifiedManifest.totalBytes, 979_513_507)
        XCTAssertEqual(Qwen3Asset.totalBytes, 979_513_507)
    }

    func testOnlyTheLFSFilesHaveAVerifiedSHA256() {
        let manifest = Qwen3Asset.verifiedManifest
        XCTAssertEqual(manifest.filesMissingSHA256, ["config.json", "tokenizer_config.json"])
        XCTAssertFalse(manifest.isComplete)
        for file in manifest.files {
            // Each file is anchored one way or the other, never neither.
            XCTAssertTrue((file.sha256 == nil) != (file.gitBlobSHA1 == nil), file.name)
        }
        assertThrows(.missingChecksums(["config.json", "tokenizer_config.json"]), try manifest.asset())
    }

    func testScriptCopyOfTheVerifiedManifestIsIdentical() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent("Scripts/qwen3-1.7b-4bit.verified.json")
        XCTAssertEqual(try ModelAssetManifest(contentsOf: url), Qwen3Asset.verifiedManifest)
    }

    // MARK: - Completing the manifest

    func testCompleteManifestBecomesTheModelAsset() throws {
        let asset = try Qwen3Asset.asset(pinnedBy: completeManifest())
        XCTAssertEqual(asset.id, "qwen3-1.7b-4bit")
        XCTAssertEqual(asset.revision, Qwen3Asset.revision)
        XCTAssertNotEqual(asset.revision, "main")
        XCTAssertEqual(asset.files.count, 4)
        XCTAssertEqual(asset.totalBytes, 979_513_507)
        XCTAssertEqual(
            asset.files.first { $0.name == "model.safetensors" },
            ModelFile(
                name: "model.safetensors",
                byteCount: 968_080_210,
                sha256: "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f"
            )
        )
        XCTAssertEqual(
            asset.files.first { $0.name == "tokenizer.json" }?.sha256,
            "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
        )
        XCTAssertEqual(asset.files.first { $0.name == "config.json" }?.sha256, fixtureConfigSHA256)
        XCTAssertTrue(asset.files.allSatisfy { $0.sha256.count == 64 })
    }

    func testCompleteManifestRoundTripsThroughAFile() throws {
        let manifest = completeManifest()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try manifest.jsonData().write(to: url)

        XCTAssertEqual(try ModelAssetManifest(contentsOf: url), manifest)
        XCTAssertEqual(try Qwen3Asset.asset(pinnedManifestAt: url), try manifest.asset())
    }

    func testNewChecksumWithoutItsGitBlobIDIsRefused() {
        let manifest = completeManifest { file in
            file.name == "config.json"
                ? File(name: file.name, byteCount: file.byteCount, sha256: file.sha256, gitBlobSHA1: nil)
                : file
        }
        assertThrows(.unanchoredChecksum(file: "config.json"), try Qwen3Asset.asset(pinnedBy: manifest))
    }

    func testContradictingAVerifiedValueIsRefused() {
        let wrongSize = completeManifest { file in
            file.name == "tokenizer.json"
                ? File(name: file.name, byteCount: file.byteCount + 1, sha256: file.sha256, gitBlobSHA1: file.gitBlobSHA1)
                : file
        }
        assertThrows(.fileMismatch(file: "tokenizer.json", field: "byteCount"), try Qwen3Asset.asset(pinnedBy: wrongSize))

        let wrongSHA256 = completeManifest { file in
            file.name == "model.safetensors"
                ? File(name: file.name, byteCount: file.byteCount, sha256: String(repeating: "f", count: 64), gitBlobSHA1: nil)
                : file
        }
        assertThrows(.fileMismatch(file: "model.safetensors", field: "sha256"), try Qwen3Asset.asset(pinnedBy: wrongSHA256))

        let wrongBlob = completeManifest { file in
            file.name == "tokenizer_config.json"
                ? File(name: file.name, byteCount: file.byteCount, sha256: file.sha256, gitBlobSHA1: String(repeating: "a", count: 40))
                : file
        }
        assertThrows(
            .fileMismatch(file: "tokenizer_config.json", field: "gitBlobSHA1"),
            try Qwen3Asset.asset(pinnedBy: wrongBlob)
        )
    }

    func testAnotherRevisionIsRefused() {
        let other = String(repeating: "1", count: 40)
        assertThrows(
            .identityMismatch(
                expected: "qwen3-1.7b-4bit mlx-community/Qwen3-1.7B-4bit@\(Qwen3Asset.revision)",
                found: "qwen3-1.7b-4bit mlx-community/Qwen3-1.7B-4bit@\(other)"
            ),
            try Qwen3Asset.asset(pinnedBy: completeManifest(revision: other))
        )
    }

    func testMovingRevisionIsRefused() {
        for revision in ["main", "Main", "master", "HEAD", ""] {
            assertThrows(.unpinnedRevision(revision), try completeManifest(revision: revision).validate())
            assertThrows(.unpinnedRevision(revision), try completeManifest(revision: revision).asset())
        }
    }

    func testDifferentFileSetIsRefused() {
        let complete = completeManifest()
        let extra = ModelAssetManifest(
            id: complete.id,
            repository: complete.repository,
            revision: complete.revision,
            files: complete.files + [File(name: "vocab.json", byteCount: 2_776_833, sha256: String(repeating: "b", count: 64))]
        )
        assertThrows(.fileSetMismatch(missing: [], unexpected: ["vocab.json"]), try Qwen3Asset.asset(pinnedBy: extra))

        let fewer = ModelAssetManifest(
            id: complete.id,
            repository: complete.repository,
            revision: complete.revision,
            files: Array(complete.files.dropLast())
        )
        assertThrows(.fileSetMismatch(missing: ["tokenizer_config.json"], unexpected: []), try Qwen3Asset.asset(pinnedBy: fewer))
    }

    // MARK: - Checksums of local files

    /// The helpers the integration test uses to check a local copy, against published vectors.
    func testFileDigestsMatchKnownValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("digests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let empty = directory.appendingPathComponent("empty")
        let abc = directory.appendingPathComponent("abc")
        let hello = directory.appendingPathComponent("hello")
        try Data().write(to: empty)
        try Data("abc".utf8).write(to: abc)
        try Data("hello\n".utf8).write(to: hello)

        XCTAssertEqual(try FileDigests.sha256(of: empty), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(try FileDigests.sha256(of: abc), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // `git hash-object` of an empty file and of "hello\n".
        XCTAssertEqual(try FileDigests.gitBlobSHA1(of: empty), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        XCTAssertEqual(try FileDigests.gitBlobSHA1(of: hello), "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    /// The published SHA-256 of each LFS file and the blob id of its pointer in the commit's tree
    /// describe the same file: the pointer rebuilt from the SHA-256 and the size hashes to that id.
    func testLFSChecksumsAgreeWithTheCommitsTree() throws {
        let pointerBlobIDs = [
            "model.safetensors": "4a262bc4638b8187b503c46579aca0c8b820f4e2",
            "tokenizer.json": "cd71f61a15a522601badb3dc960d800d9cb3766c",
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pointers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        for file in Qwen3Asset.verifiedManifest.files {
            guard let sha256 = file.sha256 else { continue }
            let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(sha256)\nsize \(file.byteCount)\n"
            let url = directory.appendingPathComponent(file.name)
            try Data(pointer.utf8).write(to: url)
            XCTAssertEqual(try FileDigests.gitBlobSHA1(of: url), pointerBlobIDs[file.name], file.name)
        }
    }

    // MARK: - Manifest consistency

    func testMalformedManifestsAreRefused() {
        func manifest(_ files: [File]) -> ModelAssetManifest {
            ModelAssetManifest(id: "x", repository: "org/x", revision: "v1.0", files: files)
        }
        assertThrows(.noFiles, try manifest([]).validate())
        assertThrows(
            .duplicateFile("a"),
            try manifest([File(name: "a", byteCount: 1), File(name: "a", byteCount: 2)]).validate()
        )
        assertThrows(.invalidByteCount(file: "a"), try manifest([File(name: "a", byteCount: -1)]).validate())
        assertThrows(
            .malformedChecksum(file: "a"),
            try manifest([File(name: "a", byteCount: 1, sha256: String(repeating: "A", count: 64))]).validate()
        )
        assertThrows(
            .malformedChecksum(file: "a"),
            try manifest([File(name: "a", byteCount: 1, sha256: "abc")]).validate()
        )
        assertThrows(
            .malformedChecksum(file: "a"),
            try manifest([File(name: "a", byteCount: 1, gitBlobSHA1: String(repeating: "g", count: 40))]).validate()
        )
        XCTAssertNoThrow(try manifest([File(name: "a", byteCount: 0, sha256: String(repeating: "c", count: 64))]).validate())
    }

    func testTagRevisionIsAccepted() throws {
        let manifest = ModelAssetManifest(
            id: "x",
            repository: "org/x",
            revision: "v1.0",
            files: [File(name: "a.bin", byteCount: 3, sha256: String(repeating: "d", count: 64))]
        )
        let asset = try manifest.asset()
        XCTAssertEqual(asset, ModelAsset(id: "x", revision: "v1.0", files: [ModelFile(name: "a.bin", byteCount: 3, sha256: String(repeating: "d", count: 64))]))
    }

    func testJSONOmitsUnknownChecksums() throws {
        let json = try XCTUnwrap(String(data: Qwen3Asset.verifiedManifest.jsonData(), encoding: .utf8))
        XCTAssertFalse(json.contains("null"))
        XCTAssertEqual(json.components(separatedBy: "\"sha256\"").count - 1, 2)
        XCTAssertEqual(json.components(separatedBy: "\"gitBlobSHA1\"").count - 1, 2)
        // The constant is written in the encoder's own format, so a regenerated file diffs cleanly.
        XCTAssertEqual(json, Qwen3Asset.verifiedManifestJSON)
    }
}
