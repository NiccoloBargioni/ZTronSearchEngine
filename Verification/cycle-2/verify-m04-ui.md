# Cycle 2 — m04-ui skeptic verdicts (checkpoint)

Scratchpad for repros: /private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m04-ui-skeptic/

## Verdicts (in progress)

### C2-m04-ui-02 — partly (medium)
- Traced: ZTronSearchResultsModel.swift:78-81 (`pageSize` setter writes `query.limit`, no revision bump); :131 (`snapshot.query == query`); SearchQuery.swift:24-35 synthesized Hashable includes `limit`; SearchService.swift:378/469-470 echoes the query it was handed (`state.query`) into every snapshot, so a stream started with limit 20 always carries limit 20.
- Repro (m04-ui-skeptic/pagesize.swift, faithful copy with a hand-driven stream) printed:
  - B: `apply: DROPPED snapshot of "harb" (snapshot limit 20, model limit 50, revision match true)` x2, `streamEnded: isLoading -> false`, final `query="harb" limit=50 hits=["har-1", "har-2"] isLoading=false`.
  - C: `update("harb"): early return (next == query)`.
  - D: `submit()` recovers: `hits=["harb-1", "harb-2"]`.
  - E: setting pageSize to the same value mid-flight is harmless; G: setting it before any query is harmless.
  - F: `pageSize before reset: 50` / `after reset: 20`.
- Correction: "only a text change recovers" is wrong: a token change or `submit()` (the spec's minimal host wires `.onSubmit { results.submit() }`) also recovers. Only the service backend is affected (scan applies synchronously). Requires changing pageSize to a different value while a stream is in flight.

### C2-m04-ui-01 — confirmed (high)
- ZTronSearchFieldMetrics+Sampled.swift:8 `sampledVersions = [17, 18]`; ZTronSearchFieldMetrics.swift:223-240 and :272 route both metrics and `ZTronSearchFieldBehavior` through `nearestSampledVersion`. Repro (m04-ui-skeptic/nearest.swift) printed `iOS 15 -> sampled 17`, `iOS 16 -> sampled 17`, `iOS 26 -> sampled 18`, `iOS 27 -> sampled 18`. Package.swift `platforms: [.iOS(.v15)]`.
- summary.csv tally (own script): 7440 rows = 6659 not-runnable, 602 fail, 179 pass; 15.5 and 16.4: 3200 not-runnable each, 0 ran; 27.0: 110 ran, 110 fail.
- Bold text, iPhone 15, L/ltr: 18 fail + 2 not-runnable (hardware backspace) on each of 17.5 and 18.6, i.e. every cell that ran fails. ios-17.5/iPhone-15/bold-text/L/ltr/software/type.json: `glyph.height reference 19.33, clone 18.67`, `clearButton.y reference 7.67, clone 8.67, off by 1.00 pt`, initial pixels 2.842%.
- Spec: 15.7 "every cell of the section 12.5 matrix"; 12.5 iOS axis 15.5, 16.4, 17.5, 18.x, beta; 17 milestone 4 gate "section 15.7 thresholds on the full 12.5 matrix". Sections 16/17 do not relax it. README.md:216-218 discloses "not met yet", so this is a disclosed unmet gate, not a hidden one; the failure mode (unsampled 15/16 values) is real.

### C2-m04-ui-05 — confirmed (medium)
- ParityScript.swift:12-88: the 10 matrix scripts = the 12.5 "Scripts" axis; none mutates the bindings, none sets an onTokenDelete veto (CloneScreen registers no `.onTokenDelete` at all), none converts programmatically; `FieldSetup.allowsDeletingTokens` is never false in a matrix script (only in BehaviorProfile's sampler action).
- grep: `submitCount`/`cancelCount`/`editingChanges` occur only in CloneField.swift:23-25,64-66 (written, never read); `cloneEventProfile`/`cloneFinalStates` only in SamplerUITests.swift:67-68,104-107 (written, never read by any tool, test or generate_ui_assets.py). `.onSelectionChanged`, `.onClear`, `.editingPolicy`, `.textInputPolicy` are not registered by the clone host at all.
- Spec p.48-49 (section 16, "UI parity suite (simulator matrix)"): token scripts incl. "insert and remove through the binding", "onTokenDelete veto", "text-to-token through textToToken and programmatically", and "every modifier in the 12.3 map fires exactly once per UIKit callback". Core unit tests (SearchFieldCoreTests:217-249, 370-388) cover veto/programmatic adoption with hand-written expectations only.
- My own replay of the samples with the harness filters (m04-ui-skeptic/profilediff.py) shows the unflagged divergences sitting in the committed samples: ios-17 0 log diffs + 1 state diff (blur-with-selected-token); ios-18 1 log diff (tap-text-deselects) + the same state diff.

### C2-m04-ui-06 — partly (low)
- SourceLint.swift:221-224: a model counts as attached when any scanned file contains one of its modifiers or any `.environmentObject(` at all. Repro (m04-ui-skeptic/lint.swift): reader alone -> `Rows.swift:2 reads ZTronSearchResultsModel without an attaching modifier`; reader + unrelated `.environmentObject(settings)` -> `[]`; reader + `.zTronSearch(` on an unrelated screen -> `[]`.
- `Examples` does not exist; `grep -rln -e EnvironmentObject -e "environmentObject(" ParityHost --include=*.swift` exits 1 (no match), so testThePackagesOwnScreensAttachTheModelsTheyRead checks nothing.
- Correction: the failure scenario ("a host codebase ... passes the lint") is not reachable: SourceLint lives in ZTronSearchFixtures, which is not a product (Package.swift products: Engine, Semantic, UI), and the only repository-level run scans ParityHost/Examples. The spec's literal requirement (a reader without attachment fails the lint) is exercised by testAScreenThatReadsAModelWithoutAttachingItFailsTheLint. Real issue: the heuristic is over-accepting (any `.environmentObject(` anywhere disables the check for every model) and the repository-level test is vacuous. Low.

### C2-m04-ui-03 — partly (low)
- Code trace (current tree): ZTronSearchField.focusChanged(false) -> core.focusChanged(to: false) (Core.swift:495-504) sets `selection = []`, `outcome.selectionChanged = true` and appends only shouldEndEditing/didEndEditing; apply (Field.swift:629-638) writes `externalSelection.wrappedValue = []` and calls every onSelectionChanged observer. No didChangeSelection event accompanies it. ZTronSearchFieldCore.swift (22:56) predates the samples (23:16), so the sampled clone column reflects this core.
- Samples (own replay, profilediff.py): both ios-17 and ios-18 `finalStates[blur-with-selected-token]` = `selected ["Maps"], not editing` vs clone `selected []`; logs equal after the harness filters. The reference reads selection via `textField.selectedTextRange` (ReferenceField.swift:81-84) regardless of first-responder state, and it logged no textFieldDidChangeSelection on blur, so the clone's onSelectionChanged fires with no UIKit callback (violates 12.3 / section 16 "fires exactly once per UIKit callback"; not a 12.5 deviation). testLosingFocusDropsTheTokenSelection (SearchFieldCoreTests:504-511) enshrines it.
- Correction: the failure scenario's "UIKit keeps Maps selected, so focusing again and pressing backspace deletes it" is not recorded anywhere: no sampled action re-focuses after a blur with a selected token, and a re-focusing tap moves the reference's selection (cf. tap-field-deselects, focus-by-tap-with-text). Nor is a visual difference recorded. What is shown is a state/callback divergence (host binding cleared, extra onSelectionChanged). Low.

### C2-m04-ui-04 — partly (low)
- Samples: own replay with EventLogComparator's filters confirms the only 18.6 log difference is tap-text-deselects; clone appends `didChangeSelection(tokens: [], text: 4+0)`, `didChangeSelection(tokens: [], text: 6+0)` after the reference's last entry; 17.5 has none. Matrix: tap-select's second tap is `.tapField` on an empty text (textPoint), so no matrix script taps text with a token selected.
- Current code: tappedInput (Field.swift:684-689) deselects (core caret -> end, event 6+0) then calls inputSelectionMoved(), which reports the inner input's touch-point caret if it differs; a later report of the input's word-end caret is reported again via onChange(of: inputSelectionReports). That reproduces the sampled sequence.
- Caveats: ios-18.json was written 2026-11-14 23:16:51, ZTronSearchField.swift last modified 23:29:16, so the sampled clone column predates the field's last edit; the mechanism is still present in the current code, but not re-run. Impact: two transient onSelectionChanged/didChangeSelection reports on one interaction, final state identical. Severity medium -> low.

### C2-m04-ui-07 — confirmed (medium), code-derived
- Field.swift:652 `allowsInput = configuration.editingPolicy == nil || core.isEditing` (also :729 on blur); :345 `.disabled(!allowsInput || !isEnabled)`; requestFocus() (:691-699), the only place that asks the policy and sets `allowsInput = true`, is called only from editingGate's tap (:488), tappedOutsideTokens (:681), tappedToken (:675) and the clear button's takesFocus (:640). Nothing observes the host's FocusState.
- Either runtime outcome is a defect: if SwiftUI refuses focus to a disabled TextField (the normal behavior), the host's `.focused` cannot begin editing (as claimed); if it did focus it, focusChanged (:713-719) logs `shouldBeginEditing(allowed:)` but ignores the answer, editing begins even when denied, and allowsInput stays false. No test or matrix script sets an editingPolicy at field level. Not run (no simulator).

### C2-m04-ui-08 — partly (medium), mechanism confirmed, runtime unverified
- Core.swift:186 `placeCaret(at: isEditing ? textSelection.lowerBound : 0)`; :143-146 clamps only; Field.swift:456-471 on iOS 18 sets `inputSelection = TextSelection(insertionPoint:)` at sentinels + core caret.
- Repro (textlogic.swift): `text -> harbor with caret 3: core caret 3 (end would be 6)`; `text -> \u{1F600}x with caret 1: core caret 1 (end would be 3); index scalar-aligned=false character-aligned=false`.
- Not verified: that SwiftUI applies the programmatic TextSelection after the new text, and the UIKit caret-to-end on `text =` (standard UIKit, not sampled). Correction: "recorded, never assumed" in the spec governs rule 5 (the clear button), not this case; the deviation stands on rule 12. Effect of a mid-surrogate index is unknown (likely snapped), not a demonstrated crash.

### C2-m04-ui-09 — confirmed (low)
- Core.swift:91-105 maps only U+2018/2019, U+201C/201D, U+2014 (to "--"), U+2013, and runs on every input change (:228, over the whole proposed text). Reference sets `smartQuotesType = .no`, `smartDashesType = .no` (ReferenceField.swift:45-46), so it keeps deliberately entered characters as typed.
- Repro (textlogic.swift) printed: `„Hallo“ -> „Hallo"`, `‚x‘ -> ‚x'`, `« bonjour » -> « bonjour »`, `1–3 -> 1-3`, `a—b -> a--b`, `“curly” -> "curly"`. testSmartQuotesAndDashesAreUndone covers only the four mapped characters.

### C2-m04-ui-10 — confirmed (low)
- FieldTypes.swift:101-112 diffs `Array(old)`/`Array(new)` (Characters). Repro printed: `cafe -> cafe\u{301}: clone shouldChange(3, 1, "e\u{301}")` vs UTF-16 diff `(4, 0, "\u{301}")`; Thai `\u{E01} -> \u{E01}\u{E48}: clone (0, 1, ...)` vs `(1, 0, "\u{E48}")`; Devanagari `\u{915} -> \u{915}\u{93F}: clone (0, 1, ...)` vs `(1, 0, "\u{93F}")`; ASCII `har -> harb` identical. The emoji-modifier example is contrived (the iOS emoji keyboard inserts the modified emoji whole), but Thai/Indic vowel and tone marks are real keystrokes. Matrix types ASCII only.

### C2-m04-ui-11 — confirmed (low)
- ParitySession.swift:219-225: notRunnable whenever every driver problem is a missing/undelivered key, overriding failures already recorded; ParityRemote.swift:105-114: "undelivered" = that side's log did not grow. Repro (status.swift): clone ignoring the delete key with an initial pixel failure -> `notRunnable | ... to either field: clone: XCUITest did not deliver the hardware keyboard's delete key to the clone`; same failures without a driver problem -> `fail`.
- Own scan of the result JSONs: 223 not-runnable cells reached a checkpoint, 203 carry comparison failures (all 203 at the initial checkpoint); 3 "either field" reasons list only the reference. gate.py counts not-runnable as blocking, so the gate is not falsely opened; summary.md's failure counts are understated.

### C2-m04-ui-12 — partly (low)
- Timestamps: summary.md/summary.csv 2026-11-15 01:45:45; Localizable.xcstrings 02:09:15, which now has `ar` for every key ("Clear text" -> "مسح النص", "Cancel" -> "إلغاء"). Host Info.plist declares en+ar. RTL results pair the reference's Arabic label with the clone's English: my count is 735 (712 "Clear text", 23 "Cancel") across 363 result files, not 802 (other Arabic-vs-English pairs, e.g. "Maps"/"Search", are node misalignments, not localization).
- README.md:216-218 overstates: iPhone 15 bold-text L/ltr has 18 fail + 2 not-runnable per version (not "20 failing"); every other iPhone 15 L/ltr appearance is 18 pass + 2 not-runnable; ios-18.6 iPhone 15 Pro Max light L ltr hardware type fails with `text: reference "mp", clone "map"` (referenceKeyPresses 2, cloneKeyPresses 3: a dropped key on the reference counted against the clone). Severity low.

### C2-m04-ui-13 — uncertain (low)
- Repro (bridge.swift): a native string's end index is `9[utf8]` and is rejected by the guard (`accepted=false`); a UTF-16 bridged index `7[utf16]` is accepted (`7..<7`). textlogic.swift: for "​harbor" native indices at UTF-16 offsets 6 and 7 are rejected, 0-5 accepted. So the conditional claim holds.
- Counter-evidence: ios-18.json cloneEventProfile[tap-text-deselects] ends with `didChangeSelection(tokens: [], text: 6+0)` after `4+0`; in the field's code that last entry can only come from inputSelectionMoved accepting an end-of-text index, which a UTF-8 index would fail. That suggests SwiftUI on 18.6 reported UTF-16 indices, provided utf16Offsets was the same when sampled (the sample predates the field's last edit by 13 minutes). Would settle it: print the reported TextSelection bounds (`[utf8]`/`[utf16]`) on an iOS 18 simulator with the current build.

### C2-m04-ui-14 — partly (low)
- Repro (textlogic.swift, copy of Field.inputChanged(from:to:) + Core.inputChanged's first branch): `tokens [Maps], text "a", select all, type "a": deleteBackwardAtStart (selects, then deletes, the last token)` — indistinguishable from a real backspace at start (same output); select all + "b" is an ordinary change `shouldChange(0, 1, "b")`; also with two sentinels.
- Correction: the claimed UIKit behavior ("logs a replacement of range (0, 1) with "a" and keeps the token") is not sampled and is doubtful: 12.5 says UIKit allows a selection spanning tokens and text, so its select-all would cover the token and typing would remove it. The clone bug stands on its own (a text replacement read as backspace-at-start, selecting then deleting a token). Rare trigger.

## Summary
| id | verdict | severity |
|---|---|---|
| C2-m04-ui-01 | confirmed | high |
| C2-m04-ui-02 | partly (also recovers on submit/token change) | medium |
| C2-m04-ui-03 | partly (state/callback divergence real; re-focus+backspace consequence unrecorded) | low |
| C2-m04-ui-04 | partly (sample predates field's last edit; impact transient) | low |
| C2-m04-ui-05 | confirmed | medium |
| C2-m04-ui-06 | partly (lint never runs on host code; heuristic over-accepting, repo test vacuous) | low |
| C2-m04-ui-07 | confirmed (code-derived; defect under either SwiftUI focus behavior) | medium |
| C2-m04-ui-08 | partly (mechanism confirmed; runtime unverified; "recorded, never assumed" is rule 5 only) | medium |
| C2-m04-ui-09 | confirmed | low |
| C2-m04-ui-10 | confirmed | low |
| C2-m04-ui-11 | confirmed | low |
| C2-m04-ui-12 | partly (735 not 802; 18 fail + 2 not-runnable, not 20 fail) | low |
| C2-m04-ui-13 | uncertain (sample suggests UTF-16 indices on 18.6) | low |
| C2-m04-ui-14 | partly (clone bug real; claimed UIKit behavior doubtful) | low |

Repro programs (all outside the repository): m04-ui-skeptic/pagesize.swift, nearest.swift, lint.swift, textlogic.swift, bridge.swift, status.swift, profilediff.py. Nothing was built or run in the repository; no simulator was booted.

STATUS: complete
