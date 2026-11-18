#!/usr/bin/env python3
"""Builds cycle-2/result.json and cycle-2/SUMMARY.md, then the cross-cycle REPORT.md.

Usage: python3 Verification/_tools/make_report.py [path to the resume workflow's output JSON]

Inputs are the checkpoint files: cycle-1/result.json, cycle-2/result-partial.json and, when given,
the verdicts of the resumed cycle 2 skeptics. _tools/report_intro.md, when present, opens the report.
"""
import json
import os
import sys
from collections import Counter

V = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3, "none": 4}
SURVIVES = ("confirmed", "partly")


def path(p):
    return os.path.join(V, p)


def load(p):
    return json.load(open(path(p)))


c1 = load("cycle-1/result.json")
c2 = load("cycle-2/result-partial.json")

# Merge the resumed skeptics' verdicts into cycle 2.
if len(sys.argv) > 1:
    wrapper = json.load(open(sys.argv[1]))
    resumed = wrapper.get("result", wrapper)
    if isinstance(resumed, str):
        resumed = json.loads(resumed)
    by_module = {x["module"]: {v["id"]: v for v in x["verdicts"]} for x in resumed.get("resumed", [])}
    for m in c2["modules"]:
        verdicts = by_module.get(m["module"])
        if not verdicts:
            continue
        m["skeptic_ran"] = True
        for f in m["findings"]:
            v = verdicts.get(f["id"])
            if not v:
                continue
            f["verdict"], f["severity"] = v["verdict"], v["severity"]
            if v.get("corrected_description"):
                f["summary"] = v["corrected_description"]
            f["skeptic"], f["repro"] = v.get("reasoning", ""), v.get("repro_result", "")
    json.dump(c2, open(path("cycle-2/result.json"), "w"), indent=1, ensure_ascii=False)

F1 = {f["id"]: f for s in c1["slices"] for f in s["findings"]}
F2 = {f["id"]: f for m in c2["modules"] for f in m["findings"]}
ALL = {**F1, **F2}


def sev_key(f):
    return (ORDER.get(f["severity"], 9), f["id"])


def short(i):
    return i.replace("C1-", "").replace("C2-", "")


def where(f, n=2):
    locs = [l.replace(V.rsplit("/Verification", 1)[0] + "/", "") for l in f.get("locations", [])[:n]]
    return ", ".join("`" + l.split(" (")[0] + "`" for l in locs)


# ---------------------------------------------------------------- cycle 2 summary
def write_cycle2_summary():
    rows = sorted(F2.values(), key=sev_key)
    vc = Counter(f["verdict"] for f in rows)
    sc = Counter(f["severity"] for f in rows if f["verdict"] in SURVIVES)
    out = ["# Cycle 2 summary — code-centric\n",
           "Six auditors read one module each line by line and held it against the specification; one skeptic per module then traced each finding concretely and tried standalone repros. Runs `wf_246c0e17-55f` (auditors and the m04 skeptic; the weekly usage limit cut off the other five skeptics) and the resume `cycle-2/workflow-resume.js`. Full notes: `find-<module>.md` and `verify-<module>.md`. Machine-readable: `result.json`.\n",
           "| Module | Files read | Lines read | Findings | Skeptic ran |", "|---|---:|---:|---:|---|"]
    for m in c2["modules"]:
        out.append(f'| {m["module"]} | {m["files_read"]} | {m["lines_read"]} | {len(m["findings"])} | {"yes" if m["skeptic_ran"] else "no"} |')
    out.append(f'\n## Findings: {len(rows)} reported, {vc["confirmed"]} confirmed, {vc["partly"]} partly confirmed, {vc["refuted"]} refuted, {vc["uncertain"]} uncertain, {vc["unverified"]} unverified\n')
    out.append(f'Surviving findings by verified severity: {sc["critical"]} critical, {sc["high"]} high, {sc["medium"]} medium, {sc["low"]} low.\n')
    current = None
    for f in rows:
        if f["severity"] != current:
            current = f["severity"]
            out.append(f"\n## {current.capitalize()}\n")
        sev = f["severity"] if f["found_severity"] == f["severity"] else f'{f["found_severity"]} → {f["severity"]}'
        out.append(f'### {f["id"]} — {f["title"]}\n')
        out.append(f'- Verdict: **{f["verdict"]}**; severity {sev}; category {f["category"]}; spec {f["spec_ref"]}')
        out.append("- Where: " + where(f, 4))
        out.append("- What: " + f["summary"])
        if f.get("skeptic"):
            out.append("- Skeptic: " + f["skeptic"])
        if f.get("repro"):
            out.append("- Repro: " + f["repro"])
        out.append("")
    out.append("\n## What the auditors did not get to\n")
    for m in c2["modules"]:
        out.append(f'- **{m["module"]}**: {m["not_checked"]}')
    out.append("\nSTATUS: complete")
    open(path("cycle-2/SUMMARY.md"), "w").write("\n".join(out) + "\n")


# ---------------------------------------------------------------- cross-cycle grouping
# The same defect found independently by both cycles. Matched by hand from the titles, locations
# and summaries of both result files on 2026-11-18.
GROUPS = [
    ("Persisted context index reused after content edits: the fingerprint ignores keywords, filters, localizations and same-length edits",
     ["C1-s01-contracts-01", "C1-s03-engine-api-03"], ["C2-m01-text-index-04", "C2-m02-query-service-02"]),
    ("Budget checks call an unscoped XCTExpectFailure, so a missed budget and every later assertion in the test pass",
     ["C1-s01-contracts-04", "C1-s06-quality-02"], ["C2-m01-text-index-01", "C2-m06-tests-gates-01"]),
    ("UI parity gate of 12.5/15.7 not met; iOS 15 and 16, the floor, were never sampled and reuse iOS 17 values",
     ["C1-s04-ui-01", "C1-s04-ui-02", "C1-s06-quality-01"], ["C2-m04-ui-01"]),
    ("Section 15.9 database targets over real SQLite never run in CI (and fail here in release)",
     ["C1-s06-quality-04"], ["C2-m05-adapters-01", "C2-m06-tests-gates-10"]),
    ("A retry of the model download restarts the in-transit file (968 MB of weights) from byte 0",
     ["C1-s05-chat-03"], ["C2-m05-adapters-02"]),
    ("Randomized stale-snapshot test cannot detect a stale snapshot",
     ["C1-s06-quality-08"], ["C2-m02-query-service-03", "C2-m06-tests-gates-05"]),
    ("Cancellation-latency tests accept far more than the 10 ms target, or time only the consumer's exit",
     ["C1-s03-engine-api-10"], ["C2-m02-query-service-10", "C2-m06-tests-gates-04"]),
    ("Resident-memory budgets of 15.2 are not asserted; model budgets are checked as on-disk size",
     ["C1-s06-quality-05"], ["C2-m03-semantic-01", "C2-m06-tests-gates-09", "C2-m05-adapters-06"]),
    ("Semantic-snapshot latency test checks a weaker gate; the reranked-snapshot target has no test",
     ["C1-s06-quality-06"], ["C2-m06-tests-gates-03"]),
    ("Filter/kind precision gate passes when the engine returns nothing",
     ["C1-s06-quality-09"], ["C2-m06-tests-gates-07"]),
    ("Attachment / EnvironmentObject lint cannot fail over the repository",
     ["C1-s04-ui-06", "C1-s06-quality-10"], ["C2-m04-ui-06"]),
    ("Changing pageSize during a search drops its snapshots and leaves the previous query's hits",
     ["C1-s03-engine-api-08", "C1-s04-ui-05"], ["C2-m04-ui-02"]),
    ("With an editingPolicy set, the host's .focused binding cannot begin editing",
     ["C1-s04-ui-10"], ["C2-m04-ui-07"]),
    ("Smart-punctuation emulation rewrites characters the user typed",
     ["C1-s04-ui-04"], ["C2-m04-ui-09"]),
    ("README overstates where the field matches the UIKit reference",
     ["C1-s04-ui-11"], ["C2-m04-ui-12"]),
    ("Chat prompt budget counts message contents only, not the template's per-message tokens",
     ["C1-s05-chat-05"], ["C2-m02-query-service-18"]),
    ("Source truncation splits on whitespace, so unspaced scripts (Japanese, Chinese, Thai) lose the whole source",
     ["C1-s05-chat-06"], ["C2-m02-query-service-07"]),
    ("Citations of ids containing ':' are never recognised; the raw marker leaks into the reply",
     ["C1-s05-chat-07"], ["C2-m02-query-service-08"]),
    ("A send during a model fetch waits uncancellably for the download while holding the generation lock",
     ["C1-s05-chat-12"], ["C2-m02-query-service-16"]),
    ("Cancellation during the prompt prefill is not bounded as specified, and no test covers it",
     ["C1-s05-chat-08"], ["C2-m05-adapters-05"]),
    ("Public setters bypass the initializers' clamps: zero or negative limits crash or hang",
     ["C1-s02-retrieval-02", "C1-s02-retrieval-03", "C1-s03-engine-api-06"], ["C2-m01-text-index-05", "C2-m02-query-service-13"]),
    ("Paging arithmetic overflows (trap) with a huge limit and a cursor",
     ["C1-s03-engine-api-05"], ["C2-m01-text-index-07"]),
    ("Canonically equivalent ids (NFC/NFD) are one id to Swift collections but two to the index",
     ["C1-s01-contracts-11"], ["C2-m01-text-index-06", "C2-m03-semantic-08"]),
]
# Found twice inside one cycle (two auditors, different slices): merged, still single-cycle.
SAME_CYCLE = [
    ("A localization key equal to its resolved value is treated as unresolved and the string is dropped",
     ["C1-s01-contracts-02", "C1-s03-engine-api-02"], []),
    ("Locale-rebuild, incremental-upsert and catalog-sized scan-creation budgets are missed by the package's own scaled estimate",
     [], ["C2-m01-text-index-02", "C2-m06-tests-gates-02"]),
]
RELATED = [
    ("Hard constraints are applied after ANN retrieval: cycle 1 says filtered queries lose semantic matches; cycle 2 says the 200-neighbour over-fetch breaks the work bound of 50",
     ["C1-s02-retrieval-01"], ["C2-m03-semantic-13"]),
    ("Preparation and load reentrancy, in different layers (ZTronChatModel.prepare vs ChatService.load)",
     ["C1-s05-chat-02", "C1-s05-chat-10"], ["C2-m02-query-service-06"]),
    ("Decode-rate calibration, in the core (can pass without a rate) vs the MLX adapter (counts hidden tokens)",
     ["C1-s05-chat-09"], ["C2-m05-adapters-14"]),
    ("Right-to-left cells show English labels (cycle 1) vs committed parity results that predate the localization (cycle 2)",
     ["C1-s04-ui-09"], ["C2-m04-ui-12"]),
    ("Gates reached only with fakes that agree with the judgments (cycle 1 refuted the narrower reranker claim)",
     ["C1-s06-quality-11"], ["C2-m06-tests-gates-11"]),
    ("Persisted index adopted without checking content: memory contexts (the shared finding above) and database-backed contexts (cycle 2 only)",
     ["C1-s01-contracts-01"], ["C2-m02-query-service-01"]),
]

grouped = {i for _, a, b in GROUPS + SAME_CYCLE for i in a + b}
unknown = sorted(i for i in grouped if i not in ALL)
if unknown:
    sys.exit("unknown ids in the grouping: " + ", ".join(unknown))


def survivors(ids):
    return [ALL[i] for i in ids if ALL[i]["verdict"] in SURVIVES]


def top_severity(fs):
    return min((f["severity"] for f in fs), key=lambda s: ORDER.get(s, 9)) if fs else "none"


def verdicts(ids):
    return ", ".join(f'{short(i)} {ALL[i]["verdict"]}/{ALL[i]["severity"]}' for i in ids)


def all_refuted(ids):
    return all(ALL[i]["verdict"] == "refuted" for i in ids)


both, disagree, half = [], [], []
for title, a, b in GROUPS:
    sa, sb = survivors(a), survivors(b)
    entry = (title, a, b, top_severity(sa + sb))
    if sa and sb:
        both.append(entry)
    elif (sa and all_refuted(b)) or (sb and all_refuted(a)):
        disagree.append(entry)
    elif sa or sb:
        half.append(entry)  # found by both, confirmed by one, the other skeptic did not settle it
both.sort(key=lambda e: (ORDER[e[3]], e[0]))
half.sort(key=lambda e: (ORDER[e[3]], e[0]))

single = []  # (cycle, title, ids, severity)
for title, a, b in SAME_CYCLE:
    s = survivors(a + b)
    if s:
        single.append(("1" if a else "2", title, a + b, top_severity(s)))
for i, f in ALL.items():
    if i in grouped or f["verdict"] not in SURVIVES:
        continue
    single.append((i[1], f["title"], [i], f["severity"]))
single.sort(key=lambda e: (ORDER[e[3]], e[0], e[2][0]))

uncertain = sorted([f for i, f in ALL.items() if f["verdict"] in ("uncertain", "unverified")], key=sev_key)
refuted = sorted([f for f in ALL.values() if f["verdict"] == "refuted"], key=lambda f: f["id"])


def summary_of(ids):
    fs = sorted(survivors(ids) or [ALL[i] for i in ids], key=sev_key)
    return fs[0]["summary"]


out = []
intro = path("_tools/report_intro.md")
if os.path.exists(intro):
    out.append(open(intro).read().rstrip() + "\n")
else:
    out.append("# Verification report — ZTronSearchEngine\n")

sev_both = Counter(e[3] for e in both)
sev_single = Counter(e[3] for e in single)
out.append("## Totals\n")
out.append(f"- Cycle 1: {len(F1)} findings; cycle 2: {len(F2)} findings.")
out.append(f"- Found and confirmed by both cycles: {len(both)} issues ({sev_both['critical']} critical, {sev_both['high']} high, {sev_both['medium']} medium, {sev_both['low']} low).")
out.append(f"- Confirmed by one cycle only: {len(single)} issues ({sev_single['critical']} critical, {sev_single['high']} high, {sev_single['medium']} medium, {sev_single['low']} low).")
out.append(f"- Found by both cycles but confirmed by only one skeptic: {len(half)}. One cycle confirmed, the other refuted: {len(disagree)}.")
out.append(f"- Uncertain or unverified: {len(uncertain)}. Refuted: {len(refuted)}.\n")

out.append("## Found independently by both cycles\n")
out.append("Each row is one defect that cycle 1 (from the spec) and cycle 2 (from the code) reached on their own, and that each cycle's skeptic failed to refute. These are the highest-confidence results.\n")
out.append("| # | Severity | Issue | Cycle 1 (verdict/severity) | Cycle 2 (verdict/severity) |")
out.append("|---:|---|---|---|---|")
for n, (title, a, b, sev) in enumerate(both, 1):
    out.append(f"| {n} | {sev} | {title} | {verdicts(a)} | {verdicts(b)} |")
out.append("")
for n, (title, a, b, sev) in enumerate(both, 1):
    f = sorted(survivors(a + b), key=sev_key)[0]
    out.append(f"**{n}. {title}** ({sev}). Where: {where(f)}. {summary_of(a + b)}\n")

if half:
    out.append("## Found by both cycles, confirmed by one skeptic\n")
    out.append("Both cycles reported it; one skeptic confirmed it and the other left it uncertain or never ran.\n")
    for title, a, b, sev in half:
        out.append(f"- **{title}** ({sev}): {verdicts(a)}; {verdicts(b)}.")
    out.append("")

if disagree:
    out.append("## One cycle confirmed, the other refuted\n")
    for title, a, b, sev in disagree:
        out.append(f"- **{title}**: {verdicts(a)}; {verdicts(b)}.")
    out.append("")

out.append("## Confirmed by one cycle only\n")
out.append("Real by its own cycle's skeptic, not reached by the other cycle. Full detail in `cycle-N/SUMMARY.md` under the id.\n")
out.append("| Severity | Cycle | Issue | Ids | Where |")
out.append("|---|---|---|---|---|")
for cycle, title, ids, sev in single:
    f = sorted(survivors(ids), key=sev_key)[0]
    out.append(f"| {sev} | {cycle} | {title} | {', '.join(short(i) for i in ids)} | {where(f, 1)} |")
out.append("")

out.append("## Related findings that are not the same defect\n")
for note, a, b in RELATED:
    out.append(f"- {note}: {verdicts(a)}; {verdicts(b)}.")
out.append("")

if uncertain:
    out.append("## Uncertain or unverified\n")
    for f in uncertain:
        out.append(f'- {short(f["id"])} ({f["verdict"]}, {f["severity"]}): {f["title"]}')
    out.append("")

out.append("## Refuted (do not chase these)\n")
for f in refuted:
    out.append(f'- {short(f["id"])}: {f["title"]}. Skeptic: {f.get("skeptic", "")}')
out.append("\nSTATUS: complete")

write_cycle2_summary()
open(path("REPORT.md"), "w").write("\n".join(out) + "\n")
print(f"both={len(both)} {dict(sev_both)} single={len(single)} {dict(sev_single)} disagree={len(disagree)} uncertain={len(uncertain)} refuted={len(refuted)}")
