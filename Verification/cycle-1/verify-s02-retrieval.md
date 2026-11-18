# Cycle 1 — s02-retrieval skeptic verification (spec sections 7 and 8)

Skeptic checkpoint. Commit cee4620. Paths are relative to /Users/admin/Documents/ZTronSearchEngine unless absolute.

Scratch (independent of the auditor's programs): /private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s02-retrieval-skeptic/
- skeptic_main.swift, compiled with an unmodified copy of Sources/ZTronSearchEngine (src/, 40 files) by
  `swiftc -swift-version 6 -Onone -parse-as-library -module-name SkepticCore -o skeptic $(find src -name "*.swift") skeptic_main.swift`.
- Outputs: out_semfilter.txt (finding 01), out_f02.txt (02), out_f03.txt (03), out_f04_f05.txt (04, 05).
Spec re-read: pages 9-16 (sections 5-9), 17-19 (9.1), 23-24 (10), 42-48 (15, 16), 50-51 (17).

Summary: 01 partly (medium), 02 confirmed (medium), 03 partly (low), 04 partly (low), 05 confirmed (low).

## C1-s02-retrieval-01 — semantic channel filters after ANN retrieval in indexed contexts
Verdict: partly. Severity: medium (auditor: high).

What holds:
- SearchService.swift:557-558 asks `semantic.nearest(to:limit:)` for `min(50*4, max(50,200))` = 200 neighbours when the query has kind/filter/phrase constraints; SemanticBoundary.swift:33 takes no constraint; LexicalIndex.swift:293-317 (`resolve`) drops violators afterwards and keeps at most 50. The design is deliberate and documented (SearchEngineConfiguration.swift:33-36, SearchService.swift:554-556), but it contradicts section 8 p14: "Filters and kind tokens are hard constraints applied before retrieval". The lexical channel does pre-filter (IndexSearcher.swift:687, 791, 856), so only the semantic channel is affected.
- HNSWGraph.search (Semantic/HNSW/HNSWGraph.swift:192) raises ef to max(ef, limit) = 200, so constrained queries also do about 3x the efSearch=64 work of section 7.3 / the "50 HNSW neighbours" of section 10.
- No fallback exists: no constrained or exhaustive path is used by core for indexed contexts.
- ScanEngine.nearest (Scan/ScanEngine.swift:335-361) sorts every vector and skips violators until the limit, i.e. it effectively pre-filters.
- Independent reproduction with random 16-D unit vectors and an exact brute-force SemanticSearching fake (best case for ANN); free text "ocean sunset" matches nothing lexically, kinds [.e]:
  - n=2000, e share 1%: indexed 2 semantic hits (2/20 of the ideal), scan 20/20
  - n=2000, 5%: indexed 13/50, scan 50/50
  - n=2000, 20% (a kind chip in a 5-kind catalog): indexed 37/50, scan 50/50
  - n=10000, 1%: indexed 1/50, scan 50/50
  - unconstrained control: nearest(limit:) asked [50]
  Survivors are about 200 x share, so the loss is real for every constrained semantic query and near-total for selective ones (empty when more than 200 non-matching items outrank every match).
- No test covers recall under constraints (SnapshotPipelineTests.swift:53 checks precision only; StrategyParityTests.swift:16 runs without a semantic channel).

What is off:
- The parity framing overreaches. Section 9.1 rule 3 and section 16 state scan/indexed identity for "the same BM25F formula, field weights, fuzzy limits and RRF"; rule 4 makes the scan semantic channel brute force "never HNSW", so semantic lists are not required to equal HNSW output. The divergence shown is real, but it is a symptom of the pre-filter deviation, not a separate parity violation.
- Severity. No hit ever violates a constraint (section 15.3 "Filter and kind tokens: precision 1.0" holds), the lexical and fuzzy channels are pre-filtered, and a visible first-page loss needs a constrained subset below roughly 10% of an indexed corpus together with a query whose words do not occur in the matching items (20 semantic survivors need 200 x share >= 20). Balanced kind chips (about 20%) keep their top ~40 semantic hits. That is a moderate recall defect in a specific scenario, not a high one.

Corrected description: in indexed contexts the semantic channel applies kind, filter and phrase constraints after an unconstrained ANN fetch of 200 neighbours (ef 200), contrary to section 8's "applied before retrieval"; constrained semantic recall drops to about 200 x (constrained share) items, which empties the semantic list for selective constraints (1% share: 1-2 hits instead of up to 50). Precision and the lexical/fuzzy channels are unaffected. Medium.

## C1-s02-retrieval-02 — RankingProfile caps enforced only in initializers
Verdict: confirmed. Severity: medium.

- RankingProfile.swift:75, 90, 92 are plain `public var`s with no didSet; the clamps live only in the inits (78-80, 94-97). Consumers read the stored values: Fusion.swift:197/205 (`maximumPins`), SearchService.swift:449 (`prefix(spec.topN)`), SearchPipeline.swift:156/165 (`topN`, `blend`).
- The engine does clamp other bounded profile values at use: `kindBoost(for:)` (RankingProfile.swift:166-169), affinity (Fusion.swift:239), popularity weight (Fusion.swift:258). Pins, topN and blend are the inconsistent ones.
- The spec anticipates configuration and caps it: section 7.4 p13 "top 16 fused hits ... (configurable, at most 32)"; section 8 p15 pins "limited to 3 per query so they cannot hide organic results". The spec's own struct shape uses `public var editorial` / `public var rerank`, and the tests use the mutate-a-copy idiom (CoreCorrectnessTests.swift:302-304 for kindBoosts).
- Independent end-to-end reproduction through SearchService (out_f02.txt):
  - `profile.editorial.maximumPins = 6` -> 6 leading pinned hits (default profile: 3)
  - `profile.rerank?.topN = 100`, reranking .on, 60 lexical hits -> one reranker call with 60 pairs, 60 hits carry .rerank
  - `profile.rerank?.blend = 2` with an indifferent cross-encoder -> the reranked head is the exact reverse of the semantic head (blend 0.7: unchanged)
  - Additional consequence the auditor did not report: `profile.rerank?.topN = -1` crashes at SearchService.swift:449 ("Can't take a prefix of negative length", exit 133); `topN = 0` silently degrades rerank.
- Only RankingTests.swift:64-65 (init path) covers the clamps.
Medium stands: explicit spec caps are bypassed through the idiomatic, spec-shaped API with plausible values (5 pins, topN 64). Mitigation: an over-large topN that breaches 400 ms is contained by the hard cap and 3-breach disable, which turns it into a lost rerank stage rather than a latency problem.

## C1-s02-retrieval-03 — SearchLimits setters bypass init clamps
Verdict: partly. Severity: low (auditor: medium).

- Mechanism confirmed. SearchEngineConfiguration.swift:28-40 are `public var`s; clamps only in init (50-55); SearchPipeline.swift:76, 101, 103 pass them through. IndexSearcher.swift:673-674 sizes `slots` to `limit` (grow-only, prepareScratch 731-742) and admitCandidates writes `slots[slotCount]` (796) before the `slotCount >= limit` check (799); Fusion.swift:82 and 190 call `prefix` with the raw values.
- Independent reproduction (out_f03.txt), 10 indexed items, query "lantern": `lexicalCandidates = 0` -> "Index out of range", exit 133; `fusionEntriesPerChannel = -1` and `retainedHits = -1` -> "Can't take a prefix of negative length", exit 133; `retainedHits = 0` and `fusionEntriesPerChannel = 0` -> 0 hits; `semanticNeighbours = 0` -> harmless.
- Description detail: the out-of-range access at IndexSearcher.swift:796 is a write, not a read.
- Severity: the spec (section 10 bounded work, section 8) gives these as fixed engine bounds and says nothing about host configuration of them; the trigger is a zero or negative value assigned through the setter (the init path clamps); the failure is a deterministic crash on the first query, so it surfaces at once in development. A robustness gap with an unlikely trigger, not a spec deviation: low.

## C1-s02-retrieval-04 — 1-2 character CJK/Thai queries run semantic and rerank
Verdict: partly. Severity: low (auditor: medium).

- Confirmed: SearchPipeline.swift:62-63 makes a query semantic-eligible when `characterCount >= minimumSemanticQueryLength || containsUnspacedScript` (QueryParser.swift:58-59). rerankAvailability (SearchService.swift:646) follows semantic eligibility.
- Spec: section 9 snapshot rule 2 (p16) "skipped, with degraded set, when the query is shorter than 3 characters"; section 10 (p23) "Queries shorter than 3 characters, or made only of tokens, skip the semantic and rerank phases". Neither section 5 (rule 5 CJK bigrams), 16 (CJK bigram/prefix tests) nor 17 grants an unspaced-script exception. The config's own doc comment (SearchEngineConfiguration.swift:133-134) also states the rule without the exception, unlike the lexical minimum (130-131).
- Independent reproduction (out_f04_f05.txt), reranking .on: '東' (1), '東京' (2), 'ตล' (2), 'a 東' -> encodeQuery 1, rerank 1, snapshots lexical -> semantic -> reranked, no degraded; 'ab' -> 0 encodes, single final lexical snapshot, degraded [rerank, semantic].
- No test asserts either behaviour for short unspaced queries (CoreCorrectnessTests.swift:102 and InternationalizationTests.swift:178 check lexical hits only).
- Severity: the extra work is one query embedding behind the same 300 ms pause and 300 ms hard cap that bound every semantic query (and one rerank on gated devices). The model loads lazily for any semantic query, so the "loads the 80 MB model" consequence is not specific to short queries. The spec gives no rationale for the 3-character rule, and the exemption mirrors the deliberate unspaced-script exemption of the lexical minimum. Real deviation from an explicit rule, small cost: low.

## C1-s02-retrieval-05 — rerank passage of untitled unspaced text is the whole text
Verdict: confirmed. Severity: low.

- SearchPipeline.swift:196-200 splits on whitespace and keeps 64 pieces; unspaced text has no whitespace, so the passage is the whole text. Reproduced: ja 2400 chars -> passage 2400 chars (1 whitespace word); th 2100 -> 2100; ja with a space per sentence -> 64 pieces (831 chars); latin -> 64 words. Titled/captioned documents are unaffected (title plus caption wins).
- The cross-encoder tokenizes the whole passage before windowing (Semantic/CoreML/ModelInput.swift:65-67 with TextTokenizing.swift:124-140), so tokenization cost grows with the text, inside the rerank race.
- Scope and consequence notes: it only affects hits with no title and no caption whose text is in an unspaced script. The per-pair input stays capped at 128 tokens as section 7.4 requires, and "64 tokens" in the spec is ambiguous (64 whitespace words of Latin text also exceed 64 model tokens), so the "model sees ~120 instead of 64" claim is the weakest part. The latency effect is linear tokenization of a few KB and was not measured. Low is right.

STATUS: complete
