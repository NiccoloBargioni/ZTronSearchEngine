# ParityHost

The UIKit parity host of `ZTronSearchField` (specification sections 12.4, 12.5 and 15.7).
It renders the pure SwiftUI field and a real `UISearchTextField` side by side at identical
sizes, drives both with the same scripts, and compares pixels, layout metrics, event logs,
accessibility trees and the text-to-token animation. It is a test host and is never shipped:
this directory is the only place in the repository that imports UIKit.

## The arrangement, and why

| Part | What it is | What it does |
|---|---|---|
| `Package.swift`, `Sources/ZTronSearchEngineUIParity` | Swift package, library | The UIKit reference field, the clone's wrapper, the stage that holds both, the scripts, capture, the comparators, the sampler |
| `Tests/ZTronSearchEngineUIParityTests` | package tests, no host app | The comparators against hand-made inputs (`ComparatorTests`), and what a host-less bundle can and cannot do (`HostCapabilityTests`) |
| `App/ParityHost.xcodeproj` / `ParityHostApp` | iOS app | The measuring instrument: hosts both fields, takes snapshots, measures frames, records logs, runs the comparators, writes one JSON result per cell |
| `App/ParityHost.xcodeproj` / `ParityHostUITests` | XCUITest bundle | The driver: real touches and keys, and the accessibility tree as the accessibility runtime hands it to a client |
| `Tools/` | Python and shell | `sample.sh`, `run-matrix.sh`, `summarize.py`, `gate.py` |
| `Samples/` | JSON, checked in | What UIKit was measured to be, per iOS major version: the input of `Scripts/generate_ui_assets.py` |
| `Results/`, `ReferenceSnapshots/` | generated | The per-cell results with `summary.md` / `summary.csv`, and the reference's snapshots per cell |

A package test bundle without a host app was tried first, because it would have been the
simplest arrangement. It cannot measure this (iOS 17.5, `xctest` process, no `UIApplication`):
`drawHierarchy` fails ("Render server returned error"), text input reaches neither the UIKit
delegate nor the SwiftUI binding (`insertText` raises no `shouldChangeCharactersIn` and no
`editingChanged`), and the accessibility runtime is not loaded. `HostCapabilityTests` pins
those findings, so a toolchain in which they change is noticed.

Input injected from inside the app was rejected too: `insertText` on the reference raises
`didChangeSelection` and `editingChanged` but not `shouldChangeCharactersIn`, so its log is
not the log a user produces. Every touch and key therefore comes from XCUITest:

- taps are real touches at screen coordinates the app reports for each field;
- software input is taps on the keys of the on-screen keyboard;
- hardware input is `XCUIApplication.typeKey`, which the app receives as `UIPress` key events
  (the result records how many each field saw). Characters and the return key arrive; the
  delete key does not under any of XCUITest's names for it, so the driver checks that a
  special key reached the field and records the cell as `not-runnable` when it did not,
  rather than compare two fields that were given nothing;
- only what a host does in code (`becomeFirstResponder`, the `.focused` binding) and waiting
  are performed inside the app.

The driver and the app talk through JSON files in a directory of the Mac, which a simulator
shares with its host (`ParityProtocol.swift`). The app is launched once per appearance and
content size and runs every direction, input and script of that configuration.

The reference is `UISearchBar().searchTextField`: a real `UISearchTextField` laid out by a
real search bar, which is also what provides the Cancel button. The clone is given the same
slot size one whole number of pixels below it, so both are in one rendering of one window.

### What is exercised, and what is not

Exercised: the ten scripts of section 12.5 under both layout directions and both inputs, on
whatever simulator the bundle is launched on; pixels of both fields from one `drawHierarchy`
of the stage; frames of the field, glyph, tokens, clear button and Cancel button and the text
baseline; the complete event log of each field; the accessibility tree of each field
(type, label, value, placeholder, identifier, selected, enabled, custom action names); the
frame-by-frame record of the text-to-token conversion.

Not exercised: iOS 15.5 and 16.4 (their simulator runtimes do not boot on this macOS; the
cells are written as `not-runnable` with the runtime's own message); physical devices; a
physical keyboard (key events come from XCUITest); shift-arrow range selection (no script
uses it); `tokenCopying` (no script uses it). Reduce Transparency and Bold Text have no
`simctl` switch and are set through the simulator's accessibility preferences; the app
checks the environment it actually runs in and records a cell as `not-runnable` when the
simulator is not in the cell's configuration, so a setting that did not take is never
compared as if it had. Under the Arabic interface of the right-to-left column the simulator's
on-screen keyboard has no Latin keys; scripts that type are recorded as `not-runnable` for
right-to-left software input and run with hardware input. The two backspace scripts are
`not-runnable` with hardware input (see above) and run with software input.

A simulator announces a hardware keyboard the first time one types on it, in an alert of its
home screen that fails the test that typed. `run-matrix.sh` therefore runs
`ParityMatrixUITests/testPrepareHardwareKeyboard` once per simulator before the cells.

Now and then an app process stops reporting itself idle, and XCUITest then waits a minute
before every event it sends. The cause is not known. The driver notices an event that took
more than 30 seconds, records the cell under way as `not-runnable` and gives the next cell a
fresh app; `run-matrix.sh` also stops one appearance and content size after `--timeout`
minutes (15 by default) and keeps what was compared until then.

## Comparators and thresholds (section 15.7)

| Comparison | Threshold | How it is measured |
|---|---|---|
| Pixels | at most 0.5% of pixels differ, and no differing pixel exceeds ΔE 2 | 8-bit sRGB snapshots at device scale. A pixel differs when any channel differs. ΔE is CIEDE2000 (kL = kC = kH = 1) between the two pixels converted to CIELAB under D65; CIE76 is recorded next to it. CIEDE2000 is used because it is the current CIE recommendation and the one whose unit is closest to "just noticeable" across hues; CIE76 overstates differences in saturated blues, which is where the selected token lives. |
| Layout metrics | within 0.5 pt | Frames of field, glyph, each token, clear button, Cancel button, and the first text baseline, in slot coordinates |
| Event log | identical order and payloads | After the two adjustments below, and nothing else |
| Accessibility tree | identical | The content nodes of each field's tree, in order |
| Text-to-token animation | same duration within one frame (16.7 ms), same final frame | A display-link recorder notes, every refresh, whether anything visible changed (place, size, opacity or fill of any layer that draws). The duration is the time from the first changed frame to the last, in whole frames; the raw time is kept as `rawDuration` |

The caret of either field is masked (its rectangle plus one pixel). The tolerated deviations
of section 12.5 are applied as follows, and each application is listed in the cell's result
under `toleratedDeviations`:

1. Range selection. Below iOS 18 both logs are reduced to changes of the token selection
   (text ranges dropped, entries that leave the set of selected tokens unchanged removed);
   from iOS 18 the text ranges are compared too. In snapshots, what UIKit draws for a range
   selection and only for one is masked: the two handles with the reach of their shadows,
   and the corners of the selected tokens that the selection highlight squares off. The
   result keeps the comparison with the caret alone masked as `pixelsCaretOnly`.
2. `textInputPolicy`. An `editingChanged` directly after a denied `shouldChange` is dropped
   from the clone's log.
3. `tokenCopying`: not applicable, no script.
4. Shift-arrow selection on iOS 15 and 16: no script.

Nothing else is filtered. A cell is `pass`, `fail`, `not-runnable` (with the reason) or
`not-applicable`.

## Sampling UIKit

    Tools/sample.sh [--os 17.5,18.6] [--device "iPhone 15"] [--skip-build] [--keep-booted]

For each iOS version the sampler boots a simulator, puts it in each of the twelve content
sizes and four appearances in turn, and measures the reference: field height, corner radius,
glyph frame, symbol point size and scale, text and placeholder and editing rectangles,
clear-button rectangle, token height, corner radius, paddings, icon spacing, token spacing
and font, the Cancel button, the overflow fade, the colors (resolved from the `UIColor` the
reference draws with, and checked against pixels rendered over white and over black; where
the two disagree the note says so and the drawn color wins), the durations, and the behavior:
five flags and the log and final state of 32 elementary actions (`BehaviorProfile.swift`),
recorded with real touches and keys from the reference and, next to it, from the clone.

It writes `Samples/ios-<major>.json`. Then:

    python3 Scripts/generate_ui_assets.py           # regenerate the metrics and the color catalog
    python3 Scripts/generate_ui_assets.py --check   # exit 1 when the generated files drift from the samples

The generator is the only writer of `ZTronSearchFieldMetrics+Sampled.swift` and
`Resources/Colors.xcassets`.

## Running the matrix

    Tools/run-matrix.sh [--os 17.5,18.6,27.0] [--devices "iPhone 15,..."]
        [--appearances light,dark,increased-contrast,reduce-transparency,bold-text]
        [--sizes XS,L,XXXL,AX5] [--directions ltr,rtl] [--inputs software,hardware]
        [--scripts type,...] [--results DIR] [--jobs N] [--timeout MINUTES] [--snapshots all]
        [--record-reference] [--skip-build] [--keep-booted]

Without options it runs the whole matrix of section 12.5. It creates the simulators it needs
(`ztron-parity-<os>-<device>`), builds once, copies the build so that a long run measures
the build it started with, and writes under `Results/`:

    Results/ios-<os>/<device>/<appearance>/<size>/<direction>/<input>/<script>.json
    Results/ios-<os>/.../<script>/<checkpoint>-{reference,clone,difference}.png   (failing checkpoints; all with --snapshots all)
    Results/summary.md, Results/summary.csv

`Tools/summarize.py [RESULTS_DIR]` rewrites the summary: coverage per iOS version and device,
passes per comparator with the worst numbers, the cells that could not run with the reason,
and the failing cells. `Tools/gate.py RESULTS_DIR [--os ...] [--device ...]` exits 0 only when
every cell of the matrix has a result and it is a pass (or not applicable); a failing cell, a
cell that could not run and a cell that was never attempted all keep the gate closed.

The package's own tests (comparators and host capabilities) run without the app:

    xcodebuild test -scheme ZTronSearchEngineUIParity \
        -destination "platform=iOS Simulator,name=iPhone 15" -derivedDataPath .derived/package

## A new iOS release

1. Install the runtime, add its version to `SPEC_OS` in `Tools/matrix.py` and `SPEC` in
   `Tools/summarize.py`, and to the matrix in `.github/workflows/parity.yml`.
2. `Tools/sample.sh --os <version>`; review the notes it prints and the diff of
   `Samples/ios-<major>.json`.
3. `python3 Scripts/generate_ui_assets.py`, then build and run the root package's tests.
4. `Tools/run-matrix.sh --os <version> --record-reference` records the reference's snapshot
   of every checkpoint under `ReferenceSnapshots/`, in the layout of `Results/`, and compares
   the clone with it as usual. Commit the samples, the generated files and the snapshots.

## Finding out why a cell differs

`DiagnosticsUITests` runs scripts without comparing and writes, per checkpoint, both logs,
both layouts, both view and layer hierarchies and a picture of the stage:

    TEST_RUNNER_ZTRON_PARITY_DUMP=/tmp/dump TEST_RUNNER_ZTRON_PARITY_SCRIPTS=tap-select \
    TEST_RUNNER_ZTRON_PARITY_DIRECTIONS=rtl TEST_RUNNER_ZTRON_PARITY_INPUTS=hardware \
      xcodebuild test-without-building -xctestrun <file> -destination id=<udid> \
        -only-testing:ParityHostUITests/DiagnosticsUITests -collect-test-diagnostics never

`TEST_RUNNER_ZTRON_PARITY_ACTIONS=blur-with-selected-token,...` does the same for elementary
actions of the behavior profile, and `TEST_RUNNER_ZTRON_PARITY_SYMBOLS=map,...` shows how the
reference draws a token icon. A variable reaches the test runner without its `TEST_RUNNER_`
prefix.

## Notes

- `.derived/` is build output and scratch; nothing in it is a deliverable.
- The UI test target's deployment target is iOS 15 like the app's; Xcode 27's XCTest is
  built for iOS 17, so linking the UI test bundle prints a deployment-target warning. The
  bundle only ever runs on simulators that can boot, which are all newer.
- CI: `.github/workflows/parity.yml` (drift check, re-sampling, the matrix per iOS version and device, the
  gate).
