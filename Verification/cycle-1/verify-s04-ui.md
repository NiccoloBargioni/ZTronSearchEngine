# Cycle 1 — skeptic verification of slice s04-ui (spec sections 12 and 13)

Skeptic: s04-ui-skeptic. Method: open every cited location, re-read the spec text (pp. 25-36, 15.7 p45,
16 pp47-49, 17 pp50-51), look for handling elsewhere, write standalone probes in
/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s04-ui-skeptic/.
Repository not modified (this file only). No build/test in the repo, no simulator.

## Verdicts (written as I go)

### C1-s04-ui-01 — Parity gate not met; most of the matrix never ran
- Verdict: CONFIRMED. Severity: high.
- Checked: re-tallied ParityHost/Results/summary.csv (7,440 rows: 179 pass, 602 fail, 6,659 not-runnable;
  15.5 and 16.4: 3,200 not-runnable each). Ran a scratch copy of ParityHost/Tools/gate.py (+summarize.py)
  against the committed results: "16000 cells: 179 pass, 602 fail, 6659 not-runnable, 0 not-applicable,
  8560 missing", exit 1 ("the gate is closed"). Passing cells by axis: rtl 0, bold-text 0, iPhone SE 0,
  iPad 0, iOS 27.0 0, and also XS/XXXL/AX5 0 (only L passes). AX5 type images viewed: equal token frames,
  map symbol and "M..." shifted ~24 px (8 pt @3x) toward the trailing side in the clone. XS initial
  1.556%/dE 27.96, XXXL dE 7.50 (summary.csv / type.json) as stated.
- Spec: 12.5 p31-32 and 15.7 p45 ("any other difference fails the build"); 17 p51 milestone 4 gate is
  "section 15.7 thresholds on the full 12.5 matrix". Nothing in 16 or 17 relaxes it.
- Mitigating detail (does not refute): README.md:216-218 discloses "The parity gate of section 15.7 is not
  met yet"; the 6,400 iOS 15.5/16.4 cells are blocked by the host (runtimes unsupported after macOS 26.99),
  not by clone code, and 8,560 further cells were never attempted. The 602 failures are real differences.

### C1-s04-ui-02 — Metrics/behavior sampled only for iOS 17 and 18, nearest-version fallback elsewhere
- Verdict: CONFIRMED. Severity: high.
- Checked: ZTronSearchFieldMetrics+Sampled.swift:8 `sampledVersions: [Int] = [17, 18]`, :394-400 behavior
  table has only 17 and 18; ZTronSearchFieldMetrics.swift:224-241 nearestSampledVersion / metrics(forMajorVersion:)
  and :271-273 behavior(forMajorVersion:) return the nearest sampled version's record; the field reads them
  with runningMajorVersion (ZTronSearchField.swift:70 and :581). Package floor is .iOS(.v15) (Package.swift:12).
  ParityHost/Samples holds only ios-17.json and ios-18.json. So iOS 15/16 get iOS 17's metrics and
  clearRemovesTokens/clearBeginsEditing/etc.; iOS 26/27 get iOS 18's.
- Spec: 12.2 rule 5 p28 ("recorded by the parity suite, never assumed"), 12.4 p31 ("sampled per iOS version",
  "re-samples them on every iOS release"). Not relaxed in 16/17.
- Extra evidence: ios-27.0/iPhone-15/light/L/ltr/software/type initial-reference.png vs initial-clone.png:
  the iOS 27 reference is a 44 pt capsule field with a dark bold glyph; the clone draws the iOS 18 36 pt
  rounded field (metrics: field.height 44 vs 36, glyph.x 12 vs 6, token.0.x 41.3 vs 33; pixels 98%).
- Nuance: on iOS 15/16 nobody has observed whether UIKit actually differs from iOS 17 (host cannot run
  those runtimes), so the user-visible effect there is unknown; on iOS 26/27 it is visible and large.

### C1-s04-ui-03 — Host cannot override the return-key label
- Verdict: CONFIRMED. Severity: medium (it is the only counterpart of UIKit's returnKeyType in the 12.3 map).
- Checked: ZTronSearchField.swift:342 applies `.submitLabel(.search)` directly on the inner TextField; no other
  submitLabel/returnKey handling anywhere in Sources/ (grep). Independent probe
  s04-ui-skeptic/submitlabel/main.swift (macOS SwiftUI): `type(of: Text("x").submitLabel(.go))` is
  `ModifiedContent<Text, _EnvironmentKeyWritingModifier<SubmitLabel>>`, i.e. an environment write; a view
  under inner .search and outer .go sees SubmitLabelKey search first, and the control
  `.submitLabel(.send).submitLabel(.go)` shows send first, confirming the innermost write is the effective one.
  So `ZTronSearchField(...).submitLabel(.go)` is shadowed by the field's own .search.
- Spec: 12.1 p27 ("the field applies .submitLabel(.search) by default and the host may override it");
  12.3 p30 maps returnKeyType to .submitLabel(_:). Not relaxed elsewhere.

### C1-s04-ui-04 — Smart-punctuation emulation rewrites pre-existing typographic characters
- Verdict: CONFIRMED (title slightly overstated). Severity: medium.
- Checked: ZTronSearchFieldCore.swift:228 `var proposed = Self.plain(Self.strip(raw))` on every input change;
  plain() (:91-105) maps U+2018/2019, U+201C/201D, U+2014, U+2013 anywhere in the text; :241 diffs the old
  text against that. Host text enters the core unfiltered through adopt() (:180-188, via
  ZTronSearchField.swift:647-653), so typographic characters can be present. The reference sets
  smartQuotesType/smartDashesType = .no (ParityHost/.../ReferenceField.swift:45-46) and so keeps them.
  Independent replica s04-ui-skeptic/plain/ (plain() and ZTronTextChange copied verbatim):
  "l’arme"+"s" -> binding "l'armes", shouldChange(1, 5, "'armes"); "Assassin’s Creed"+" " ->
  shouldChange(8, 8, "'s Creed "); "A"+pasted "—" -> "A--"; "„Zeit“" -> "„Zeit\"" (mixed);
  ASCII control "abc"+"d" -> (3, 0, "d"). Only test: SearchFieldCoreTests.swift:105, typed input only.
- Spec: 12.1 p27 (smart quotes/dashes off), 12.3 p30 (same payloads as UIKit), 12.2 rule 12.
- Correction to the title: the rewrite is not of "the whole text on every keystroke"; plain() scans the whole
  text each change but only changes it when such characters are present, so the rewrite happens once, on
  the first change after they appear. Description and failure scenario are otherwise accurate.

### C1-s04-ui-05 — pageSize set mid-search keeps the previous query's hits; reset() drops pageSize
- Verdict: CONFIRMED. Severity: medium.
- Checked: ZTronSearchResultsModel.swift:78-81 setter writes `query.limit` only (no revision bump, no restart);
  SearchQuery is Hashable with synthesized == that includes `limit` (Contracts/SearchQuery.swift:24-35);
  service snapshots carry the query they were started with (SearchService.swift:469-470 `query: state.query`);
  apply() drops on `snapshot.query == query` mismatch (:131); streamEnded clears isLoading (:149-152);
  update() copies the current limit and returns early on equality (:65-70); reset() builds
  `SearchQuery(text: "")` (:89), default limit 20 (SearchQuery.swift:34).
  Independent replica s04-ui-skeptic/pagesize/main.swift: "dropped snapshot for Query(text: harbor, limit: 20)",
  hits stay ["hits for lantern/20"], isLoading false, query harbor/50; update(harbor) does not restart;
  after reset pageSize = 20; control: a change made while idle takes effect with the next query.
- Spec: 13 p34 (snapshot applied only for the current query; isLoading until the final snapshot or a
  cancellation). pageSize itself is an extra API not in the spec's p33 listing, and its doc comment says
  "Changing it takes effect with the next query", which the mid-flight case contradicts.
- Notes: submit() would also recover (it restarts with the current query). The reset() half is the more
  likely trigger in practice: the spec's own minimal host calls results.reset() from onSearchCancel (p29),
  so a host that set pageSize silently returns to 20 after the first Cancel.

### C1-s04-ui-06 — Attach lint is repository-global, any .environmentObject( silences it, in-repo run vacuous
- Verdict: CONFIRMED. Severity: medium.
- Checked: Sources/ZTronSearchFixtures/SourceLint.swift:222-227: per model, `attached` is true if ANY scanned
  file contains one of its modifiers OR the text `.environmentObject(` (any object). LintTests.swift:154-161
  scans ParityHost and Examples. Probe s04-ui-skeptic/attachlint/ compiles the real SourceLint.swift verbatim:
  detail reader alone -> ["Detail.swift:2"]; + another screen attaching -> []; + unrelated
  `.environmentObject(appSettings)` -> []; detail + chat reader + unrelated env -> [] (the one unrelated
  injection silences every model); detail + chat reader + catalog -> ["Chat.swift:2"]. Examples has 0 files
  (directory absent); ParityHost has 33 Swift files, 0 contain @EnvironmentObject, 0 findings.
- Spec: 13.1 rule 3 p36; 16 p49 ("a screen that reads a model through @EnvironmentObject without an attaching
  modifier fails the lint test"). The synthetic positive test (LintTests.swift:114-152) passes, so the lint
  catches only the case where nothing in the scanned sources attaches or injects anything.
- Nuance: a text lint cannot know view ancestry, so some global approximation is unavoidable, and the in-repo
  run being empty follows from section 13 (no screens ship). The substantive defect is the
  any-`.environmentObject(` rule, which disables the check in practically every real host app.

### C1-s04-ui-07 — Bold Text not modelled
- Verdict: PARTLY. Severity: medium.
- Real: metrics are looked up by iOS version and content size only (ZTronSearchFieldMetrics.swift:237-240;
  ZTronSearchField.swift:69-71); nothing in Sources/ZTronSearchEngineUI reads legibilityWeight (grep). All 62
  bold-text cells fail; at L/LTR on iPhone 15 (17.5 and 18.6, 36 cells) every one fails pixels and metrics
  while event log, accessibility and state pass; worst metric 1.0 pt (token-overflow 5.67 pt), pixels
  1.5-3.98% (token-overflow ~15.5%). 18.6 type.json: clearButton.y 7.67 vs 8.67, clearButton.height 20 vs 19,
  glyph.height 19.33 vs 18.67, token.0.width 73 vs 73.67, 2.67% / dE 28.75, as stated.
- Off: the clone DOES render Bold Text: ios-18.6/iPhone-15/bold-text/L/ltr/software/type/initial-clone.png shows
  bold "Maps", bold map symbol, bold glyph and clear symbol, like the reference. SwiftUI applies the
  legibility weight to `.system(size:)` fonts, so the fixed-size fonts are not the cause and switching to
  `.body` would not by itself fix anything. What is missing is bold-specific geometry (glyph and clear-button
  frames, token width). And UIKit does not "enlarge the token text": the reference token is narrower
  (73 vs 73.67).
- Corrected description: the sampled metrics have no Bold Text variant, so under Bold Text the clone's glyph,
  clear-button and token frames keep the regular-weight geometry and differ from UIKit by up to ~1 pt (5.67 pt
  after token overflow), failing every bold-text cell; the weight itself is applied.

### C1-s04-ui-08 — Metrics capture records the reference's undrawn glyph at accessibility sizes
- Verdict: PARTLY. Severity: low.
- Real mechanism: ReferenceField+Layout.swift:10-12 takes the first UIImageView with no visibility test
  (clearButton/cancelButton use isVisible, :14-36); :111 records it; MetricsComparator.swift:52-55 and :81
  fail any "(reference only)" frame. ReferenceSampler.swift:165-168 records glyphShownWithContent 0 for
  accessibility1-5 (Samples/ios-18.json), and the clone omits the glyph then (ZTronSearchField.swift:125-127,
  :141-142). AX5 type images: no glyph in either.
- Off: the reference's glyph is not gone at those sizes, only undrawn. In every one of the 122 iPhone 15 AX5
  checkpoints that report "glyph (reference only)", the accessibility comparator also reports the reference's
  `Image label="Search" identifier="magnifyingglass"` node that the clone lacks (exact same count, 122/122;
  XCUITest snapshot via ParityRemote.swift:241-264). The harness's metrics capture is therefore consistent with
  the reference's accessibility tree, and the clone differs from UIKit there regardless (15.7: accessibility
  trees identical). A clone that matched the reference tree (an undrawn but accessible glyph) would report a
  glyph part (CloneField.swift:157) and the comparator would compare frames instead of failing "missing".
  So "even a pixel-perfect clone fails" and the test-integrity framing are not established. Also the AX5
  cells fail metrics on other values (baseline 72, token heights 46+ checkpoints), pixels and accessibility,
  so the capture changes no gate outcome today.
- Corrected description: the reference capture and the sampler disagree on whether the glyph "exists" at
  AX sizes with content (sampler: not shown; capture: present). The reference keeps the glyph as an
  accessibility element while not drawing it; the clone drops it entirely. Which side to change is open; as
  written, the failure points at a real accessibility-tree difference in the clone, not only at the harness.

### C1-s04-ui-09 — No RTL (Arabic) cell passes: English clear/Cancel labels, tokens 2 pt shorter
- Verdict: PARTLY. Severity: medium.
- Confirmed: 0 of 315 RTL results pass (summary.csv). On iPhone 15 L RTL (17.5/18.6), failures are dominated by
  token.0.height/token.0.y (230 checkpoints) and the clear-button label (reference "مسح النص", clone
  "Clear text"; Cancel "إلغاء" vs "Cancel"). Token height is fixed by English-sampled metrics:
  ZTronSearchField.swift:508 `.frame(height: metrics.tokenHeight)` (24.33 at L) while the Arabic-locale
  reference token is 26.33.
- Not established: that the package mislocalizes in real apps. The strings are looked up with
  Bundle.module.localizedString (ZTronSearchField.swift:768-773, ZTronSearchFieldCore.swift:509-524) and
  Localizable.xcstrings has the Arabic values. Probe s04-ui-skeptic/l10n/ loads the built UI resource bundle
  (DerivedData .../Debug/ZTronSearchEngine_ZTronSearchEngineUI.bundle) with -AppleLanguages (ar): with a main
  bundle that declares no Arabic, preferredLocalizations = ["en"] and the lookup returns English; with a main
  bundle whose Info.plist declares CFBundleLocalizations [en, ar] (as ParityHost/App/Support/ParityHostApp-Info.plist
  does), it returns "مسح النص", "إلغاء", "بحث". So the lookup code works; why the iOS host build shows English
  (iOS packaging of the string catalog, the generated Info.plist, project knownRegions = (en, Base)) is unknown,
  and no iOS build product exists on this Mac to inspect.
- Corrected description: RTL cells fail because the clone's token geometry is sampled under English only
  (2 pt shorter than UIKit in Arabic; a real clone limitation), and because in the parity host build the clear
  and Cancel labels came out English. The second may be a host build/packaging artifact; the failure scenario
  about Arabic VoiceOver users in real apps is unverified.

### C1-s04-ui-10 — With an editingPolicy, the host's .focused cannot start editing
- Verdict: CONFIRMED by code (runtime not observed). Severity: medium.
- Checked: ZTronSearchField.swift:29 `allowsInput` starts true but synchronize() (:647-653, run onAppear :84)
  sets it to `editingPolicy == nil || core.isEditing`, i.e. false with a policy while idle; :345
  `.disabled(!allowsInput || !isEnabled)` on the inner TextField; the only code that enables it and asks the
  policy before focus is requestFocus() (:691-699), reached from the tap gate (:484-490), token taps (:668-677)
  and taps outside tokens (:679-682). focusChanged (:701-736) consults the policy only after focus has already
  arrived (:713-717). Nothing observes a host focus request (the host's FocusState is outside the field), so with
  the inner input disabled no focusable descendant exists for the host's `.focused` to land on (UITextField
  refuses first responder while disabled), and the policy is never asked. No unit test or parity script sets
  editingPolicy except the core-only SearchFieldCoreTests.swift:479; CloneField sets none.
- Spec: 12.1 p27 (".focused($isFocused) works directly"), 12.3 p30 (policy evaluated before the inner input is
  enabled; UIKit's becomeFirstResponder asks textFieldShouldBeginEditing). Not relaxed elsewhere.
- Residual uncertainty: the end-to-end symptom (keyboard never appears, host binding falls back to false) was not
  observed on a device or simulator; it follows from the disabled input plus standard UIKit/SwiftUI focus rules.

### C1-s04-ui-11 — README overstates where the field matches the reference
- Verdict: CONFIRMED. Severity: low.
- Checked: README.md:216-218 "the field matches the reference on iOS 17.5 and 18.6 on 3x iPhones, left to right,
  at the default content size, and is outside a threshold elsewhere." Tally of summary.csv at L/LTR on
  iPhone 15 and 15 Pro Max for 17.5/18.6: bold-text 18 fail + 2 not-runnable per version on iPhone 15;
  light/dark/increased-contrast/reduce-transparency 18 pass + 2 not-runnable per group (hardware
  backspace-delete/backspace-select: XCUITest did not deliver the delete key); iPhone 15 Pro Max ran light only
  (17.5: 18 pass; 18.6: 17 pass, 1 fail = hardware type, state "mp" vs "map", the reference lost a keystroke).
- Extra inaccuracy: "outside a threshold elsewhere" is also wrong for most of "elsewhere": 6,659 cells could not
  run and 8,560 were never attempted, so they are unproven rather than out of threshold.

### C1-s04-ui-12 — Token drawn as a radius-4 rounded rectangle, not a capsule
- Verdict: CONFIRMED as spec-text drift. Severity: low (the code is right; the spec text is wrong).
- Checked: ZTronSearchField.swift:508-510 `RoundedRectangle(cornerRadius: metrics.tokenCornerRadius, style:
  .continuous)`; every sampled size on 17 and 18 has tokenCornerRadius 4, tokenCornerCurve continuous
  (Samples/ios-17.json, ios-18.json; 25 table entries in ZTronSearchFieldMetrics+Sampled.swift). No `Capsule`
  anywhere in Sources/ZTronSearchEngineUI. Reference images (18.6 AX5, bold-text, 27.0) show UIKit tokens as
  small-radius rounded rectangles, so a Capsule would itself break 12.2 rule 12 and 15.7.
- Spec: 12 p25 ("built from TextField, Capsule, ...") and 12.4 p31 table ("Token: capsule") conflict with 12.4's
  own rule that defaults are sampled from UIKit. Extra: README.md ("The field is SwiftUI only: TextField,
  Capsule, FocusState and an asset catalog") repeats the claim though the code uses no Capsule.

### C1-s04-ui-13 — A stream that ends without a final snapshot leaves stale or partial hits
- Verdict: PARTLY. Severity: low.
- Real (by reading): service cancel paths end the stream without a final snapshot: setLocale -> cancel()
  (SearchService.swift:892-903, :311-316), triggered by NSLocale.currentLocaleDidChangeNotification when
  followsSystemLocale (default true, SearchEngineConfiguration.swift:158; observer :800-801); the producer task
  then calls continuation.finish() (:284-288). A thrown lexical search returns silently (:397-401). The model's
  loop then ends normally and streamEnded() only clears isLoading (ZTronSearchResultsModel.swift:149-152);
  error is set only by page failures (:194-205); update() with the same text returns early (:65-70). Hits stay
  at the last applied snapshot of this query (lexical, non-final) or at the previous query's hits.
- Off: the spec basis is weaker than stated. 13 p34 says isLoading is true "until the final snapshot or a
  cancellation", and p25 requires search tasks to be cancelled on locale change, so isLoading=false after the
  service cancels is what the spec prescribes; the spec defines no recovery. The defect is robustness (no
  re-run or indication; the same text cannot re-trigger, only an edit or submit() recovers), and the trigger is
  rare (a resolved-language change during an in-flight search, or a lexical error).

### C1-s04-ui-14 — The spec's minimal host does not type-check against textToToken
- Verdict: PARTLY. Severity: low.
- Real: probe s04-ui-skeptic/texttotoken/ mirrors SearchSchema, ZTronSearchToken and the exact signature of
  ZTronSearchFieldEnvironment.swift:120; the spec's closure (p29) fails with "generic parameter 'Schema' could not
  be inferred"; the same closure with `ZTronSearchToken<CatalogSchema>(...)` type-checks. Same shape for
  onTokenDelete (:125) and tokenCopyProvider (:134).
- Off: the code implements the spec's own declaration. 12.1 p26 declares `textToToken(_ rule: @escaping (String) ->
  ZTronSearchToken<Schema>?)` inside `extension View`, where Schema can only be a generic parameter of the method,
  and the example chains it after `.focused/.onSubmit/.onSearchCancel` (which return `some View`), so no
  implementation of that declaration can make the example compile: `.filter($0)` constrains only Schema.Filter.
  This is a defect of the spec's example, not of the implementation. README's field example does not use
  textToToken.

## Summary

| ID | Verdict | Severity |
|---|---|---|
| C1-s04-ui-01 | confirmed | high |
| C1-s04-ui-02 | confirmed | high |
| C1-s04-ui-03 | confirmed | medium |
| C1-s04-ui-04 | confirmed (title overstated) | medium |
| C1-s04-ui-05 | confirmed | medium |
| C1-s04-ui-06 | confirmed | medium |
| C1-s04-ui-07 | partly (the clone does render Bold Text; bold-specific geometry is what is missing) | medium |
| C1-s04-ui-08 | partly (reference glyph is still an accessibility element; clone omits it) | low |
| C1-s04-ui-09 | partly (token geometry real; English labels unexplained, lookup code works) | medium |
| C1-s04-ui-10 | confirmed by code, runtime not observed | medium |
| C1-s04-ui-11 | confirmed | low |
| C1-s04-ui-12 | confirmed as spec-text drift (code follows UIKit) | low |
| C1-s04-ui-13 | partly (isLoading=false on cancellation is what 13 prescribes; robustness gap) | low |
| C1-s04-ui-14 | partly (defect of the spec's example; code implements the spec's declaration) | low |

Probes (all outside the repository):
/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s04-ui-skeptic/
gate/ (copy of gate.py + summarize.py), submitlabel/, plain/, pagesize/, attachlint/ (real SourceLint.swift),
l10n/ (built UI resource bundle, Arabic lookup), texttotoken/.

STATUS: complete
