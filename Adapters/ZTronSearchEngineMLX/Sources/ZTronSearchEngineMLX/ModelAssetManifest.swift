import Foundation
import ZTronSearchEngine

/// The files of one model repository at one pinned revision, with the checksums that are known.
///
/// A manifest is the JSON form of a `ModelAsset` before every checksum is known. Hugging Face
/// publishes the SHA-256 of files stored through Git LFS; for the small files kept in Git itself
/// it only publishes the Git blob id (a SHA-1). A manifest can therefore be *partial*: every file
/// has a name and a byte count, and each has a SHA-256, a Git blob id, or both.
///
/// `Scripts/pin-qwen3-asset.swift` turns a partial manifest into a complete one from a local copy
/// of the files, and ``asset()`` turns a complete manifest into the `ModelAsset` core works with.
public struct ModelAssetManifest: Sendable, Hashable, Codable {
    /// One file of the repository.
    public struct File: Sendable, Hashable, Codable {
        /// Path of the file inside the repository.
        public let name: String
        /// Size in bytes.
        public let byteCount: Int64
        /// Lowercase hexadecimal SHA-256 of the file; `nil` when it has not been pinned yet.
        public let sha256: String?
        /// Lowercase hexadecimal Git blob id of the file (SHA-1 of `"blob <size>\0"` followed by
        /// the content); `nil` for files stored through Git LFS, whose blob is only a pointer.
        public let gitBlobSHA1: String?

        /// Creates a file entry.
        public init(name: String, byteCount: Int64, sha256: String? = nil, gitBlobSHA1: String? = nil) {
            self.name = name
            self.byteCount = byteCount
            self.sha256 = sha256
            self.gitBlobSHA1 = gitBlobSHA1
        }
    }

    /// Why a manifest cannot be used.
    public enum ManifestError: Error, Sendable, Hashable {
        /// The revision is a moving reference such as `"main"`, or is empty.
        case unpinnedRevision(String)
        /// The manifest lists no file.
        case noFiles
        /// A file is listed twice.
        case duplicateFile(String)
        /// A byte count is negative.
        case invalidByteCount(file: String)
        /// A checksum is not lowercase hexadecimal of the right length.
        case malformedChecksum(file: String)
        /// These files have no SHA-256 yet.
        case missingChecksums([String])
        /// The manifest describes another asset or revision than the one expected.
        case identityMismatch(expected: String, found: String)
        /// The manifest does not list exactly the expected files.
        case fileSetMismatch(missing: [String], unexpected: [String])
        /// A file differs from what is known about the pinned revision.
        case fileMismatch(file: String, field: String)
        /// A file's SHA-256 is new and comes without the Git blob id that would tie it to the
        /// pinned commit.
        case unanchoredChecksum(file: String)
    }

    /// The asset identifier core uses, e.g. `"qwen3-1.7b-4bit"`.
    public let id: String
    /// The repository the files come from, e.g. `"mlx-community/Qwen3-1.7B-4bit"`.
    public let repository: String
    /// The pinned commit or tag. Never a branch name.
    public let revision: String
    /// The files, in a stable order.
    public let files: [File]

    /// Creates a manifest.
    public init(id: String, repository: String, revision: String, files: [File]) {
        self.id = id
        self.repository = repository
        self.revision = revision
        self.files = files
    }

    /// Decodes a manifest from JSON.
    public init(json data: Data) throws {
        self = try JSONDecoder().decode(ModelAssetManifest.self, from: data)
    }

    /// Reads a manifest from a JSON file.
    public init(contentsOf url: URL) throws {
        try self.init(json: Data(contentsOf: url))
    }

    /// The manifest as pretty-printed JSON with sorted keys, the form the pinning script writes.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Sum of the byte counts.
    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    /// Names of the files that have no SHA-256 yet.
    public var filesMissingSHA256: [String] {
        files.filter { $0.sha256 == nil }.map(\.name)
    }

    /// `true` when every file has a SHA-256.
    public var isComplete: Bool {
        filesMissingSHA256.isEmpty
    }

    /// Checks the manifest's own consistency: a pinned revision, at least one file, no duplicate,
    /// no negative size, well-formed checksums.
    public func validate() throws {
        let moving: Set<String> = ["", "main", "master", "head", "latest"]
        guard !moving.contains(revision.lowercased()) else {
            throw ManifestError.unpinnedRevision(revision)
        }
        guard !files.isEmpty else {
            throw ManifestError.noFiles
        }
        var seen = Set<String>()
        for file in files {
            guard seen.insert(file.name).inserted else {
                throw ManifestError.duplicateFile(file.name)
            }
            guard file.byteCount >= 0 else {
                throw ManifestError.invalidByteCount(file: file.name)
            }
            if let sha256 = file.sha256, !Self.isLowercaseHex(sha256, length: 64) {
                throw ManifestError.malformedChecksum(file: file.name)
            }
            if let gitBlobSHA1 = file.gitBlobSHA1, !Self.isLowercaseHex(gitBlobSHA1, length: 40) {
                throw ManifestError.malformedChecksum(file: file.name)
            }
        }
    }

    /// Checks this manifest against what is known about the pinned revision.
    ///
    /// The two must name the same asset, repository and revision and list the same files with
    /// the same sizes. Wherever `reference` knows a checksum, this manifest must not contradict
    /// it. A SHA-256 that `reference` does not know is accepted only when this manifest also
    /// carries the Git blob id `reference` knows for that file: the blob id is what ties the new
    /// value to the pinned commit. The pinning script writes both.
    public func validate(against reference: ModelAssetManifest) throws {
        try validate()
        let identity = "\(id) \(repository)@\(revision)"
        let expectedIdentity = "\(reference.id) \(reference.repository)@\(reference.revision)"
        guard identity == expectedIdentity else {
            throw ManifestError.identityMismatch(expected: expectedIdentity, found: identity)
        }

        let ours = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let theirs = Dictionary(reference.files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = theirs.keys.filter { ours[$0] == nil }.sorted()
        let unexpected = ours.keys.filter { theirs[$0] == nil }.sorted()
        guard missing.isEmpty && unexpected.isEmpty else {
            throw ManifestError.fileSetMismatch(missing: missing, unexpected: unexpected)
        }

        for expected in reference.files {
            guard let file = ours[expected.name] else { continue }
            guard file.byteCount == expected.byteCount else {
                throw ManifestError.fileMismatch(file: file.name, field: "byteCount")
            }
            if let sha256 = expected.sha256, let found = file.sha256, found != sha256 {
                throw ManifestError.fileMismatch(file: file.name, field: "sha256")
            }
            if let gitBlobSHA1 = expected.gitBlobSHA1, let found = file.gitBlobSHA1, found != gitBlobSHA1 {
                throw ManifestError.fileMismatch(file: file.name, field: "gitBlobSHA1")
            }
            if file.sha256 != nil, expected.sha256 == nil, expected.gitBlobSHA1 != nil, file.gitBlobSHA1 == nil {
                throw ManifestError.unanchoredChecksum(file: file.name)
            }
        }
    }

    /// The `ModelAsset` this manifest describes.
    ///
    /// - Throws: ``ManifestError/missingChecksums(_:)`` while a file has no SHA-256, and the
    ///   errors of ``validate()``.
    public func asset() throws -> ModelAsset {
        try validate()
        let missing = filesMissingSHA256
        guard missing.isEmpty else {
            throw ManifestError.missingChecksums(missing)
        }
        return ModelAsset(
            id: id,
            revision: revision,
            files: files.map { ModelFile(name: $0.name, byteCount: $0.byteCount, sha256: $0.sha256 ?? "") }
        )
    }

    private static func isLowercaseHex(_ string: String, length: Int) -> Bool {
        string.utf8.count == length
            && string.utf8.allSatisfy { ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f")) }
    }
}

extension ModelAssetManifest.ManifestError: LocalizedError {
    /// The error as one sentence, for logs and diagnostics.
    public var errorDescription: String? {
        switch self {
        case .unpinnedRevision(let revision):
            return "The revision \"\(revision)\" is not pinned; use a commit or a tag."
        case .noFiles:
            return "The manifest lists no file."
        case .duplicateFile(let name):
            return "The manifest lists \(name) twice."
        case .invalidByteCount(let file):
            return "The byte count of \(file) is negative."
        case .malformedChecksum(let file):
            return "A checksum of \(file) is not lowercase hexadecimal of the right length."
        case .missingChecksums(let names):
            return "No SHA-256 is pinned for: \(names.joined(separator: ", "))"
        case .identityMismatch(let expected, let found):
            return "The manifest describes \(found), not \(expected)."
        case .fileSetMismatch(let missing, let unexpected):
            return "The manifest's files differ from the pinned revision (missing: \(missing), unexpected: \(unexpected))."
        case .fileMismatch(let file, let field):
            return "\(file) differs from the pinned revision in \(field)."
        case .unanchoredChecksum(let file):
            return "The SHA-256 of \(file) comes without the Git blob id that ties it to the pinned revision."
        }
    }
}
