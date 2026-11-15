import Foundation
import SQLite
import ZTronSearchEngine

// `SearchBindingValue` and SQLite.swift's `Binding?` describe the same five storage classes.
// The mapping is exact in both directions for integers, text, blobs and NULL, and for every real
// number SQLite itself can store.
//
// Two limits come from below the adapter and are worth knowing:
// - SQLite stores a NaN as NULL, so `.real(.nan)` reads back as `.null`.
// - SQLite.swift binds and reads text as a C string, so text ends at an embedded NUL character.
//   Bytes that may contain one belong in a `.blob`.

extension SearchBindingValue {
    /// The engine's value for a value SQLite.swift bound or read. `nil` is SQL `NULL`.
    ///
    /// SQLite.swift maps exactly six Swift types to SQLite: `Int64`, `Double`, `String`, `Blob`,
    /// and `Int` and `Bool`, which it stores as integers. Its documentation forbids any other
    /// conformance to `Binding`, and it traps when asked to bind one; so does this initializer.
    public init(_ binding: (any Binding)?) {
        switch binding {
        case nil:
            self = .null
        case let value as String:
            self = .text(value)
        case let value as Int64:
            self = .int(value)
        case let value as Double:
            self = .real(value)
        case let value as Blob:
            self = .blob(Data(value.bytes))
        case let value as Int:
            self = .int(Int64(value))
        case let value as Bool:
            self = .int(value ? 1 : 0)
        case .some(let other):
            preconditionFailure("SQLite.swift cannot bind a value of type \(type(of: other)).")
        }
    }

    /// The value as SQLite.swift binds it. `.null` is `nil`.
    public var sqliteBinding: (any Binding)? {
        switch self {
        case .null: return nil
        case .int(let value): return value
        case .real(let value): return value
        case .text(let value): return value
        case .blob(let data): return Blob(bytes: [UInt8](data))
        }
    }
}
