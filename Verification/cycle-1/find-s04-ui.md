# Cycle 1 — slice s04-ui (spec sections 12 and 13, pages 25-36)

Auditor: s04-ui. Method: requirement-centric trace (spec -> code -> test), then defect hunt, then
knock-down of own findings. Repository not modified (this file only). No swift build / swift test /
xcodebuild run, no simulator booted. Test pass status taken from Verification/_runs/c1-debug-swift-test.log.
Committed parity results (ParityHost/Results) were read, not re-run. Scratch programs live in
/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s04-ui/
(submitlabel/, plain/, pagesize/, attachlint/, texttotoken/).

Tally: 66 requirements — 45 met, 17 partial, 0 missing, 3 contradicted, 1 unverifiable-here.

Paths below: UI = Sources/ZTronSearchEngineUI, T = Tests/ZTronSearchEngineUITests, PH = ParityHost.

## Requirement table

| R# | Sect/page | Requirement | Status | Code | Test |
|---|---|---|---|---|---|
| R1 | 12 p25 | Pure SwiftUI 1:1 clone of UISearchTextField/UISearchToken (appearance, behavior, a11y); every UIKit delegate callback/control event mapped to a modifier | partial | UI/ZTronSearchField.swift, UI/ZTronSearchFieldEnvironment.swift:86-146 | Map: T/SearchFieldCoreTests (core only). Parity: PH/Results summary shows 602 failing cells (see 01, 02, 07, 09) |
| R2 | 12 p25, 2 p3 | UI product never imports UIKit; no UIViewRepresentable / UIKit class, color, font; lint fails on import UIKit | met | Sources/ZTronSearchFixtures/SourceLint.swift:120-129 | T/LintTests.swift:19 testTheUIProductNeverUsesUIKit, :26 testTheUIKitLintCatchesWhatItShould |
| R3 | 12 p25 | Built from TextField, Capsule, FocusState, asset catalog; iOS 15 APIs only | partial | TextField/FocusState/catalog yes; token shape is RoundedRectangle (UI/ZTronSearchField.swift:493-512), see 12 | none (iOS 15 compile only in ci.yml, not run here) |
| R4 | 12.1 p26 | init(text:tokens:prompt: Text? = nil, tokenSelection: Binding<Set<UUID>>? = nil); nil prompt = "Search"; nil selection = field-owned | met | UI/ZTronSearchField.swift:57-67, 324-326 | none asserts the default prompt |
| R5 | 12.1 p26 | Appearance modifiers and defaults (.native, nil tokenBackground, .whileEditing, keyboard enum, .automatic cancel, deletion .enabled, copying .disabled) | met | UI/ZTronSearchFieldEnvironment.swift:6-27, 42-82 | none asserts the defaults |
| R6 | 12.1 p26-27 | Event modifiers: onEditingChanged, editingPolicy, textInputPolicy, onSelectionChanged, onClear, onSearchCancel, textToToken, onTokenDelete, tokenCopyProvider, onSearchFieldEvent | met | UI/ZTronSearchFieldEnvironment.swift:86-146 | core behavior in T/SearchFieldCoreTests:314, 390, 410, 455, 475; modifier wiring only via parity host |
| R7 | 12.1 p27 | .focused($x) works directly, host FocusState round-trips | partial | UI/ZTronSearchField.swift:341, 691-736 | parity focus-round-trip passes on 17.5/18.6 iPhone 15 L LTR; not run on 15/16; plausible failure with editingPolicy (10) |
| R8 | 12.1 p27 | .onSubmit fires on search key; .submitLabel(.search) default, host may override | contradicted | UI/ZTronSearchField.swift:342 (override impossible, 03); onSubmit L346 | parity submit cells pass at default size; no test of override |
| R9 | 12.1 p27 | Autocorrection, spell checking, smart quotes, smart dashes off; autocapitalization never | partial | UI/ZTronSearchField.swift:343, 811-844; smart punctuation emulated by rewriting UI/ZTronSearchFieldCore.swift:89-105 (over-reaches, 04) | T/SearchFieldCoreTests.swift:105 testSmartQuotesAndDashesAreUndone (asserts the rewrite) |
| R10 | 12.1 p27 | Text binding = textual portion, updated every change; field never debounces or talks to a model | met | UI/ZTronSearchField.swift:389-399, 456-471; UI/ZTronSearchFieldCore.swift:225-292 | T/SearchFieldCoreTests.swift:71, 158 |
| R11 | 12.1 p27 | Dynamic Type, RTL, VoiceOver labels, Cancel verified vs UIKit on the matrix | contradicted | — | PH/Results: 0 RTL cells pass, Arabic labels English (09); XS/XXXL/AX5 and bold-text cells fail (01, 07) |
| R12 | 12.2 p27 | ZTronSearchToken<Schema>: Identifiable, Hashable, Sendable; Kind filter/kind/phrase; id, kind, text, systemImage | met | UI/ZTronSearchToken.swift:9-15 | T/SearchFieldCoreTests.swift:606 |
| R13 | 12.2 r1 p28 | Order glyph, tokens, text, clear; binding never contains a token | met | UI/ZTronSearchField.swift:231-265 | T/SearchFieldCoreTests.swift:314; parity default-size cells pass |
| R14 | 12.2 r2 | Tap selects token, tap elsewhere deselects, selected token deleted by backspace if enabled and not vetoed | met | UI/ZTronSearchFieldCore.swift:322-345, 365-397 | T/SearchFieldCoreTests.swift:192, 217 |
| R15 | 12.2 r3 | Backspace at start selects last token, second deletes; U+200B sentinel; iOS 17+ onKeyPress(.delete); sentinel never leaks | met | UI/ZTronSearchFieldCore.swift:298-310; UI/ZTronSearchField.swift:476-480, 848-854 | T/SearchFieldCoreTests.swift:113, 158, 289 |
| R16 | 12.2 r4 | textToToken on every change and on submit; replaces textual portion with UIKit insertion animation | met | UI/ZTronSearchFieldCore.swift:350-360; UI/ZTronSearchField.swift:605-644 | T/SearchFieldCoreTests.swift:314, 352; animation comparator passes wherever the final frame matches |
| R17 | 12.2 r5 | Clear follows clearButtonMode; token effect recorded per iOS version from the reference, never assumed | partial | UI/ZTronSearchFieldCore.swift:407-440; behavior only sampled for 17/18, nearest-version fallback (02) | T/SearchFieldCoreTests.swift:410 |
| R18 | 12.2 r6 | Cancel (.automatic) while editing; clears text and tokens, drops focus, calls onSearchCancel | met | UI/ZTronSearchFieldCore.swift:444-462; UI/ZTronSearchField.swift:111-113, 196-218 | T/SearchFieldCoreTests.swift:455 |
| R19 | 12.2 r7 | Tokens are a11y elements; label/value/traits/custom actions copied from UIKit per iOS version | partial | UI/ZTronSearchField.swift:528-545 (label, selected trait); only 17/18 sampled (02) | parity a11y comparator: 144/248 pass on 17.5 iPhone 15 |
| R20 | 12.2 r8 | RTL mirrors; glyph and clear swap sides | met | HStack under layoutDirection | RTL cells: glyph and clear frames within 0.5 pt (only token height/y and labels differ, 09) |
| R21 | 12.2 r9 | Field/token heights track .body under Dynamic Type; long tokens tail-truncate at UIKit width | partial | UI/ZTronSearchFieldMetrics.swift:237-240 (sampled per size, 17/18 only); fixed .system(size:) fonts L285, 316, 337, 502, 522 | XS (1.56% px, dE 28) / XXXL (dE 7.5) / AX5 cells fail; bold text not modelled (07) |
| R22 | 12.2 r10 | Pure SearchQuery(text:tokens:) mapping, unit-tested without UI | met | UI/ZTronSearchToken.swift (queryToken, init); Sources/ZTronSearchEngine/Contracts/SearchQuery.swift:39-61, 81-86 | T/SearchFieldCoreTests.swift:606; T/ResultsModelTests.swift:55 |
| R23 | 12.2 r11 | Tokens never take part in fuzzy expansion or prefix matching | unverifiable | core matcher (other slice) not traced | — |
| R24 | 12.2 r12, 12.5 | Only the listed deviations tolerated | met | PH/Sources/ZTronSearchEngineUIParity/ParitySession.swift:241-286 (caret, range-selection display), EventLogComparator | harness only |
| R25 | 12.2 p29-30 | Minimal host example | partial | API names/shapes exist; the example's textToToken closure does not type-check (14) | scratch probe texttotoken/ |
| R26 | 12.3 p30 | One SwiftUI counterpart per UIKit callback; parity log same order and payloads | partial | map complete; payloads wrong after typographic rewrite (04) | event-log comparator 246/248 on 17.5 iPhone 15 |
| R27 | 12.3 p30 | editingPolicy evaluated before inner input enabled; denial shows no flicker | partial | tap path UI/ZTronSearchField.swift:484-490, 691-699; programmatic focus path not gated (10) | T/SearchFieldCoreTests.swift:475 (core only); no parity script uses editingPolicy |
| R28 | 12.3 | textInputPolicy reverts a denied change | met | UI/ZTronSearchFieldCore.swift:225-292 | T/SearchFieldCoreTests.swift:390 |
| R29 | 12.3 | onSelectionChanged: tokens all iOS, text selection iOS 18+ | met | UI/ZTronSearchField.swift (TextSelection iOS 18 gate) | T/SearchFieldCoreTests.swift:516 |
| R30 | 12.3 | onClear false keeps text | met | UI/ZTronSearchFieldCore.swift:407-440 | T/SearchFieldCoreTests.swift:410 |
| R31 | 12.3 | tokens binding carries user insert/delete/select | met | UI/ZTronSearchField.swift:647-653 | T/SearchFieldCoreTests.swift:370 |
| R32 | 12.3 | tokenCopying/tokenCopyProvider no-op without pasteboard API | met | UI/ZTronSearchFieldEnvironment.swift:134 (stored, unused) | — |
| R33 | 12.3, 2 | Package enums wrap keyboardType and textContentType | met | UI/ZTronSearchFieldTypes.swift; UI/ZTronSearchField.swift:811-844 | lint (R2) |
| R34 | 12.4 p31 | Defaults sampled from UIKit; re-sampled each iOS release, build fails on drift | partial | samples only 17.5/18.6 (02); generate_ui_assets.py --check compares committed samples to generated code, not a re-sample | Verification/_runs c2-ui-assets-check.log EXIT 0; parity.yml re-sample not run here |
| R35 | 12.4 | Asset catalog colors with light/dark/increased-contrast variants | met | UI/Resources/Colors.xcassets (7 colors x 4 variants) | — |
| R36 | 12.4 | Field height 36 pt default, grows with Dynamic Type | met | UI/ZTronSearchFieldMetrics+Sampled.swift:21-34, 37-388 | parity default-size metrics pass |
| R37 | 12.4 | Corner radius 10 pt | met | same | same |
| R38 | 12.4 | Background searchFieldFill | met | UI/ZTronSearchField.swift:152-159 | same |
| R39 | 12.4 | Glyph magnifyingglass, secondary label, leading | met | UI/ZTronSearchField.swift:125-127, 161-171 | same |
| R40 | 12.4 | Text .body primary; placeholder in placeholderText | partial | placeholder UI/ZTronSearchField.swift:314-317 ok; text font .system(size:) L337, not .body, no Bold Text (07) | bold-text cells fail |
| R41 | 12.4 | Clear xmark.circle.fill in clearGlyph, trailing, per mode | met | UI/ZTronSearchField.swift:115-123, 173-191 | T/SearchFieldCoreTests.swift:410 |
| R42 | 12.4 | Token capsule, symbol + text, tokenFill / tokenBackground; selected colors | partial | colors ok; RoundedRectangle radius 4 (12) | — |
| R43 | 12.4 | Insets/spacing sampled per iOS version in ZTronSearchFieldMetrics, single source | partial | single source ok; only 17/18 (02) | — |
| R44 | 12.5 p31 | Parity host renders clone and UIKit reference side by side; pixels, metrics, event logs, a11y on every cell; UIKit only there | met | PH/ (Package.swift UIKit only there), Comparators, ParitySession | — |
| R45 | 12.5 p31-32 | Matrix 5 iOS x 4 devices x 5 appearances x 4 sizes x 2 directions x 2 inputs x 10 scripts | partial | matrix defined (800 cells per iOS/device) but 7,440 of 16,000 results exist; 15.5/16.4 not runnable | PH/Results/summary.md:7-29 |
| R46 | 12.5 / 15.7 p32 | Every cell within 15.7 thresholds; anything else fails the build (milestone 4) | contradicted | PH/Tools/gate.py | summary.csv: 179 pass, 602 fail, 6,659 not runnable (01) |
| R47 | 13 p32 | Narrow models, no single screen object, no list/row/chat view ships | met | UI/ (models + modifiers + field only) | — |
| R48 | 13 p33 | ZTronSearchResultsModel API | met | UI/ZTronSearchResultsModel.swift | T/ResultsModelTests.swift |
| R49 | 13 p33 | ZTronSuggestionsModel API (minimumQueryLength 2, pageSize 10) | met | UI/ZTronSearchResultsModel.swift:216-289 (extra defaulted debounce) | T/ResultsModelTests.swift:293 |
| R50 | 13 p34 | update returns early when the query is equal | met | UI/ZTronSearchResultsModel.swift:65-70 | T/ResultsModelTests.swift:32 |
| R51 | 13 p34 | Snapshot applied only for current generation and equal query | met | UI/ZTronSearchResultsModel.swift:130-142 | T/ResultsModelTests.swift:119, 153 |
| R52 | 13 p34 | isLoading true until the final snapshot or a cancellation | partial | false without a final snapshot of the current query after a pageSize change (05) | T/ResultsModelTests.swift:78 |
| R53 | 13 p34 | Every hit has a kind; hitsByKind one section per class, fused order | met | UI/ZTronSearchResultsModel.swift:22-24 | T/ResultsModelTests.swift:66 |
| R54 | 13 p34 | Scan: no debounce, single final snapshot same turn, init(scan:) no actor hop, several models | met | UI/ZTronSearchResultsModel.swift:52, 101-126; Scan/ScanIndex.swift:61-92 | T/ResultsModelTests.swift:227, 251 |
| R55 | 13 p34 | zTronLoadsNextPage(of:) calls loadNextPage from onAppear | met | UI/ZTronAttachmentModifiers.swift:92-94 | T/AttachmentModifierTests.swift:175 |
| R56 | 13 p34 | Paging in own cancellable task guarded by generation+cursor, no duplicate pages | met | UI/ZTronSearchResultsModel.swift:158-205 | T/ResultsModelTests.swift:170, 193 |
| R57 | 13 p34 | Query change cancels page in flight, clears cursor | met | UI/ZTronSearchResultsModel.swift:207-213 | T/ResultsModelTests.swift:209 |
| R58 | 13 p34 | Suggestions disabled below minimumQueryLength; at most pageSize per page | met | UI/ZTronSearchResultsModel.swift:216-289 | T/ResultsModelTests.swift:293; T/AttachmentModifierTests.swift:223 |
| R59 | 13 p34 | isZTronSearching key, default false, public | met | UI/ZTronAttachmentModifiers.swift:12-23 | T/AttachmentModifierTests.swift:106 |
| R60 | 13 p34 | Screen injects .environment(\.isZTronSearching, results.isLoading) | met | UI/ZTronAttachmentModifiers.swift:25-38 | T/AttachmentModifierTests.swift:72 |
| R61 | 13.1 p35 | zTronSearch, zTronResults, zTronLoadsNextPage, zTronSuggestions, zTronChat(prepare:) | met | UI/ZTronAttachmentModifiers.swift:40-109 | T/AttachmentModifierTests.swift:72-360 |
| R62 | 13.1 r1 | A modifier never creates state | met | same | T/LintTests.swift:106; T/AttachmentModifierTests.swift:127 |
| R63 | 13.1 r2 | Modifiers thin, under 30 lines | met | same | T/LintTests.swift:92 |
| R64 | 13.1 r3 / 16 p49 | Lint test catches a screen reading a model without attaching it | partial | Sources/ZTronSearchFixtures/SourceLint.swift:211-240 (repository-global, any .environmentObject counts) | T/LintTests.swift:114 (positive), :154 vacuous (06) |
| R65 | 13.1 r4 | Field modifiers unprefixed and no-ops elsewhere; package-state modifiers zTron-prefixed | met | environment-based field configuration | — |
| R66 | 13.1 r5 | Early or repeated zTronLoadsNextPage harmless | met | UI/ZTronSearchResultsModel.swift:158-183 | T/AttachmentModifierTests.swift:175; T/ResultsModelTests.swift:193 |

## Findings

### C1-s04-ui-01 — Parity gate of 12.5/15.7 not met; most of the matrix never ran
- Severity: high. Category: spec-missing. Verdict: CONFIRMED (committed results).
- Spec: 12.5 p31-32 (matrix, every cell within thresholds, milestone 4 gate), 15.7.
- Locations: ParityHost/Results/summary.md:7-29; ParityHost/Results/summary.csv; ParityHost/Tools/gate.py; README.md:216-218.
- Description: the matrix needs 5 iOS x 4 devices x 800 = 16,000 cells. The committed run has 7,440 results: 179 pass, 602 fail, 6,659 not runnable. iOS 15.5 and 16.4 (3,200 each) never ran ("The iOS 15.5 simulator runtime is not supported on hosts after macOS 26.99.99", "no iOS 16.4 simulator runtime is installed"). 17.5/18.6 ran 440 results each, 27.0 ran 160. No RTL cell passes, no bold-text cell passes (0 of 62 run), no iPhone SE, iPad or iOS 27 cell passes.
- Evidence: awk over summary.csv column 8: 602 fail / 6659 not-runnable / 179 pass. Causes visible in results: Arabic cells token.0.height 26.3 vs 24.3 pt and token.0.y 5 vs 6 (ios-18.6/iPhone-15/light/L/rtl/hardware/type.json); AX5 token content (symbol and text) drawn about 24 px (8 pt) further from the token's leading edge in the clone with equal token frames (ios-18.6/iPhone-15/light/AX5/ltr/software/type/initial-reference.png vs initial-clone.png, 6.81% pixels, dE 28.5); XS type 1.56% / dE 27.96; XXXL dE 7.5; bold text (07).
- Failure scenario: gate.py fails the build on every non-pass cell, so milestone 4 cannot close; on any configuration outside 17.5/18.6 3x iPhone LTR default size the field visibly differs from UISearchTextField.

### C1-s04-ui-02 — Metrics and behavior exist only for iOS 17 and 18; iOS 15/16 floor and iOS 26+ silently reuse the nearest
- Severity: high. Category: spec-deviation. Verdict: CONFIRMED (code).
- Spec: 12.2 rule 5 (token effect of clear "recorded per iOS version from the reference, never assumed"), 12.4 (defaults sampled from UIKit, re-sampled each release; metrics per iOS version).
- Locations: UI/ZTronSearchFieldMetrics+Sampled.swift:8 (`sampledVersions: [Int] = [17, 18]`), :394-400; UI/ZTronSearchFieldMetrics.swift:218-240 (nearestSampledVersion, metrics(forMajorVersion:contentSize:)), :271-273 (behavior(forMajorVersion:)); ParityHost/Samples (ios-17.json, ios-18.json only).
- Description: runningMajorVersion feeds metrics and behavior lookups that fall back to the nearest sampled version. On iOS 15 and 16 (the package floor) every metric and every recorded behavior, including clearRemovesTokens, is iOS 17's; on iOS 26/27 it is iOS 18's.
- Evidence: code above; summary.csv has no iOS 15/16 sample or run and 0 passing iOS 27 cells (110 ran, all fail).
- Failure scenario: an iOS 15.8 device renders the field with iOS 17 insets/radii and applies iOS 17's clear-button token behavior, which was never observed on iOS 15; an iOS 26/27 device gets the iOS 18 layout although the system field changed.

### C1-s04-ui-03 — Host cannot override the return-key label
- Severity: medium. Category: spec-deviation. Verdict: CONFIRMED (probe).
- Spec: 12.1 p27 ("`.submitLabel(.search)` is the default; the host may override it").
- Locations: UI/ZTronSearchField.swift:342.
- Description: the field applies `.submitLabel(.search)` directly on the inner TextField. SubmitLabel travels in the environment and the innermost value wins, so a host `.submitLabel(.go)` on ZTronSearchField never reaches the TextField.
- Evidence: scratch probe submitlabel/main.swift (SwiftUI, environment dump): insideField -> SubmitLabelKey search listed before go (inner wins); hostOnly -> go; none -> no entries.
- Failure scenario: `ZTronSearchField(...).submitLabel(.go)` still shows "search" on the return key.
- Repro: scratchpad/cycle-1/s04-ui/submitlabel/main.swift.

### C1-s04-ui-04 — Smart-punctuation emulation rewrites the whole text on every keystroke
- Severity: medium. Category: bug. Verdict: CONFIRMED (replica).
- Spec: 12.1 p27 (smart quotes/dashes off = keyboard does not substitute), 12.3 p30 (parity log same payloads as UIKit), 12.1 binding = textual portion.
- Locations: UI/ZTronSearchFieldCore.swift:89-105 (plain), :228 (`var proposed = Self.plain(Self.strip(raw))`), :241 (`ZTronTextChange.between(text, proposed)`).
- Description: plain() maps U+2018/2019 to ', U+201C/201D to ", U+2014 to "--", U+2013 to "-" anywhere in the text, on every input change. Text that already contains typographic characters (set by the host, pasted, typed by long-press) is rewritten as a side effect of the next keystroke, and the logged change becomes a multi-character replacement.
- Evidence: replica plain/main.swift printed: text "l’arme" + typed "s" -> binding "l'armes", logged shouldChange(location: 1, length: 5, replacement: "'armes") where UIKit logs (6, 0, "s"); "A" + pasted "—" -> "A--"; "" + "„Zeit“" -> "„Zeit\"" (mixed quotes). T/SearchFieldCoreTests.swift:105 asserts the rewrite on typed input and does not cover pre-existing text.
- Failure scenario: host restores a recent search "Assassin’s Creed"; the user types a space; the field shows "Assassin's Creed " and textInputPolicy/onSearchFieldEvent receive a 14-character replacement instead of an insertion.
- Repro: scratchpad/cycle-1/s04-ui/plain/main.swift.

### C1-s04-ui-05 — Changing pageSize during a search leaves the previous query's hits on screen; reset() drops pageSize
- Severity: medium. Category: bug. Verdict: CONFIRMED (replica).
- Spec: 13 p34 (snapshot applied only for the current query; isLoading until final snapshot or cancellation; update returns early when the query is equal).
- Locations: UI/ZTronSearchResultsModel.swift:78-81 (pageSize setter mutates query.limit only), :65-70 (update copies limit, early return), :130-131 (apply guard), :149-152 (streamEnded), :89 (reset builds a new query without limit).
- Description: the setter changes `query.limit` without bumping the revision or restarting the search. Snapshots of the in-flight stream carry the old limit, fail `snapshot.query == query` and are dropped; the stream end clears isLoading. update() with the same text then returns early because the query is equal. reset() replaces the query with `SearchQuery(text: "")`, silently restoring the default page size.
- Evidence: replica pagesize/main.swift printed: step 2 snapshot for Query(text: "harbor", limit: 20) dropped, hits=["hits for lantern/20"], isLoading=false, query harbor/50; step 3 update("harbor") returned early; step 4 after reset pageSize=20.
- Failure scenario: results for "lantern" are shown; the user types "harbor"; the host sets pageSize = 50 (for example on a size-class change) before the snapshot arrives; the list keeps showing "lantern" hits with no spinner and no error until the text changes.
- Repro: scratchpad/cycle-1/s04-ui/pagesize/main.swift.

### C1-s04-ui-06 — Attach lint is repository-global and its in-repo run is vacuous
- Severity: medium. Category: test-integrity. Verdict: CONFIRMED (replica).
- Spec: 13.1 rule 3 p36; 16 p49 ("a screen that reads a model through @EnvironmentObject without an attaching modifier fails the lint test").
- Locations: Sources/ZTronSearchFixtures/SourceLint.swift:211-240 (L224-226 `attached = sources.contains { ... || source.code.contains(".environmentObject(") }`); Tests/ZTronSearchEngineUITests/LintTests.swift:154-161.
- Description: attachment is decided per model type over all scanned files, and any `.environmentObject(` call of any object counts as attaching every model. A screen that reads ZTronSearchResultsModel without being under an attaching modifier passes if any other file attaches that type or injects anything. The in-repo test scans ParityHost and a non-existent Examples directory; neither contains an @EnvironmentObject reader, so it cannot fail.
- Evidence: replica attachlint/main.swift printed: orphan alone -> ["Detail.swift:2"]; orphan + unrelated attached screen -> []; orphan + unrelated .environmentObject(appSettings) -> []. `grep -rn @EnvironmentObject ParityHost Sources` finds only SourceLint's own comment/code; `ls Examples` -> No such file or directory.
- Failure scenario: a host app with a catalog screen that uses `.zTronSearch(results, ...)` and a detail screen presented elsewhere that declares `@EnvironmentObject var results: ZTronSearchResultsModel<S>` passes the lint and crashes at run time with the missing-object error.
- Repro: scratchpad/cycle-1/s04-ui/attachlint/main.swift.

### C1-s04-ui-07 — Bold Text is not modelled; text uses fixed-size system fonts instead of .body
- Severity: medium. Category: spec-deviation. Verdict: CONFIRMED (code + committed results).
- Spec: 12.4 (text .body; metrics sampled from UIKit), 12.2 rule 9, 12.5 (bold text is a matrix appearance).
- Locations: UI/ZTronSearchField.swift:163, 178, 201, 285, 316, 337, 502, 522 (`.font(.system(size: metrics...))`); UI/ZTronSearchFieldMetrics.swift:237-240 (lookup by version and content size only; no legibility-weight axis anywhere in UI/).
- Description: metrics are keyed by iOS version and content size; nothing reads legibilityWeight. Under Bold Text UIKit enlarges symbols and token text; the clone keeps regular metrics.
- Evidence: summary.csv bold-text: 0 pass, 62 fail. ios-18.6/iPhone-15/bold-text/L/ltr/software/type.json: clearButton.y 7.67 vs 8.67, clearButton.height 20 vs 19, glyph.height 19.33 vs 18.67, token.0.width 73 vs 73.67; pixels 2.67%, dE 28.75.
- Failure scenario: with Settings > Accessibility > Bold Text on, every field differs from UISearchTextField at the default size.

### C1-s04-ui-08 — Parity metrics capture reports the reference's hidden glyph, failing every accessibility-size cell with content
- Severity: medium. Category: test-integrity. Verdict: CONFIRMED (code + snapshots).
- Spec: 12.5 (metrics comparison on every cell), 15.7 (layout within 0.5 pt).
- Locations: ParityHost/Sources/ZTronSearchEngineUIParity/ReferenceField+Layout.swift:10-12 (glyphView = first UIImageView, no visibility check), :111 (`if let glyph = glyphView { metrics.frames["glyph"] = ... }`), compare :15-18 (clearButton filtered by isVisible); ReferenceSampler.swift:165-168 (the sampler treats the same view as not shown).
- Description: at AX1-AX5 with tokens or text UIKit does not draw the glyph (sampled glyphShownWithContent 0 in Samples/ios-18.json accessibility1-5; the clone hides it accordingly, UI/ZTronSearchField.swift:125-127). The metrics capture still records the hidden view's frame, so the comparator reports "glyph (reference only)" as missing and fails the cell even though neither image shows a glyph.
- Evidence: ios-18.6/iPhone-15/light/AX5/ltr/software/type.json: metrics missing ['glyph (reference only)'] at initial, focused and typed, failures []; type/initial-reference.png and type/initial-clone.png both show no magnifying glass. The reference's runtime accessibility tree also lists an Image "Search" node there (node count 4 vs 3); whether VoiceOver exposes it on a device was not checked.
- Failure scenario: even a pixel-perfect clone fails the metrics comparator in all AX-size cells with content, so the gate cannot pass; conversely a fix that "adds the glyph back" would make the clone wrong.
- Knock-down note: an earlier hypothesis that the clone wrongly hides the glyph at AX sizes was rejected after viewing the snapshots.

### C1-s04-ui-09 — No RTL (Arabic) cell passes: clear and Cancel labels stay English, tokens 2 pt shorter
- Severity: medium. Category: bug. Verdict: CONFIRMED symptom; root cause not verified.
- Spec: 12.1 p27 (VoiceOver labels, RTL verified on the matrix), 12.2 rules 7-8.
- Locations: UI/ZTronSearchField.swift:768-773 (clearText via Bundle.module), UI/ZTronSearchFieldCore.swift:509-524 (ZTronSearchStrings); ParityHost/App/ParityHostUITests/ParityRemote.swift:28 (cells launch with -AppleLanguages (ar)); UI/ZTronSearchFieldMetrics (English-only samples).
- Description: in Arabic cells the reference labels the clear button "مسح النص" and Cancel "إلغاء"; the clone says "Clear text" and "Cancel" although Localizable.xcstrings has the Arabic strings (and the macOS-built bundle has ar.lproj) and the host Info.plist lists ar. Token height is 24.3 pt in the clone vs 26.3 pt in the reference (token.0.y 6 vs 5): metrics were sampled under English only.
- Evidence: ios-18.6/iPhone-15/light/L/rtl/hardware/clear.json and cancel.json accessibility differences; type.json metrics failures token.0.height/token.0.y; summary.csv: 0 passing RTL results.
- Failure scenario: an Arabic VoiceOver user hears English labels for the field's buttons; Arabic layouts differ visibly.

### C1-s04-ui-10 — With an editingPolicy, the host's .focused cannot start editing (policy never consulted)
- Severity: medium. Category: bug. Verdict: PLAUSIBLE (needs a device; not covered by unit tests or parity scripts).
- Spec: 12.1 p27 (.focused works directly), 12.3 p30 (editingPolicy evaluated before the inner input is enabled).
- Locations: UI/ZTronSearchField.swift:345 (`.disabled(!allowsInput || !isEnabled)`), :484-490 (gate only on tap), :652 (`allowsInput = configuration.editingPolicy == nil || core.isEditing`), :691-699 (requestFocus only from the tap gate), :707-713 (comment expects "the host's .focused" to arrive), :729.
- Description: with a policy the inner TextField stays disabled until a tap passes the gate. Setting the host FocusState to true targets a disabled TextField, which SwiftUI does not focus, so neither the policy nor focus happens. UIKit's becomeFirstResponder asks textFieldShouldBeginEditing and focuses when allowed.
- Failure scenario: a host with `.editingPolicy { _ in true }` and `.focused($focused)` sets focused = true in onAppear; the keyboard never appears and the binding falls back to false.

### C1-s04-ui-11 — README overstates where the field matches the reference
- Severity: low. Category: false-claim. Verdict: CONFIRMED.
- Spec: 12.5 / 15.7 reporting.
- Locations: README.md:216-218.
- Description: README says the field matches on iOS 17.5 and 18.6 on 3x iPhones, left to right, at the default content size. At that size and direction, bold-text cells fail 18/18 on both versions on iPhone 15, 2 of 20 cells per group are not runnable, and 18.6 iPhone 15 Pro Max has 1 failure (type/hardware: reference "mp", clone "map", the reference dropped a keystroke, a harness flake).
- Failure scenario: a reader concludes default-size LTR is done; it is not for Bold Text users.

### C1-s04-ui-12 — Token drawn as a radius-4 rounded rectangle, not a capsule
- Severity: low. Category: spec-deviation. Verdict: CONFIRMED (deliberate, follows the UIKit sample).
- Spec: 12 p25 ("Capsule"), 12.4 (token capsule).
- Locations: UI/ZTronSearchField.swift:493-512; UI/ZTronSearchFieldMetrics+Sampled.swift:21-34 (tokenCornerRadius 4).
- Description: the shape follows the sampled UIKit corner radius, which matches the reference in passing cells; the spec text says capsule. Spec/implementation drift only.

### C1-s04-ui-13 — A stream that ends without a final snapshot leaves stale or partial hits presented as settled
- Severity: low. Category: bug. Verdict: PLAUSIBLE (by reading).
- Spec: 13 p34 (isLoading, error, a view never shows results of a query typed past).
- Locations: UI/ZTronSearchResultsModel.swift:149-152 (streamEnded only clears isLoading), :65-70; Sources/ZTronSearchEngine/Service/SearchService.swift:892-903 (setLocale calls cancel() at :898 on NSLocale.currentLocaleDidChangeNotification), the run() pipeline's swallowed lexical error.
- Description: when the service cancels the in-flight query (locale change) or the pipeline returns on an error, the model keeps the last non-final hits, isLoading becomes false and error stays nil (error is set only by page failures, :194-205); re-sending the same text returns early.
- Failure scenario: the system locale changes during a search; the screen shows a partial list with no spinner and no error until the user edits the text.

### C1-s04-ui-14 — The specification's minimal host does not type-check against textToToken
- Severity: low. Category: api. Verdict: CONFIRMED (probe with mirrored signatures).
- Spec: 12.2 p29 (minimal host).
- Locations: UI/ZTronSearchFieldEnvironment.swift:120 (`func textToToken<Schema: SearchSchema>(_ rule: @escaping (String) -> ZTronSearchToken<Schema>?)`), same shape :125 onTokenDelete, :134 tokenCopyProvider.
- Description: Schema can only be inferred from the closure result; `ZTronSearchToken(kind: .filter($0), ...)` constrains only Schema.Filter, which Swift cannot invert. Hosts must write `ZTronSearchToken<CatalogSchema>(...)`.
- Evidence: texttotoken/main.swift (ZTronSearchToken.Kind and View.textToToken mirrored) -> "error: generic parameter 'Schema' could not be inferred".
- Repro: scratchpad/cycle-1/s04-ui/texttotoken/main.swift.

## Knocked down (not reported)
- Snapshot equality guard dropping service snapshots: service snapshots carry the exact query passed (SearchService.swift:278-295), so `snapshot.query == query` holds in normal use.
- zTronChat onDisappear cancelling more than generation: ZTronChatModel.cancel() (:125-133) cancels only generation; model survives (T/AttachmentModifierTests.swift:328).
- Missing token custom actions: the reference tokens expose none on 17/18; the comparator checks custom actions.
- tokenCopying/tokenCopyProvider being no-ops: allowed by 12.3.
- Results-model ordering race between actor calls: same-priority FIFO, no failing interleaving found.
- Clone hiding the glyph at accessibility sizes: snapshots show the reference hides it too (see 08).
- 18.6 Pro Max type/hardware failure: reference dropped a keystroke, not a clone defect (noted in 11).

## Not checked
- Anything needing a device or simulator: real rendering, VoiceOver behavior, keyboard traits (spell checking, smart punctuation actually off), hardware-keyboard onKeyPress(.delete), focus with editingPolicy (10).
- iOS 15 and 16 runtime behavior: no runtimes; parity cells not runnable here.
- Root cause of English labels in Arabic cells (09): resource-bundle localization inside the iOS app build.
- R23: whether the core excludes token filters/kinds/phrases from fuzzy expansion and prefix matching (core matcher, other slice).
- ZTronTextChange.between (grapheme-based diff) vs UIKit UTF-16 ranges for combining marks: suspected, not reproduced.
- CI behavior: parity.yml re-sampling and drift diff, ci.yml iOS 15.5 xcodebuild compile; not run.
- Full review of ParitySession / matrix scripts beyond tolerated deviations and the glyph capture; reasons for the 2 not-runnable cells per group.
- Chat model internals (14.5) and section 11 rows on p25 (outside slice).
- Package build and tests not run (ground rules); pass status from Verification/_runs/c1-debug-swift-test.log.

STATUS: complete
