# Cycle 2 — m04-ui findings (checkpoint)

Auditor scope: Sources/ZTronSearchEngineUI (incl. Resources), ParityHost (Sources, App, Tools, Tests, Samples, Results/summary.md), Scripts/generate_ui_assets.py.
Tests: Tests/ZTronSearchEngineUITests, ParityHost/Tests. Spec: sections 12, 13, 14.5, 15.7.
Standalone confirmation programs (outside the repository): scratchpad/cycle-2/m04-ui/pagesize.swift, textlogic.swift
(/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m04-ui/).

## Findings

### C2-m04-ui-01 — high — spec-missing — The 15.7 parity gate is not met; iOS 15/16 (the package floor) were never sampled or run, so the field ships iOS 17 values there unverified
- Spec: 12.4 (sampled per iOS version), 12.5 matrix (15.5, 16.4, 17.5, latest 18.x, beta), 15.7 (every cell), rule 12.
- Locations: Sources/ZTronSearchEngineUI/ZTronSearchFieldMetrics+Sampled.swift:8 (`sampledVersions = [17, 18]`); ZTronSearchFieldMetrics.swift:223-240 (`nearestSampledVersion`, `metrics(forMajorVersion:)`) and :272 (behavior lookup); ParityHost/Results/summary.md (Coverage, "Cells that could not run"); README.md:216-218.
- What happens: on iOS 15 and 16 `nearestSampledVersion` returns 17, so field height, insets, glyph and token frames, durations and the behavior flags (clearRemovesTokens, clearBeginsEditing, submitKeepsEditing, typingReplacesSelectedTokens, conversionSelectsToken) are the iOS 17.5 sample; on iOS 26/27 they are the iOS 18.6 sample. Results: 7440 cell results, 179 pass, 602 fail, 6659 not runnable; all 6400 cells of 15.5/16.4 not runnable (runtimes cannot boot on this macOS); every 27.0 cell that ran fails (initial pixels ~98% differ); bold-text fails every L/ltr cell on iPhone 15 at the initial checkpoint on both 17.5 and 18.6 (1.5-15.6% of pixels, glyph height 19.33 vs 18.67 pt, clear button 1 pt off); RTL, iPhone SE (2x) and iPad fail pixel/accessibility thresholds. Gate tool (Tools/gate.py) correctly reports the gate closed. Disclosed in README ("not met yet"), but still a release gate of 15.7 unmet, and the reference device of section 15 (iPhone 6s, iOS 15.8) runs an unsampled configuration.
- Failure scenario: a host on iOS 15/16 gets UISearchTextField metrics and clear/submit behavior of iOS 17, never compared against the UIKit field of iOS 15/16.

### C2-m04-ui-02 — medium — bug — Setting `pageSize` while a query is in flight drops every snapshot of that query and leaves the previous query's hits on screen, stuck until the text changes
- Spec: 13 (results model; generation/stale-result guarantees), 14.5.
- Locations: Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:65-70 (`update` copies `query.limit` then returns early when equal), :78-81 (`pageSize` setter mutates `query.limit` without bumping `revision`), :131 (`apply` requires `snapshot.query == query`), :149-152 (`streamEnded` clears `isLoading`), :89 (`reset()` replaces `query` and silently reverts `pageSize` to the default limit).
- Mechanism: `SearchQuery`'s synthesized Hashable includes `limit`. After `update("harb")` starts a stream, `pageSize = 50` changes `query.limit`; every "harb" snapshot carries limit 20 and fails `snapshot.query == query`; the stream ends and `isLoading` turns false; `hits` remain those of "har" while `query.text` is "harb". The attachment modifier re-forwarding "harb" hits the early return (`next == query`), so nothing recovers until the text changes. Separately, `reset()` reverts a host-set page size.
- Evidence (standalone copy of the logic, pagesize.swift, printed):
  `after "har": query="har" hits=["har-1", "har-2"] isLoading=false` / `dropped snapshot of "harb" (limit 20); model query limit is 50` (twice) / `after "harb" + pageSize=50: query="harb" hits=["har-1", "har-2"] isLoading=false` / `update("harb"): returns early, query unchanged` / `after forwarding "harb" again: query="harb" hits=["har-1", "har-2"] isLoading=false`.
- Tests: ResultsModelTests has no pageSize test.

### C2-m04-ui-03 — medium — spec-deviation — Ending editing drops the token selection (and fires onSelectionChanged) where the UIKit reference keeps it selected; recorded in both samples, checked by nothing
- Spec: 12.2 rule 2 and rule 12 (only 12.5 deviations tolerated), 12.3 (every modifier fires once per UIKit callback).
- Locations: Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:483-505 (`focusChanged(to: false)`: lines 499-501 `selection = []`, `outcome.selectionChanged = true`); ZTronSearchField.swift:612-644 (apply calls `onSelectionChanged` at :637 and writes the host's tokenSelection binding); Tests/ZTronSearchEngineUITests/SearchFieldCoreTests.swift:504-511 (`testLosingFocusDropsTheTokenSelection` enshrines it); ParityHost/Samples/ios-17.json and ios-18.json `behavior.finalStates` vs `behavior.cloneFinalStates` for "blur-with-selected-token".
- Evidence: both samples record reference `text "", tokens ["Maps"], selected ["Maps"], not editing` and clone `... selected [], not editing`. Both logs are identical (no didChangeSelection on blur), so the clone changes the host's selection and calls `onSelectionChanged` with no UIKit callback behind it. No matrix script blurs with a selected token (focus-round-trip has no tokens), and nothing compares cloneFinalStates (see C2-m04-ui-05).
- Failure scenario: user taps a token, then dismisses the keyboard: UIKit keeps the token selected (so the next focus + backspace deletes it); the clone deselects it and notifies the host.

### C2-m04-ui-04 — medium — spec-deviation — On iOS 18, tapping the text to deselect a token logs two extra caret moves the reference does not log
- Spec: 12.2 rule 2, 12.5 (text selection observable and compared from iOS 18), 15.7 (event log identical).
- Locations: Sources/ZTronSearchEngineUI/ZTronSearchField.swift:684-689 (`tappedInput` deselects, then `inputSelectionMoved()`), :417-426; ParityHost/Samples/ios-18.json `eventProfile` vs `cloneEventProfile` "tap-text-deselects".
- Evidence: reference `[..., didChangeSelection(tokens: ["Maps"], text: 0+0), didChangeSelection(tokens: [], text: 6+0)]`; clone the same followed by `didChangeSelection(tokens: [], text: 4+0), didChangeSelection(tokens: [], text: 6+0)`. Applying the harness's own filters (EventLogComparator: revert-notification drop; no text-selection reduction at iOS 18) to all 32 sampled actions with a script, this is the only remaining log difference on 18.6 (none on 17.5). No matrix script taps the text with a token selected (tap-select taps the empty text point), so the gate cannot see it.
- Failure scenario: iOS 18 host observing selection gets two spurious caret reports (to the touch point, then back) after every tap on the text that deselects a token; parity log fails for that interaction.

### C2-m04-ui-05 — medium — test-integrity — The parity suite does not check several things the spec puts under it: three token scripts, the public modifiers' callback counts, and the sampled clone profile
- Spec: UI parity suite list (spec p.48: "Token scripts: insert and remove through the binding, tap-select, backspace-select then backspace-delete, onTokenDelete veto, text-to-token through textToToken and programmatically, token overflow scrolling"; "every modifier in the 12.3 map fires exactly once per UIKit callback"), 15.7.
- Locations: ParityHost/Sources/ZTronSearchEngineUIParity/ParityScript.swift:12-88 (10 scripts; no binding insert/remove, no veto, no programmatic conversion; FieldSetup.allowsDeletingTokens never false in a matrix script); CloneField.swift:19-25, 63-66 (the compared clone log is the core's `onSearchFieldEvent` stream; `editingChanges`, `submitCount`, `cancelCount` from `.onEditingChanged/.onSubmit/.onSearchCancel` are recorded and never compared - no other reference in the repository); App/ParityHostUITests/SamplerUITests.swift:36-38 (doc: the reference log "is what the clone's log is held to") and :62-69 (clone log and final state stored, never compared; generate_ui_assets.py and the tests do not read cloneEventProfile/cloneFinalStates).
- Consequence: a duplicate or missing `.onSubmit`/`.onEditingChanged`/`.onSearchCancel` call, or a selection callback without a UIKit counterpart (C2-m04-ui-03), passes every comparator; the divergences of C2-m04-ui-03/04 sit in the committed samples unflagged. Core unit tests cover veto and programmatic conversion against hand-written expectations only, not against the reference.

### C2-m04-ui-06 — medium — test-integrity — The @EnvironmentObject lint is vacuous over the repository and global in what counts as an attachment
- Spec: 13.1 / UI test list ("a screen that reads a model through @EnvironmentObject without an attaching modifier fails the lint test").
- Locations: Tests/ZTronSearchEngineUITests/LintTests.swift:154-161 (`testThePackagesOwnScreensAttachTheModelsTheyRead` scans "ParityHost" and "Examples"); Sources/ZTronSearchFixtures/SourceLint.swift:211-236 (`unattachedEnvironmentObjects`).
- Evidence: "Examples" does not exist; ParityHost contains no `@EnvironmentObject` or `.environmentObject(` at all (grep), so the repository-level test can never find anything. In the helper, `attached` is true for a model when ANY scanned file contains one of its modifiers or ANY `.environmentObject(` call (for any object), and then no file is checked for that model.
- Failure scenario: a host codebase with `.environmentObject(settings)` anywhere, or `.zTronSearch(...)` on one screen, passes the lint while another screen reads `@EnvironmentObject var results: ZTronSearchResultsModel<...>` with nothing attaching it (runtime crash the lint exists to prevent).

### C2-m04-ui-07 — medium — bug (plausible) — With an editingPolicy set, the host's `.focused` binding cannot begin editing
- Spec: 12.2 ("`.focused($isFocused)` works directly: the field forwards focus to its inner text input"), 12.3 (`.editingPolicy` maps to textFieldShouldBeginEditing), UI suite "Focus round trip through .focused".
- Locations: Sources/ZTronSearchEngineUI/ZTronSearchField.swift:345 (`.disabled(!allowsInput || !isEnabled)`), :652 (`allowsInput = configuration.editingPolicy == nil || core.isEditing`), :729 (re-disabled on every blur), :691-699 (`requestFocus` is the only path that asks the policy and enables input; reached from taps only).
- Mechanism: when a policy is set and the field is not editing, the inner TextField is disabled; a host setting its FocusState to true targets a disabled control, and nothing in the field observes the host's request, so the policy is never asked and editing never begins. UIKit's `becomeFirstResponder()` asks textFieldShouldBeginEditing and begins editing when allowed. Not run (no simulator allowed); no matrix script or test sets an editingPolicy (core test testEditingPolicyGatesBeginAndEnd exercises the core only).

### C2-m04-ui-08 — medium — spec-deviation (plausible) — On iOS 18+, text set through the binding while editing keeps the caret at its old UTF-16 offset (possibly inside a surrogate pair) and the field pushes that caret into the input
- Spec: 12.2 rule 12, 12.5 (text selection compared from iOS 18).
- Locations: Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:180-187 (`adopt`: `placeCaret(at: isEditing ? textSelection.lowerBound : 0)`), :143-146 (`placeCaret` clamps but does not align to scalar boundaries); ZTronSearchField.swift:647-653 (`synchronize` -> `setBuffer`), :456-471 (iOS 18: `inputSelection = TextSelection(insertionPoint:)` at the core's caret).
- Scenario: user typed "har" (caret 3); host replaces text with "harbor" (autocomplete) while editing; the core keeps caret 3 and on iOS 18 sets the input's selection there, so the next keystroke gives "harxbor"; UITextField moves the caret to the end when `text` is assigned (platform behavior, not sampled by the parity host - itself against "recorded, never assumed"). With text replaced by "😀x" and caret 1, the index handed to TextSelection points inside the surrogate pair. Below iOS 18 the input's own caret is not overridden. No test adopts non-empty text while editing.

### C2-m04-ui-09 — low — spec-deviation — Smart-quote/dash undo is both incomplete and over-eager
- Spec: 12.2 ("smart quotes and smart dashes are off"); reference sets smartQuotesType/smartDashesType = .no (ParityHost ReferenceField.swift:45-46).
- Locations: Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:91-105 (`plain`), applied to every input change at :228.
- Evidence (textlogic.swift, standalone copy, printed): `„Hallo“ -> „Hallo"`, `‚x‘ -> ‚x'`, `« bonjour » -> unchanged`, `1–3 -> 1-3`, `a—b -> a--b`.
- Effect: locale smart punctuation (German „“, Polish/Czech „”, French « ») is left half-substituted, while characters a user enters on purpose (long-press en/em dash, pasted curly quotes) are rewritten, an em dash becoming two characters; the reference keeps both as entered (smart substitution off). Text binding and shouldChange payloads differ from the reference. Test testSmartQuotesAndDashesAreUndone covers only the four mapped characters.

### C2-m04-ui-10 — low — spec-deviation — shouldChange payloads are computed per grapheme, not per UTF-16 edit
- Spec: 12.3 (shouldChangeCharactersIn mapping), 15.7 (identical payloads).
- Locations: Sources/ZTronSearchEngineUI/ZTronSearchFieldTypes.swift:101-112 (`ZTronTextChange.between` diffs `Array(old)`/`Array(new)` Characters); used at ZTronSearchFieldCore.swift:241 and passed to textInputPolicy.
- Evidence (textlogic.swift printed): `cafe -> cafe\u{301}: shouldChange(3, 1, "e\u{301}")` (UIKit inserts the mark: (4, 0, "\u{301}")); Thai `\u{E01} -> \u{E01}\u{E48}: shouldChange(0, 1, ...)` (UIKit (1, 0, "\u{E48}")); `👍 -> 👍🏽: shouldChange(0, 2, ...)` (UIKit (2, 0, modifier)).
- Effect: for combining marks (Thai, Vietnamese, Indic, decomposed Latin) and emoji modifiers the log and the change a textInputPolicy sees differ from UIKit; the matrix only types ASCII, so it is never exercised.

### C2-m04-ui-11 — low — test-integrity — "not runnable" overrides comparison failures already recorded, hiding 203 failing cells from the failure counts
- Spec: 15.7 (every cell), 12.5.
- Locations: ParityHost/Sources/ZTronSearchEngineUIParity/ParitySession.swift:216-229; App/ParityHostUITests/ParityRemote.swift:105-114 (a key counts as "undelivered" when the field's own log does not grow).
- Evidence: of 223 not-runnable cells that reached a checkpoint, 203 carry comparison failures (e.g. ios-27.0/iPhone-15-Pro-Max/light/L/ltr/hardware/backspace-delete.json "initial pixels: 98.026% differ"; ios-18.6/iPhone-15/light/L/rtl/software/submit.json "initial pixels: 1.083% differ"), yet summary.md lists them under "Cells that could not run". The condition only requires that every driver problem be an undelivered-key one, not that both fields failed, so a clone that ignores a hardware delete (its log does not grow) is reported as a driver limitation; the reason text says "to either field" even when only one side is listed (3 cells). gate.py still counts not-runnable as blocking, so the gate is not opened falsely.

### C2-m04-ui-12 — low — false-claim — Committed results predate the committed localization, and the README's summary of them overstates
- Locations: ParityHost/Results/summary.md (mtime 2026-11-15 01:45) vs Sources/ZTronSearchEngineUI/Resources/Localizable.xcstrings (02:09); README.md:216-218.
- Evidence: 802 accessibility differences in RTL cells are the clone's English label against the reference's Arabic (e.g. ios-27.0/iPhone-15-Pro-Max/light/L/rtl/hardware/tap-select.json node 4 label: reference Arabic "clear text", clone "Clear text"); the xcstrings now carries ar; the results were not re-run. README says the field "matches the reference on iOS 17.5 and 18.6 on 3x iPhones, left to right, at the default content size"; summary.csv has all bold-text L/ltr cells on iPhone 15 failing on both versions and ios-18.6 iPhone 15 Pro Max light L ltr hardware type failing (state "mp" vs "map", a driver flake counted as a clone failure).

### C2-m04-ui-13 — low — bug (plausible) — iOS 18 caret reports near the end of the text are dropped if TextSelection indices count UTF-8
- Locations: Sources/ZTronSearchEngineUI/ZTronSearchField.swift:428-441 (`utf16Offsets`; comment claims the guard holds "whichever encoding it counts in").
- Evidence (textlogic.swift printed): buffer "\u{200B}harbor" has utf16=7, utf8=9; a native (UTF-8) end index compared with the 7-space limit: `caret at end <= limit: false`; a UTF-16 (bridged) end index: true. The sentinel alone makes UTF-8 longer than UTF-16, so with UTF-8 indices every caret in the last two positions (more with non-ASCII text) is rejected and the move is not reported. Which encoding SwiftUI's TextSelection indices use was not verified (no simulator).

### C2-m04-ui-14 — low — bug — Select-all then entering the identical text is treated as backspace-at-start (selects, then deletes, the last token)
- Locations: Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:231-234 (`!hasSentinel && proposed == text` -> `deleteBackwardAtStart`); ZTronSearchField.swift:389-399 (`lostSentinel && strip(raw) == core.text`).
- Scenario: tokens [Maps], text "a"; select all in the input (covers the sentinel) and type "a", or paste the same text: the input holds "a" without the sentinel, so the field logs shouldChange(-1, 1, "", true) and selects "Maps"; repeating it deletes the token. UIKit logs a replacement of the text range (0, 1, "a").

## Knocked down
- Text-to-token "never animates" (shortestAnimation 0.1 s vs sampled 0/0.033 s): the reference completes within 1-2 frames; AnimationComparator passes L/ltr 17.5/18.6 cells; ZTronSearchField.swift:375-379, 618-626 document the choice.
- reset()'s `Task { await service.cancel() }` racing the next `results(for:)`: both unstructured tasks start on the main actor in FIFO order and hop to the service actor in that order.
- ZTronChatModel cancelled send still calling chat.send: AsyncThrowingStream next() in a cancelled task terminates the stream and ChatService.send's onTermination cancels generation (ChatService.swift:398).
- Token custom actions (delete, copy): the reference tree exposes none; no custom-action differences in results.
- Hardware delete on iOS 17+ via sentinel unless a token is selected (vs "uses onKeyPress(.delete) instead"): no observable difference found.
- gate.py treating not-applicable as pass: no cell is ever not-applicable (summary.csv).
- Pixel/metrics/animation comparator thresholds match 15.7 (0.5%, ΔE 2 CIEDE2000, 0.5 pt, 1 frame); event-log filters are limited to the two 12.5 deviations.

## Files read
- Spec text (Verification/_inputs/spec.txt): sections 9-14.5, 15.7, UI parity suite list, 16, 17.
- Sources/ZTronSearchEngineUI: all 10 .swift files, Resources/Localizable.xcstrings, Colors.xcassets.
- Scripts/generate_ui_assets.py.
- Tests/ZTronSearchEngineUITests: all 5 files.
- ParityHost: README.md, Package.swift, App/Support/ParityHostApp-Info.plist, Results/summary.md and summary.csv (plus scripted scans of result JSONs), Samples/ios-17.json and ios-18.json (scripted), Sources: Comparators/* (6), AnimationRecorder, ParityResult, ParityCell, ParitySession, ParityCapture, CloneField, ParityScript, FieldSetup, ParityEvent, BehaviorProfile, ReferenceField (setup part); App/ParityHostUITests/ParityRemote.swift, SamplerUITests.swift; Tools/gate.py, summarize.py, run-matrix.sh, sample.sh, matrix.py (first 120 lines); Tests: ComparatorTests (test list), HostCapabilityTests (first 60 lines).
- Core context: Contracts/SearchQuery.swift, SearchHit.swift (snapshot), Service/SearchService.swift (results/page/cancel), Fixtures/SourceLint.swift (lint), Chat/ChatService.swift (onTermination), root README.md.

## Not checked
- ParityHost Sources: ReferenceSampler.swift (654 lines; how metrics/colors are sampled), most of ReferenceField.swift, ReferenceField+Layout.swift, ParityStage.swift, ParityProtocol.swift, Diagnostics.swift, SymbolLab.swift, ParitySchema.swift, ParityHost.swift.
- App: AppMain.swift, ParityMatrixUITests.swift, DiagnosticsUITests.swift, Xcode project/scheme.
- Tools: sample.py, matrix.py after line 120. Tests: ComparatorTests bodies, rest of HostCapabilityTests.
- Colors.xcassets values against the samples beyond generate_ui_assets.py --check (log c2-ui-assets-check.log EXIT 0).
- No runtime check of SwiftUI focus/TextSelection behavior (C2-m04-ui-07, -08, -13 are code-derived): simulators may not be booted.

STATUS: complete
