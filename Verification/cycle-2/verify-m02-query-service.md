# Cycle 2 — skeptic m02-query-service — verification checkpoint

Method: each finding traced from the public API in the repository sources (read only). Behavioural claims were
re-run on my own copy. The first run (cut off by a usage limit, no verdicts recorded) built under
/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m02-query-service-skeptic.
This resumed run re-copied Sources/ZTronSearchEngine and Sources/ZTronSearchFixtures (diff -r clean against the
repository) to
/private/tmp/claude-501/-Users-admin-Documents-ZTronSearchEngine/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m02-query-service-skeptic/src
and compiled them there with swiftc (-swift-version 6 -enable-testing -Onone, build.sh) into build/*.dylib; drivers
(cdriver.sh) and their outputs (run/*.txt) live in the same folder. Every output quoted below was produced in this
resumed run. Nothing was built, run or changed in the repository; the auditor's drivers were not reused.

(S = /private/tmp/claude-501/-Users-admin-Documents-ZTronSearchEngine/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m02-query-service-skeptic)

---

## C2-m02-query-service-01 — PARTLY (mechanics confirmed in full; severity high, not critical)

Trace: SearchService.init(context:) -> prepare (database context: storage starts as an empty scan, isReady false)
-> detached finishSetup -> startChangeObservers() then rebuild(adoptingPersistedIndex: true) -> rebuildLocked
-> adoptPersistedIndex (SearchService+Context.swift:673-703). `expected` is built with `fingerprint: ""` (675), so
LexicalIndex.validate checks versions/languages/model only; when the adopted count > scanThreshold (or .indexed) the
index becomes storage and rebuildLocked returns at 351-353 without reading any table. TableState.isKnown stays
false, so the first live change on a table runs a full rebuildLocked (apply, 572-575) and heals everything; until
then nothing compares the index with the rows. The design is deliberate (doc at 671-672 "The rows are then not read
at all until something changes"; DatabaseSourceTests.swift:774-778 asserts "rows not re-read"), but it contradicts
the public docs at :6-11 ("waitUntilReady() returns once they are in") and :47 ("Returns once every source of the
context has been read").

Repro (S/f01/driver.swift, S/f01b/driver.swift; outputs S/run/f01-output.txt, S/run/f01b-output.txt), FakeSearchDatabaseConnection, 900 rows:
- .files storage, id "tools-screen": after the first service is released (0 subscribers) the host inserts row 5000
  "Zeppelin Hangar", renames row 1 "Lighthouse Keeper", deletes row 2. Second service: "statements reading tools: 0,
  count 900"; 'zeppelin' -> []; 'lighthouse' -> []; 'tool number 2' top3 -> ["tools#2", ...] (deleted row still
  served). After one live update of an unrelated row: zeppelin found true, 'lighthouse' -> ["tools#1"].
- Same with .database(tablePrefix: "zts"), id "tools-db": identical output.
- Control: 300 rows (automatic -> scan) re-reads the table (1 statement) and is correct.
- Mixed context (one memory tip + 700 rows, .files): launch 2 handed only "tip-new": 'lantern' -> [],
  'bundled' -> ["tip-old"] (the persisted memory item replaces the one handed in).
- .database storage, id .default: a live insert is seen live, but after 3 s and a new launch "reads of tools 0;
  'walrus' -> []" (schedulePersist does not persist id .default, :637); with a named id the next launch finds it.
- Additional, by reading: SearchService.deinit cancels persistTask (SearchService.swift:176), so releasing a context
  within the 1 s debounce after a live change also drops that change from the persisted file.

Spec: section 6 only requires discarding on projection/normalizer/model mismatch; 9.2 rule 6 and 15.9 ("Index round
trip inside the host database ... 250 ms load") make adopting a persisted index to skip row reads an intended
start path, and 9.2 rule 6 assumes the index "commits with the data at sync time". Nothing in 9.2, 16 or 17 says how
commits made while no service listens reach the index, and 9.2 rule 4 (one document set from the sources) plus the
public docs say the rows are what is searched. So: real defect, partly a spec gap.

Severity: high. Silent, persistent across launches, default storage for any named indexed database context, and in
the screen-scoped pattern 9.1 rule 6 encourages the index can stay frozen indefinitely. But no crash, no host data
loss, and it heals on refresh(), a locale change or the first change to that table while a context is alive; the
mixed-context memory-item loss is the clearest outright bug inside it.

## C2-m02-query-service-02 — CONFIRMED (high)

Trace: SearchContext(id:items:) / (id:sources:) default indexStorage = .default = .files(Caches/ZTronSearchEngine)
(SearchContext.swift:24-28, 75). prepare (SearchService+Context.swift:122-141): a memory-only context with
wantsIndex and a non-default id computes fingerprint(of: items) (181-199: id, kind raw value, searchText UTF-8 length,
searchTitle UTF-8 length, updatedAt only) and, when the file validates, memory-maps it and returns without projecting
(needsPersistence false, no background work), so the stale index stays for the life of the service and across
launches. Only the internal doc of the static helper (178-179) mentions "Edits that keep all of them need an explicit
refresh()"; the public SearchIndexStorage/SearchContext docs and README say nothing.

Repro (S/f02/driver.swift, output S/run/f02-output.txt; 600 filler tools + one edited item, id "catalog", .files):
  [keywords alpha -> omega] fingerprints equal: true; second scan=false; adopted 'omega' -> []; fresh build -> ["special"]
  [same-length text edit anchor -> zebras] fingerprints equal: true; adopted 'zebras' -> []; fresh build -> ["special"]
  [same-length title edit] fingerprints equal: true; adopted 'ankor' -> []; fresh build -> ["special"]
  [localization 'it' added (locale it)] fingerprints equal: true; adopted 'mappa' -> []; fresh build -> ["special"]
  [filters ios -> mac] fingerprints equal: true; adopted 'anchor' (platform=mac) -> []; fresh build -> ["special"]
  [searchLanguage en -> it] fingerprints equal: true
  [caption nil -> 'Lantern festival'] fingerprints equal: true; adopted 'lantern' -> []; fresh build -> ["pic"]
  [ocrText nil -> 'Quokka crossing'] fingerprints equal: true; adopted 'quokka' -> []; fresh build -> ["pic"]
  [control: text length change] fingerprints equal: false; adopted 'zebra' -> ["special"]
(The first run's "same-length typo" probe was matched by fuzzy search anyway, so it was replaced by the
anchor -> zebras edit, which is a clean probe.)

Spec: 9.1 rule 6 and section 6 only key the file by contextID/projectionVersion and discard on version mismatch; they
do not license serving an index built from other items than the ones handed in (section 6: the projection of the
same item and locale is the document). A stale filter record also breaks 15.3 "Precision 1.0; no hit may violate a
hard constraint". Severity high: a translation-only or keyword/filter-only app update is a realistic trigger, the
stale file survives in Caches across launches, and there is no public hint to call refresh().

## C2-m02-query-service-03 — PARTLY (test gap confirmed by mutation; severity medium, not high)

Trace: ConcurrencyTests.swift:157-219. Each consumer only sees its own stream; the producer of a stream only ever
emits snapshots of that stream's query and lane generation (SearchService.swift:278-295, 375-383). So
`snapshot.query != expected` and `snapshot.generation != own` (own = first generation seen on the same stream) can
only catch a cross-stream mix-up, never a late publication; the other assertions (published > 0, finals <= changes+20,
generation growth at the probes, last query final) are blind to staleness too. Nothing records the order of a
stream's yields relative to later results(for:) calls.

Repro by mutation (S/f03: driver.swift = the test body with the ledger logic verbatim; RandomCorpus.swift identical to
the test target's, StubSemantic.swift identical apart from one blank line; same seed 2024, 300 items, debounces
0.4/0.8 ms, LexicalIndex service as TestSupport.indexedService). Mutant = my fresh copy with only the
`guard isCurrent(lane) else { return false }` in publish (SearchService.swift:380) replaced by a counter of emits made
after a newer interactive generation exists (S/f03/src-mut, built into S/f03/build-mut; DYLD_PRINT_LIBRARIES confirms
each driver loads its own library). Output S/run/f03-output.txt:
  mutated:    test assertions: mismatched == 0 -> true (0); published > 0 -> true (2228); finals <= changes+20 -> true (1184);
              generation probes failing 0; last final -> true
              ground truth: emits after a newer query was issued = 692
  unmodified: mismatched == 0 -> true (0); published 1541; finals 910; probes failing 0; last final -> true
So the 10,000-change test passes unchanged while the library publishes 692 stale snapshots.
testAnObsoleteProducerNeverYields would not catch this mutant either (its old producer is stopped by the
post-semantic `guard isCurrent(lane)` at :425, which the mutant keeps).

Severity: medium. The production code does enforce the property today (isCurrent is checked with no await before
emit, on the actor), and the UI boundary re-checks revision and query (ZTronSearchResultsModel.swift:131, section 11
rule 6). The defect is that the 15.4 / section 11 gate evidence is vacuous for regressions, not a live stale result.

## C2-m02-query-service-04 — CONFIRMED (medium)

Trace: SearchRowProjector.project (SearchRowProjector.swift:85-156). A literal field assigns only to the base surface
(103-107). A keyed field assigns its first resolved string to the base surface (132-135) AND, for every catalog
language including the base one, writes it into searchLocalizations[tag] (137-146; .text via localizedTexts, 140/155).
SearchProjector.project (SearchProjector.swift:99-113) then lets the "en" localization win under locale en and, since
text != baseText, moves the whole base surface (literal + key string) to localizedAlt (111; keywords 112).

Repro (S/f04/driver.swift, output S/run/f04-output.txt; FakeLocalizedStringResolver [en, it]; locale en, secondary
none; 30 filler tools whose text contains "lanterns" and "beacon"; row context vs memory context with the same filler;
query limit 200):
  text role:     row document text="Frozen Harbor" localizedAlt=["Literal paragraph about lanterns.\nFrozen Harbor"]
                 memory document text="Literal paragraph about lanterns.\nFrozen Harbor" localizedAlt=[]
                 'lanterns': row score 0.01758 rank 31 field localizedAlt | memory score 0.02623 rank 1 field text
  keywords role: row keywords=["sea","ice"] localizedAlt=["lantern, beacon, sea, ice"]; memory keywords all four
                 'beacon': row rank 31 (localizedAlt) | memory rank 1 (keywords)
  control (literal text + keyed title, different roles): identical documents, identical score and rank.
(With a single matching document the fused RRF score is the same, which is why only a competing corpus shows it.)

Spec: 9.2 rule 3 (literals keep their declared language; only the other preferred languages feed localizedAlt — with no
secondary languages nothing should be in localizedAlt) and 15.9 "Ranking of a database row against the same item held
in memory: identical score and order". Both are violated for same-role literal + key mixes. Severity medium: needs
that field layout, but then every literal match of the row is ranked at 0.5 weight.

## C2-m02-query-service-05 — PARTLY (race confirmed; severity low, not medium)

Trace: load(from:) and every finished turn call noteUse() (ChatService.swift:296, 480), which arms idleTask to call
unloadIfIdle(since: use) after idleUnload. send() (377-400) neither bumps `use` nor cancels idleTask; runTurn stays in
lifecycle .ready through ensureLoaded, search.retrieve (all phases, semantic/rerank under their caps), render and
prompt assembly, and only sets .generating at 477. unloadIfIdle (599-602) sees `current == use` and `.ready`, calls
unload(), which cancels every session task (412) and unloads the model; the turn throws at the next
Task.checkCancellation (454/474) and its message is not added to the history (remember() is only reached in the
generation block).

Repro (S/f05/driver.swift, output S/run/f05-output.txt). Realistic window instead of the auditor's slowed countTokens:
FakeLanguageModel/FakeModelAssetProvider from the fixtures, ChatConfiguration(availability: .on, idleUnload: 0.6),
search service with a StubSemantic delayed 0.25 s (below the 300 ms cap):
  race:    send at +451 ms after the load -> "threw CancellationError after 187 ms; sources 0; text: (none)";
           model loadCalls 1 unloadCalls 1 generateCalls 0
  control: send at +103 ms -> finished after 259 ms, 6 sources, "The harbor map."; unloadCalls 0
  control: no semantic delay, send at +471 ms -> finished after 10 ms; unloadCalls 0

Severity: low. The window is the retrieval/assembly time of one turn (about 0.05-0.7 s with semantic and rerank caps)
right at the idleUnload boundary (120 s by default), so only a send landing in that fraction of a second is hit; the
effect is a cancelled turn the user can resend. Spec 14.3/14.4 do imply the model must not be unloaded while a turn
is using it, so it is a real lifecycle race.

## C2-m02-query-service-06 — CONFIRMED (medium)

Trace: (a) load(from:) (ChatService.swift:282-298) suspends in `model.load`; unload() (409-420) meanwhile sees
.loading, calls model.unload() and sets .onDisk; nothing tells the suspended load, which resumes and
settle(.ready(directory)) + noteUse(). (b) ensureLoaded (532-561) loads from .onDisk without setting `preparation`;
prepare() (129-155) falls to `default` for .loading, finds preparation == nil and starts runPreparation, which sets
.onDisk (247) and calls load(from:) again while the first load is in flight.

Repro (S/f06/driver.swift, output S/run/f06-output.txt; FakeLanguageModel load delay 300 ms, availability .on,
idleUnload 0; (a) uses the real memory-warning notification the observer listens for):
  (a) before the warning: lifecycle loading | isLoaded false
      just after the warning: lifecycle onDisk | isLoaded false | unloadCalls 1
      after the load finished: lifecycle ready | readiness ready | runtime isLoaded true | loadCalls 1 unloadCalls 1
      control, warning when ready: lifecycle onDisk | isLoaded false | unloadCalls 2
  (b) after unload: onDisk, loadCalls 1; send -> +100 ms: loading, loadCalls 2; prepare() -> +200 ms: loading,
      loadCalls 3, isLoaded false (both loads in flight); final: ready, loadCalls 3 (2 expected), loadedDirectories 3

Spec: 14.4 / 15.7 ("on a memory warning the LLM unloads before the embedding model"; 1.8 GB resident). A warning
during the ~1 GB weight load is the likeliest moment for one, and it is silently undone; (b) doubles load work and
peak memory. Severity medium as reported.

## C2-m02-query-service-07 — CONFIRMED (medium)

Trace: ChatService.render (ChatService.swift:564-579) builds "[kind:id] title, caption-or-text" and calls
PromptAssembler.truncate (CitationParser.swift:165-180), which keeps the longest prefix of whitespace-separated words
that fits maximumSourceTokens (80). An unspaced caption/text is one word, so it is dropped whole.

Repro (S/f0708/driver.swift, output S/run/f0708-output.txt; the real internal truncate via @testable; token counter =
one token per non-space character as a stand-in for a subword tokenizer on CJK; approx. 4 chars/token for English):
  ja source: 169 chars, 167 tokens -> kept 18 chars, 17 tokens: "[map:harbor] 凍った港,"
  zh source: 122 tokens -> kept 17 tokens: "[map:harbor] 冰冻港口,"
  ja long title: 115 tokens -> kept "[map:harbor]"
  en source: 142 tokens -> kept 80 tokens (278 chars)
The fixtures' FakeLanguageModel counts whitespace words, so ChatTests can never see this.

Spec: 14.3 rule 1 ("caption from its localized surface, at most 80 tokens per source"): the cap holds, but for
Japanese/Chinese (and long Thai runs) the localized caption/text never reaches the prompt although ~60 tokens of the
budget remain. Severity medium: grounded-answer quality (15.7 gate) collapses to titles for those locales.

## C2-m02-query-service-08 — CONFIRMED (medium)

Trace: CitationParser.consume (CitationParser.swift:76-81) re-checks the whole prefix before every ':' with
isKind(pending.dropFirst().dropLast()); for "[map:m:harbor]" the second ':' tests "map:m", which is not a kind, so
the held text is released as plain text; marker(in:) (95-101, split on the first colon) is never reached. Ids with
':' are produced by the engine's own SearchRowIdentity.prefixed (SearchRowProjector.swift:76) and the prompt renders
"[\(kind):\(id)]" (ChatService.swift:565) and tells the model to cite it "exactly as it is written".

Repro (same driver/output, real CitationParser, CatalogKind as the kind check):
  "See [map:m:harbor] and [map:harbor]." sources {m:harbor, harbor} -> [.text("See [map:m:harbor] and "), .citation(harbor), .text(".")]
  "See [tip:tip:42]." sources {tip:42} -> [.text("See [tip:tip:42].")]
  deltas "See [ma" "p:m:har" "bor] now" -> text only, marker leaked
  control "[tool:tools#7]" (default "<table>#<id>" identity) -> .citation(tools#7)

Spec: 14.3 rule 3 (".citation only when the id is in the sources"; markers never in the text) is violated for any
known id containing ':'. Severity medium: no source chips and raw markers in every such answer, for a documented id
scheme.

## C2-m02-query-service-09 — CONFIRMED (medium)

Trace: SearchRowProjector.swift:175 reads updatedAt through SearchBindingValue.dateValue -> SearchDateParser.date
(SearchSQLComposer.swift:190-209), which builds a new ISO8601DateFormatter for each option set it tries, per value.
Reached in the reference setup: SQLite.swift stores Date as TEXT via its global dateFormatter
"yyyy-MM-dd'T'HH:mm:ss.SSS" UTC (Adapters/ZTronSearchEngineSQLite/.build/checkouts/SQLite.swift/Sources/SQLite/Foundation.swift:64-70),
and the adapter maps String to .text (SQLiteBindings.swift:24-25). Such a value costs one construction (the fractional
attempt succeeds); SQLite's CURRENT_TIMESTAMP text "YYYY-MM-DD HH:MM:SS" costs two.

Repro (S/f09/main.swift: SearchDateParser copied verbatim, `diff` of the 20 lines against the repository clean; a
cached-formatter variant for comparison, results checked equal; swiftc -O; Apple M3, load average ~5-6 from other jobs,
so the ratios are the robust part). Output S/run/f09-output.txt, two rounds:
  verbatim, SQLite.swift text:      236-242 us/value (500-row page 118-121 ms)
  verbatim, CURRENT_TIMESTAMP text: 379-381 us/value (page 189-190 ms)
  cached formatters:                55 us/value (page 28 ms) / 104 us/value (page 52 ms)
  10,000 ISO8601DateFormatter constructions alone: 878-883 ms
Against the README's Mac scaling (device budget / 6) a 500-row page has ~6.7 ms here (40 ms on the iPhone 6s); date
parsing alone takes ~120-190 ms, and 10k rows ~2.4-3.8 s on this Mac, before the x6 device factor (budget 1.5 s).
(ISO8601DateFormatter parsing itself is also slow, so caching alone would not reach the budget; the per-value
construction is still the dominant 3.6-4.3x.) Severity medium: performance-budget breach (15.9) for a common column
type of the reference adapter; no functional failure.

## C2-m02-query-service-10 — PARTLY (test gap real, but worse in mechanism and wrong in its failure scenario; severity low)

Trace: ConcurrencyTests.swift:49-79 asserts `worst < 0.010 + full / 4` (confirmed). But `worst` is the time from
task.cancel() to the CONSUMER task's exit; cancelling the consumer ends its `for await` over the AsyncStream at once
(and only then onTermination cancels the producer, SearchService.swift:292), so the value never depends on how long
the producer keeps searching. The loose bound is therefore moot: the assertion cannot fail on producer latency.
testTheScoringLoopChecksCancellation (:82-107) does constrain the spacing, but only to "at least one checkpoint within
the work of a 4,000-item heavy search".

Repro (S/f10: driver.swift = both tests' logic verbatim; driver2.swift adds a producer-side measure, `await
service.count` right after cancel, which queues on the LexicalIndex actor behind the synchronous search; count.swift
counts scoring-loop work units; mutants of my fresh copy change only the three `if work >= 1_000` checkpoints in
IndexSearcher.swift:685/789/852; DYLD_PRINT_LIBRARIES confirms the library per run). Outputs S/run/f10-output.txt,
S/run/f10-driver2-output.txt, S/run/f10-count-output.txt:
  work units of one heavy-query search: 4,000 items (seed 77) = 15,188; 30,000 items (seed 4242) = 95,946
  spacing 1,000 (orig): full 11.8 ms, test worst 0.0 ms -> PASS; scoring-loop test PASS; producer-side worst 4.2-4.9 ms
  spacing 15,000:       full 11.2 ms, test worst 0.1 ms -> PASS; scoring-loop test PASS (both green at 15x sparser)
  spacing 100,000:      test worst 0.0 ms -> PASS; scoring-loop test FAIL; producer-side worst 5.6-8.8 ms
  spacing 1,000,000:    test worst 0.0 ms -> PASS; scoring-loop test FAIL; producer-side worst 8.8-16.6 ms
  test metric (consumer exit) in every build: 0.02-0.09 ms
So the auditor's failure scenario ("every 100,000 keeps both tests green") is refuted: the pre-cancelled 4,000-item
test goes red. Corrected: the latency assertion is vacuous (measures the consumer), and spacing up to ~15,000
postings passes both tests.

Severity: low. The code meets section 11 rule 4 today (checkpoints every 1,000 units; producer-side worst ~5 ms on
this Mac in a debug build), gross regressions are caught by the second test, and the gap is gate evidence (15.4), not
behaviour.

## C2-m02-query-service-11 — CONFIRMED (low)

Trace: SearchRowProjector.swift:116-147 resolves every keyed field in every language the catalog lists and stores each
in searchLocalizations; SearchProjector (SearchProjector.swift:79-138) only reads the active chain, the configured
secondary languages, or all of them only under includesAllLanguages. A locale change re-reads the rows anyway
(RebuildScope.localeChange), so the extra strings are not reused.

Repro (S/fsearch/driver.swift arg "11", output S/run/f11-output.txt; debug build; 2,000 rows x 3 keyed fields;
FakeLocalizedStringResolver = dictionary lookups, i.e. a cached resolver; locale en, no secondary languages):
  2 catalog languages:  ready in 131 / 144 / 130 ms; localizedAlt entries of notes#1: 0
  30 catalog languages: ready in 465 / 355 / 349 ms; localizedAlt entries of notes#1: 0
Linear extra cost (~2.7x here) for strings that are all discarded. Severity low: 15.9 is specified with 2 languages,
and the waste disappears only under SecondaryLanguages that include all languages.

## C2-m02-query-service-12 — CONFIRMED (low)

Trace: SearchRowProjector.swift:157-161 sets the row item's single searchLanguage only when the union of literal tags
and keys' first-resolved languages has one element and no literal is untagged; otherwise nil, and SearchProjector
gives the base-surface fields that nil language (SearchProjector.swift:67, 81-88). DocumentAnalysis passes the field
language to the tokenizer (DocumentAnalysis.swift:30, 110), which uses it for the NLTokenizer language and the
folding locale (SearchTokenizer.swift:61-64, 229-230, 243-244).

Repro (S/fsearch/driver.swift, output S/run/fsearch-output.txt; literal text "L'hôtel près du port gelé." + keyed
title whose catalog base is en):
  literal fr: document.language=en languages.title=en languages.text=nil | 'hôtel' matchedField=text matchedLanguage=nil
  control literal en: languages.text=en | matchedLanguage=en
Spec 9.2 rule 3 ("Literal fields keep their declared language tag") is not met for mixed-language rows. Severity low:
the practical effect is the language hint/folding locale for that field (mostly relevant to segmentation-sensitive
scripts and Turkish/Azeri casing) and a nil matchedLanguage; memory items share the same one-base-language model.

## C2-m02-query-service-13 — CONFIRMED (low)

Trace: the clamps live only in the initializers (RankingProfile.swift:79-82 maximumPins 0...3, 95-98 topN 1...32 and
blend 0...1; SearchEngineConfiguration.swift:54-55 retainedHits >= 1); the properties are public vars and the README
configures profiles by mutation (README.md:137-139). SearchService.swift:449 `semanticRanked.prefix(spec.topN)` and
Fusion.swift:190 `order.prefix(limit)` (limit = retainedHits, SearchPipeline.swift:103) trap on negative values.

Repro (S/fsearch/driver.swift, output S/run/fsearch-output.txt):
  RerankSpec(topN: 64).topN = 32; after `rerank.topN = 64` -> 64; `blend = 5` -> 5.0
  EditorialPolicy(maximumPins: 10).maximumPins = 3; after assignment -> 10
  SearchLimits(retainedHits: -1).retainedHits = 1; after assignment -> -1
  profile.rerank?.topN = 64 with reranking .on: passages sent to the cross-encoder per call = [64] (7.4: at most 32)
  retainedHits = -1, query: "Fatal error: Can't take a prefix of negative length from a collection", exit status 133
  rerank topN = -1, query: same fatal error, exit status 133
Severity low: needs an out-of-range host value, but the documented ceilings are not enforced and bad values crash.

## C2-m02-query-service-14 — CONFIRMED (low)

Trace: rerankPhase accepts any score array of the right length (SearchService.swift:716-719); SearchPipeline.reranked
(SearchPipeline.swift:155-192) min-max normalizes it with no finiteness check; +inf makes (x-min)/(inf-min) = 0 for
every finite score and NaN for itself; a NaN reaches the comparator and the score mapping.

Repro (S/fsearch/driver.swift, output S/run/fsearch-output.txt; internal SearchPipeline.reranked on 5 documents with
fused scores 0.050...0.046, blend 0.7; then end to end with FakeReranker.setScoring returning +inf for passage 2):
  [0.1, 0.9, 0.4, 0.3, 0.2]  -> d1=0.0500 d2=0.0476 d0=0.0470 d3=0.0468 d4=0.0460   (control: d1 leads)
  [0.1, 0.9, inf, 0.3, 0.2]  -> d0=0.0500 d1=0.0490 d2=nan d3=0.0470 d4=0.0460      (rerank lost, NaN)
  [0.1, nan, 0.4, 0.3, 0.2]  -> d0=0.0500 d1=nan d2=0.0830 d3=0.0645 d4=0.0460      (score above the head's top)
  end to end: phase reranked, first scores [0.0262, 0.0258, nan, 0.0249, 0.0245, 0.0241], contains NaN true, degraded []
Severity low: requires a misbehaving cross-encoder (e.g. FP16 overflow), but then the published snapshot carries NaN
and no degraded flag.

## C2-m02-query-service-17 — CONFIRMED (low)

Trace: SearchQuery.limit is a public var (SearchQuery.swift:34, default 20, no validation); snapshot(of:from:isFinal:)
(SearchService.swift:464-479) computes end = min(count, start + max(0, limit)), so with limit 0 end == start and
nextCursor = SearchCursor(offset: start) whenever documents remain.

Repro (S/fsearch/driver.swift, output S/run/fsearch-output.txt; 30-item scan context, query "lantern", limit 0):
  final: hits 0, next cursor offset 0; pages 1-5: hits 0, next cursor offset 0 each; control limit 10: next cursor offset 10
Severity low: a host loop "page until nextCursor is nil" never ends for limit 0 (the UI model's one-page-per-cursor
guard would stop at the repeated cursor instead).

## C2-m02-query-service-19 — PARTLY (dead error case confirmed; the "silent" part is overstated; low)

Trace: `case missingLocalizedStringResolver` (SearchHit.swift:134-135) is the only occurrence in Sources, Tests and
README (grep). With no resolver the projector reports `.unresolvedLocalizationKey` through reporter.debug and indexes
nothing for the field (SearchRowProjector.swift:111-114); testAContextWithoutAResolverIndexesNothingForKeyedFields
(DatabaseSourceTests.swift:334-345) asserts exactly that. But DiagnosticReporter.debug (Diagnostics.swift:33-40) only
limits the os_log line to DEBUG builds and forwards the diagnostic to the host's diagnostics sink in every build, and
spec 9.2 rule 3 itself prescribes this handling for an unresolved key ("indexes nothing for that field and is logged
in debug; the raw key never enters the index"). The spec never names this error case or requires an error; "required
when any field is a localized key" has no stated failure mode, and SearchService.init(context:) is non-throwing.
Corrected description: a public error case documented as reported is dead code, and a missing resolver is only
visible through the diagnostics sink. Severity low (API hygiene / discoverability).

## C2-m02-query-service-15 — CONFIRMED (low)

Trace: ZTronSearch.init (ChatService.swift:679-684) installs `{ await service.unload() }` as the search service's
memoryWarningPredecessor (stored strongly, SearchService.swift:787-789; never cleared), capturing the ChatService
strongly, while ChatService holds `search` strongly (ChatService.swift:26). SearchService -> closure -> ChatService ->
SearchService.

Repro (S/fchat/driver.swift, output S/run/fchat-output.txt; weak references after the facade and locals go out of
scope, 1 s grace):
  with chat true:  predecessor installed true;  search service freed false | chat service freed false
  with chat false: predecessor installed false; search service freed true
Severity low: the facade is documented as wired once (14.1), but 9.1 rule 6 ("releasing the service frees
everything") fails whenever a host builds it per screen/context.

## C2-m02-query-service-16 — PARTLY (mechanism confirmed; impact overstated; low)

Trace: runTurn takes the generation lock (ChatService.swift:435-436), then ensureLoaded parks in
withCheckedContinuation while `preparation != nil` (534-539); waiters are resumed only in runPreparation's defer
(181-187), after the fetch AND the load. Task cancellation does not resume a checked continuation.

Repro (S/fchat/driver.swift, output S/run/fchat-output.txt; FakeModelAssetProvider missing, 4 fetch steps x 0.5 s,
prepare(policy: .allowCellular); session A sends at +100 ms):
  download+load finished at +2063 ms
  session A: cancel(a) at +322 ms -> stream ended at +2063 ms (1741 ms after the cancel): threw CancellationError
  session B (sent right after the cancel): ended at +2063 ms: finished "Hello there."
  consumer-task cancel (the UI model's path) at +316 ms -> consumer done 0 ms later
So the parked turn does hold the lock until the preparation ends, but (1) no session can generate before the fetch and
load end anyway, so B is not delayed at all, and (2) ZTronChatModel.cancel() (ZTronChatModel.swift:125-133) cancels
its own consuming task and clears isGenerating at once. Corrected description: a turn cancelled through
ChatService.cancel(_:) (or superseded) while waiting for a fetch/load keeps its stream open, and the lock, until the
preparation ends; only hosts that wait for that stream's end after cancel(_:) see "stop" lag. Severity low.

## C2-m02-query-service-18 — CONFIRMED (low)

Trace: PromptAssembler.assemble (CitationParser.swift:144-161) sums countTokens(content) per message; the MLX adapter's
countTokens encodes content without special tokens (Adapters/ZTronSearchEngineMLX/.../MLXLanguageModel.swift:293-298),
but the runtime renders the asset's chat template and budgets the reply as
max(0, min(maxNewTokens, contextWindow - promptTokens)) on the rendered prompt (SamplingPlan.swift:173-174), throwing
promptTooLong only past the window. ChatTests.swift:463-494 sums the same content-only counts.

Repro (S/fchat/driver.swift, output S/run/fchat-output.txt; real PromptAssembler, fake word counter, window 4096,
maxNewTokens 512 (GenerationOptions default), margin 64; 60 history messages of 55 words; 6 sources):
  budget 3520; assembled 58 messages (kept history 56, dropped 4); content tokens 3502
  ChatML template (~5 tokens/message + 3) ~293 -> rendered prompt ~3795 > budget by 275; + maxNewTokens = 4307 > 4096
  adapter reply budget = 301 tokens instead of 512
Spec 14.3 rule 2 (prompt inside contextWindow - maxNewTokens - 64) is not met for the rendered prompt once the history
has more than ~12 messages; the window itself is still guarded by the adapter, so the effect is a shortened reply in
long sessions. Severity low.

---

## Summary (auditor severity -> skeptic verdict / severity)

| id | auditor | verdict | severity | note |
|----|---------|---------|----------|------|
| 01 | critical | partly | high | all mechanics reproduced; self-heals on refresh()/first live change; spec gap on offline commits |
| 02 | high | confirmed | high | 8 fingerprint-invisible edits reproduced, incl. localizations and filters |
| 03 | high | partly | medium | mutation: 692 stale emits, test green; code and UI boundary enforce it today |
| 04 | medium | confirmed | medium | row rank 31 vs memory rank 1 |
| 05 | medium | partly | low | race reproduced with a realistic semantic delay; sub-second window at the 120 s boundary |
| 06 | medium | confirmed | medium | warning during load undone; double load |
| 07 | medium | confirmed | medium | CJK caption dropped whole |
| 08 | medium | confirmed | medium | ids with ':' leak as raw markers |
| 09 | medium | confirmed | medium | 236-380 us/value; 3.6-4.3x from constructions |
| 10 | medium | partly | low | latency assertion measures the consumer (always ~0); 100,000 spacing is caught by the other test; ~15,000 passes both |
| 11 | low | confirmed | low | 2.7x for 30 vs 2 catalog languages |
| 12 | low | confirmed | low | languages.text nil, matchedLanguage nil |
| 13 | low | confirmed | low | clamps bypassed; 64 passages; negative values trap (exit 133) |
| 14 | low | confirmed | low | NaN in a published reranked snapshot, degraded [] |
| 15 | low | confirmed | low | neither service freed with chat wired |
| 16 | low | partly | low | parked turn real; no extra delay for other sessions; UI stop is immediate |
| 17 | low | confirmed | low | cursor offset 0 forever |
| 18 | low | confirmed | low | rendered prompt 275 over budget; reply capped at 301 of 512 |
| 19 | low | partly | low | dead error case; diagnostic still reaches the sink; spec rule 3 prescribes the drop |

No finding was refuted. Every behavioural claim was re-run in this resumed run from my own drivers under S.

STATUS: complete
