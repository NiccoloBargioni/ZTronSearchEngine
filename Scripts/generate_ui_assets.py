#!/usr/bin/env python3
"""Generates the UI product's asset catalog and metrics table from UIKit samples.

The search field's colors and metrics are sampled from UIKit by the parity host, never typed
from memory (specification section 12.4). The sampler (ParityHost/Tools/sample.sh) writes one
JSON file per iOS major version into ParityHost/Samples/; this script turns them into

  Sources/ZTronSearchEngineUI/Resources/Colors.xcassets
  Sources/ZTronSearchEngineUI/ZTronSearchFieldMetrics+Sampled.swift

Usage: python3 Scripts/generate_ui_assets.py [--samples ParityHost/Samples] [--check]

--check regenerates in memory and exits non-zero when the committed files differ: the build
step that fails when a sampled value drifts.

A sample file holds:
  majorVersion          the iOS major version it was sampled on
  colors                name -> appearance -> [red, green, blue, alpha] in sRGB
  metricsByContentSize  content size -> metric -> points (or seconds, for durations)
  behavior              what the reference does where the specification says "recorded"
The sampler also records where each value came from (sampledOn, colorSources, defaults,
rects, notes); those are for people and for the checks below.
"""
import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
COLOR_NAMES = ["searchFieldFill", "tokenFill", "tokenText", "tokenSelectedFill", "tokenSelectedText", "placeholderText", "clearGlyph"]
APPEARANCES = ["light", "dark", "lightHighContrast", "darkHighContrast"]
CONTENT_SIZES = [
    "xSmall", "small", "medium", "large", "xLarge", "xxLarge", "xxxLarge",
    "accessibility1", "accessibility2", "accessibility3", "accessibility4", "accessibility5",
]
# The arguments of ZTronSearchFieldMetrics.init, in order: (field, key of the sample's metrics,
# kind). A length is in points, a duration in seconds, a scale is the index of an SF Symbol
# scale (0 small, 1 medium, 2 large) and a flag is 0 or 1.
METRIC_FIELDS = [
    ("fieldHeight", "fieldHeight", "length"), ("cornerRadius", "cornerRadius", "length"),
    ("glyphLeading", "glyphLeading", "length"), ("glyphTop", "glyphTop", "length"),
    ("glyphWidth", "glyphWidth", "length"), ("glyphHeight", "glyphHeight", "length"),
    ("glyphScale", "glyphShownScaleIndex", "scale"), ("showsGlyphWithContent", "glyphShownWithContent", "flag"),
    ("textLeading", "textLeading", "length"), ("contentLeading", "contentLeading", "length"),
    ("textTrailing", "textTrailing", "length"), ("textTrailingWithClearButton", "textTrailingWithClearButton", "length"),
    ("baseline", "baseline", "length"), ("fontSize", "fontSize", "length"),
    ("clearButtonWidth", "clearButtonWidth", "length"), ("clearButtonHeight", "clearButtonHeight", "length"),
    ("clearButtonTop", "clearButtonTop", "length"), ("clearButtonTrailing", "clearButtonTrailing", "length"),
    ("clearButtonScale", "clearScaleIndex", "scale"),
    ("tokenHeight", "tokenHeight", "length"), ("tokenTop", "tokenTop", "length"),
    ("tokenCornerRadius", "tokenCornerRadius", "length"), ("tokenHorizontalPadding", "tokenHorizontalPadding", "length"),
    ("tokenIconSpacing", "tokenIconSpacing", "length"), ("tokenLabelTop", "tokenLabelTop", "length"),
    ("tokenFontSize", "tokenFontSize", "length"), ("tokenSpacing", "tokenSpacing", "length"),
    ("tokenLeadingInset", "tokenLeadingInset", "length"), ("tokenTextSpacing", "tokenToTextSpacing", "length"),
    ("tokenWidthLimitShare", "tokenWidthLimitShare", "length"), ("tokenWidthLimitExtra", "tokenWidthLimitExtra", "length"),
    ("caretRoomAfterToken", "caretRoomAfterToken", "length"),
    ("caretRoomAfterText", "caretRoomAfterText", "length"), ("overflowFadeLength", "overflowFadeLength", "length"),
    ("cancelButtonSpacing", "cancelButtonSpacing", "length"), ("cancelButtonTop", "cancelButtonTop", "length"),
    ("cancelButtonHeight", "cancelButtonHeight", "length"), ("cancelTitleTop", "cancelTitleTop", "length"),
    ("cancelTitleHeight", "cancelTitleHeight", "length"), ("cancelFontSize", "cancelFontSize", "length"),
    ("tokenInsertionDuration", "tokenInsertionDuration", "duration"),
    ("cancelAnimationDuration", "cancelAnimationDuration", "duration"),
]
SYMBOL_SCALES = [".small", ".medium", ".large"]
BEHAVIOR_FIELDS = ["clearRemovesTokens", "clearBeginsEditing", "typingReplacesSelectedTokens", "submitKeepsEditing", "conversionSelectsToken"]


class SampleError(Exception):
    pass


def load_samples(directory):
    samples = {}
    for path in sorted(directory.glob("ios-*.json")):
        data = json.loads(path.read_text())
        validate(data, path.name)
        samples[int(data["majorVersion"])] = data
    return samples


def validate(sample, name):
    """A sample must carry everything the product is generated from, and nothing provisional."""
    if sample.get("provisional"):
        raise SampleError(f"{name} is a provisional placeholder, not a sample of UIKit: run ParityHost/Tools/sample.sh")
    for color in COLOR_NAMES:
        for appearance in APPEARANCES:
            components = sample.get("colors", {}).get(color, {}).get(appearance)
            if not isinstance(components, list) or len(components) != 4:
                raise SampleError(f"{name}: color {color} has no {appearance} variant")
    sizes = sample.get("metricsByContentSize", {})
    for size in CONTENT_SIZES:
        if size not in sizes:
            raise SampleError(f"{name}: no metrics for content size {size}")
        for _, key, kind in METRIC_FIELDS:
            value = sizes[size].get(key)
            if not isinstance(value, (int, float)):
                raise SampleError(f"{name}: content size {size} has no metric {key}")
            if kind == "scale" and value not in (0, 1, 2):
                raise SampleError(f"{name}: {key} is {value} at {size}, not the index of a symbol scale")
            if kind == "flag" and value not in (0, 1):
                raise SampleError(f"{name}: {key} is {value} at {size}, not a flag")
        # The symbols are drawn at the body font's point size; the layout relies on it.
        metrics = sizes[size]
        for key in ("clearPointSize", "tokenIconShownPointSize"):
            if abs(metrics.get(key, -1) - metrics["fontSize"]) > 0.01:
                raise SampleError(f"{name}: {key} is {metrics.get(key)} at {size}, not the font size {metrics['fontSize']}")
        glyph = metrics.get("glyphShownPointSize", -1)
        if abs(glyph - metrics["fontSize"]) > 0.01:
            raise SampleError(f"{name}: the glyph is drawn at {glyph} pt at {size}, not the font size {metrics['fontSize']}")
        if metrics.get("tokenIconShownScaleIndex") != 0:
            raise SampleError(f"{name}: the token icon is not drawn at the small symbol scale at {size}")
    for field in BEHAVIOR_FIELDS:
        if not isinstance(sample.get("behavior", {}).get(field), bool):
            raise SampleError(f"{name}: behavior.{field} was not recorded")


def color_entry(components, appearance):
    entry = {
        "color": {
            "color-space": "srgb",
            "components": {
                "red": f"{components[0]:.4f}", "green": f"{components[1]:.4f}",
                "blue": f"{components[2]:.4f}", "alpha": f"{components[3]:.4f}",
            },
        },
        "idiom": "universal",
    }
    appearances = []
    if appearance in ("dark", "darkHighContrast"):
        appearances.append({"appearance": "luminosity", "value": "dark"})
    if appearance in ("lightHighContrast", "darkHighContrast"):
        appearances.append({"appearance": "contrast", "value": "high"})
    if appearances:
        entry["appearances"] = appearances
    return entry


def catalog_files(sample):
    files = {"Contents.json": json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"}
    for name in COLOR_NAMES:
        colors = [color_entry(sample["colors"][name][appearance], appearance) for appearance in APPEARANCES]
        contents = {"colors": colors, "info": {"author": "xcode", "version": 1}}
        files[f"{name}.colorset/Contents.json"] = json.dumps(contents, indent=2) + "\n"
    return files


def number(value, digits=6):
    text = f"{float(value):.{digits}f}".rstrip("0").rstrip(".")
    return text if text not in ("", "-0") else "0"


def duration(sample, key):
    """A duration is timed frame by frame at every content size and does not depend on it:
    the median of the sizes, as a whole number of 60 Hz frames."""
    values = sorted(sample["metricsByContentSize"][size][key] for size in CONTENT_SIZES)
    median = values[len(values) // 2]
    return round(median * 60) / 60


def metrics_literal(sample, size, indent):
    metrics = sample["metricsByContentSize"][size]
    arguments = []
    for field, key, kind in METRIC_FIELDS:
        if kind == "scale":
            value = SYMBOL_SCALES[int(metrics[key])]
        elif kind == "flag":
            value = "true" if metrics[key] else "false"
        elif kind == "duration":
            value = number(duration(sample, key))
        else:
            value = number(metrics[key])
        arguments.append(f"{field}: {value}")
    lines = [f"{indent}ZTronSearchFieldMetrics("]
    row = indent + "    "
    for argument in arguments:
        candidate = row + argument + ", "
        if len(candidate) > 118:
            lines.append(row.rstrip())
            row = indent + "    " + argument + ", "
        else:
            row = candidate
    lines.append(row.rstrip().rstrip(","))
    lines.append(f"{indent})")
    return "\n".join(lines)


def metrics_source(samples):
    versions = sorted(samples)
    lines = [
        "import SwiftUI",
        "",
        "// Generated by Scripts/generate_ui_assets.py from ParityHost/Samples. Do not edit by hand:",
        "// re-sample with the parity host (ParityHost/Tools/sample.sh) and run the script again.",
        "",
        "extension ZTronSearchFieldMetrics {",
        "    /// The iOS major versions the UIKit reference was sampled on, ascending.",
        f"    static let sampledVersions: [Int] = [{', '.join(str(version) for version in versions)}]",
        "",
        "    /// Metrics sampled from the UIKit reference on an iOS major version, by content size.",
        "    static func sampled(forMajorVersion version: Int) -> [ContentSize: ZTronSearchFieldMetrics]? {",
        "        switch version {",
    ]
    for version in versions:
        lines.append(f"        case {version}: return sampled{version}")
    lines += [
        "        default: return nil",
        "        }",
        "    }",
        "",
        "    /// The newest sampled version at the default content size: what is used when a table",
        "    /// has no entry.",
        "    static let fallback: ZTronSearchFieldMetrics =",
        metrics_literal(samples[versions[-1]], "large", "        "),
    ]
    for version in versions:
        sampled_on = samples[version].get("sampledOn", {})
        lines += [
            "",
            f"    /// Sampled on iOS {sampled_on.get('osVersion', version)} ({sampled_on.get('device', 'simulator')}).",
            f"    private static let sampled{version}: [ContentSize: ZTronSearchFieldMetrics] = [",
        ]
        for size in CONTENT_SIZES:
            lines.append(f"        .{size}:")
            lines.append(metrics_literal(samples[version], size, "            ") + ",")
        lines.append("    ]")
    lines += [
        "}",
        "",
        "extension ZTronSearchFieldBehavior {",
        "    /// What the UIKit reference does where the specification says \"recorded, never assumed\",",
        "    /// keyed by iOS major version.",
        "    static let sampled: [Int: ZTronSearchFieldBehavior] = [",
    ]
    for version in versions:
        behavior = samples[version]["behavior"]
        arguments = ", ".join(f"{field}: {str(bool(behavior[field])).lower()}" for field in BEHAVIOR_FIELDS)
        lines.append(f"        {version}: ZTronSearchFieldBehavior({arguments}),")
    newest = samples[versions[-1]]["behavior"]
    arguments = ", ".join(f"{field}: {str(bool(newest[field])).lower()}" for field in BEHAVIOR_FIELDS)
    lines += [
        "    ]",
        "",
        f"    /// The record of the newest sampled version, iOS {versions[-1]}.",
        f"    static let newestSampled = ZTronSearchFieldBehavior({arguments})",
        "}",
        "",
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", default=str(ROOT / "ParityHost" / "Samples"))
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()

    try:
        samples = load_samples(pathlib.Path(arguments.samples))
    except SampleError as error:
        print(error, file=sys.stderr)
        return 2
    if not samples:
        print("no samples found in", arguments.samples, file=sys.stderr)
        return 2
    # An asset catalog has no variant per OS version, so it carries the colors of the newest
    # sampled version; a version whose colors differ is reported.
    newest = samples[max(samples)]
    drift = sorted(version for version, sample in samples.items()
                   if any(sample["colors"][name] != newest["colors"][name] for name in COLOR_NAMES))

    expected = {}
    catalog = ROOT / "Sources" / "ZTronSearchEngineUI" / "Resources" / "Colors.xcassets"
    for relative, contents in catalog_files(newest).items():
        expected[catalog / relative] = contents
    expected[ROOT / "Sources" / "ZTronSearchEngineUI" / "ZTronSearchFieldMetrics+Sampled.swift"] = metrics_source(samples)
    unexpected = [path for path in catalog.rglob("Contents.json") if path not in expected] if catalog.exists() else []

    if drift:
        print(f"note: the colors sampled on iOS {drift} differ from those of iOS {max(samples)}, which the catalog carries")
    if arguments.check:
        stale = [str(path.relative_to(ROOT)) for path, contents in expected.items()
                 if not path.exists() or path.read_text() != contents]
        stale += [str(path.relative_to(ROOT)) + " (not generated)" for path in unexpected]
        for path in stale:
            print("drift:", path)
        return 1 if stale else 0

    for path in unexpected:
        path.unlink()
        if not any(path.parent.iterdir()):
            path.parent.rmdir()
    for path, contents in expected.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
    print(f"wrote {len(expected)} files from samples of iOS {sorted(samples)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
