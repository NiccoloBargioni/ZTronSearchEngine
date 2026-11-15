import CryptoKit
import Foundation
import ZTronAssetKit
import ZTronSearchEngine

/// Why a `ModelAsset` cannot be served: the descriptor itself is unusable, whatever is stored.
struct InvalidDescriptor: Error, Sendable, Hashable {
    let reason: String
}

/// A `ModelAsset` checked once and laid out for the bridge: the catalog asset that holds each
/// file, and the name of the directory the files appear in.
struct ModelAssetPlan: Sendable {
    /// One file of the model.
    struct Entry: Sendable, Hashable {
        let file: ModelFile
        /// The asset of the host's ZTronAssetKit catalog that holds the file's bytes.
        let identifier: AssetID
        /// `file.sha256` in lowercase: the name ZTronAssetKit gives a blob of these bytes.
        let sha256: String
        /// `file.name` split at `/`, so a name may place the file in a subdirectory.
        let pathComponents: [String]
    }

    let asset: ModelAsset
    let entries: [Entry]
    /// Every catalog asset of the model, once each, in file order.
    let identifiers: [AssetID]
    /// The directory of this descriptor under the provider's root. Another revision, or the
    /// same revision with another file list, has another name.
    let directoryName: String

    /// Checks `asset` and maps its files through `identifier`.
    ///
    /// A descriptor is refused when a file has no SHA-256 of 64 hexadecimal digits or a negative
    /// size, when a name is empty, absolute, or holds an empty, `.` or `..` component, when two
    /// names collide (also when they differ only in case, or one is a directory of the other),
    /// or when two files of different content map to one catalog asset.
    init(asset: ModelAsset, identifier: (ModelAsset, ModelFile) -> AssetID) throws(InvalidDescriptor) {
        var entries: [Entry] = []
        var identifiers: [AssetID] = []
        var contentByIdentifier: [AssetID: Entry] = [:]
        var paths: Set<String> = []

        for file in asset.files {
            let sha256 = file.sha256.lowercased()
            guard Self.isSHA256(sha256) else {
                throw InvalidDescriptor(reason: "'\(file.name)' has no SHA-256 of 64 hexadecimal digits")
            }
            guard file.byteCount >= 0 else {
                throw InvalidDescriptor(reason: "'\(file.name)' has a negative byte count")
            }
            let components = file.name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let isSafe = !file.name.isEmpty && components.allSatisfy { component in
                !component.isEmpty && component != "." && component != ".." && !component.contains("\0")
            }
            guard isSafe else {
                throw InvalidDescriptor(reason: "'\(file.name)' is not a relative file name")
            }
            guard paths.insert(file.name.lowercased()).inserted else {
                throw InvalidDescriptor(reason: "'\(file.name)' is listed twice")
            }

            let assetID = identifier(asset, file)
            guard !assetID.rawValue.isEmpty else {
                throw InvalidDescriptor(reason: "'\(file.name)' maps to an empty asset identifier")
            }
            let entry = Entry(file: file, identifier: assetID, sha256: sha256, pathComponents: components)
            if let other = contentByIdentifier[assetID] {
                guard other.sha256 == sha256, other.file.byteCount == file.byteCount else {
                    throw InvalidDescriptor(
                        reason: "'\(other.file.name)' and '\(file.name)' differ but map to the asset '\(assetID.rawValue)'"
                    )
                }
            } else {
                contentByIdentifier[assetID] = entry
                identifiers.append(assetID)
            }
            entries.append(entry)
        }

        // A file cannot also be the directory of another one.
        for entry in entries where entry.pathComponents.count > 1 {
            for depth in 1..<entry.pathComponents.count {
                let parent = entry.pathComponents[..<depth].joined(separator: "/").lowercased()
                guard !paths.contains(parent) else {
                    throw InvalidDescriptor(reason: "'\(entry.file.name)' lies inside the file '\(parent)'")
                }
            }
        }

        self.asset = asset
        self.entries = entries
        self.identifiers = identifiers
        self.directoryName = Self.directoryName(for: asset)
    }

    /// The entries whose bytes one catalog asset holds.
    func entries(of identifier: AssetID) -> [Entry] {
        entries.filter { $0.identifier == identifier }
    }

    /// `<id>@<revision>-<digest>`: readable, safe as one path component, and distinct for every
    /// descriptor because the digest covers the id, the revision and every file.
    private static func directoryName(for asset: ModelAsset) -> String {
        var hasher = SHA256()
        func feed(_ text: String) {
            hasher.update(data: Data(text.utf8))
            hasher.update(data: Data([0]))
        }
        feed(asset.id)
        feed(asset.revision)
        for file in asset.files {
            feed(file.name)
            feed(String(file.byteCount))
            feed(file.sha256.lowercased())
        }
        let digest = hasher.finalize().prefix(8).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
        let name = "\(sanitized(asset.id, limit: 64))@\(sanitized(asset.revision, limit: 40))-\(digest)"
        // Never a hidden directory, whatever the id starts with.
        return name.hasPrefix(".") ? "_" + name : name
    }

    /// Keeps ASCII letters, digits, `.`, `_` and `-`; everything else becomes `_`.
    private static func sanitized(_ text: String, limit: Int) -> String {
        var result = ""
        for scalar in text.unicodeScalars.prefix(limit) {
            let isPlain = scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "." || scalar == "_" || scalar == "-")
            result.unicodeScalars.append(isPlain ? scalar : "_")
        }
        return result
    }

    private static func isSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}

/// What a blob of ZTronAssetKit's store proves about its bytes, read from its URL alone.
///
/// The bridge never hashes a stored file again. It relies on this property of ZTronAssetKit:
/// **a blob's file name is the SHA-256 that ZTronAssetKit computed from the blob's own bytes
/// before it put the file in place.**
///
/// - `Sources/ZTronAssetStorage/Store/AssetStore+Publish.swift:70-124` checks the size, hashes
///   the staged file by streaming, and compares the digest with the manifest's checksum. A
///   mismatch deletes the staged bytes and throws (`:435-444`), so nothing is published.
/// - `:132` builds the blob's key from that digest (`BlobKey(hash: digest, ext:)`), never from
///   the manifest's claim, also for an entry that publishes no checksum.
/// - `Sources/ZTronAssetStorage/Layout/StoreLayout.swift:17-20` and `:91-94` turn the key into the
///   file name `blobs/<aa>/<64 lowercase hex>.<ext>`.
/// - `Sources/ZTronAssetStorage/Snapshot/SnapshotTable.swift:11-24` builds every `AssetLocation`
///   a lookup returns from that same key, and `AssetClient.resolve` returns the same URL.
/// - `SPEC.md:131` states it as invariant I-1 of the store.
///
/// So a blob named by `ModelFile.sha256` held exactly the model's bytes when it was written.
/// What the name cannot show is damage after that. ZTronAssetKit drops a present record whose
/// blob is missing or has another size at every launch
/// (`Sources/ZTronAssetStorage/Store/LaunchReconciliation.swift:153-169`) and hashes stored blobs
/// again in `performMaintenance`; the bridge adds a size check of the file on disk whenever it
/// materializes a directory (`ModelDirectoryStore`).
enum StoredBlob {
    /// The lowercase SHA-256 a blob URL is named by, or `nil` when the last path component is
    /// not `<64 lowercase hex>.<extension>`.
    static func contentHash(of url: URL) -> String? {
        let parts = url.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, parts[0].utf8.count == 64 else {
            return nil
        }
        let isLowercaseHex = parts[0].utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
        return isLowercaseHex ? String(parts[0]) : nil
    }
}
