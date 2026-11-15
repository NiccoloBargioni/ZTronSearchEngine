import Foundation

/// File access that never blocks the cooperative thread pool.
///
/// The only synchronous file calls the engine makes from a task are the memory-map open and
/// close (specification section 11, rule 7). Everything else goes through this queue and comes
/// back through a continuation.
enum FileIO {
    private static let queue = DispatchQueue(label: "com.ztron.searchengine.file-io", qos: .utility)

    /// Writes atomically, creating intermediate directories.
    static func write(_ data: Data, to url: URL) async throws {
        try await run {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    static func remove(_ url: URL) async {
        try? await run {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func exists(_ url: URL) async -> Bool {
        (try? await run { FileManager.default.fileExists(atPath: url.path) }) ?? false
    }

    /// Memory-maps a file. Pages load on demand.
    static func map(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SearchError.persistence("cannot map \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func run<Result: Sendable>(_ work: @escaping @Sendable () throws -> Result) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch let error as SearchError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: SearchError.persistence(error.localizedDescription))
                }
            }
        }
    }
}

/// A first-in, first-out lock for actor methods that must not interleave across suspension points.
///
/// Actors are reentrant: an `await` inside a mutation lets another mutation start. Methods that
/// need to finish before the next one begins take this lock. It never blocks a thread and never
/// waits on a task: ownership is handed straight to the next waiter.
struct AsyncLock {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Returns `true` when the lock was free and is now held by the caller.
    mutating func tryAcquire() -> Bool {
        if isHeld { return false }
        isHeld = true
        return true
    }

    mutating func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        waiters.append(continuation)
    }

    mutating func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
