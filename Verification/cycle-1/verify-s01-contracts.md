# Cycle 1, slice s01-contracts: skeptic verification

Skeptic checkpoint for the auditor findings in find-s01-contracts.md (spec sections 1-6, pages 1-10).
Scratch directory: /private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s01-contracts-skeptic/
Nothing in the repository was built, tested or modified (only this file was written).

## Verdicts

### C1-s01-contracts-01: partly (severity high, not critical)
- Code read: SearchService+Context.swift:122-141 adopts the mapped file when `LexicalIndex.validate` passes; validate (LexicalIndex.swift:187-207) checks projection version, normalizer version, model id, locale tag, secondary languages, includesAllLanguages and the content fingerprint. `fingerprint(of:)` (181-199) mixes only fnv1a(id), fnv1a(kind), text and title UTF-8 byte counts and updatedAt. Default storage is `.files(Caches/ZTronSearchEngine)` (SearchContext.swift:24-28, 75). The only test (SearchContextTests.swift:311-340) changes the item count. README has no mention of persistence or refresh(); the public refresh() doc says only "Re-reads every source on demand."
- Independent probe p01 (my own swiftc build of unmodified copies of core and fixtures): 600 tools, locale it, `.files(dir)`. v2 changes t0's keywords (alpha to bravo), filter (ios to mac) and adds an Italian title, same lengths. Output: fingerprint v1 == v2 true; 'bravo' -> []; 'martello' -> []; 'alpha' -> [t0]; hammer+platform=mac -> []; hammer+platform=ios -> [t0]; a second v2 launch still serves the stale file; after refresh(): martello and bravo hit, alpha gone. Control: lengthening t0's text makes the file rejected and 'martello' hits.
- Why partly: the defect is real as described, but critical overstates it. The trigger needs the whole-context fingerprint unchanged (same item count, and no item changes id, kind, text or title byte length, or updatedAt), so it is the translations-only or keywords/filters-only update. It is recoverable (refresh(), cache purge, a locale change, any later fingerprinted change), with no crash or data loss. Silent, persistent wrong results in a plausible update pattern: high.

### C1-s01-contracts-02: partly (severity medium, not high)
- Code read: SearchRowProjector.swift:124-136 skips any resolved string equal to the key (`string != value`); 148-150 reports unresolved. The core protocol doc (DatabaseBoundary.swift:236-244) only says the host implements it with `Bundle.localizedString(forKey:value:table:)`; it never says nil means missing. The reference adapter returns nil for missing keys (sentinel value).
- Independent probe p02 (FakeSearchDatabaseConnection + FakeLocalizedStringResolver, order [en, de, it]; en Bluetooth=Bluetooth, Settings=Settings; de Settings=Einstellungen; a dotted control key). Locale en, .none: bt title nil; set title Einstellungen, language de; 'bluetooth' -> []; 'settings' -> []; dotted control works. Diagnostics report Bluetooth as unresolved. Same under .all and under locale it.
- xcstringstool check: a catalog with explicit en values compiles to en.lproj "Settings" => "Settings", so the reference resolver hands core the key-equal value and the core guard drops it. With implicit source values (the String Catalog default), xcstringstool emits no en.lproj entries at all, so the reference resolver returns nil for en before core sees anything; the core guard then still drops other languages' key-equal values (de "Bluetooth").
- Why partly: real, reproduced. But the guard is how core meets 9.2 rule 3 ("the raw key never enters the index") against key-echoing resolvers, which the spec's own suggested `Bundle.localizedString(forKey:value:table:)` pattern produces. That is a trade-off left by an underspecified protocol contract, not a plain slip. The English loss in the catalog case is only partly the core guard. Only hosts whose keys equal a resolved value (source-text keys) are affected; dotted keys are not. For those hosts the impact is serious, hence medium overall.

### C1-s01-contracts-03: partly (severity medium, not high)
- Code read: SearchTokenizer.swift:152-171 skips a bigram whose range equals a word range (the term is the same, so the index still holds the two-character word, but no unigrams). QueryParser.swift:76-77 drops query bigram tokens. 145 computes the per-word fallback only for words of 3+ characters. QueryPlanner.swift:148-157 says the fallback uses bigrams "which the index always carries". SearchPipeline.swift:39-43 tokenizes the query in the active locale (5.10 allows that below 8 characters). InternationalizationTests.swift:170-184 uses ja items and a ja engine only.
- Independent probe p03: '地圖' zh-Hans -> [地, 圖, bigram]; zh-Hant -> [地圖]; '地图' zh-Hant -> [地, 图, bigram]; parse of 地圖 in zh-Hans -> clauses 地 (prefix=false) and 圖 (prefix=true), no fallback. Exact-title misses, the same for indexed and scan strategies: en none; th none; zh_CN 地圖 (zh-Hant), 地図 (ja), 大學 for 北京大學; zh_TW 地图 (zh-Hans), 地図 (ja), 大学 for 北京大学; ja 地图 and 地圖. Same-language queries all hit.
- Why partly: the mechanism and the misses are as described. But it fires only when the query is typed in a different CJK variety than the active locale's segmenter: Simplified in a zh_TW engine, Traditional or Chinese-only forms in a ja engine, and so on. Same-language queries work, and users rarely type the other variety. It does defeat 5.3 for CJK bilinguals on two-character words, the commonest Chinese word length. Medium, consistent with C1-s01-contracts-05.

### C1-s01-contracts-04: partly (severity medium, not high; scope slightly wider)
- Code read: PerformanceTests.swift:77-85 registers `XCTExpectFailure(knownGap)` only when `measured > allowed`, then asserts `measured <= allowed`. testFullLexicalRebuildOnLocaleChange (301-328) passes a knownGap that admits the 2 s target is missed. The class skips itself in DEBUG (58-62). The class is not @MainActor, so the test body runs off the main thread.
- Independent probe p04 (a scratch SwiftPM package with a verbatim copy of check(), async tests that hop actors first): 10x over budget with knownGap passes (expected failure); within budget passes; control without knownGap fails. In the over-budget case the later `XCTAssertLessThan(worstQuery, 0.25, "a query never waits for the rebuild")` failure is also absorbed as expected, because the non-scoped XCTExpectFailure covers the rest of the test.
- Corrections: .github/workflows/ci.yml has a "Section 15 targets (release build)" job that runs `swift test -c release -Xswiftc -enable-testing --filter PerformanceTests`, so CI does execute the test. It just cannot fail on the budget. The finding's "the swift test CI unit job never runs it" is true but incomplete. Scope is wider than stated: over budget, the 15.1 "never blocking a query" check (line 327) is neutralized too. The "strictly" comment is false as claimed.
- Why medium: a test-integrity defect that hides a self-documented gap and any regression from the CI gate (and the 17 milestone-1 gate), not a product behavior defect.

### C1-s01-contracts-05: partly (severity medium; failure scenario needs restating)
- Code read: LanguageTag.swift:68-81 seeds `seen` with the active primary subtag and keeps a secondary tag only if its primary subtag is new; `.explicit` and `.all` go through the same init (83-96). The projector's own `consumed` set (SearchProjector.swift:116-123) already removes duplicate tags, so the language-level de-duplication buys nothing and drops script and regional variants. Spec 5.3 asks for "the other entries in Locale.preferredLanguages".
- Independent probe p05 (indexed context, item with base en plus two variant localizations):
  - pt_PT with preferred [pt-PT, pt-BR]: secondary []; alt ["Bus stop"]; 'onibus' -> []. Same with `.explicit(["pt-BR"])`. With `.all`, alt gains "Ponto de ônibus" and 'onibus' hits.
  - sr_Cyrl_RS with [sr-Cyrl-RS, sr-Latn-RS]: secondary []; 'grada' (Latin title) -> []. It hits under `.all`.
  - zh_CN with [zh-Hans-CN, zh-Hant-TW]: secondary []; alt lacks 圖書館. Under `.all` alt has 圖書館, but '圖書館' still -> [].
  - en-US with en-GB: harmless; the active chain already picks en-GB.
- Why partly: the claim that script and regional variants never reach localizedAlt is right. The stated failure scenario (zh-Hans user searching a Traditional title) is not fixed by this finding alone: with the Traditional surface in localizedAlt, the query is still segmented in zh-Hans and misses (C1-s01-contracts-03). Corrected scenario: a pt-PT user with pt-BR, or a sr-Cyrl user with sr-Latn, as a second preferred language cannot find an item by the other variant's title. For zh-Hans/zh-Hant both this and C1-s01-contracts-03 must be fixed. Medium stands.

### C1-s01-contracts-06: partly (severity low, not medium)
- Code read: setLocale (SearchService.swift:892-903) calls cancel() (311-316: bumps the generation, cancels activeTask, drops `retained`) before the rebuild, and the locale observer (793-803) goes through setLocale. The stream's task then finishes the continuation (286-292), so the open interactive stream ends without a final snapshot. The detached chat lane (`retrieve`) is not cancelled. InternationalizationTests.swift:285-292 asserts `received == 0` "by design", and 233-283 tolerates one cancelled query. In ZTronSearchResultsModel.swift:101-152, start() keeps the old hits, and streamEnded() sets isLoading = false, so the list keeps whatever it last showed.
- Spec: 5.7 says "in-flight and new searches keep using the old index until the swap"; 16 says "while queries keep working on the old index". Cancelling the in-flight search contradicts the first half. Nothing requires the cancel: a stale cursor is already handled by the generation check in page(after:).
- Why partly: the deviation is real and deliberate. The UI outcome is as described only if no snapshot of the current query had arrived; otherwise the current query's lexical hits stay, without the semantic phase. It needs a locale change (system notification, for example on returning to the foreground after a region change, or a host setLocale) inside the short window while a search is in flight. The next keystroke recovers, and no wrong result is published. Low.

### C1-s01-contracts-07: confirmed (severity medium)
- Code read: SearchService+Context.swift:97 (prepare) and 242 (replaceMemory) run `lastOccurrences` before `project`, so the duplicate report in `project` (SearchService.swift:1002-1004) never fires for a context's memory items. The comment at SearchService+Context.swift:395-396 ("Within the memory items the projection has already seen to it") is therefore wrong. Only memory-against-database clashes are reported (397-403). `reportKindCollisions` (SearchService.swift:1033-1045) returns at once above 512 documents. `.duplicateID` is a programmer error that calls assertionFailure (Diagnostics.swift:20-31; SearchEngineConfiguration.swift:96-101).
- Independent probe p07, with assertsOnProgrammerError left at its default (true): a context (scan and indexed) holding Tool "dup" and MapItem "dup" gives 'hammer' -> [], 'harbor' -> [dup:map], no diagnostic and no trap, also after replace(items:). A second index(_:) batch of 600 with a cross-kind clash gives no diagnostic, and x0's kind becomes map. One batch holding both traps with "SearchableID dup is not unique inside its context."
- Spec 4 p6 makes any collision a debug assertion, and 9.1 rule 1 scopes uniqueness to the context. The description and scope are accurate. Medium: it only bites on a host error, but that error (overlapping numeric id spaces across item arrays) is realistic, and the engine silently drops items where the spec requires a debug trap.

### C1-s01-contracts-08: confirmed (severity low)
- Code read: LanguageTag.swift:32-51. The chain calls Apple's matcher with the localization keys only (never the base language), then keeps any answer whose primary subtag matches, then appends the bare-language entry. Its own comment admits Apple "answers with an arbitrary available localization when nothing matches".
- Independent probe p08: Apple gives [en] for zh-Hant-TW over [zh-Hans, en], zh-HK over [zh-Hans, en], sr-Cyrl-RS over [sr-Latn, en] and sr-Latn-RS over [sr, en]. The engine's chains over the keys give [zh-Hans], [zh-Hans], [sr-Latn] and [sr]. zh-Hant-TW over [zh, zh-Hant] gives Apple [zh-Hant] and the engine [zh-Hant, zh]. pt-PT over [pt-BR] agrees (Apple crosses regions too). End to end, a zh_TW projection of an item with base en and zh-Hans gives title 地图, language zh-Hans, alt [Map].
- 5.2 says fallbacks "follow Apple's rules", and Apple does not cross scripts when the base exists. Accurate as described. Low: recall is intact (the English base stays in localizedAlt, and Simplified queries hit the title). The visible effect is the matchedLanguage and highlight mismatch against a Bundle-localized display.

### C1-s01-contracts-09: partly (severity low; interpretive)
- Code read: SearchProjector.swift:109-113 appends shadowed base title, text, keywords and caption to localizedAlt whatever the policy. The `.none` doc comment (SearchEngineConfiguration.swift:9) states it on purpose. InternationalizationTests.swift:29-39 and 134-153 (TestSupport defaults to `.none`) find the 'base' item through localizedAlt (en) under an Italian engine. DatabaseSourceTests.swift:288-290 codify the same for rows.
- Spec reading: the 5 intro says "the base surface is only a fallback", and section 6 defines localizedAlt as "secondary-language surfaces". Both support the finding when the base language is not a secondary language, and always under `.none`. 5.6 does not: "never over the base surface alone" holds as long as localized tokens are matched too, which they are. 16 ("Localized title wins over the base title") is satisfied by the implementation's ranking (title beats localizedAlt).
- Why partly: the behavior is real and deliberate. Whether it deviates depends on reading "only a fallback" strictly; the cited 5.6 does not carry it. The failure scenario is extra low-weight recall (and fuzzy or prefix noise from base tokens), not a wrong primary result. Low; a spec-owner decision.

### C1-s01-contracts-10: partly (severity low; failure scenario uses the wrong filter type)
- Code read: unknownFilter is reported only in SearchService.project (994-998) and SearchRowProjector (163-172). HardConstraints.allows (BM25F.swift:105-116) compares raw FilterRecord strings. No load path (LexicalIndex.load/adopt, context adoption) decodes records, so unknown records in a loaded or persisted index are never logged. Unknown kinds, by contrast, are dropped and logged at query time (SearchPipeline.swift:106-117). The test (CoreCorrectnessTests.swift:229-243) covers projection time only.
- For typed queries the raw equality already behaves like ignoring an unknown record: a typed case cannot express the value, and AND/OR semantics are unchanged. Only an escape-hatch query with the same key and value reaches it.
- Correction: the stated scenario ("a ZTronStringFilter platform=watch query") cannot arise. ZTronStringFilter.init?(key:value:) always succeeds (SearchSchema.swift:68-70), so no record is unknown under ZTronStringSchema. The real case is a typed schema with an escape hatch, for example `CatalogFilter.string(key: "platform", value: "watch")`, against a stale index (reachable via C1-s01-contracts-01). The logging gap stands as a 4.1 deviation. Low.

### C1-s01-contracts-11: confirmed (severity low; plus a strategy divergence)
- Code read: SearchableID is synthesized Hashable over a String, so equality and hashing use canonical equivalence; `<` compares UTF-8 bytes (Searchable.swift:35-37). Index lookup hashes UTF-8 bytes and memcmp-compares them (IndexSegment.swift:428-445), and LexicalIndex.locate uses it (449-456).
- Independent probe p11 (NFC "café" vs NFD "cafe+U+0301"): == true, equal hashes, a<b false, b<a true, so Comparable is inconsistent with ==. Indexed context: after remove(NFD) of the NFC item, count 1 and 'ghost' still hits; after index(NFD), count 2 with two hits. Scan context: remove(NFD) removes it (count 0), and index(NFD) replaces it (count 1).
- Accurate as described. The extra point is that the scan and indexed strategies disagree on such ids, against the 9.1 rule 3 parity promise. Low: it needs ids that differ only in Unicode normalization.

### C1-s01-contracts-12: confirmed (severity low)
- Code read: ChatService.swift:620-633, `ChatDeviceProfile.current` reads `Bundle.main.infoDictionary` for CFBundleShortVersionString and CFBundleVersion to build `buildFingerprint`. It is only the default: ChatService.swift:252 uses `configuration.device ?? ChatDeviceProfile.current`, and ChatTests inject `device.buildFingerprint`. The other Bundle use in core is the static matcher `Bundle.preferredLocalizations`, which 5.2 mandates.
- Spec: 4 p6 ("core stays bundle-free") and 5.12 ("The resolver is the only place a bundle is consulted") are literally contradicted. The stated purposes (localization, deterministic tests) are not harmed, and 14.4 (spec line 1787, recompute the verdict "after an app or OS update") needs an app version from somewhere. The failure scenario is benign: a host without an Info.plist gets a stable "0(0)" app part. Accurate; low.

## Summary

| ID | Verdict | Severity (auditor -> skeptic) |
|---|---|---|
| C1-s01-contracts-01 | partly | critical -> high |
| C1-s01-contracts-02 | partly | high -> medium |
| C1-s01-contracts-03 | partly | high -> medium |
| C1-s01-contracts-04 | partly | high -> medium |
| C1-s01-contracts-05 | partly | medium -> medium (scenario restated) |
| C1-s01-contracts-06 | partly | medium -> low |
| C1-s01-contracts-07 | confirmed | medium -> medium |
| C1-s01-contracts-08 | confirmed | low -> low |
| C1-s01-contracts-09 | partly | low -> low (interpretive) |
| C1-s01-contracts-10 | partly | low -> low (scenario corrected) |
| C1-s01-contracts-11 | confirmed | low -> low |
| C1-s01-contracts-12 | confirmed | low -> low |

No finding was refuted. Every behavioral claim reproduced with my own probes on a fresh swiftc build of unmodified copies of Sources/ZTronSearchEngine and Sources/ZTronSearchFixtures (p01, p02, p03, p05, p07, p08, p11). The XCTExpectFailure semantics were checked in a scratch SwiftPM package (p04), and String Catalog compilation with xcstringstool (p02/xc, p02/xc2).

STATUS: complete
