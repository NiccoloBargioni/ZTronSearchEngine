# Cycle 1 — s02-retrieval (spec sections 7 and 8, pages 10-15)

Auditor checkpoint, final. Commit cee4620. Status values: met, partial, missing, contradicted, unverifiable-here.
Paths are relative to /Users/admin/Documents/ZTronSearchEngine unless absolute. "Semantic" = Sources/ZTronSearchEngineSemantic.
Test evidence: Verification/_runs/c1-debug-swift-test.log (debug `swift test`, 0 failures). PerformanceTests, the 100k HNSW recall
tests and SignalTuningTests.testSweep skip in debug and only run in the CI release job, so they were not counted as evidence here.

Scratch programs (all under /private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s02-retrieval/core/):
exp_main.swift and exp_semantic.swift, compiled with an unmodified copy of Sources/ZTronSearchEngine (src/, 40 files) by
`swiftc -swift-version 6 -Onone -parse-as-library`. Everything they printed is in exp_output.txt in the same folder.

Counts: 52 requirements; met 45, partial 5, missing 0, contradicted 0, unverifiable-here 2.

## Requirement table

| R# | Section / page | Requirement | Status | Code | Test |
|----|----------------|-------------|--------|------|------|
| R1 | 7 / p10 | Three channels produce independent ranked lists; only fusion combines them | met | Index/IndexSearcher.swift:715-723; Service/SearchService.swift:547-614; Service/SearchPipeline.swift:84-104 | RankingTests.swift:17 |
| R2 | 7 table / p11 | Lexical = BM25F + prefix on last token; every debounced keystroke | met | Query/BM25F.swift:27-78; Query/QueryParser.swift:85-96; Service/SearchService.swift:393-399 | CoreCorrectnessTests.swift:48; SnapshotPipelineTests.swift:112 |
| R3 | 7.1 / p11 | Field weights / b: title 8.0/0.5, keywords 4.0/0.3, caption 2.5/0.75, text 1.0/0.75, localizedAlt 0.5/0.75, ocrText 0.5/0.75 | met | Contracts/RankingProfile.swift:22-29,145-152 | RankingTests.swift:55 |
| R4 | 7.1 / p11 | k1 = 1.2 | met | Contracts/RankingProfile.swift:16 | RankingTests.swift:59 |
| R5 | 7.1 / p11 | Prefix expansion of final token over sorted vocabulary, capped at 32 | met | Index/IndexSearcher.swift:118-170; Contracts/SearchEngineConfiguration.swift:45; Query/QueryPlanner.swift:141-146 | CoreCorrectnessTests.swift:48,59 |
| R6 | 7.1 / p11 | Tokens with digits or - _ . match exactly only | met | Text/SearchTokenizer.swift:200-236; Text/SearchNormalizer.swift:110-124; Query/QueryParser.swift:78-96 | CoreCorrectnessTests.swift:138 |
| R7 | 7.1 / p11 | Varint postings per field, per-field document lengths | met | Index/SegmentWriter.swift:78-80,105,219 | structural (StrategyParityTests.swift:47,99) |
| R8 | 7 table / p11 | Fuzzy = trigram candidates over vocabulary + bounded Damerau-Levenshtein verification | met (OSA variant, documented at Text/EditDistance.swift:3-6) | Index/IndexSearcher.swift:172-611; Text/EditDistance.swift | FuzzyChannelTests.swift:125,173,203,224 |
| R9 | 7 table / p11 | Fuzzy runs once the longest token has >= 3 characters | met | Query/QueryParser.swift:88-89; Query/QueryPlanner.swift:109-110 | TextPipelineTests.swift:221 |
| R10 | 7.2 / p12 | Generate candidates, then augment the query and retrieve normally | met | Query/QueryPlanner.swift:164-177; Index/IndexSearcher.swift:889-894 | CoreCorrectnessTests.swift:111 |
| R11 | 7.2 / p12 | Allowed edits by length 1-2: 0, 3-5: 1, 6+: 2 | met | Text/EditDistance.swift:11-15 | TextPipelineTests.swift:136; CoreCorrectnessTests.swift:118,127 |
| R12 | 7.2 / p12 | No fuzzy expansion for IDs, URLs, model numbers, filters, phrases, chips | met | Query/QueryParser.swift:78-109 | CoreCorrectnessTests.swift:138,159,309; TextPipelineTests.swift:210 |
| R13 | 7.2 / p12 | At most 8 candidates per token, ranked by edits then df | met | Index/IndexSearcher.swift:195-202; Scan/ScanEngine.swift:430-439 | FuzzyChannelTests.swift:279 |
| R14 | 7.2 / p12 | Candidate weight 1/(1+edits) | met | Query/QueryPlanner.swift:170-174 | indirect only (no test asserts the weight) |
| R15 | 7.2 / p12 | Distance on normalized scalars after folding | met | Query/QueryParser.swift:84; Text/EditDistance.swift:69 | TextPipelineTests.swift:152 |
| R16 | 7.2 / p12 | Fuzzy operates on the vocabulary, never on documents | met | Index/IndexSearcher.swift:172-203 | FuzzyChannelTests.swift |
| R17 | 7 table / p11 (with 9 rule 2 p16, 10 p23) | Semantic runs after the semantic pause or on submit, and only for eligible queries | partial (1-2 character CJK/Thai queries run it: finding 04) | Service/SearchService.swift:424-429; Service/SearchPipeline.swift:62-63 | SnapshotPipelineTests.swift:83,132 |
| R18 | 7.3 / p12 | Item vectors from one deterministic composition, encoded once at build/sync time with the same pinned model as queries | met (contract: the host supplies `embeddingText` or a precomputed `embedding`; the engine never composes) | Contracts/Searchable.swift:81-86; Projection/SearchProjector.swift:170; Service/SearchService+Context.swift:137,157; Semantic/SemanticIndex.swift:259 | SemanticIndexTests.swift:541 |
| R19 | 7.3 / p12 | Vector store records model id, dimensions, quantization | met | Semantic/Vector/QuantizedVectorStore.swift:33-132,218-219 | QuantizedVectorStoreTests.swift:145; SemanticIndexTests.swift:365 |
| R20 | 7.3 / p12 | Only the query is encoded at query time | met | Service/SearchService.swift:563-569; Semantic/SemanticIndex.swift:140-166 | SnapshotPipelineTests.swift:49-50 |
| R21 | 7.3 / p12 | HNSW returns top 50 with M = 16, efSearch = 64 | partial (constrained queries ask for 200: finding 01) | Semantic/HNSW/HNSWConfiguration.swift:41-59; Contracts/SearchEngineConfiguration.swift:46; Service/SearchService.swift:557-558 | HNSWRecallTests.swift:37-65 |
| R22 | 7.3 / p12 | Core ML model, 8-bit weights, <= 384 dims, 128-token window, verified to load on iOS 15.8, CPU budgets | unverifiable-here (no model in the repo, no iOS 15 device or simulator; the code enforces <= 384 dims and defaults the window to 128) | Semantic/SemanticError.swift:76-78; Semantic/CoreML/CoreMLEmbeddingProvider.swift:48-72; Semantic/SemanticIndex.swift:360 | CoreMLAdapterTests.swift:298; SemanticIndexTests.swift:249 |
| R23 | 7.3 / p12 | EmbeddingProvider is a protocol; tests use a deterministic fake | met | Semantic/EmbeddingProvider.swift:11-28 | Tests/ZTronSearchEngineSemanticTests/FakeEmbeddingProvider.swift:12; CoreMLAdapterTests.swift:391 |
| R24 | 7.3 / p12 | Distance kernels use Accelerate or simd; no per-element Swift loops in the hot path | met | Semantic/Vector/VectorKernels.swift:22-208; Scan/ScanEngine.swift:345 | VectorKernelTests.swift:13,24 |
| R25 | 7 table / p11 | Rerank of the top 16 fused hits after the semantic snapshot, gated devices only | met | Service/SearchService.swift:441-461 | SnapshotPipelineTests.swift:300 |
| R26 | 7.4 / p12 | `SearchEngineConfiguration.reranking`, default `.auto` | met | Contracts/SearchEngineConfiguration.swift:161 | none specific |
| R27 | 7.4 / p12 | `.auto`: 16 synthetic pairs, p95 <= 15 ms, >= 3 GB, no memory warning in 10 min | met | Semantic/Calibration/RerankCalibrationGate.swift:173-253 | RerankCalibrationGateTests.swift:114-240 |
| R28 | 7.4 / p13 | Verdict persisted, recomputed after an app or OS update | met | RerankCalibrationGate.swift:178-180; Semantic/Calibration/CalibrationEnvironment.swift:54-65 | RerankCalibrationGateTests.swift:279 |
| R29 | 7.4 / p13 | `.on` forces the stage; `.off` never loads the model | met | Service/SearchService.swift:627-648 | SnapshotPipelineTests.swift:323 |
| R30 | 7.4 / p13 | Decision measured, never read off the chip name | met | RerankCalibrationGate.swift:183-224 | RerankCalibrationGateTests.swift |
| R31 | 7.4 / p13 | Input: top 16 (configurable, at most 32), localized surface (title + caption or first 64 tokens), 128 tokens per pair, one batched call | partial (the 32 ceiling is bypassable: finding 02; unspaced text passage is not 64 tokens: finding 05) | Service/SearchService.swift:449,681-703; Service/SearchPipeline.swift:196-200; Semantic/CoreML/CoreMLCrossEncoder.swift:112-125 | RankingTests.swift:342; SnapshotPipelineTests.swift:300; ModelInputTests.swift:77 |
| R32 | 7.4 / p13 | Cross-encoder 8-bit, <= 6 layers, <= 60 MB | unverifiable-here (model artifact not in the repo; the 60 MB load-time budget is enforced) | Semantic/CoreML/CoreMLCrossEncoder.swift:135-138; Semantic/SemanticError.swift:82 | CoreMLAdapterTests.swift:208,494 |
| R33 | 7.4 / p13 | Final = 0.7 x normalized CE + 0.3 x normalized RRF | met at defaults (blend bypass: finding 02) | Service/SearchPipeline.swift:155-192 | RankingTests.swift:314 |
| R34 | 7.4 / p13 | Only the reranked head is reordered | met | Service/SearchPipeline.swift:182 | RankingTests.swift:297 |
| R35 | 7.4 / p13 | Third snapshot `.reranked`, final; the semantic snapshot is then not final | met | Service/SearchService.swift:443-454 | SnapshotPipelineTests.swift:300 |
| R36 | 7.4 / p13 | Rerank skipped and degraded when semantic skipped, tokens only, or 400 ms cap breached | met | Service/SearchService.swift:404-408,436,455-458,646 | SnapshotPipelineTests.swift:375,391 |
| R37 | 7.4 / p13 | 3 breaches disable the stage for the session and force recalibration | met | Service/SearchService.swift:726-736; RerankCalibrationGate.swift:159-163 | SnapshotPipelineTests.swift:391; RerankCalibrationGateTests.swift:339 |
| R38 | 7.4 / p13 | Lazy load; unload with the embedding model after 60 s idle | met | Service/SearchService.swift:744-764; CoreMLCrossEncoder.swift:112-148 | SnapshotPipelineTests.swift:249 |
| R39 | 8 / p13 | Weighted RRF s(d) = sum w_c/(k + r_c) | met | Query/Fusion.swift:70-107 | RankingTests.swift:17,34 |
| R40 | 8 / p13 | k = 60 | met | Contracts/RankingProfile.swift:111,127 | RankingTests.swift:61 |
| R41 | 8 / p13 | Channel weights lexical 1.0, fuzzy 0.6, semantic 0.8 | met | Contracts/RankingProfile.swift:154-158 | RankingTests.swift:60 |
| R42 | 8 / p14 | RankingProfile shape | met | Contracts/RankingProfile.swift:106-170 | RankingTests.swift:55 |
| R43 | 8 / p14 | kindBoosts keyed by rawValue, multiplicative, clamped 0.5...1.5 | met | Contracts/RankingProfile.swift:166-169; Query/Fusion.swift:155-166 | RankingTests.swift:74 |
| R44 | 8 / p14 | Popularity log1p-scaled, adds at most 15% of the top fused score | met | Query/Fusion.swift:170-172,249-263 | RankingTests.swift:113,251 |
| R45 | 8 / p14 | Freshness exponential decay, half-life in days, TemporalSearchable only | met | Query/Fusion.swift:149-176; Projection/SearchProjector.swift:157 | RankingTests.swift:137 |
| R46 | 8 / p14 | Editorial pins and suppressions through EditorialProvider | met | Query/Fusion.swift:136-145,196-220 | RankingTests.swift:169 |
| R47 | 8 / p14 | rerank topN 16, blend 0.7, applied only past the gate | met at defaults (setters bypass the caps: finding 02) | Contracts/RankingProfile.swift:88-101 | RankingTests.swift:62 |
| R48 | 8 / p14 | Filters and kind tokens are hard constraints applied before retrieval; kindBoosts only reorder survivors | partial (indexed semantic channel filters after ANN: finding 01) | Index/IndexSearcher.swift:677,791,856; Service/SearchService.swift:554-558,605; Index/LexicalIndex.swift:293-317 | CoreCorrectnessTests.swift:285; SnapshotPipelineTests.swift:53 |
| R49 | 8 / p14 | Providers optional, Sendable, synchronous; a throwing provider is treated as absent | met | Contracts/RankingProfile.swift:178-200; Query/Fusion.swift:224-263 | RankingTests.swift:194 |
| R50 | 8 table / p13-14 | Popularity, Editorial and Personalization providers | met | Contracts/RankingProfile.swift:178-219 | RankingTests.swift:159,251 |
| R51 | 8 / p15 | Pins applied after fusion and rerank, at most 3 per query | partial (the cap is bypassable through the property setter: finding 02) | Query/Fusion.swift:196-220; Service/SearchService.swift:419,442,453 | RankingTests.swift:169; SnapshotPipelineTests.swift:422 |
| R52 | 8 / p15 | Every hit carries its kind and its channels | met | Service/SearchPipeline.swift:120-141 | RankingTests.swift:17; CoreCorrectnessTests.swift:111 |

## Findings

### C1-s02-retrieval-01 — Indexed semantic channel applies hard constraints after ANN retrieval; filtered queries lose their semantic matches and disagree with the scan strategy
- Severity: high. Category: spec-deviation.
- Spec: section 8 p14, "Filters and kind tokens are hard constraints applied before retrieval"; section 7.3 p12, "HNSW returns the top 50"; section 10 p23, bounded work of "50 HNSW neighbours"; section 15 parity ("Scan and indexed strategies rank the same documents identically").
- Locations: Sources/ZTronSearchEngine/Service/SearchService.swift:554-558 and 605; Sources/ZTronSearchEngine/Index/LexicalIndex.swift:293-317 (`resolve`); Sources/ZTronSearchEngine/Contracts/SemanticBoundary.swift:33 (`nearest(to:limit:)` takes no constraints); Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:33-36 (documents the post-filter); contrast Sources/ZTronSearchEngine/Scan/ScanEngine.swift:335-361.
- Description: for an indexed context, the semantic phase asks the ANN index for `min(neighbours*4, max(neighbours, 200))` = 200 neighbours of the unconstrained space, then drops every neighbour that violates a kind, filter or phrase constraint. When more than 200 non-matching items sit closer to the query than the constrained subset, the semantic channel returns nothing. The scan strategy instead ranks every vector and filters before taking the limit, so it returns the right items. The constraint is not applied before retrieval, the HNSW request exceeds 50, and the two strategies give different results.
- Evidence: scratch program exp_semantic.swift (`semanticFilterExperiment`). It uses a brute-force exact `SemanticSearching` fake (the best case for any ANN) with 300 kind-`a` items whose vectors sit next to the query and 20 kind-`b` items further away, and the query "ocean sunset" with kinds [.b], which matches nothing lexically. It printed:
  `indexed: phase semantic hits 0 semantic hits 0 nearest(limit:) asked [200]`
  `scan:    phase semantic hits 20 semantic hits 20 first ["b0", "b1", "b10"]`
  No test covers this. StrategyParityTests.swift:16 compares strategies without a semantic channel, and CoreCorrectnessTests.swift:285 and SnapshotPipelineTests.swift:53 only check that survivors respect the constraints.
- Failure scenario: a catalog above the 500-item scan threshold, the user taps a kind chip such as Images or sets a platform filter, and types a descriptive query whose words do not appear in the matching items. The filtered subset is a small share of the corpus (1% leaves about 2 expected survivors out of 200). The semantic list is empty or nearly so, and the final snapshot shows few or no hits, although 50 matching items exist and a scan context over the same items returns them.

### C1-s02-retrieval-02 — RankingProfile caps (3 pins, rerank topN <= 32, blend 0...1) are enforced only in initializers; public property setters bypass them
- Severity: medium. Category: api.
- Spec: section 8 p15, pins "limited to 3 per query"; section 7.4 p13, input "top 16 fused hits (configurable, at most 32)"; section 7.4 blend 0.7 / 0.3 "so one confident pass cannot push an exact-title hit out of the head".
- Locations: Sources/ZTronSearchEngine/Contracts/RankingProfile.swift:75,78-80,90-97; Sources/ZTronSearchEngine/Query/Fusion.swift:197,205; Sources/ZTronSearchEngine/Service/SearchService.swift:449,453; Sources/ZTronSearchEngine/Service/SearchPipeline.swift:156,163.
- Description: `EditorialPolicy.maximumPins`, `RerankSpec.topN` and `RerankSpec.blend` are public `var`s. Their clamps live only in `init`, and the consumers read the stored values without re-clamping. Mutating a profile, the natural Swift idiom (`var p = RankingProfile.default; p.editorial.maximumPins = 6`), breaks the documented and specified ceilings. RankingTests.swift:64-65 checks only the initializer path.
- Evidence: scratch program exp_main.swift, modes `pins` and `rerank`, printed:
  `init clamp: EditorialPolicy(maximumPins: 6).maximumPins = 3` / `setter: profile.editorial.maximumPins = 6`
  `e2e final hits: d4,d9,d8,d7,d6,d5,d3,d2,d1,d0` / `e2e leading pinned hits: 6 (spec section 8: at most 3 per query)`
  `init clamp: RerankSpec(topN: 100).topN = 32 ...` / `setter: profile.rerank.topN = 100` / `documents carrying .rerank: 40 (spec 7.4: at most 32)` / `passages SearchService.swift:449 would send: 40`
  `setter: profile.rerank.blend = 2.0` / `blend=2, flat CE scores, head order: d15,d14,...,d0` (the fused head is fully reversed when the cross-encoder is indifferent)
- Failure scenario: a host sets `profile.editorial.maximumPins = 5` and gets 5 pins hiding organic results. Or it sets `profile.rerank?.topN = 64`: 64 pairs go to the cross-encoder in one call, which is twice the window budget the 400 ms cap was sized for, so the stage breaches and is disabled after 3 queries. Or it sets `blend = 1.5`, which gives a negative fused weight and lets the cross-encoder invert the head.

### C1-s02-retrieval-03 — SearchLimits setters bypass the init clamps; lexicalCandidates = 0 crashes the lexical search, negative fusion and retained limits trap
- Severity: medium. Category: bug.
- Spec: section 8 p13-14 (fusion of at most 200 entries per channel, 200 hits retained) and the bounded-work limits used by the section 7.1 lexical channel (2,000 candidates).
- Locations: Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:28-55 (public vars; the clamps exist only in init); Sources/ZTronSearchEngine/Index/IndexSearcher.swift:673-674,731-742,796 (`slots[slotCount]` written before the limit check, while `prepareScratch` allocates `limit` = 0 slots); Sources/ZTronSearchEngine/Index/IndexSearcher.swift:715-717 and Sources/ZTronSearchEngine/Query/Fusion.swift:82 (`prefix(entriesPerChannel)`); Sources/ZTronSearchEngine/Query/Fusion.swift:190 (`order.prefix(limit)`); Sources/ZTronSearchEngine/Service/SearchPipeline.swift:101-103.
- Description: `SearchLimits.init` clamps every value to at least 1 (or 0), which shows the engine relies on that invariant. The stored properties are public `var`s, and `SearchEngineConfiguration.limits` passes them through untouched. A zero candidate limit makes `admitCandidates` index into an empty slot array. Negative list limits reach `prefix(_:)`, which traps. `retainedHits = 0` silently returns empty results.
- Evidence: scratch program exp_main.swift, end-to-end through `SearchService` with 10 indexed items and the query "lantern". It printed:
  baseline `final hits: 10`
  `limits.lexicalCandidates = 0` -> `Swift/ContiguousArrayBuffer.swift:708: Fatal error: Index out of range`, exit 133 (the init would have clamped to 1: `SearchLimits(lexicalCandidates: 0).lexicalCandidates = 1`)
  `limits.fusionEntriesPerChannel = -1` -> `Fatal error: Can't take a prefix of negative length from a collection`, exit 133
  `limits.retainedHits = -1` -> same trap, exit 133
  `limits.retainedHits = 0` -> `final hits: 0`
- Failure scenario: `var config = SearchEngineConfiguration(); config.limits.lexicalCandidates = 0` (or a value computed from a remote config that underflows) crashes the app on the first non-trivial indexed query. A computed negative fusion or retained limit crashes every query.

### C1-s02-retrieval-04 — 1-2 character CJK/Thai queries run the semantic phase (and the rerank phase on gated devices)
- Severity: medium. Category: spec-deviation.
- Spec: section 9 snapshot rule 2 (p16), the semantic snapshot "is skipped, with degraded set, when the query is shorter than 3 characters"; section 10 (p23), "Queries shorter than 3 characters, or made only of tokens, skip the semantic and rerank phases". Section 7 table (p11) semantic trigger.
- Locations: Sources/ZTronSearchEngine/Service/SearchPipeline.swift:61-63 (`|| parsed.containsUnspacedScript`); Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:133-134; Sources/ZTronSearchEngine/Service/SearchService.swift:520-525,627-648.
- Description: semantic eligibility is `characterCount >= minimumSemanticQueryLength || containsUnspacedScript`. Any query with one CJK or Thai character therefore encodes a query embedding, publishes a semantic snapshot instead of a degraded lexical-final one, and is eligible for rerank, which the spec forbids for queries under 3 characters. The only CJK short-query test (CoreCorrectnessTests.swift:102 and InternationalizationTests.swift:178) asserts lexical results only.
- Evidence: scratch program exp_semantic.swift (`shortUnspacedExperiment`) printed:
  `query 東京 chars 2 encodeQuery calls 1 final phase semantic degraded []`
  `query 東 chars 1 encodeQuery calls 1 final phase semantic degraded []`
  `query ab chars 2 encodeQuery calls 0 final phase lexical degraded ["semantic"]`
- Failure scenario: a Japanese user types one kanji and pauses. On the reference device (A9, CPU-only) the 80 MB embedding model is loaded and run for a 1-character query, which the 3-character rule exists to prevent. The final snapshot is `.semantic` without `degraded`, contrary to snapshot rule 2. On gated devices a cross-encoder pass also runs.

### C1-s02-retrieval-05 — The rerank passage for untitled text in unspaced scripts is the whole text, not the first 64 tokens
- Severity: low. Category: spec-deviation.
- Spec: section 7.4 p13, passage = "title plus caption, or the first 64 tokens of text".
- Locations: Sources/ZTronSearchEngine/Service/SearchPipeline.swift:196-200; Sources/ZTronSearchEngineSemantic/Tokenization/TextTokenizing.swift:124-125 (the whole passage is tokenized before windowing).
- Description: `passage(for:)` takes `text.split(whereSeparator: \.isWhitespace).prefix(64)`. CJK and Thai text has no whitespace, so the whole text is a single "word" and passes through unshortened. The cross-encoder tokenizes the full string before cutting it to the 128-token window. Tokenization cost grows with the text length inside the 400 ms rerank cap, and the model sees about 120 tokens instead of 64. RankingTests.swift:342-347 only covers Latin text.
- Evidence: scratch program exp_main.swift, mode `passage`, printed `CJK text chars 2400 passage chars 2400 (spec 7.4: first 64 tokens of text)` versus `Latin passage words 64`.
- Failure scenario: an untitled Japanese tip or OCR-heavy image with a long text reaches the reranked head. Each rerank tokenizes the full text (several KB), which adds latency toward the 400 ms cap, and the passage differs from the specified 64-token surface.

## Candidates knocked down (not reported)
- Memory threshold rounded to whole GiB before the >= 3 GB comparison: matches how devices report marketing memory; not a defect.
- The fuzzy list includes exact matches: the spec says the query is "augmented", so this is by design.
- Freshness boost has no 15% cap: the spec caps popularity only.
- Trigram candidate generation: lossless against brute force (FuzzyChannelTests.swift:125,173,203,224).
- OSA instead of unrestricted Damerau-Levenshtein: documented (Text/EditDistance.swift:3-6), a standard restricted DL; it only differs for a transposition plus an edit between the swapped letters.
- Required-clause bits past index 63 (IndexSearcher.swift:899, QueryPlanner.swift:122): the parser caps clauses at 64 (QueryParser.swift:37,63), and phrase verification still filters, so there is no observable effect.
- `lastKind = ""` cache in ResultRanker.rank: affects only a kind whose rawValue is the empty string.
- A memory-warning refusal by the gate leaves the stage off for the rest of the session (SearchService.swift:662-664) although the gate does not persist that verdict: consistent with the spec's "one-time calibration on first use"; documentation drift at most.
- Reranker model budget 60 x 1024 x 1024 bytes vs "60 MB": unit ambiguity only.

## Not checked
- Device-only properties: that the Core ML embedding model and cross-encoder load on iOS 15.8, their 8-bit weights and layer count (no model artifact in the repo; no iOS 15/16 simulator or device on this Mac), and real calibration timings (p95 per pair) on any device.
- Release-only tests: PerformanceTests, the 100k HNSW recall tests (ZTRON_SEMANTIC_LARGE) and SignalTuningTests.testSweep skip in debug; their gates were not run here (no `swift test`/`swift build` in the repository per the ground rules).
- HNSW recall@k at 100k and the efConstruction=200 build quality: only the 20k debug run in the test log was considered.
- Relevance gates of section 15.3 (exact title rank 1 >= 98%, prefix MRR@10, typo recall@10): owned by another slice; not re-measured.
- Thread-safety of the semantic actors under contention (TSan) and memory budgets of section 10.
- Persisted-verdict behaviour across a real app/OS update (only the fingerprint logic was read).

STATUS: complete
