# Verification report — ZTronSearchEngine

Two independent, skeptical verification cycles against commit `cee4620`, run 2026-11-17 and 18.

- **Cycle 1, requirement-centric.** Six auditors each took one slice of the 58-page specification and traced every requirement into the code and tests. A skeptic per slice then tried to refute each finding.
- **Cycle 2, code-centric.** Six auditors each read one module line by line and held it against the spec. A skeptic per module then traced each finding concretely and tried standalone repros.

Cycle 2's prompts were written before any cycle 1 result came back, and no agent saw the other cycle's notes. Nothing in the repository was modified: agents worked read-only, and repro builds ran in scratch copies.

## Bottom line

The package is real and substantially built:
- `swift test` passes with no compiler warnings: 580 tests, in debug and under Thread Sanitizer.
- It builds for the iOS 15 simulator.
- The SQLite (78 tests) and AssetKit (103 tests) adapters pass.
- Cycle 1 traced 479 requirements: 351 met, 78 partly met, 5 missing, 14 contradicted, and 31 that cannot be checked on this Mac.

What does not hold up is the claim that the quality gates are demonstrated:
- `PerformanceTests` cannot fail on several of the budgets it states, because an unscoped `XCTExpectFailure` absorbs both the miss and every later assertion in the test.
- Three budgets are missed by the package's own scaled estimate. At a load average of about 6, the 100k-item locale rebuild took 853 ms against 333 ms allowed, and upserts ran 3.0–3.9x over.
- The UI parity gate is not met. The README says so, but it overstates where the field matches.
- Several other gates rest on tests that cannot fail, or that never run in CI.

Both cycles also found real defects in normal use. The most important: a persisted search-context index is reused after its content changes, so results go stale across launches.

The skeptics refuted only 1 of 154 findings. Their main correction was severity: they downgraded 14 of 64 findings in cycle 1 and 25 of 90 in cycle 2, and upgraded none. Each finding had one skeptic, not a panel. That is why the 23 issues both cycles reached on their own are the strongest results.

## Fix first

1. **Stale persisted indexes.** The memory-context fingerprint ignores keywords, filters, localizations and same-length edits (both cycles, high). Database-backed contexts adopt a persisted index without reading their rows, so writes made while nothing was subscribed are never indexed (cycle 2, high).
2. **Performance gates that cannot fail.** Scope `XCTExpectFailure` to the one assertion it excuses (both cycles, high). Then decide what to do about the missed locale-rebuild, upsert and catalog-sized scan budgets (cycle 2, high, matching the release runs above).
3. **Model download and chat readiness.**
   - A retry restarts the 968 MB weights file from byte 0 (both cycles, high).
   - Calling `prepare()` during a download restarts it or leaves readiness stuck (cycle 1, high).
   - An interrupted calibration persists a failing verdict, so chat stays off on a capable device (cycle 1, high).
4. **Writes racing a rebuild.** `index`, `remove` and `replace` calls that race a rebuild are silently undone (cycle 1, high).
5. **UI parity.** The gate is not met, and iOS 15 and 16, the package floor, were never sampled (both cycles, high).
6. **Local chat target.** The grounded-answers target has no 100-question golden set and no measurement (cycle 1, high).

## Evidence from running the suites

| Run | Result | Log (`_runs/`) |
|---|---|---|
| `swift test`, debug | 580 tests, 0 failures, 22 skipped (all budget or large-corpus tests), 0 warnings | `c1-debug-swift-test.log` |
| `swift test --sanitize=thread` | 580 tests, 0 failures, no TSan report | `c2-tsan-swift-test.log` |
| iOS Simulator `build-for-testing` | succeeded | `c2-ios-build.log` |
| `generate_ui_assets.py --check` | no drift | `c2-ui-assets-check.log` |
| SQLite adapter, debug | 78 tests, 1 skipped (its §15.9 targets need release) | `c2-sqlite-adapter.log` |
| SQLite adapter §15.9 targets, release | 1 failure: incremental 10.2 ms vs 8.3 ms allowed on this Mac | `c2-sqlite-release-targets.log` |
| AssetKit adapter | 103 tests, 0 failures | `c2-assetkit-adapter.log` |
| Release `PerformanceTests` | Failed in both of my runs, at load averages of 370 and about 10, with 12 simulators booted by other work, so those timings are unreliable. A cycle 2 skeptic re-measured at load 5–7: fusion and page targets pass, and only the §15.9 incremental-upsert p95 fails, intermittently. Every run absorbed 4–5 budget misses through `XCTExpectFailure` | `c2-release-performance*.log` |
| Release `RelevanceTests`, 100k distractors | 21 tests passed. The semantic and rerank gates use fakes built from the golden judgments | `c2-release-relevance-full.log` |
| Release semantic suite, large HNSW | 1 failure in both runs: the isotropic test, documented as "not a gate", enforces cache-cold p95 (0.95 ms vs 0.83 ms) | `c2-release-semantic-large.log`, `c2-release-hnsw-recall-rerun.log` |
| MLX adapter | not run: no Metal toolchain, and its dependency set is not cached | — |

## What this verification does not cover

- Nothing ran on a device. Budgets for the reference device (iPhone 6s, iOS 15.8) are approximated by scaling. The iOS 15 and 16 simulators cannot boot on this Mac, and the parity matrix was not rerun.
- No real embedding model, cross-encoder or language model was evaluated: the package ships none.
- Five of the six cycle 2 skeptics were cut off by the weekly usage limit on 2026-11-17. They were resumed on 2026-11-18 from their own partial notes, with unchanged instructions.
- Cost: cycle 1 took 12 agents and 2.6M subagent tokens. Cycle 2 took 17 agent runs and 4.8M tokens.

Per-finding detail: `cycle-1/SUMMARY.md` and `cycle-2/SUMMARY.md`, by id. Agents' own notes: `cycle-N/find-*.md` and `verify-*.md`.
