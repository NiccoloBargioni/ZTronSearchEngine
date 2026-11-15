import Foundation

/// File access that never blocks the cooperative thread pool.
///
/// The only synchronous file call the semantic channel makes from a task is the memory-map
/// open (specification section 11, rule 7). Writes, directory listings and size checks run on
/// this queue and come back through a continuation.
enum FileAccess {
    private static let queue = DispatchQueue(label: "com.ztron.searchengine.semantic.file-io", qos: .utility)

    /// Memory-maps a file. Pages load on demand.
    static func map(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SemanticError.io("cannot map \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Writes atomically, creating intermediate directories.
    static func write(_ data: Data, to url: URL) async throws {
        try await run {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    /// The names of the regular files directly inside `directory`.
    static func fileNames(in directory: URL) async throws -> [String] {
        try await run {
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
        }
    }

    /// Bytes a file, or everything under a directory, takes on disk.
    ///
    /// This walks the directory synchronously. Only for callers that already run off the
    /// cooperative pool: the Core ML adapters call it on their own serial queue.
    static func footprintBlocking(of url: URL) throws -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw SemanticError.io("\(url.lastPathComponent) does not exist")
        }
        if !isDirectory.boolValue {
            return try fileSize(atPath: url.path)
        }
        var total: Int64 = 0
        guard let enumerator = manager.enumerator(atPath: url.path) else {
            throw SemanticError.io("cannot list \(url.lastPathComponent)")
        }
        while let relative = enumerator.nextObject() as? String {
            let path = url.appendingPathComponent(relative).path
            var childIsDirectory: ObjCBool = false
            if manager.fileExists(atPath: path, isDirectory: &childIsDirectory), !childIsDirectory.boolValue {
                total += try fileSize(atPath: path)
            }
        }
        return total
    }

    private static func fileSize(atPath path: String) throws -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw SemanticError.io("cannot size \(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func run<Result: Sendable>(_ work: @escaping @Sendable () throws -> Result) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch let error as SemanticError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: SemanticError.io(error.localizedDescription))
                }
            }
        }
    }
}
