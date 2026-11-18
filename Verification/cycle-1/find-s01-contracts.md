# Cycle 1, slice s01-contracts (spec sections 1-6, pages 1-10)

Auditor checkpoint. Requirement-centric trace of commit cee4620. Status values: met, partial, missing, contradicted, unverifiable-here.

Evidence rules applied: a comment, README sentence or test name is not evidence; a test counts only if it asserts on product code, cannot pass vacuously and does not skip in CI.

Path legend: Core = Sources/ZTronSearchEngine, Sem = Sources/ZTronSearchEngineSemantic, UI = Sources/ZTronSearchEngineUI, Fix = Sources/ZTronSearchFixtures, T = Tests/ZTronSearchEngineTests, ST = Tests/ZTronSearchEngineSemanticTests, UT = Tests/ZTronSearchEngineUITests, FT = Tests/ZTronSearchFixturesTests.

Scratch directory (all probes): /private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s01-contracts/ . Probes were compiled with swiftc from copies of Core and Fix (`swiftc -swift-version 6 -Onone -enable-testing -parse-as-library -emit-library ... -module-name ZTronSearchEngine`), never inside the repository.

Run log used: Verification/_runs/c1-debug-swift-test.log (complete, EXIT 0, 0 warnings; PerformanceTests all skipped in debug).

## Requirement table

| R# | Sec/page | Requirement | Status | Code | Test |
|---|---|---|---|---|---|
| R1 | 1 p1 | Fully offline: no network at query time | met | grep of Sources: no URLSession, Network or @objc use; core imports Foundation, NaturalLanguage, Accelerate, os | none direct (UT/LintTests.swift:47 is an import allow-list, Foundation still includes URLSession) |
| R2 | 1 p1, 2 p2 | iOS 15.0 deployment floor | met | Package.swift:12 `platforms: [.iOS(.v15)]`; iOS 16 runtime-only existentials gated @available(iOS 16) (Core/Contracts/Searchable.swift:142-158) | T/SearchContextTests.swift:206; CI iOS 15.5 simulator job (not run here) |
| R3 | 1 p1, 2 p2 | Swift 6 strict concurrency | met | Package.swift:58 `swiftLanguageModes: [.v6]`; build log 0 warnings | build itself |
| R4 | 1 p1-2 | Fast on iPhone 6s (reference device targets) | unverifiable-here | Fix/ReferenceDevice.swift (scaled budgets) | T/PerformanceTests.swift (XCTSkip in DEBUG 58-62; knownGap pattern, see F04); no device, no release perf log |
| R5 | 1 p1 | One engine for all kinds, kind-aware ranking, every hit reports its class | met | Core/Contracts/RankingProfile.swift:112-113, 166-169; hit kind in Core/Service/SearchPipeline.swift:120-141 | T/CoreCorrectnessTests.swift:182; T/RankingTests.swift:74; UT/ResultsModelTests.swift:66 |
| R6 | 1 p1 | Host-decided independent contexts with own schema | met | Core/Contracts/SearchContext.swift; Core/Service/SearchService+Context.swift:75-154 | T/SearchContextTests.swift:25, 77, 97 |
| R7 | 1 p1 | Memory or SQLite items via host-injected boundary; string expressions hold text or key | met | Core/Contracts/DatabaseBoundary.swift:67, 176, 241 | T/DatabaseSourceTests.swift:262-346, 397 |
| R8 | 1 p1 | Semantic and cross-language retrieval via shared multilingual space | met (existence) | Core/Contracts/SemanticBoundary.swift:24; Sem/EmbeddingProvider.swift:11; Sem/SemanticIndex.swift | ST/VectorSetCatalogTests.swift:66; FT/GoldenSetTests.swift:215 |
| R9 | 1 p1 | Typo tolerance with bounded edit distance | met | Core fuzzy channel; Core/Contracts/SearchEngineConfiguration.swift:44 | T/CoreCorrectnessTests.swift:111, 118, 127; T/FuzzyChannelTests.swift:203 |
| R10 | 1 p1 | Index and match localized values whenever provided, base otherwise | partial | Core/Projection/SearchProjector.swift:64-172; Core/Database/SearchRowProjector.swift:115-150 | T/InternationalizationTests.swift:30, 134 - see F01, F02, F03 |
| R11 | 1 p1 | Throttled, cancellable search that never publishes stale results | partial | Core/Service/SearchService.swift:311-316, 368-462; SearchEngineConfiguration.swift:162-163 | T/ConcurrencyTests.swift:34-159; T/SnapshotPipelineTests.swift:112; UT/ResultsModelTests.swift:119 - see F06 |
| R12 | 1 p1 | Grounded chat via local LLM only through host-injected boundaries | met | Core/Contracts/ChatBoundary.swift:66, 183; Core/Chat/ChatService.swift:23 | T/ChatTests.swift:102; UT/AttachmentModifierTests.swift:362-406 |
| R13 | 1 p1 | Non-goal: no online/server search, no cloud LLM | met | as R1; MLX adapter is on-device (Adapters/ZTronSearchEngineMLX) | none direct |
| R14 | 1 p1 | Personalization: hook only | met | Core/Contracts/RankingProfile.swift:196-219 | T/RankingTests.swift:159 |
| R15 | 1 p2 | Field, observable models, attachment modifiers; no list/row/transcript/chat views | met | UI: only public View is ZTronSearchField; models @MainActor | UT/LintTests.swift:92, 106, 154 |
| R16 | 2 p2 | One SwiftPM package, three library products | met | Package.swift:14-16 | none (manifest) |
| R17 | 2 p2 | tools 6.0, platforms [.iOS(.v15)], swiftLanguageModes [.v6] | met | Package.swift:1, 12, 58 | none (manifest) |
| R18 | 2 p2 | Core depends on nothing; Foundation, NaturalLanguage, Accelerate | met (plus `os` for logging, see knocked down) | core target has no dependencies; imports per grep | UT/LintTests.swift:47 |
| R19 | 2 p2 | Core contents (contracts, schema, document, projector, normalizer, tokenizer, contexts, ScanIndex, DB boundaries, BM25F, fuzzy, RRF, RankingProfile, SearchService, persistence, facade, ModelAssetProviding, LocalLanguageModel, ChatService) | met | Core/Scan/ScanIndex.swift:8; Core/Index/LexicalIndex.swift:22; Core/Service/SearchService.swift:12; Core/Chat/ChatService.swift:23, 666; Core/Contracts/ChatBoundary.swift:66, 183; Core/Contracts/DatabaseBoundary.swift:67, 176, 241 | existence only |
| R20 | 2 p2 | Semantic: EmbeddingProvider, Core ML adapter, INT8 store, HNSW actor, Reranking, cross-encoder, calibration gate | met | Sem/EmbeddingProvider.swift:11; Sem/CoreML/CoreMLEmbeddingProvider.swift:19; Sem/Vector/QuantizedVectorStore.swift:33; Sem/HNSW/HNSWIndex.swift:27; Sem/CoreML/CoreMLCrossEncoder.swift:23; Reranking protocol in Core/Contracts/SemanticBoundary.swift:51 (knocked down) | ST suite (172 tests, 3 skipped, run log) |
| R21 | 2 p3 | UI contents; SwiftUI only; Semantic injected, never imported | met | UI imports only SwiftUI, Combine, Foundation, ZTronSearchEngine (grep); Package.swift:31 | UT/LintTests.swift:19 |
| R22 | 2 p3 | MLX separate package, iOS 17/macOS 14, core + mlx-swift + mlx-swift-lm | met | Adapters/ZTronSearchEngineMLX/Package.swift:13, 20-30 | CI MLX job (not run here) |
| R23 | 2 p3 | SQLite reference adapter separate; SQLite.swift 0.16+ | met | Adapters/ZTronSearchEngineSQLite/Package.swift:11, 16 | adapter tests not run here |
| R24 | 2 p3 | Parity host is a test host, never shipped | met | ParityHost/ outside the root products (Package.swift:14-16) | none |
| R25 | 2 p3 | No third-party packages in core or UI | met | root Package.swift has no package dependencies | UT/LintTests.swift:53 |
| R26 | 2 p3 | UI never imports UIKit, no UIKit types | met | UI import grep | UT/LintTests.swift:19, 26 |
| R27 | 2 p3 | keyboardType/textContentType wrapped by package enums | met | UI/ZTronSearchField.swift:811-842 | none found |
| R28 | 2 p3 | Lint step fails the build on import UIKit in UI | met (as a CI test) | Fix/SourceLint.swift; .github/workflows/ci.yml unit job | UT/LintTests.swift:19, 26 |
| R29 | 2 p3 | @unchecked Sendable only in HNSW wrapper | met (stricter: none in products) | Sem/HNSW/HNSWIndex.swift:25-27 (actor); only use is adapter SQLiteSearchConnection.swift:41 (9.2 rule 7) | UT/LintTests.swift:66 |
| R30 | 2 p4 | MLX iOS 17 floor never raises package floor | met | Adapters/ZTronSearchEngineMLX/Package.swift:13 vs Package.swift:12 | none |
| R31 | 2 p4 | ZTronAssetKit never imported; injected via ModelAssetProviding through facade | met | Core/Contracts/ChatBoundary.swift:66; Core/Chat/ChatService.swift:666; Adapters/ZTronSearchEngineAssetKit/Package.swift:27-28 | T/ChatTests.swift:102; UT/LintTests.swift:53 |
| R32 | 2 p4 | Core compiles on macOS | met | run log (arm64-apple-macosx, EXIT 0); scratch swiftc build of Core on macOS succeeded | T suite ran on macOS |
| R33 | 2 p4 | Swift-only, Sendable public API; no Objective-C exposure | met | grep: no @objc / NSObject in Sources; public types Sendable | compile in Swift 6 mode |
| R34 | 2 p4 | Test targets mirror products + fixtures with golden set and 100k generator | met | Package.swift:38-55; Fix/ | FT/GoldenCorpusTests.swift:11; FT/SyntheticCorpusTests.swift:32 |
| R35 | 3 p4 | Searchable gives evidence; weight only in RankingProfile and providers | met | Core/Contracts/Searchable.swift:50-110; RankingProfile.swift:106-170 | T/RankingTests.swift:74, 159 |
| R36 | 3 p4 | Domain owns no scores, weights, boosts, relevance, index details | met | Core/Contracts/Searchable.swift:50-127 | structural |
| R37 | 3 p4 | Domain never imports index types; projection is the engine-side view | met | Searchable.swift; Core/Contracts/SearchDocument.swift:89 | structural |
| R38 | 3 p4 | Retune by swapping RankingProfile | met | RankingProfile.swift:106-160 | T/RankingTests.swift:74 |
| R39 | 4 p4 | Three required members; capabilities detected by conformance at projection | met | Searchable.swift:50-59; SearchProjector.swift:64-172 | T/InternationalizationTests.swift:108 |
| R40 | 4 p5 | SearchableID signature | met (but see F11) | Searchable.swift:9-26, 35-37 | used throughout |
| R41 | 4 p5 | SearchItemKind signature | met | Searchable.swift:41 | T/CoreCorrectnessTests.swift:182 |
| R42 | 4 p5 | Searchable<Kind> signature | met | Searchable.swift:50-59 | compile |
| R43 | 4 p5-6 | Capability protocol signatures | met (+ additive CaptionedSearchable) | Searchable.swift:63-110 | T/InternationalizationTests.swift:108 |
| R44 | 4 p6 | SearchLocalization signature | met | Searchable.swift:115-127 | T/InternationalizationTests.swift:30-76 |
| R45 | 4 p6 | Values are resolved strings; core does no bundle lookups; keys only via injected resolver | partial | Core/Chat/ChatService.swift:624 (Bundle.main.infoDictionary); DatabaseBoundary.swift:241 | none asserts bundle-freedom - see F12 |
| R46 | 4 p6 | Filter keys/values canonical; index persists only two strings | met | Core/Contracts/SearchSchema.swift:16-34 | T/CoreCorrectnessTests.swift:216 |
| R47 | 4 p6 | searchKind required, never defaulted | met | Searchable.swift:56 (no default anywhere, grep) | compile |
| R48 | 4 p6 | SearchableID unique across kinds; collision is a debug assertion | partial | Core/Support/Diagnostics.swift:20-31; SearchService.swift:1002-1004, 1017-1045; SearchService+Context.swift:97, 242 | T/IndexMaintenanceTests.swift:60; T/DatabaseSourceTests.swift:464-476 - see F07 |
| R49 | 4 p6 | Images only through text; engine never reads pixels | met | Searchable.swift:63-110 (caption/OCR text only) | T/CoreCorrectnessTests.swift:33 |
| R50 | 4 p6 | Capability matrix expressible | met | Searchable.swift:63-110; Fix/CatalogSchema.swift | T/InternationalizationTests.swift:108 |
| R51 | 4.1 p7 | Engine generic over one SearchSchema; typed hits/queries/tokens/snapshots | met | SearchService.swift:12 | T/CoreCorrectnessTests.swift:216, 375 |
| R52 | 4.1 p7 | SearchSchema / SearchFilter signatures | met | SearchSchema.swift:6-9, 16-23 | T/CoreCorrectnessTests.swift:216 |
| R53 | 4.1 p7-8 | Fallback string schema + ZTronSearchService typealias | met | SearchSchema.swift:44-80 | T/CoreCorrectnessTests.swift:333 |
| R54 | 4.1 p8 | One schema per engine, fixed at construction | met | SearchService.swift:12 (generic parameter) | T/SearchContextTests.swift:25 |
| R55 | 4.1 p8 | Heterogeneous item types share the schema | met | Searchable.swift:142-158 (AnySearchable) | T/CoreCorrectnessTests.swift:182 |
| R56 | 4.1 p8 | Only raw strings persisted | met | SearchDocument.swift:89-160; SearchSchema.swift:26-34 | T/CoreCorrectnessTests.swift:216; T/StrategyParityTests.swift:136 |
| R57 | 4.1 p8 | Typed cases rebuilt at query time; unknown kinds never surface; unknown filters ignored; both logged | partial | Core/Service/SearchPipeline.swift:108-118 (kinds); SearchService.swift:994-998, Core/Query/BM25F.swift:82-117 (filters stay raw) | T/CoreCorrectnessTests.swift:199, 229 - see F10 |
| R58 | 4.1 p8 | Equality, AND across keys, OR within a key | met | BM25F.swift:82-117 | T/CoreCorrectnessTests.swift:263 |
| R59 | 4.1 p8 | Filters never localized, fuzzed or prefix-matched | met | BM25F.swift:82-117 | T/CoreCorrectnessTests.swift:309 |
| R60 | 4.1 p8 | Equality only | met | BM25F.swift:82-117 | T/CoreCorrectnessTests.swift:263 |
| R61 | 5 p8 | Localized values for the active locale; base only a fallback; every channel | partial | SearchProjector.swift:109-113 | T/InternationalizationTests.swift:30-39, 134-153 (codify) - see F09, F02, F03 |
| R62 | 5.1 p8 | locale defaults to Locale.current, resolved to BCP 47 once per generation | met | SearchEngineConfiguration.swift:157, 179; Core/Text/LanguageTag.swift:68-81 | T/InternationalizationTests.swift:233 |
| R63 | 5.2 p8 | Field chain exact tag, language, base via Bundle.preferredLocalizations | partial | LanguageTag.swift:32-51 | T/InternationalizationTests.swift:57 - see F08 |
| R64 | 5.3 p9 | Other preferred languages into low-weight localizedAlt; .preferredLanguages, .all, .none | partial | SearchEngineConfiguration.swift:4-13, 159; LanguageTag.swift:68-81; RankingProfile.swift:150 | T/InternationalizationTests.swift:78, 87, 96, 155 - see F05 |
| R65 | 5.4 p9 | NFKC then folding per field language; original kept for highlighting | met | Core/Text/SearchNormalizer.swift:21-35, 45-70 | T/InternationalizationTests.swift:209; T/CoreCorrectnessTests.swift:396 |
| R66 | 5.5 p9 | NLTokenizer(.word) with setLanguage per field; CJK/Thai bigrams | partial | Core/Text/SearchTokenizer.swift:61-94, 152-171, 244; Core/Query/QueryParser.swift:76-77, 145 | T/InternationalizationTests.swift:170 (same language only) - see F03 |
| R67 | 5.6 p9 | Fuzzy and prefix over normalized localized tokens | met | lexical vocabulary of indexed fields (Core/Index/LexicalIndex.swift) | T/InternationalizationTests.swift:170; T/CoreCorrectnessTests.swift:48, 111 |
| R68 | 5.7 p9 | Locale change: background rebuild, new generation, old index serves in-flight and new searches until swap; 2 s/100k | partial | SearchService.swift:793-803, 892-903; SearchService+Context.swift:330-418 | T/InternationalizationTests.swift:233, 285 (codifies cancel); T/PerformanceTests.swift:301-328 (cannot fail) - see F04, F06 |
| R69 | 5.8 p9 | Vectors from base composition at build/sync; per-locale sets with base fallback; never re-embed on device | met (existence) | Sem/SemanticIndex.swift:208-233, 241-284 | ST/VectorSetCatalogTests.swift:11, 37, 66; ST/SemanticIndexTests.swift:570; T/InternationalizationTests.swift:294 |
| R70 | 5.9 p9 | Filters, dates, numbers compared canonically | met | SearchSchema.swift:26-34; BM25F.swift:82-117 | T/CoreCorrectnessTests.swift:309; T/DatabaseSourceTests.swift:370 |
| R71 | 5.10 p9 | Query language optional; recognizer may hint for 8+ chars; else active locale | met (hint optional, off by default) | SearchPipeline.swift:39-43; QueryParser.swift:160-168; SearchEngineConfiguration.swift:144-146, 174 | T/InternationalizationTests.swift:222 |
| R72 | 5.11 p9 | Hits report matchedLanguage and matchedField | met | SearchPipeline.swift:120-141 | T/CoreCorrectnessTests.swift:396 |
| R73 | 5.12 p9 | DB keys resolved exact/language/base and feed localizedAlt; resolver only bundle consumer | partial | Core/Database/SearchRowProjector.swift:115-150 (guard 125-126); ChatService.swift:624 | T/DatabaseSourceTests.swift:262-346 (dotted keys only, fixture 45-53) - see F02, F12 |
| R74 | 5 p9 | UI ships Localizable.xcstrings in Bundle.module (Cancel, Clear, Searching, No results) | met | UI/Resources/Localizable.xcstrings (ar, de, en, es, fr, it, ja); Package.swift:32; UI/ZTronSearchFieldCore.swift:522 | none direct |
| R75 | 6 p10 | SearchDocument shape, projectionVersion = 1 | met (+ additive `languages`) | SearchDocument.swift:89-160 (version at 90) | T/StrategyParityTests.swift:136 |
| R76 | 6 p10 | FilterRecord shape | met | SearchSchema.swift:26-34 | T/CoreCorrectnessTests.swift:216 |
| R77 | 6 p10 | Document built once at index time from item + active locale | partial | SearchService.swift:977-1014; SearchService+Context.swift:122-141, 181-199 | T/SearchContextTests.swift:311-340 (changes only the count) - see F01 |
| R78 | 6 p10 | SearchProjector.project(_:locale:) is pure | met | SearchProjector.swift:25-28 | T/InternationalizationTests.swift:23 |
| R79 | 6 p10 | Persisted files record projection/normalizer version and model id; mismatch discards and rebuilds | met | LexicalIndex.swift:187-207 | T/StrategyParityTests.swift:136, 161; T/DatabaseSourceTests.swift:841 |
| R80 | 6 p10 | Projection is the only type index actors accept | met | LexicalIndex.swift:22 (API takes SearchDocument); ScanIndex.swift:8 | compile |

Tally: 80 requirements; met 67, partial 12 (R10, R11, R45, R48, R57, R61, R63, R64, R66, R68, R73, R77), missing 0, contradicted 0, unverifiable-here 1 (R4).

## Findings

### C1-s01-contracts-01 - CRITICAL - bug
**A persisted context index is adopted after item content changes: the content fingerprint hashes only ids, kinds, text and title byte lengths and updatedAt.**

- Spec: 6 p10 (document built once from the item and the active locale), 5 p8 (localized values indexed), 1 p1.
- Locations: Sources/ZTronSearchEngine/Service/SearchService+Context.swift:181-199 (fingerprint), 122-141 (persisted file adopted after `LexicalIndex.validate`); Sources/ZTronSearchEngine/Index/LexicalIndex.swift:187-207; Sources/ZTronSearchEngine/Contracts/SearchContext.swift:24-28, 75 (default storage `.files(Caches/ZTronSearchEngine)`); Tests/ZTronSearchEngineTests/SearchContextTests.swift:311-340.
- Description: An indexed memory context (more than 500 documents, or `.indexed`) with the default file storage adopts the index file of the previous launch whenever projection version, normalizer version, embedding model id, locale and the "content fingerprint" agree. The fingerprint mixes only `fnv1a(id)`, `fnv1a(kind)`, `searchText.utf8.count`, `searchTitle.utf8.count` and `updatedAt`:
  ```swift
  mix(fnv1a(item.searchID.rawValue))
  mix(fnv1a(item.searchKind.rawValue))
  mix(UInt64(item.searchText.utf8.count))
  if let title = (item.base as? any TitledSearchable)?.searchTitle { mix(UInt64(title.utf8.count)) }
  if let date = (item.base as? any TemporalSearchable)?.updatedAt { mix(date.timeIntervalSinceReferenceDate.bitPattern) }
  ```
  Keywords, filters, localizations, caption, OCR text and the characters of text and title are ignored. An app update that adds translations, changes keywords or filters, or edits text without changing its byte length keeps serving the old documents on every launch. An internal doc comment (lines 178-179) admits "Edits that keep all of them need an explicit refresh()", but nothing public says so: README has no mention of refresh(), and the public `refresh()` doc says only "Re-reads every source on demand."
- Evidence: I ran scratch probe e2e/main.swift `e1` (600 tools, context "catalog", locale "it", `.files(dir)`; v1 tool t0 keyword [alpha], filter platform=ios; v2 same lengths, keyword [bravo], filter platform=mac, Italian title "Martello"). It printed: `v2 stored t0 keywords: ["alpha"] filters: ["platform=ios"] title: Hammer tool`; `'bravo' -> []`; `'martello' -> []`; `'alpha' -> ["t0"]`; `hammer platform=mac -> []`; `hammer platform=ios -> ["t0"]`; after `refresh()`: `'bravo' -> ["t0"]`, `'martello' -> ["t0"]`. The only persistence test changes just the item count.
- Failure scenario: Version 2 of an app adds Italian translations and new keywords to an existing 600-item catalog. Italian users keep the version 1 index from Caches indefinitely: localized titles and new keywords never match, removed keywords still match, and filters answer from the old values (platform=mac excludes the item, platform=ios includes it).
- Severity reasoning: wrong results in normal use (an ordinary content update), persisting across launches, undocumented to hosts.

### C1-s01-contracts-02 - HIGH - bug
**A localization key whose resolved string equals the key is treated as unresolved: the base-language value is dropped, another language becomes the base surface, and a key that is identical in every language indexes nothing.**

- Spec: 5.12 p9 (keys resolved exact tag, language, base), 9.2, 5 p8.
- Locations: Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:124-136 (guard `string != value`), 148-150 (unresolved goes to `reporter.debug`); Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/BundleLocalizedStringResolver.swift (already returns nil for missing keys, "The key itself is never returned"); Tests/ZTronSearchEngineTests/DatabaseSourceTests.swift:45-53 (fixture uses dotted keys only).
- Description: `guard let string = resolver.string(...), SearchProjector.nonEmpty(string) != nil, string != value else { continue }` skips any resolved value equal to the key, presumably to filter NSLocalizedString's echo of a missing key. The reference resolver already returns nil for missing keys, and Xcode String Catalogs use the source text as the key by default ("Bluetooth", "Settings", "Wi-Fi"). For such keys the development-language string is discarded, the first language whose string differs becomes the base surface, and a key equal in all languages produces no surface at all.
- Evidence: I ran scratch probe `e5` (FakeLocalizedStringResolver, language order [en, de, it]; en {Bluetooth: Bluetooth, Settings: Settings}, de {Bluetooth: Bluetooth, Settings: Einstellungen}, it {Bluetooth: Bluetooth, Settings: Impostazioni}; context locale en). It printed: `settings#bt title nil`; `settings#set title Einstellungen language de alt []`; `'bluetooth' -> []`; `'settings' -> []`; `'einstellungen' -> ["settings#set"]`; diagnostics `[unresolvedLocalizationKey(key: "Bluetooth", table: nil, language: "en")]`.
- Failure scenario: An English user searches a settings table keyed by String Catalog source text. "Bluetooth" is unfindable in every language, and "Settings" is indexed as German "Einstellungen" for the English user, so the query "settings" returns nothing.

### C1-s01-contracts-03 - HIGH - bug
**Two-character CJK words miss exact-title queries whenever the query is tokenized in a different CJK language than the field.**

- Spec: 5.5 p9 (CJK/Thai bigrams), 5.10 p9, 1 p1.
- Locations: Sources/ZTronSearchEngine/Text/SearchTokenizer.swift:152-171 (no bigram equal to a word range, no unigrams), 244 (setLanguage per field); Sources/ZTronSearchEngine/Query/QueryParser.swift:76-77 (`case .bigram: continue`), 145 (`guard word.count >= 3` for the bigram fallback); Sources/ZTronSearchEngine/Service/SearchPipeline.swift:39-43 (query tokenized in the active locale); Tests/ZTronSearchEngineTests/InternationalizationTests.swift:170-184 (same language only).
- Description: The indexer segments a two-character word with the field's language. When that segmenter keeps it whole (地圖 under zh-Hant), only the word token is stored. The query is segmented with the active locale. If that segmenter splits the word (zh-Hans splits 地圖 into 地 and 圖 plus a bigram), the parser drops the bigram and runs its fallback only for 3+ character words. The clauses 地 (exact) and 圖 (prefix) match nothing.
- Evidence:
  - I ran scratch probe `cjk`. It printed: "地圖" with zh-Hans gives [地, 圖, bigram 地圖]; with zh-Hant gives [地圖]; "地图" with zh-Hant gives [地, 图, bigram 地图]. Query "地圖" parsed in zh-Hans gives clauses `地 prefix=false`, `圖 prefix=true` and no bigram fallback.
  - I ran scratch probe `cjk2` (exact-title matrix). It printed misses as follows:

    | Engine locale | Exact titles that miss |
    |---|---|
    | en | none |
    | th | none |
    | zh_CN | 地図 (ja item), 地圖 (zh-Hant item) |
    | zh_TW | 地図 (ja), 地图 (zh-Hans), 大学 (zh-Hans item 北京大学) |
    | ja | 地圖 (zh-Hant), 地图 (zh-Hans) |

  - Probe `e3` under `.all` and zh_CN printed alt `["Map","地圖"]` but query `地圖 -> []`.
- Failure scenario: A zh_TW user types the exact title 地图 of an item localized in zh-Hans and gets no hit. A Japanese-locale user types the Traditional title 地圖 reached through localizedAlt and gets no hit.

### C1-s01-contracts-04 - HIGH - test-integrity
**The 2 s / 100k locale-rebuild budget test cannot fail: an over-budget measurement is turned into an expected failure.**

- Spec: 5.7 p9 ("Budget: 2 s for 100k items"), 15.1.
- Locations: Tests/ZTronSearchEngineTests/PerformanceTests.swift:70-86 (check helper), 301-328 (rebuild test, knownGap at 325), 58-62 (XCTSkip in DEBUG); Sources/ZTronSearchFixtures/ReferenceDevice.swift:72 (`localeRebuild = 2.0`).
- Description: `check()` calls `XCTExpectFailure(knownGap)` only `if let knownGap, measured > allowed`, then asserts `measured <= allowed`. Over budget, the failure is expected and the test passes. Within budget, nothing is registered and the test passes. Every measurement passes. The comment "Recorded as an expected failure, strictly: the day it is met, this test says so" is false, because strictness only applies to an expectation that is registered, and none is registered when the budget is met. The knownGap text admits that the reference device misses 2 s. The test is also skipped in DEBUG, so the `swift test` CI unit job never runs it. Call sites 396, 397 and 534 use the same pattern (outside this slice).
- Evidence: code read as quoted; run log c1-debug-swift-test.log shows every PerformanceTests case skipped; no release performance log in Verification/_runs.
- Failure scenario: A regression that makes the locale rebuild ten times slower still passes, and the suite reports the 5.7 budget as checked.

### C1-s01-contracts-05 - MEDIUM - spec-deviation
**Secondary languages are de-duplicated by primary language subtag, so script and regional variants (zh-Hant, sr-Latn, pt-BR) never reach localizedAlt, even when listed explicitly.**

- Spec: 5.3 p9.
- Locations: Sources/ZTronSearchEngine/Text/LanguageTag.swift:68-81; Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:4-13.
- Description: `ResolvedLanguages.init` seeds `seen` with the active tag's language and keeps a secondary tag only if `seen.insert(LanguageTag.language(of: canonical)).inserted`. Simplified and Traditional Chinese, Cyrillic and Latin Serbian, and European and Brazilian Portuguese are distinct localizations, and the spec feeds the other preferred languages into localizedAlt. `.explicit(["zh-Hant"])` under zh-Hans is dropped as well.
- Evidence:
  - I ran scratch `lang`, a verbatim copy of LanguageTag and ResolvedLanguages. It printed secondary `[]` for each of these:
    - zh-Hans-CN with [zh-Hans-CN, zh-Hant-TW]
    - sr-Cyrl-RS with [sr-Cyrl-RS, sr-Latn-RS]
    - pt-PT with [pt-PT, pt-BR]
  - Probe `e3` printed, for preferred [zh-Hans-CN, zh-Hant-TW]: active zh-Hans, secondary [], title 地图, alt ["Map"], query 地圖 -> []. It printed the same for explicit [zh-Hant].
- Failure scenario: A user with both Simplified and Traditional Chinese in preferred languages searches the Traditional title of an item localized in both and gets no hit.

### C1-s01-contracts-06 - MEDIUM - spec-deviation
**setLocale cancels the in-flight search instead of letting it finish on the old index.**

- Spec: 5.7 p9 ("in-flight and new searches keep using the old index until the swap"), 1 p1 (never stale).
- Locations: Sources/ZTronSearchEngine/Service/SearchService.swift:892-903 (setLocale), 311-316 (cancel), 793-803 (locale notification observer, same path); Tests/ZTronSearchEngineTests/InternationalizationTests.swift:285-292 (asserts `received == 0`), 233-283 (tolerates one cancelled query); Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:101-152.
- Description: setLocale runs `guard resolved != languages else { return }; cancel(); await semantic?.setLocale(resolved.active); await rebuild(languages: resolved, scope: .localeChange)`. Every open result stream ends without a final snapshot. testLocaleChangeCancelsTheSearchInFlight asserts the deviation. In the UI, `start` does not clear hits and `streamEnded` sets `isLoading` to false, so the previous query's hits stay on screen for the current text with no loading state.
- Evidence: code as quoted; the test passes in c1-debug-swift-test.log.
- Failure scenario: The user types "lantern" and the system locale changes, or the host calls setLocale, while the search runs. The search is cancelled and the list shows the hits of the previous text, not loading, until the next keystroke.

### C1-s01-contracts-07 - MEDIUM - bug
**Id collisions are never debug-asserted for contexts, and cross-kind collisions between index batches go unchecked above 512 documents.**

- Spec: 4 p6 ("SearchableID ... unique across kinds within one engine; a collision is a debug assertion").
- Locations: Sources/ZTronSearchEngine/Service/SearchService+Context.swift:97, 242 (`lastOccurrences` before projection); Sources/ZTronSearchEngine/Service/SearchService.swift:1002-1004 (duplicate report inside project), 1017-1030 (lastOccurrences), 1033-1045 (`reportKindCollisions` starts `guard documents.count <= 512 else { return }`); Sources/ZTronSearchEngine/Support/Diagnostics.swift:20-31.
- Description: Context preparation and `replace(items:)` de-duplicate items before projection, so the duplicate check never sees the collision: no diagnostic, no assertionFailure, and the earlier item is silently replaced, even across kinds. For `index(_:)`, a later batch of more than 512 documents that reuses an existing id under another kind replaces it silently.
- Evidence: I ran scratch probe `e2`. It printed:
  - Context with Tool "dup" and MapItem "dup": hits `["dup:map"]`, diagnostics `[]`. Still `[]` after `replace(items:)`.
  - `index(_:)` with both items in one batch: `[duplicateID(id: dup)]`.
  - A second batch of 600 with a cross-kind collision: `[]`, and `x0 kind now: map`.
  - A second batch of 1: `[duplicateID(id: x0)]`.

  Existing tests cover only the database-source collision (DatabaseSourceTests.swift:464-476) and one batch (IndexMaintenanceTests.swift:60).
- Failure scenario: A host builds a context from tools and maps whose id spaces overlap. The tool disappears from search, and no debug build ever asserts.

### C1-s01-contracts-08 - LOW - spec-deviation
**The field fallback chain treats a script variant as a language match, unlike Bundle.preferredLocalizations.**

- Spec: 5.2 p8.
- Locations: Sources/ZTronSearchEngine/Text/LanguageTag.swift:32-51.
- Description: `chain` keeps every Apple match whose primary language subtag equals the wanted language, then appends the bare-language entry. Apple does not cross scripts when another localization exists.
- Evidence:
  - I ran scratch `lang` and its probes. Apple's `preferredLocalizations`:
    - (["zh-Hans","en"], "zh-Hant-TW") gives ["en"]
    - (["sr-Latn","en"], "sr-Cyrl-RS") gives ["en"]
  - The engine's chains:
    - zh-Hant-TW over [zh-Hans] gives ["zh-Hans"]
    - sr-Latn-RS over [sr] gives ["sr"]
    - zh-Hant-TW over [zh, zh-Hant] gives ["zh-Hant","zh"]
  - Probe `e3` (zh_TW user, item with zh-Hans plus English base) printed title 地图, language zh-Hans, while Apple picks ["en"].
- Failure scenario: A Traditional Chinese user's index holds the Simplified title as the primary title, while Bundle-based UI shows English. matchedLanguage and highlighting then disagree with what is displayed.

### C1-s01-contracts-09 - LOW - spec-deviation
**Shadowed base surfaces are always indexed into localizedAlt, even with SecondaryLanguages.none.**

- Spec: 5 p8 ("the base surface is only a fallback"), 5.3 p9, 5.6 p9.
- Locations: Sources/ZTronSearchEngine/Projection/SearchProjector.swift:109-113; Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:9.
- Description: The projector always appends base title, text, keywords and caption to localizedAlt when a localization shadows them, whatever the secondary-language policy. The `.none` doc comment says so. Tests codify it: InternationalizationTests.swift:30-39 and 134-153, where a base-title query finds the item through localizedAlt under `.none`.
- Caveat: the section 16 acceptance line "Localized title wins over the base title" can be read as tolerating the base at lower weight.
- Evidence: code read; the tests pass in the run log.
- Failure scenario: An Italian user with `.none` gets an item for the English base word "hammer" (title "Martello"). Fuzzy and prefix expansion run over English base tokens.

### C1-s01-contracts-10 - LOW - spec-deviation
**Typed filters are never rebuilt at query time, and unknown filter records in a loaded or persisted index are never logged.**

- Spec: 4.1 p8.
- Locations: Sources/ZTronSearchEngine/Service/SearchService.swift:994-998; Sources/ZTronSearchEngine/Query/BM25F.swift:82-117 (raw string equality at 105-116); Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:163-172.
- Description: unknownFilter is reported only while projecting. At query time HardConstraints compares raw FilterRecord strings. Records written by another build are never decoded or logged, and a `.string` escape-hatch filter can still match them. Unknown kinds, by contrast, are dropped and logged at query time (SearchPipeline.swift:108-118).
- Evidence: code reading only; no scratch run. CoreCorrectnessTests.swift:229-243 covers the projection-time case only.
- Failure scenario: v2 removes `.platform(.watch)`, and a v1 index file is adopted (see F01). No diagnostic is logged, and a ZTronStringFilter platform=watch query still matches the stale records.

### C1-s01-contracts-11 - LOW - bug
**Canonically equivalent ids (NFC and NFD) are one id to Swift collections and two to the index, and SearchableID `<` is inconsistent with `==`.**

- Spec: 4 p5 (SearchableID Hashable, Comparable).
- Locations: Sources/ZTronSearchEngine/Contracts/Searchable.swift:35-37 (UTF-8 byte comparison); Sources/ZTronSearchEngine/Index/IndexSegment.swift:428-445 (memcmp lookup); Sources/ZTronSearchEngine/Index/LexicalIndex.swift:449-456.
- Description: Equality and hashing use Swift canonical equivalence. Ordering and index lookup use bytes.
- Evidence: I ran scratch probe `e9`. It printed:
  - `==` is true, while `<` is false one way and true the other.
  - After `remove(NFD)` of an NFC-indexed item: count 1, and `'ghost' -> ["café"]`.
  - After `index(NFD)`: count 2, with two hits whose ids are equal.
- Failure scenario: Ids derived from file names (often NFD) cannot be removed with the NFC spelling. The item stays searchable and duplicates appear.

### C1-s01-contracts-12 - LOW - spec-deviation
**Core consults Bundle.main.infoDictionary.**

- Spec: 4 p6 (core does no bundle lookups), 5.12 p9 (the resolver is the only place a bundle is consulted).
- Locations: Sources/ZTronSearchEngine/Chat/ChatService.swift:624.
- Description: ChatDeviceProfile.current reads `Bundle.main.infoDictionary`. It is not a localization lookup, but it is a bundle consultation inside core.
- Evidence: grep.
- Failure scenario: A host without a main-bundle info dictionary (command-line or test host) gets a different device profile. This is a contract deviation with small reach.

## Knocked down (not reported)
- Reranking protocol declared in core although section 2 lists it under Semantic: the section 9 initializer needs it visible to core; Semantic holds the implementation.
- `os` imported by core beyond Foundation, NaturalLanguage and Accelerate: used for unified logging, which 4.1 implies ("logged"); no dependency added; the lint test asserts the allow-list.
- @unchecked Sendable in the SQLite adapter (SQLiteSearchConnection.swift:41): allowed by 9.2 rule 7; none in the products.
- MLX adapter also depends on swift-transformers: confined to the separate adapter package.
- README says "Three packages" next to a four-row table: documentation only, outside the normative text.
- `SearchEngineConfiguration.default` captures Locale.current once: the locale-change observer rebuilds, and iOS relaunches apps on a language change.
- Public `LexicalIndex.load(from:)` does not check the embedding model id: the context path (LexicalIndex.validate) and the vector store do.
- Query language hint off by default: 5.10 says the recognizer "may" hint.
- R69 on-device embedding: `embedMissing` encodes only items without vectors, only when the host calls it at sync time; locale changes swap vector sets without re-embedding (SemanticIndex.swift:208-233, 241-284).

## Not checked
- Reference-device budgets (R4, the 2 s locale rebuild for 100k): no iPhone 6s, PerformanceTests skip in DEBUG, and no release performance log was present in Verification/_runs.
- Spec PDF tables and figures: pdftoppm is not installed; I used the text extraction (spec.txt).
- iOS simulator (15.5 / 18.6) and TSan results: no simulators booted (ground rule); the TSan log was still .partial.
- Behavior of sections 7-14 beyond existence (BM25F scoring, fuzzy, RRF, semantic quality, chat): other slices.
- 5.8 per-locale vector sets: code path and tests read; no vector-set files exercised.
- Adapter packages (SQLite, MLX, AssetKit) and ParityHost: not built or tested.
- TokenizerSession cache memory (up to 50k entries per language per thread): not quantified.
- UI string catalog: entries read from the .xcstrings; not rendered.

STATUS: complete
