import Foundation
import ZTronAssetKit

/// Why a model directory could not be put in place.
enum ModelDirectoryError: Error, Sendable, Hashable {
    /// The blobs of these files are missing on disk, are not regular files, or have another
    /// size than the descriptor states.
    case damagedBlobs([String])
    /// The volume has no room for the directory.
    case diskFull
    /// Any other file-system failure, as the system described it.
    case failed(String)
}

/// The directories the runtime loads from: one per model descriptor, holding one symbolic link
/// per file, named as the descriptor names it and pointing at the file's blob in ZTronAssetKit's
/// store.
///
/// The runtime needs `config.json`, `model.safetensors` and so on in one directory, while the
/// store holds `blobs/<aa>/<sha256>.<ext>`. The store also limits a file extension to eight
/// letters or digits (`Sources/ZTronAssetModel/Identity/AssetFileExtension.swift:10-14`), so a
/// blob can never be called `model.safetensors`. A link gives the file its real name without a
/// second copy of 968 MB.
///
/// Why symbolic links, not hard links or copies:
///
/// - A symbolic link costs no disk space and holds no bytes of its own. The store stays the only
///   owner of the bytes, so its budget, its eviction and a host's `purge` free what they report.
///   A hard link or a copy would keep 968 MB alive behind the store's back; on APFS a copy is a
///   clone and costs nothing at first, but still keeps the blocks once the store deletes its blob.
/// - When the store deletes a blob (a purge, a prune after the catalog dropped the entry), the
///   link dangles. `availability(of:)` reads the store first, so it answers `.missing` as soon
///   as the store's snapshot drops the file, and it removes the directory once a link is
///   broken on disk. A model that is already loaded keeps running: the runtime holds the bytes
///   in memory.
/// - A link is never placed inside the store's root: the store deletes every foreign name under
///   `blobs/` at launch (`Sources/ZTronAssetStorage/Store/LaunchReconciliation.swift:15-21`).
///
/// Every file-system call runs on one serial queue of this store, never on the cooperative pool.
struct ModelDirectoryStore: Sendable {
    /// The directory that holds one subdirectory per model descriptor.
    let root: URL
    private let queue = DispatchQueue(label: "com.ztron.searchengine.assetkit.directories", qos: .utility)

    init(root: URL) {
        self.root = root
    }

    /// `Library/Caches/ZTronSearchEngineAssetKit/Models`: the links are rebuilt from the store
    /// whenever they are missing, so nothing is lost when the system clears caches.
    static var defaultRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("ZTronSearchEngineAssetKit", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Where the directory of `plan` is, whether or not it exists.
    func url(for plan: ModelAssetPlan) -> URL {
        root.appendingPathComponent(plan.directoryName, isDirectory: true)
    }

    /// Checks every blob on disk, then makes the directory of `plan` hold exactly one link per
    /// file. A directory that already does is returned untouched.
    ///
    /// - Parameter blobs: The blob URL of every catalog asset of `plan`.
    /// - Throws: `.damagedBlobs` when a blob is missing, is not a regular file or has another
    ///   size than its file states; nothing is changed then.
    func materialize(_ plan: ModelAssetPlan, blobs: [AssetID: URL]) async throws(ModelDirectoryError) -> URL {
        let root = self.root
        let directory = url(for: plan)
        return try await run { () throws(ModelDirectoryError) -> URL in
            var links: [Link] = []
            var damaged: [String] = []
            for entry in plan.entries {
                guard let blob = blobs[entry.identifier], Self.isIntact(blob, byteCount: entry.file.byteCount) else {
                    damaged.append(entry.file.name)
                    continue
                }
                links.append(Link(pathComponents: entry.pathComponents, destination: blob.path))
            }
            guard damaged.isEmpty else {
                throw .damagedBlobs(damaged)
            }
            if Self.holdsExactly(links, at: directory) {
                return directory
            }
            do {
                try Self.rebuild(directory, named: plan.directoryName, in: root, links: links)
            } catch {
                throw Self.directoryError(error)
            }
            return directory
        }
    }

    /// The files of `plan` whose blob is missing on disk, is not a regular file or has another
    /// size than the file states. Changes nothing.
    func damagedFiles(of plan: ModelAssetPlan, blobs: [AssetID: URL]) async -> [ModelAssetPlan.Entry] {
        await run {
            plan.entries.filter { entry in
                guard let blob = blobs[entry.identifier] else {
                    return false
                }
                return !Self.isIntact(blob, byteCount: entry.file.byteCount)
            }
        }
    }

    /// Removes the directory of `plan` when one of its links no longer leads to a file of the
    /// size the plan states. A directory whose links all hold is left alone.
    ///
    /// Called when the store does not list every file. That alone is no reason to delete: the
    /// snapshot the provider reads can trail a download that just finished, and a blob the store
    /// is about to delete stays readable for the store's deletion grace. Only what is broken on
    /// disk goes.
    func removeIfBroken(_ plan: ModelAssetPlan) async {
        let root = self.root
        let directory = url(for: plan)
        await run {
            let fileManager = FileManager.default
            guard (try? fileManager.attributesOfItem(atPath: directory.path)) != nil else {
                return
            }
            let holds = plan.entries.allSatisfy { entry in
                let item = entry.pathComponents.reduce(directory) { $0.appendingPathComponent($1) }
                guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: item.path) else {
                    return false
                }
                return Self.isIntact(URL(fileURLWithPath: destination), byteCount: entry.file.byteCount)
            }
            if !holds {
                try? fileManager.removeItem(at: directory)
                Self.removeLeftovers(of: plan.directoryName, in: root)
            }
        }
    }

    /// Removes the directory of `plan` and anything an interrupted rebuild left next to it.
    func remove(_ plan: ModelAssetPlan) async {
        let root = self.root
        let directory = url(for: plan)
        await run {
            try? FileManager.default.removeItem(at: directory)
            Self.removeLeftovers(of: plan.directoryName, in: root)
        }
    }

    // MARK: - File-system units (called on the queue only)

    private struct Link {
        let pathComponents: [String]
        let destination: String

        var relativePath: String {
            pathComponents.joined(separator: "/")
        }
    }

    /// Whether `blob` is a regular file of exactly `byteCount` bytes.
    private static func isIntact(_ blob: URL, byteCount: Int64) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: blob.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.int64Value == byteCount
    }

    /// Whether `directory` holds every link of `links` with its destination, and nothing else
    /// but the subdirectories those links need.
    private static func holdsExactly(_ links: [Link], at directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard let found = try? fileManager.subpathsOfDirectory(atPath: directory.path) else {
            return false
        }
        var destinations: [String: String] = [:]
        var subdirectories: Set<String> = []
        for link in links {
            destinations[link.relativePath] = link.destination
            for depth in 1..<link.pathComponents.count {
                subdirectories.insert(link.pathComponents[..<depth].joined(separator: "/"))
            }
        }
        var matched = 0
        for path in found {
            let item = directory.appendingPathComponent(path).path
            if let destination = destinations[path] {
                guard (try? fileManager.destinationOfSymbolicLink(atPath: item)) == destination else {
                    return false
                }
                matched += 1
            } else if subdirectories.contains(path) {
                let type = (try? fileManager.attributesOfItem(atPath: item))?[.type] as? FileAttributeType
                guard type == .typeDirectory else {
                    return false
                }
            } else {
                return false
            }
        }
        return matched == destinations.count
    }

    /// Builds the links in a sibling directory, then puts it in place of `directory`, so a
    /// reader never sees a directory with some of its links.
    private static func rebuild(_ directory: URL, named name: String, in root: URL, links: [Link]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        removeLeftovers(of: name, in: root)
        let staging = root.appendingPathComponent(".\(name).\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for link in links {
                let item = link.pathComponents.reduce(staging) { $0.appendingPathComponent($1) }
                try fileManager.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: item.path, withDestinationPath: link.destination)
            }
            if (try? fileManager.attributesOfItem(atPath: directory.path)) != nil {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.moveItem(at: staging, to: directory)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Removes what an interrupted `rebuild` of the directory called `name` left in `root`.
    private static func removeLeftovers(of name: String, in root: URL) {
        let fileManager = FileManager.default
        let prefix = ".\(name)."
        for item in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] where item.hasPrefix(prefix) {
            try? fileManager.removeItem(at: root.appendingPathComponent(item))
        }
    }

    private static func directoryError(_ error: any Error) -> ModelDirectoryError {
        let failure = error as NSError
        let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        let isFull = [failure, underlying].contains { candidate in
            guard let candidate else {
                return false
            }
            if candidate.domain == NSCocoaErrorDomain {
                return candidate.code == NSFileWriteOutOfSpaceError
            }
            return candidate.domain == NSPOSIXErrorDomain && (candidate.code == Int(ENOSPC) || candidate.code == Int(EDQUOT))
        }
        return isFull ? .diskFull : .failed(failure.localizedDescription)
    }

    // MARK: - Queue

    private func run<Value: Sendable>(_ work: @escaping @Sendable () throws(ModelDirectoryError) -> Value) async throws(ModelDirectoryError) -> Value {
        let result: Result<Value, ModelDirectoryError> = await withCheckedContinuation { continuation in
            queue.async {
                do throws(ModelDirectoryError) {
                    continuation.resume(returning: .success(try work()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }

    private func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
