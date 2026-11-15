import Foundation

/// The failures the adapter reports on its own.
///
/// Errors raised by SQLite (a syntax error, a constraint, a locked database) are not wrapped:
/// they pass through as SQLite.swift's `Result`, whose description carries SQLite's message and
/// code.
public enum SQLiteSearchError: Error, Sendable, Hashable {
    /// The connection was closed.
    case connectionClosed
    /// `write` was called on a connection whose database is read-only.
    case readOnlyConnection
    /// The location is not one SQLite can open: a URL that is not a file URL.
    case unsupportedLocation(String)
    /// A statement was given a different number of bindings than it has parameters.
    case bindingCountMismatch(expected: Int, provided: Int, statement: String)
    /// A reader or writer was used after the transaction it belongs to ended.
    case transactionEnded
}

extension SQLiteSearchError: CustomStringConvertible {
    /// What went wrong, in a sentence. Core puts it in the diagnostic it reports.
    public var description: String {
        switch self {
        case .connectionClosed:
            return "The database connection is closed."
        case .readOnlyConnection:
            return "The database connection is read-only; it cannot run a write transaction."
        case .unsupportedLocation(let location):
            return "SQLite cannot open '\(location)': only file URLs name a database file."
        case .bindingCountMismatch(let expected, let provided, let statement):
            return "The statement has \(expected) parameter(s) but \(provided) binding(s) were given: \(statement)"
        case .transactionEnded:
            return "The reader or writer was used after its transaction ended."
        }
    }
}
