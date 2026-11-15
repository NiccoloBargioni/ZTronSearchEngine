#!/usr/bin/env python3
"""Summarizes the per-cell results of the parity matrix.

Reads every cell result under a results directory and writes `summary.csv` (one row per
cell) and `summary.md` (coverage, comparator outcomes with the worst numbers, the cells that
could not run with the reason, and the failing cells).

Usage: Tools/summarize.py [RESULTS_DIR]
"""
import collections
import csv
import json
import pathlib
import sys

SPEC = {
    "os": ["15.5", "16.4", "17.5", "18.6", "27.0"],
    "device": ["iPhone SE (3rd generation)", "iPhone 15", "iPhone 15 Pro Max", "iPad (10th generation)"],
    "appearance": ["light", "dark", "increased-contrast", "reduce-transparency", "bold-text"],
    "contentSize": ["XS", "L", "XXXL", "AX5"],
    "direction": ["ltr", "rtl"],
    "input": ["software", "hardware"],
    "script": ["type", "backspace-select", "backspace-delete", "tap-select", "clear", "submit", "cancel", "text-to-token",
               "token-overflow", "focus-round-trip"],
}
COMPARATORS = ["pixels", "metrics", "eventLog", "accessibility", "animation", "state"]


def load(results):
    cells = []
    for path in sorted(results.rglob("*.json")):
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and "cell" in data and "status" in data:
            data["_path"] = str(path.relative_to(results))
            cells.append(data)
    return cells


def number(value):
    """Result files write non-finite numbers as strings."""
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(value)
    except (TypeError, ValueError):
        return float("nan")


def comparator_outcomes(cell):
    """comparator -> True (passed), False (failed) or None (not compared), for a cell that ran."""
    outcomes = dict.fromkeys(COMPARATORS)
    checkpoints = cell.get("checkpoints") or []
    if checkpoints:
        for name in ("pixels", "metrics", "accessibility", "state"):
            outcomes[name] = all(checkpoint[name]["passes"] for checkpoint in checkpoints)
    if cell.get("eventLog"):
        outcomes["eventLog"] = cell["eventLog"]["passes"]
    if cell.get("animation"):
        outcomes["animation"] = cell["animation"]["passes"]
    return outcomes


def fraction(passed, failed):
    return f"{passed}/{passed + failed}" if passed + failed else "-"


def main():
    results = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent / "Results").resolve()
    cells = load(results)
    if not cells:
        print(f"no cell results under {results}")
        return 1

    rows = []
    for cell in cells:
        identity = cell["cell"]
        outcomes = comparator_outcomes(cell) if cell["status"] in ("pass", "fail") else dict.fromkeys(COMPARATORS)
        rows.append({
            "os": identity["os"], "device": identity["device"], "appearance": identity["appearance"],
            "contentSize": identity["contentSize"], "direction": identity["direction"], "input": identity["input"],
            "script": identity["script"], "status": cell["status"],
            **{name: {True: "pass", False: "fail", None: ""}[outcomes[name]] for name in COMPARATORS},
            "worstPixelPercent": cell.get("worstPixelPercent", ""), "worstDeltaE": cell.get("worstDeltaE", ""),
            "worstMetricDeviation": cell.get("worstMetricDeviation", ""),
            "toleratedDeviations": len(cell.get("toleratedDeviations") or []),
            "failureCount": len(cell.get("failures") or []),
            "reason": (cell.get("reason") or "").replace("\n", " "),
            "result": cell["_path"],
        })
    with open(results / "summary.csv", "w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    groups = collections.OrderedDict()
    for cell, row in zip(cells, rows):
        groups.setdefault((row["os"], row["device"]), []).append((cell, row))
    per_group = 1
    for axis in ("appearance", "contentSize", "direction", "input", "script"):
        per_group *= len(SPEC[axis])

    lines = ["# Parity matrix results", ""]
    lines.append(f"{len(cells)} cell results under `{results.name}/`. Thresholds (specification 15.7): at most 0.5% of pixels "
                 "differ and no differing pixel exceeds ΔE 2 (CIEDE2000); layout metrics within 0.5 pt; event logs and "
                 "accessibility trees identical; text-to-token animation within one frame (16.7 ms) with the same final frame.")
    lines += ["", "## Coverage", "",
              f"The matrix of specification 12.5 has {per_group} cells per iOS version and device.", "",
              "| iOS | Device | Results | Ran | Passed | Failed | Not runnable | Not applicable |",
              "|---|---|---:|---:|---:|---:|---:|---:|"]
    for (version, device), members in groups.items():
        count = collections.Counter(row["status"] for _, row in members)
        ran = count["pass"] + count["fail"]
        lines.append(f"| {version} | {device} | {len(members)} | {ran} | {count['pass']} | {count['fail']} | "
                     f"{count['not-runnable']} | {count['not-applicable']} |")
    missing = [(version, device) for version in SPEC["os"] for device in SPEC["device"] if (version, device) not in groups]
    if missing:
        lines += ["", "No result at all (never attempted): " + ", ".join(f"iOS {version} / {device}" for version, device in missing) + "."]

    lines += ["", "## Comparators", "",
              "Cells that ran, as passed/compared per comparator, with the worst numbers of the group.", "",
              "| iOS | Device | Pixels | Metrics | Event log | Accessibility | Animation | State | Worst pixel % | Worst ΔE | Worst metric (pt) |",
              "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for (version, device), members in groups.items():
        ran = [(cell, row) for cell, row in members if row["status"] in ("pass", "fail")]
        if not ran:
            continue
        parts = []
        for name in COMPARATORS:
            passed = sum(1 for _, row in ran if row[name] == "pass")
            failed = sum(1 for _, row in ran if row[name] == "fail")
            parts.append(fraction(passed, failed))
        worst_pixel = max((number(cell.get("worstPixelPercent", 0)) for cell, _ in ran), default=0)
        worst_delta = max((number(cell.get("worstDeltaE", 0)) for cell, _ in ran), default=0)
        worst_metric = max((number(cell.get("worstMetricDeviation", 0)) for cell, _ in ran), default=0)
        lines.append(f"| {version} | {device} | " + " | ".join(parts) + f" | {worst_pixel:.3f} | {worst_delta:.2f} | {worst_metric:.2f} |")

    tolerated = collections.Counter()
    for cell in cells:
        for entry in cell.get("toleratedDeviations") or []:
            tolerated[entry.split(":")[0]] += 1
    if tolerated:
        lines += ["", "## Tolerated deviations applied", "",
                  "Cells in which the harness applied one of the deviations specification 12.5 allows.", ""]
        lines += [f"- {name}: {count} cells" for name, count in tolerated.most_common()]

    reasons = collections.Counter(row["reason"] for row in rows if row["status"] in ("not-runnable", "not-applicable"))
    if reasons:
        lines += ["", "## Cells that could not run", "", "| Cells | Reason |", "|---:|---|"]
        lines += [f"| {count} | {reason} |" for reason, count in reasons.most_common()]

    failing = [(cell, row) for cell, row in zip(cells, rows) if row["status"] == "fail"]
    lines += ["", "## Failing cells", ""]
    if not failing:
        lines.append("None.")
    else:
        lines += [f"{len(failing)} cells; `summary.csv` lists all of them and each result file lists every failure.", "",
                  "| iOS | Device | Appearance | Size | Dir | Input | Script | Failed comparators | Pixel % | ΔE | Metric (pt) | First failure |",
                  "|---|---|---|---|---|---|---|---|---:|---:|---:|---|"]
        for cell, row in failing[:400]:
            failed = ", ".join(name for name in COMPARATORS if row[name] == "fail") or "driver"
            first = (cell.get("failures") or [row["reason"]])[0].replace("|", "\\|")
            if len(first) > 150:
                first = first[:147] + "..."
            lines.append(
                f"| {row['os']} | {row['device']} | {row['appearance']} | {row['contentSize']} | {row['direction']} | {row['input']} | "
                f"{row['script']} | {failed} | {number(row['worstPixelPercent']):.3f} | {number(row['worstDeltaE']):.2f} | "
                f"{number(row['worstMetricDeviation']):.2f} | {first} |")
        if len(failing) > 400:
            lines.append(f"\n...and {len(failing) - 400} more in `summary.csv`.")
    (results / "summary.md").write_text("\n".join(lines) + "\n")

    status = collections.Counter(row["status"] for row in rows)
    print(f"{len(rows)} cells: {status['pass']} passed, {status['fail']} failed, {status['not-runnable']} not runnable, "
          f"{status['not-applicable']} not applicable; wrote {results / 'summary.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
