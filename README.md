# ZTronSearchEngine

Fully offline, typo-tolerant, multilingual search for Apple platforms, with a pure-SwiftUI search
field. iOS 15.0 floor, Swift 6 language mode, no third-party dependency in the package itself.

A query yields a stream of snapshots: lexical and fuzzy hits within milliseconds, then the same
list refined by the semantic channel, then (on devices that pass a calibration) the head of it
reordered by a cross-encoder. Every snapshot carries a generation, so a view never shows the
results of a query the user has already typed past.

## Products

| Product | Imports | What it holds |
| --- | --- | --- |
| `ZTronSearchEngine` | Foundation, NaturalLanguage, Accelerate, os | Contracts, text pipeline, BM25F index, fuzzy channel, fusion and ranking, `SearchService`, search contexts, database sources, chat service |
| `ZTronSearchEngineSemantic` | Core ML, Accelerate | INT8 vector store, HNSW index, Core ML embedding provider and cross-encoder, rerank calibration gate |
| `ZTronSearchEngineUI` | SwiftUI | `ZTronSearchField`, tokens, the results, suggestions and chat models, the `zTron…` attachment modifiers |

Three packages keep their dependencies out of these products:

| Package | Depends on | What it holds |
| --- | --- | --- |
| `Adapters/ZTronSearchEngineSQLite` | SQLite.swift | The reference adapter of the database boundary |
| `Adapters/ZTronSearchEngineMLX` | mlx-swift, mlx-swift-lm (iOS 17, macOS 14) | The reference local language-model runtime |
| `Adapters/ZTronSearchEngineAssetKit` | ZTronAssetKit | The model-asset boundary over ZTronAssetKit |
| `ParityHost` | UIKit | The reference rendering the SwiftUI field is compared with; the only UIKit in the repository |

## Searching

Items stay the host's own types. They say what they are through small protocols, and a schema
names the kinds and filters of one catalog:

```swift
import ZTronSearchEngine

enum CatalogKind: String, SearchItemKind { case map, tip, tool }

enum CatalogFilter: SearchFilter {
    case platform(String)
    var key: String { "platform" }
    var value: String { switch self { case .platform(let name): return name } }
    init?(key: String, value: String) {
        guard key == "platform" else { return nil }
        self = .platform(value)
    }
}

enum CatalogSchema: SearchSchema {
    typealias Kind = CatalogKind
    typealias Filter = CatalogFilter
}

struct Tip: Searchable, TitledSearchable {
    let searchID: SearchableID
    let searchTitle: String
    let searchText: String
    var searchKind: CatalogKind { .tip }
}
```

A service over an index the host owns:

```swift
let service = SearchService<CatalogSchema>(index: LexicalIndex())
await service.index(tips)

for await snapshot in await service.results(for: SearchQuery(text: "frozn harbor")) {
    render(snapshot.hits)           // lexical first, then semantic, then reranked
    if snapshot.isFinal { break }
}
```

Small lists (a settings screen, a picker) need neither an index nor an actor:

```swift
let settings = ScanIndex<SettingsSchema>(items: entries)
let hits = settings.hits(for: SearchQuery(text: "notif"))    // synchronous, same ranking
```

A context can also draw its documents from database tables, through a boundary the host
implements (`Adapters/ZTronSearchEngineSQLite` does it for SQLite.swift), and keep its index in
a file of its own or inside the host database. See `SearchContext`, `SearchSource` and
`SearchTableSource`.

Constrained existentials (`[any Searchable<Kind>]`) need the iOS 16 runtime, so on the iOS 15
floor the entry points are generic (`index<Item>(_:)`, `SearchContext(id:items:)`) and carry
items as `AnySearchable<Kind>`; the spellings of the specification are available from iOS 16.

## The search field

```swift
import ZTronSearchEngineUI

struct CatalogScreen: View {
    @StateObject private var results: ZTronSearchResultsModel<CatalogSchema>
    @State private var text = ""
    @State private var tokens: [ZTronSearchToken<CatalogSchema>] = []

    var body: some View {
        VStack {
            ZTronSearchField(text: $text, tokens: $tokens, prompt: Text("Search"))
            List(results.hits) { hit in Row(hit) }
        }
        .zTronSearch(results, text: $text, tokens: $tokens)
    }
}
```

The field is SwiftUI only: `TextField`, `Capsule`, `FocusState` and an asset catalog sampled
from `UISearchTextField` by the parity host. The models are `@MainActor` observable objects the
host owns; the modifiers only wire them.

## Semantic channel, reranking and chat

Each is injected, and the engine runs the channels it is given:

```swift
import ZTronSearchEngineSemantic

let semantic = try SemanticIndex(provider: embeddingProvider)     // any EmbeddingProvider
let service = SearchService<CatalogSchema>(index: index, semantic: semantic, reranker: reranker)

let engine = ZTronSearch(search: service, assets: assetProvider, languageModel: runtime)
let chat = engine.chat        // nil when either boundary is absent
```

The package ships no model. `Scripts/semantic` converts a multilingual embedding model and a
cross-encoder to Core ML with 8-bit weights; which models to ship is an open question of the
specification.

## Ranking signals

`RankingProfile` holds everything the engine weighs, and the host injects the signals:
popularity, editorial pins and suppressions, user affinity. Freshness comes from `updatedAt`.

```swift
var profile = RankingProfile.default
profile.freshness = .freshness(halfLifeDays: 30)
profile.kindBoosts = ["tip": 1.005]
let service = SearchService<CatalogSchema>(
    index: index, profile: profile, signals: SignalProviders(popularity: analytics)
)
```

Popularity and freshness default to a weight of 0.5% of the top fused score
(`SignalSpec.tunedWeight`), far below the 15% ceiling. That is what the golden judgments allow
a signal that knows nothing about relevance: reciprocal rank fusion puts neighbouring ranks
1.6% of the top score apart, so such a signal starts costing queries at 1% and breaks the
exact-title or localized-title gate at 3%; kind boosts do at 1%. A signal that agrees with
relevance can carry more. Measure before raising it: `SignalTuningTests` runs the golden set
under one profile after another and prints what each costs every class.

## Layout

```
Sources/ZTronSearchEngine           core
Sources/ZTronSearchEngineSemantic   vectors, HNSW, Core ML adapters, calibration
Sources/ZTronSearchEngineUI         field, models, modifiers, resources
Sources/ZTronSearchFixtures         golden corpus and query set, synthetic corpus, fakes
Tests/                              one test target per product, plus the fixtures' own
Adapters/                           SQLite, MLX and ZTronAssetKit packages
ParityHost/                         UIKit reference and the parity suite
Scripts/                            asset generation and model conversion
```

## Verifying

```sh
# Everything that runs on a Mac, in a debug build.
swift test

# The same under Thread Sanitizer.
swift test --sanitize=thread

# Quality targets of section 15 that need no model: latency, memory, small contexts, database
# sources. Budgets are asserted on optimized builds only.
swift test -c release -Xswiftc -enable-testing --filter PerformanceTests

# Relevance gates over the golden set among 100,000 distractors (5,000 by default).
ZTRON_FULL_CORPUS=1 swift test -c release -Xswiftc -enable-testing --filter RelevanceTests

# The sweep the default signal weights come from (add ZTRON_FULL_CORPUS=1 for 100,000).
ZTRON_TUNE_SIGNALS=1 swift test -c release -Xswiftc -enable-testing --filter SignalTuningTests

# HNSW recall and latency at 100,000 vectors.
ZTRON_SEMANTIC_LARGE=1 swift test -c release -Xswiftc -enable-testing --filter ZTronSearchEngineSemanticTests

# The adapters, each from its own directory. The SQLite one asserts the section 15.9 targets
# against a real database in a release build.
(cd Adapters/ZTronSearchEngineSQLite && swift test)
(cd Adapters/ZTronSearchEngineSQLite && swift test -c release -Xswiftc -enable-testing --filter DatabaseTargetsTests)
(cd Adapters/ZTronSearchEngineMLX && swift test --build-system native)
(cd Adapters/ZTronSearchEngineAssetKit && ZTRON_ASSETKIT_PATH=/path/to/ZTronAssetKit swift test)

# The whole suite on an iOS simulator.
xcodebuild test -scheme ZTronSearchEngine-Package -destination "platform=iOS Simulator,name=iPhone 15,OS=17.5"

# UI parity against the UIKit reference: drift of the sampled assets, the matrix, the gate.
# ParityHost/README.md says what each does and what a Mac can and cannot run.
python3 Scripts/generate_ui_assets.py --check
ParityHost/Tools/run-matrix.sh
python3 ParityHost/Tools/gate.py ParityHost/Results
```

The performance tests hold every measurement against its budget on the reference device
(iPhone 6s, iOS 15.8, 100,000 items, Release). Off that device they assert the budget divided by
how much slower the device is than the machine running them (`ReferenceDevice.slowdown`, 6 for an
Apple-silicon Mac). Passing there is necessary for passing on the device, not sufficient: only a
run on the device settles a gate, and `PerformanceTests` carries `XCTClockMetric` and
`XCTMemoryMetric` baselines to record there.

The relevance tests use the deterministic fake embedding provider and reranker of the fixtures.
They prove the pipeline reaches the gates with a model that understands the query; they say
nothing about a particular production model.

The parity gate of section 15.7 is not met yet. `ParityHost/Results/summary.md` holds the last
run: the field matches the reference on iOS 17.5 and 18.6 on 3x iPhones, left to right, at the
default content size, and is outside a threshold elsewhere.
