#!/usr/bin/env python3
"""The gate of milestone 4: section 15.7 thresholds on the full 12.5 matrix.

Exits 0 only when every cell of the matrix, for the iOS versions and devices asked for, has a
result and that result is a pass. A cell that failed, could not run, or was never attempted
fails the gate; "not applicable" passes it, because the specification itself excludes the cell.

Usage: Tools/gate.py RESULTS_DIR [--os 17.5,18.6] [--device "iPhone 15"]
"""
import argparse
import itertools
import json
import pathlib
import sys

from summarize import SPEC


def slug(text):
    return text.replace(" ", "-").replace("(", "").replace(")", "")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("results")
    parser.add_argument("--os", default=",".join(SPEC["os"]))
    parser.add_argument("--device", action="append", help="repeatable; default: every device of the matrix")
    options = parser.parse_args()
    results = pathlib.Path(options.results)
    versions = [part.strip() for part in options.os.split(",") if part.strip()]
    devices = options.device or SPEC["device"]

    counts = {"pass": 0, "fail": 0, "not-runnable": 0, "not-applicable": 0, "missing": 0}
    examples = {}
    axes = [SPEC["appearance"], SPEC["contentSize"], SPEC["direction"], SPEC["input"], SPEC["script"]]
    for version in versions:
        for device in devices:
            for appearance, size, direction, keyboard, script in itertools.product(*axes):
                path = results / f"ios-{version}" / slug(device) / appearance / size / direction / keyboard / f"{script}.json"
                status = "missing"
                reason = "no result file"
                if path.exists():
                    try:
                        data = json.loads(path.read_text())
                        status = data.get("status", "missing")
                        reason = data.get("reason") or ""
                    except ValueError:
                        reason = "unreadable result file"
                counts[status] = counts.get(status, 0) + 1
                if status not in ("pass", "not-applicable"):
                    examples.setdefault(status, []).append(f"{path.relative_to(results)}: {reason}")

    total = sum(counts.values())
    print(f"{total} cells: " + ", ".join(f"{count} {status}" for status, count in counts.items()))
    for status, lines in examples.items():
        print(f"\n{status} ({len(lines)}):")
        for line in lines[:20]:
            print("  " + line[:300])
        if len(lines) > 20:
            print(f"  ...and {len(lines) - 20} more")
    blocked = counts["fail"] + counts["not-runnable"] + counts["missing"]
    if blocked:
        print(f"\nthe gate is closed: {blocked} of {total} cells are not passes")
        return 1
    print("\nthe gate is open")
    return 0


if __name__ == "__main__":
    sys.exit(main())
