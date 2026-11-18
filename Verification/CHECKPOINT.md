# Verification checkpoint — ZTronSearchEngine

Started 2026-11-17 against commit `cee4620` (the only commit); **finished 2026-11-18**. Nothing here is
committed; the whole `Verification/` folder is untracked working state and can be deleted when you
are done with it.

Request: "Run two independent skeptical verification cycles against this package. Save progress
checkpoints because quota is running out."

**Read `REPORT.md` first.** It opens with the bottom line and what to fix first, then lists the 23
issues both cycles found independently, the 87 only one cycle found, and the refuted ones.

## Design

| | Cycle 1 | Cycle 2 |
|---|---|---|
| Lens | Requirement-centric: start from the spec, trace each requirement to code and tests | Code-centric: read each module line by line, then hold it against the spec |
| Split | 6 spec slices (§1–6, §7–8, §9–11, §12–13, §14, §15–18) | 6 modules (text+index, query+service, semantic, UI+parity, adapters, tests+gates) |
| Skeptic | One refuter per slice, re-reads the spec text and the code | One refuter per module, traces inputs concretely and tries standalone repros |
| Evidence run | `swift test` (debug) | TSan, adapters, iOS build, release-mode quality targets |

Independence: cycle 2's prompts were written to `cycle-2/workflow.js` before any cycle 1 result
came back, and every agent was told not to read other agents' or other cycles' notes. Agents were
read-only on the repository.

## Status

| Step | State | Output |
|---|---|---|
| Spec text extracted | done | `_inputs/spec.txt` |
| Test and build runs | done (see the evidence table in `REPORT.md`) | `_runs/*.log` |
| Cycle 1: 6 tracers → 6 skeptics | done 2026-11-17 17:47: 479 requirements traced, 64 findings (36 confirmed, 27 partly, 1 refuted) | `cycle-1/find-*.md`, `verify-*.md`, `result.json`, `SUMMARY.md` |
| Cycle 2: 6 auditors → 6 skeptics | auditors and the m04 skeptic done 2026-11-17; five skeptics cut off by the weekly usage limit, resumed from their partial notes and done 2026-11-18 (`workflow-resume.js`): 90 findings (50 confirmed, 39 partly, 1 uncertain) | `cycle-2/find-*.md`, `verify-*.md`, `result.json`, `SUMMARY.md` |
| Cross-cycle report | done | `REPORT.md` (regenerate with `python3 Verification/_tools/make_report.py Verification/cycle-2/resume-output.json`; the hand-matched groups are in that script) |

## If you want to go further

- Every finding id in `REPORT.md` has its full text, evidence and the skeptic's reasoning in
  `cycle-N/SUMMARY.md`; the agents' own notes (requirement tables, repro output) are in
  `cycle-N/find-*.md` and `verify-*.md`.
- Not covered here: anything on a device, the iOS 15/16 simulators (unusable on this Mac), the
  parity matrix, the MLX adapter's tests, and any real model.
