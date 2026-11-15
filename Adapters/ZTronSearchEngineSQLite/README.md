# ZTronSearchEngineSQLite

The reference SQLite.swift adapter of ZTronSearchEngine (specification section 9.2, rules 7 and 8).

ZTronSearchEngine can search the rows of a SQLite database, but its core never imports
SQLite.swift: it talks to a database through a small boundary (`SearchDatabase`,
`SearchDatabaseConnection`, `SearchSQL`) that the host implements and injects. This package is
that implementation for hosts that use [SQLite.swift](https://github.com/stephencelis/SQLite.swift).
It is a separate package, so SQLite.swift never reaches the core products.

| Type | What it does |
| --- | --- |
| `SQLiteSearchDatabase` | Opens file, in-memory and URI locations as a SQLite.swift `Connection`. |
| `SQLiteSearchConnection` | Deferred read transactions, write transactions, the change stream from SQLite's update, commit and rollback hooks, and `withConnection` for the host's own statements. |
| `SearchSQL`, `SearchTableSource`, `SearchStringField`, `SearchFilterColumn` extensions | Render `Expression<String>`, any other typed expression and `Table` to the fragments core composes. |
| `BundleLocalizedStringResolver` | Resolves localization keys from the `.lproj` strings tables of the host's bundles. |

## Requirements

- iOS 15 or later. Tests run on macOS with `swift test`.
- SQLite.swift 0.16 or later. The package resolves 0.17.0 today and is tested against 0.16.0
  and 0.17.0; it uses no API that only the newer one has. Both need Swift tools 6.1, and 0.17
  requires macOS 12 when built for the Mac.
- Swift 6 language mode, with a plain `import SQLite`: no `@preconcurrency` is needed with
  either version.

## Wiring a host

The host declares its table once with SQLite.swift and reuses the same typed columns to tell
the engine what to search.

```swift
import SQLite
import ZTronSearchEngine
import ZTronSearchEngineSQLite

// 1. The host's schema. `SQLite.Expression` is spelled with its module because Foundation has
//    an `Expression` of its own on recent systems.
let tools = Table("tools")
let id = SQLite.Expression<Int64>("id")
let titleKey = SQLite.Expression<String>("title_key")     // a key of Catalog.strings
let summary = SQLite.Expression<String>("summary")        // the text itself, in English
let tags = SQLite.Expression<String?>("tags")             // "navigation, brass"
let platform = SQLite.Expression<String>("platform")      // "ios,mac"
let isPublished = SQLite.Expression<Bool>("is_published")
let updatedAt = SQLite.Expression<Date?>("updated_at")

// 2. Open the database through the adapter.
let database = SQLiteSearchDatabase(options: .init(enablesWAL: true))
let connection = try await database.connect(.file(databaseURL, readonly: false))

// 3. Say what to search, from the typed columns.
let source = SearchTableSource<AppSchema>(
    table: tools,
    id: id,
    kind: .tool,
    fields: [
        .init(role: .title, expression: titleKey, encoding: .localizedKey(table: "Catalog", bundle: .main)),
        .init(role: .text, expression: summary, encoding: .literal(language: "en")),
        .init(role: .keywords, expression: tags, separator: ","),
    ],
    filters: [.init(key: "platform", expression: platform, separator: ",")],
    predicate: isPublished,
    updatedAt: updatedAt
)

// 4. One context and its service. Once the context is indexed (above 500 rows, or with
//    `strategy: .indexed`) its index is kept in the same database, in `zt_search_*` tables
//    the engine writes through the connection.
let context = SearchContext<AppSchema>(
    id: "catalog",
    sources: [.database(connection, [source])],
    localizedStrings: BundleLocalizedStringResolver(),
    indexStorage: .database(tablePrefix: "zt_search")
)
let service = SearchService<AppSchema>(context: context)
await service.waitUntilReady()

for await snapshot in await service.results(for: SearchQuery(text: "sextant"), trigger: .submit) {
    print(snapshot.hits.map(\.id))                         // [tools#17]
}

// 5. The host writes through the same connection, so the engine hears about it.
try await connection.withConnection { db in
    try db.run(tools.filter(id == 17).update(summary <- "Brass sextant with its case"))
}
```

`AppSchema` is the host's `SearchSchema`. The sample is compiled and run by
`ReadmeSampleTests`; change one and the other has to follow.

### Declaring a source

- **Fields.** A field is an `Expression<String>` or `Expression<String?>` and an encoding:
  `.literal(language:)` when the column holds the text, `.localizedKey(table:bundle:)` when it
  holds a key of a strings table, `.perRow(isKey:table:bundle:)` when a boolean column says
  which of the two a row holds.
- **Filters.** A filter is a key and any typed expression; its value reaches
  `Schema.Filter.init?(key:value:)` as text.
- **Predicate, not `filter`.** Pass the table without clauses and give the condition as
  `predicate:`. A table that carries clauses of its own (`tools.filter(...)`, a join, a column
  list) is rendered as a sub-select, which has no rowid: the engine then reads the whole source
  again on every change instead of the rows that changed.
- **Rowid.** `rowID:` is `.automatic` by default: `rowid` for a table, none for a view or a
  sub-select. Pass `.unavailable` for a table declared `WITHOUT ROWID`.
- **Other fragments.** `SearchSQL(expression)` renders any typed expression, `SearchSQL(table:)`
  a table, and core's own `SearchSQL(template:bindings:)` takes SQL written by hand. Templates
  and bindings are passed through untouched.

A statement whose bindings do not match its placeholders throws
`SQLiteSearchError.bindingCountMismatch` when it runs. SQLite.swift would trap.

## Changes

`SQLiteSearchConnection.changes(in:)` is fed by SQLite's update, commit and rollback hooks:

- each commit yields one `SearchDatabaseChange` per subscribed table it touched, with the
  rowids that were inserted, updated or deleted;
- a transaction that is rolled back yields nothing;
- every subscriber has a stream of its own, and a stream that is cancelled or dropped gives up
  its subscription.

The engine subscribes by itself. What the host has to do is make its writes through the
connection the engine reads from, with `withConnection`, and keep three rules:

1. The `Connection` handed to the body must not outlive it, and neither may a `Statement` or a
   row iterator made from it. Return plain values. The compiler enforces this in Swift 6 mode.
2. A transaction begun in a body must end in that body.
3. The update, commit and rollback hooks belong to the adapter. Subscribe to `changes(in:)`
   instead of setting them.

SQLite does not report everything. The update hook stays silent for writes made through
another connection or by another process, for `WITHOUT ROWID` tables, for `DELETE FROM table`
without a `WHERE` clause on a table without triggers (use `DELETE FROM table WHERE 1`), and for
rows that `INSERT OR REPLACE` removes to make room. After such a change, tell the engine:

```swift
connection.reportUnknownChanges(in: ["tools"])   // the table is read again as a whole
```

## Write-ahead logging

`SQLiteSearchDatabase.Options.enablesWAL` runs `PRAGMA journal_mode = WAL` when a file database
is opened. The specification recommends it when the host writes while the engine reads: with a
write-ahead log a reader on one connection never blocks a writer on another, and each page the
engine reads stays a consistent snapshot. The mode is stored in the database file. In-memory and
read-only databases are left alone, and so is `synchronous`.

`Options.busyTimeout` (5 seconds by default) is how long a statement waits for a lock held by
another connection before it fails with `SQLITE_BUSY`. The wait happens on the connection's own
queue.

A connection opened read-only refuses `write` with `SQLiteSearchError.readOnlyConnection`, so
it cannot hold the index: use `.files` or `.inMemory` index storage with it.

## Localized strings

`BundleLocalizedStringResolver` maps each `SearchBundleID` to a `Bundle` (`.main` is
`Bundle.main` unless the host registers another) and answers from the strings tables of the
bundle's `.lproj` directories:

```swift
let resolver = BundleLocalizedStringResolver(bundles: ["catalog": catalogBundle])
```

- `languages(bundle:table:)` lists the languages that have the table, the bundle's development
  localization first; core takes the first one as the base the others fall back to.
- `string(forKey:table:bundle:language:)` is `Bundle.localizedString(forKey:value:table:)` on
  the bundle of that language. A missing key is `nil`, never the key.
- The resolver is immutable, which is what makes it `Sendable` without a lock: it finds every
  language bundle once, when it is created, and keeps them. Foundation keeps a strings table in
  memory once a bundle has read it, so the resolver adds no cache of its own.

## Concurrency

`SQLiteSearchConnection` is the one `@unchecked Sendable` of the adapter, as the specification
allows (section 9.2, rule 7). Its doc comment states the invariant: the SQLite.swift
`Connection`, and everything kept next to it, is only ever touched by a block running on one
private serial `DispatchQueue`. `read`, `write`, `withConnection` and `close` suspend the caller
and resume it with the result; nothing blocks a thread of Swift's cooperative pool. The hooks
run on that queue too, because SQLite calls them on the thread that runs the statement.

## Tests

```sh
swift test
```

The tests use real SQLite databases, in memory and in temporary files, and strings bundles
written at test time. They cover connections, transactions, bindings, the change stream,
expression and table rendering (including core's composed SELECT), write-ahead logging, core's
index tables, the resolver, and a `SearchService` over a table of 200 rows from the first query
to the results after a change.

Three tests in `EndToEndTests` commit while the engine pages through a table: during the first
load, during a `refresh()`, and a delete that moves a row across a page boundary. They hold the
engine to applying every change once the read is in.

`.github/workflows/adapter-tests.yml` at the root of the repository is the GitHub Actions job
that runs the tests on a macOS runner, with and without Thread Sanitizer, against the
SQLite.swift the package resolves and against 0.16.0.
