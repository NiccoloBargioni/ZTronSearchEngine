import Foundation
import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSQLite

// MARK: - Schema

/// The tiny host schema the tests search with: two kinds and one filter dimension.
enum CatalogKind: String, SearchItemKind, CaseIterable {
    case tool
    case tip
}

enum CatalogFilter: SearchFilter {
    case platform(String)

    var key: String { "platform" }

    var value: String {
        switch self { case .platform(let platform): return platform }
    }

    init?(key: String, value: String) {
        guard key == "platform" else { return nil }
        self = .platform(value)
    }
}

enum CatalogSchema: SearchSchema {
    typealias Kind = CatalogKind
    typealias Filter = CatalogFilter
}

// MARK: - Files

/// A directory of its own for one test, removed when the test is done.
struct TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZTronSearchEngineSQLiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Writes a bundle with one `.lproj` directory per language, each holding the given strings
/// tables, and loads it.
///
/// - Parameter tables: Language, then table name, then key and string.
func makeStringsBundle(
    in directory: URL,
    name: String = "Fixture",
    developmentRegion: String?,
    tables: [String: [String: [String: String]]]
) throws -> Bundle {
    let root = directory.appendingPathComponent("\(name).bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var info: [String: Any] = [
        "CFBundleIdentifier": "com.ztron.searchengine.sqlite.tests.\(UUID().uuidString)",
        "CFBundleName": name,
        "CFBundlePackageType": "BNDL",
    ]
    if let developmentRegion { info["CFBundleDevelopmentRegion"] = developmentRegion }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: root.appendingPathComponent("Info.plist"))

    for (language, languageTables) in tables {
        let lproj = root.appendingPathComponent("\(language).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        for (table, strings) in languageTables {
            // A compiled strings table is a property list of keys and strings.
            try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
                .write(to: lproj.appendingPathComponent("\(table).strings"))
        }
    }
    return try XCTUnwrap(Bundle(url: root), "the fixture bundle could not be loaded")
}

// MARK: - Waiting

struct TimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` until it holds. Returns `false` when it still does not after `timeout`.
func eventually(timeout: TimeInterval = 10, _ condition: @Sendable () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return try await condition()
}

/// Waits until no change stream is subscribed to `connection` any more.
func waitUntilUnsubscribed(_ connection: SQLiteSearchConnection, timeout: TimeInterval = 10) async -> Bool {
    await eventually(timeout: timeout) { await connection.subscriberCount() == 0 }
}

/// The table name the change-stream tests use to mark "everything before this was delivered".
let changeMarker = "__marker__"

/// Sends a marker to every stream subscribed to ``changeMarker``.
///
/// The connection delivers changes in the order its queue ran the statements, so a marker sent
/// after a statement arrives after that statement's changes: what precedes it in a stream is
/// exactly what the statements before it caused, and "nothing" can be asserted without waiting
/// for a timeout.
func sendMarker(on connection: SQLiteSearchConnection) {
    connection.reportUnknownChanges(in: [changeMarker])
}

/// Everything `stream` yields before the next marker. A stream that never yields the marker
/// fails the test instead of hanging it.
func changesBeforeMarker(
    in stream: AsyncStream<SearchDatabaseChange>,
    timeout: TimeInterval = 10
) async throws -> [SearchDatabaseChange] {
    try await withThrowingTaskGroup(of: [SearchDatabaseChange]?.self) { group in
        group.addTask {
            var collected: [SearchDatabaseChange] = []
            for await change in stream {
                if change.table == changeMarker { return collected }
                collected.append(change)
            }
            throw TimedOut(description: "the change stream ended before the marker")
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let collected = first else {
            throw TimedOut(description: "no marker within \(timeout) s")
        }
        return collected
    }
}

/// The next element of `stream`, or `nil` when none arrives in time or the stream ends.
func firstElement<Element: Sendable>(of stream: AsyncStream<Element>, timeout: TimeInterval = 10) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask {
            for await element in stream { return element }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        defer { group.cancelAll() }
        return await group.next() ?? nil
    }
}

/// The next change of `stream`, or an error when none arrives in time.
func nextChange(in stream: AsyncStream<SearchDatabaseChange>, timeout: TimeInterval = 10) async throws -> SearchDatabaseChange {
    guard let change = await firstElement(of: stream, timeout: timeout) else {
        throw TimedOut(description: "no change within \(timeout) s")
    }
    return change
}

// MARK: - Searching

/// The final snapshot of a submitted query.
func finalSnapshot<Schema: SearchSchema>(
    of service: SearchService<Schema>,
    for query: SearchQuery<Schema>
) async -> SearchSnapshot<Schema>? {
    var last: SearchSnapshot<Schema>?
    for await snapshot in await service.results(for: query, trigger: .submit) {
        last = snapshot
    }
    return last
}

/// The ids of the final hits of a submitted text query.
func hitIDs<Schema: SearchSchema>(of service: SearchService<Schema>, for text: String) async -> [String] {
    await finalSnapshot(of: service, for: SearchQuery(text: text))?.hits.map(\.id.rawValue) ?? []
}

// MARK: - SQL

extension SQLiteSearchConnection {
    /// Runs statements in one write transaction.
    func execute(_ statements: [SearchSQL]) async throws {
        try await write { writer in
            for statement in statements {
                _ = try writer.run(statement)
            }
        }
    }

    /// The first value of the first row of a statement.
    func value(_ statement: SearchSQL) async throws -> SearchBindingValue? {
        try await read { try $0.scalar(statement) }
    }

    /// Every row of a statement.
    func allRows(_ statement: SearchSQL) async throws -> [[SearchBindingValue?]] {
        try await read { reader in try reader.rows(statement).map(\.values) }
    }
}
