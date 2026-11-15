#!/usr/bin/env python3
"""Samples the UIKit reference and writes ParityHost/Samples/ios-<major>.json.

The clone's defaults are sampled from UIKit, not typed from memory (specification section
12.4). For every iOS version asked for, this script boots a simulator, puts it in each content
size and appearance in turn, and runs the sampler of the host app's UI test bundle, which
measures a real UISearchTextField inside a real UISearchBar. It then merges what was measured
into one file per iOS major version, in the schema Scripts/generate_ui_assets.py reads.

Usage: Tools/sample.sh [--os 17.5,18.6,26.5,27.0] [--device "iPhone 15"] [--skip-build]
                       [--keep-booted]

After sampling, regenerate the product's assets:  python3 Scripts/generate_ui_assets.py
"""
import argparse
import datetime
import json
import os
import pathlib
import shutil
import subprocess
import sys

import matrix

# SwiftUI's DynamicTypeSize case name -> the name `simctl ui content_size` takes.
CONTENT_SIZES = [
    ("xSmall", "extra-small"), ("small", "small"), ("medium", "medium"), ("large", "large"), ("xLarge", "extra-large"),
    ("xxLarge", "extra-extra-large"), ("xxxLarge", "extra-extra-extra-large"), ("accessibility1", "accessibility-medium"),
    ("accessibility2", "accessibility-large"), ("accessibility3", "accessibility-extra-large"),
    ("accessibility4", "accessibility-extra-extra-large"), ("accessibility5", "accessibility-extra-extra-extra-large"),
]
# Appearance of a sampling run -> the key of the color variant it renders.
APPEARANCES = [("light", "light"), ("dark", "dark"), ("increased-contrast", "lightHighContrast"),
               ("dark-increased-contrast", "darkHighContrast")]
# The colors the asset catalog carries, and where each comes from in a sample.
CATALOG_COLORS = ["searchFieldFill", "tokenFill", "tokenText", "tokenSelectedFill", "tokenSelectedText", "placeholderText", "clearGlyph"]


def run_sampler(udid, xctestrun, work, test, output):
    """Runs one sampler test of the UI test bundle; returns the JSON it wrote, or None."""
    work.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()
    environment = dict(os.environ)
    environment["TEST_RUNNER_ZTRON_PARITY_SAMPLE_OUT"] = str(output)
    environment["TEST_RUNNER_ZTRON_PARITY_SCRATCH"] = str(work)
    result_bundle = work / f"{output.stem}.xcresult"
    shutil.rmtree(result_bundle, ignore_errors=True)
    with open(work / f"{output.stem}.log", "w") as log:
        subprocess.run(
            ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "-destination", f"id={udid}",
             f"-only-testing:ParityHostUITests/SamplerUITests/{test}", "-resultBundlePath", str(result_bundle),
             "-derivedDataPath", str(work / "derived"), "-collect-test-diagnostics", "never"],
            stdout=log, stderr=subprocess.STDOUT, env=environment,
        )
    if not output.exists():
        return None
    return json.loads(output.read_text())


def sample_version(version, runtime, types, options, xctestrun):
    device = options.device
    udid = matrix.simulator(version, device, runtime, types)
    matrix.boot(udid)
    work = matrix.HOST / ".derived" / "samples" / version
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    by_size = {}
    for name, simctl_name in CONTENT_SIZES:
        matrix.configure(udid, "light", "L")
        matrix.simctl("ui", udid, "content_size", simctl_name)
        sample = run_sampler(udid, xctestrun, work, "testSampleAppearance", work / f"light-{name}.json")
        if sample is None:
            sys.exit(f"iOS {version}: the sampler wrote nothing at content size {name}, see {work}/light-{name}.log")
        by_size[name] = sample
        matrix.log(f"iOS {version}: sampled content size {name}: field height {sample['metrics'].get('fieldHeight')}")

    by_appearance = {"light": by_size["large"]}
    for appearance, key in APPEARANCES[1:]:
        matrix.configure(udid, appearance, "L")
        sample = run_sampler(udid, xctestrun, work, "testSampleAppearance", work / f"{appearance}-large.json")
        if sample is None:
            sys.exit(f"iOS {version}: the sampler wrote nothing under the {appearance} appearance, see {work}/{appearance}-large.log")
        by_appearance[key] = sample
        matrix.log(f"iOS {version}: sampled appearance {appearance}")

    matrix.configure(udid, "light", "L")
    behavior = run_sampler(udid, xctestrun, work, "testSampleBehavior", work / "behavior.json")
    if behavior is None:
        sys.exit(f"iOS {version}: the behavior sampler wrote nothing, see {work}/behavior.log")
    matrix.log(f"iOS {version}: sampled behavior: {json.dumps({k: v for k, v in behavior.items() if k != 'notes'})}")
    if not options.keep_booted:
        matrix.simctl("shutdown", udid, check=False)

    base = by_size["large"]
    notes = []
    colors = {}
    sources = {}
    for name in CATALOG_COLORS:
        colors[name] = {}
        for _, key in APPEARANCES:
            resolved = base["colors"].get(name, {}).get(key)
            rendered = by_appearance[key]["renderedColors"].get(name)
            resolved = resolved if resolved and len(resolved) == 4 else None
            rendered = rendered if rendered and len(rendered) == 4 else None
            if resolved is None and rendered is None:
                sys.exit(f"iOS {version}: the color {name} could neither be resolved nor rendered under {key}")
            if resolved is None:
                colors[name][key] = rendered
                notes.append(f"{name} ({key}): no UIColor could be resolved; taken from pixels rendered over white and over black")
                continue
            colors[name][key] = resolved
            if rendered is None:
                continue
            # A rendering knows a color to 8 bits; a translucent one, solved from two renderings,
            # to a little less. Within that, the resolved UIColor is the exact value of what is
            # drawn. Beyond it UIKit draws something else than the color it holds: an opaque
            # rendering is then exact and wins.
            worst = max(abs(a - b) for a, b in zip(resolved, rendered))
            opaque = rendered[3] >= 0.999 and resolved[3] >= 0.999
            if worst <= (0.006 if opaque else 0.03):
                continue
            described = f"resolves to {[round(v, 4) for v in resolved]} but is drawn as {[round(v, 4) for v in rendered]}"
            if rendered[3] >= 0.999:
                colors[name][key] = rendered
                notes.append(f"{name} ({key}): the reference's UIColor {described}; the drawn color is used")
            else:
                notes.append(f"{name} ({key}): the reference's UIColor {described}; the drawn color is translucent and "
                             "too coarse to use, the resolved one is kept")
        sources[name] = base["defaults"].get(f"{name}Source", "the UIColor the reference draws with, resolved per appearance")
    for sample in list(by_size.values()) + list(by_appearance.values()):
        for note in sample.get("notes", []):
            if note not in notes:
                notes.append(note)

    merged = {
        "majorVersion": int(version.split(".")[0]),
        "sampledOn": {
            "osVersion": base["osVersion"], "device": device, "modelIdentifier": base["modelIdentifier"],
            "scale": base["scale"], "date": datetime.date.today().isoformat(),
        },
        "colors": colors,
        "colorSources": sources,
        "renderedColors": {key: by_appearance[key]["renderedColors"] for _, key in APPEARANCES},
        "otherColors": {name: value for name, value in sorted(base["colors"].items()) if name not in CATALOG_COLORS},
        "metrics": base["metrics"],
        "metricsByContentSize": {name: by_size[name]["metrics"] for name, _ in CONTENT_SIZES},
        "behavior": behavior,
        "defaults": base["defaults"],
        "rects": base["rects"],
        "notes": notes,
    }
    path = matrix.HOST / "Samples" / f"ios-{merged['majorVersion']}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
    matrix.log(f"iOS {version}: wrote {path}")
    for note in notes:
        matrix.log(f"iOS {version}: note: {note}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--os", default="17.5,18.6,26.5,27.0", help="iOS versions (major.minor), one per major version")
    parser.add_argument("--device", default="iPhone 15")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--keep-booted", action="store_true")
    options = parser.parse_args()

    installed = matrix.runtimes()
    types = matrix.device_types()
    scratch = matrix.HOST / ".derived" / "samples"
    scratch.mkdir(parents=True, exist_ok=True)
    versions = [part.strip() for part in options.os.split(",") if part.strip()]
    runnable = []
    for version in versions:
        runtime = installed.get(version)
        if runtime is None or not runtime.get("isAvailable", False):
            reason = "is not installed" if runtime is None else runtime.get("availabilityError", "is not available")
            matrix.log(f"iOS {version}: not sampled: the simulator runtime {reason}")
            continue
        runnable.append((version, runtime))
    if not runnable:
        sys.exit("no runnable iOS version to sample")
    if not options.skip_build:
        matrix.build(scratch)
    xctestrun = matrix.test_run_file(scratch)
    for version, runtime in runnable:
        sample_version(version, runtime, types, options, xctestrun)


if __name__ == "__main__":
    main()
