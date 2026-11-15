# Parity matrix results

7440 cell results under `Results/`. Thresholds (specification 15.7): at most 0.5% of pixels differ and no differing pixel exceeds ΔE 2 (CIEDE2000); layout metrics within 0.5 pt; event logs and accessibility trees identical; text-to-token animation within one frame (16.7 ms) with the same final frame.

## Coverage

The matrix of specification 12.5 has 800 cells per iOS version and device.

| iOS | Device | Results | Ran | Passed | Failed | Not runnable | Not applicable |
|---|---|---:|---:|---:|---:|---:|---:|
| 15.5 | iPad (10th generation) | 800 | 0 | 0 | 0 | 800 | 0 |
| 15.5 | iPhone 15 | 800 | 0 | 0 | 0 | 800 | 0 |
| 15.5 | iPhone 15 Pro Max | 800 | 0 | 0 | 0 | 800 | 0 |
| 15.5 | iPhone SE (3rd generation) | 800 | 0 | 0 | 0 | 800 | 0 |
| 16.4 | iPad (10th generation) | 800 | 0 | 0 | 0 | 800 | 0 |
| 16.4 | iPhone 15 | 800 | 0 | 0 | 0 | 800 | 0 |
| 16.4 | iPhone 15 Pro Max | 800 | 0 | 0 | 0 | 800 | 0 |
| 16.4 | iPhone SE (3rd generation) | 800 | 0 | 0 | 0 | 800 | 0 |
| 17.5 | iPad (10th generation) | 40 | 31 | 0 | 31 | 9 | 0 |
| 17.5 | iPhone 15 | 320 | 248 | 72 | 176 | 72 | 0 |
| 17.5 | iPhone 15 Pro Max | 40 | 31 | 18 | 13 | 9 | 0 |
| 17.5 | iPhone SE (3rd generation) | 40 | 31 | 0 | 31 | 9 | 0 |
| 18.6 | iPad (10th generation) | 40 | 20 | 0 | 20 | 20 | 0 |
| 18.6 | iPhone 15 | 320 | 248 | 72 | 176 | 72 | 0 |
| 18.6 | iPhone 15 Pro Max | 40 | 31 | 17 | 14 | 9 | 0 |
| 18.6 | iPhone SE (3rd generation) | 40 | 31 | 0 | 31 | 9 | 0 |
| 27.0 | iPad (10th generation) | 40 | 17 | 0 | 17 | 23 | 0 |
| 27.0 | iPhone 15 | 40 | 31 | 0 | 31 | 9 | 0 |
| 27.0 | iPhone 15 Pro Max | 40 | 31 | 0 | 31 | 9 | 0 |
| 27.0 | iPhone SE (3rd generation) | 40 | 31 | 0 | 31 | 9 | 0 |

## Comparators

Cells that ran, as passed/compared per comparator, with the worst numbers of the group.

| iOS | Device | Pixels | Metrics | Event log | Accessibility | Animation | State | Worst pixel % | Worst ΔE | Worst metric (pt) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 17.5 | iPad (10th generation) | 0/31 | 19/31 | 20/31 | 18/31 | 0/3 | 27/31 | 26.164 | 100.00 | 254.50 |
| 17.5 | iPhone 15 | 72/248 | 121/248 | 246/248 | 144/248 | 8/24 | 246/248 | 55.394 | 100.00 | 154.67 |
| 17.5 | iPhone 15 Pro Max | 18/31 | 21/31 | 31/31 | 20/31 | 2/3 | 31/31 | 18.853 | 100.00 | 50.00 |
| 17.5 | iPhone SE (3rd generation) | 0/31 | 21/31 | 31/31 | 20/31 | 0/3 | 31/31 | 21.752 | 100.00 | 50.50 |
| 18.6 | iPad (10th generation) | 0/20 | 17/20 | 20/20 | 17/20 | 0/2 | 20/20 | 15.941 | 92.46 | 2.00 |
| 18.6 | iPhone 15 | 72/248 | 121/248 | 230/248 | 144/248 | 8/24 | 246/248 | 55.317 | 100.00 | 154.67 |
| 18.6 | iPhone 15 Pro Max | 17/31 | 21/31 | 28/31 | 19/31 | 2/3 | 30/31 | 18.776 | 100.00 | 50.00 |
| 18.6 | iPhone SE (3rd generation) | 0/31 | 21/31 | 27/31 | 19/31 | 0/3 | 30/31 | 21.665 | 100.00 | 50.50 |
| 27.0 | iPad (10th generation) | 0/17 | 0/17 | 13/17 | 0/17 | 0/2 | 15/17 | 97.739 | 100.00 | 890.00 |
| 27.0 | iPhone 15 | 0/31 | 0/31 | 23/31 | 0/31 | 0/3 | 24/31 | 98.357 | 99.38 | 889.67 |
| 27.0 | iPhone 15 Pro Max | 0/31 | 0/31 | 23/31 | 0/31 | 0/3 | 24/31 | 98.367 | 99.38 | 889.67 |
| 27.0 | iPhone SE (3rd generation) | 0/31 | 0/31 | 23/31 | 0/31 | 0/3 | 24/31 | 97.753 | 99.38 | 890.00 |

## Tolerated deviations applied

Cells in which the harness applied one of the deviations specification 12.5 allows.

- 12.5 text selection: 297 cells
- 12.5 range selection: 155 cells

## Cells that could not run

| Cells | Reason |
|---:|---|
| 3200 | The iOS 15.5 simulator runtime is not supported on hosts after macOS 26.99.99. |
| 3200 | no iOS 16.4 simulator runtime is installed on this Mac; iOS 16.0 is installed, but: The iOS 16.0 simulator runtime is not supported on hosts after macOS 26.99.99. |
| 98 | the driver could not deliver the script's keys to either field: reference: the on-screen keyboard shows no "m" key; clone: the on-screen keyboard shows no "m" key |
| 97 | the driver could not deliver the script's keys to either field: reference: XCUITest did not deliver the hardware keyboard's delete key to the reference; clone: XCUITest did not deliver the hardware keyboard's delete key to the clone |
| 24 | the driver could not deliver the script's keys to either field: reference: the on-screen keyboard shows no "x" key; clone: the on-screen keyboard shows no "x" key |
| 19 | the UI test bundle stopped before it reached this cell (xcodebuild exit -15), see ParityHost/.derived/matrix/27.0-iPad-10th-generation/light-L/xcodebuild.log |
| 16 | the UI test bundle stopped before it reached this cell: the run was stopped because the app had stopped reporting itself idle and XCUITest waited a minute before every event |
| 3 | the driver could not deliver the script's keys to either field: reference: XCUITest did not deliver the hardware keyboard's delete key to the reference |
| 1 | the script was cut short: reference: the app stopped reporting itself idle: XCUITest waited more than 30 s for it before type("map") |
| 1 | the script was cut short: clone: the app stopped reporting itself idle: XCUITest waited more than 30 s for it before type("map") |

## Failing cells

602 cells; `summary.csv` lists all of them and each result file lists every failure.

| iOS | Device | Appearance | Size | Dir | Input | Script | Failed comparators | Pixel % | ΔE | Metric (pt) | First failure |
|---|---|---|---|---|---|---|---|---:|---:|---:|---|
| 17.5 | iPad (10th generation) | light | L | ltr | hardware | cancel | pixels, metrics, eventLog, accessibility | 10.532 | 92.46 | 64.00 | driver: clone: the clone shows no Cancel button to tap |
| 17.5 | iPad (10th generation) | light | L | ltr | hardware | clear | pixels | 1.992 | 92.46 | 0.50 | initial pixels: 1.992% differ (limit 0.5%), max ΔE 92.46 (limit 2.0), 1986 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | hardware | focus-round-trip | pixels | 0.762 | 28.74 | 0.50 | initial pixels: 0.762% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | hardware | submit | pixels, eventLog, state | 0.762 | 92.46 | 0.50 | initial pixels: 0.762% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | hardware | tap-select | pixels | 1.658 | 41.78 | 0.50 | initial pixels: 1.658% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1540 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | hardware | text-to-token | pixels, eventLog, animation | 0.762 | 92.46 | 0.50 | initial pixels: 0.762% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | hardware | token-overflow | pixels, metrics, eventLog | 26.164 | 94.06 | 254.50 | initial pixels: 12.354% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 10128 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | hardware | type | pixels, eventLog, accessibility, state | 1.639 | 92.46 | 0.50 | initial pixels: 1.077% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1009 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | software | backspace-delete | pixels | 1.658 | 27.58 | 0.50 | initial pixels: 1.658% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1540 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | software | backspace-select | pixels | 1.658 | 41.55 | 0.50 | initial pixels: 1.658% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1540 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | software | cancel | pixels | 1.675 | 92.46 | 0.50 | initial pixels: 1.077% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1009 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | software | clear | pixels | 1.992 | 92.46 | 0.50 | initial pixels: 1.992% differ (limit 0.5%), max ΔE 92.46 (limit 2.0), 1986 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | software | focus-round-trip | pixels | 0.762 | 28.74 | 0.50 | initial pixels: 0.762% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | software | submit | pixels, eventLog, state | 0.762 | 92.46 | 0.50 | initial pixels: 0.762% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | software | tap-select | pixels | 1.658 | 41.78 | 0.50 | initial pixels: 1.658% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1540 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | software | text-to-token | pixels, animation | 0.762 | 92.46 | 0.50 | initial pixels: 0.762% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | software | token-overflow | pixels | 16.142 | 92.46 | 0.50 | initial pixels: 12.354% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 10128 px over the limit |
| 17.5 | iPad (10th generation) | light | L | ltr | software | type | pixels | 1.675 | 92.46 | 0.50 | initial pixels: 1.077% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1009 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | hardware | cancel | pixels, metrics, eventLog, accessibility | 8.367 | 92.46 | 41.00 | driver: clone: the clone shows no Cancel button to tap |
| 17.5 | iPad (10th generation) | light | L | rtl | hardware | clear | pixels, metrics, accessibility | 9.713 | 100.00 | 50.50 | initial pixels: 9.713% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 11011 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | hardware | focus-round-trip | pixels | 0.762 | 28.74 | 0.50 | initial pixels: 0.762% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | hardware | submit | pixels, eventLog, accessibility, state | 0.762 | 92.46 | 0.50 | initial pixels: 0.762% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 1.098 | 41.55 | 2.00 | initial pixels: 1.098% differ (limit 0.5%), max ΔE 26.07 (limit 2.0), 1028 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | hardware | text-to-token | pixels, metrics, eventLog, accessibility, animation | 0.762 | 92.46 | 2.00 | initial pixels: 0.762% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | hardware | token-overflow | pixels, metrics, eventLog, accessibility | 19.285 | 92.46 | 2.00 | initial pixels: 7.111% differ (limit 0.5%), max ΔE 26.40 (limit 2.0), 6193 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | hardware | type | pixels, metrics, eventLog, accessibility | 2.380 | 92.46 | 2.00 | initial pixels: 0.674% differ (limit 0.5%), max ΔE 26.07 (limit 2.0), 635 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 1.098 | 26.07 | 2.00 | initial pixels: 1.098% differ (limit 0.5%), max ΔE 26.07 (limit 2.0), 1028 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | software | backspace-select | pixels, metrics, accessibility | 1.098 | 41.55 | 2.00 | initial pixels: 1.098% differ (limit 0.5%), max ΔE 26.07 (limit 2.0), 1028 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | software | clear | pixels, metrics, accessibility | 9.713 | 100.00 | 50.50 | initial pixels: 9.713% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 11011 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | software | focus-round-trip | pixels | 0.762 | 28.74 | 0.50 | initial pixels: 0.762% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPad (10th generation) | light | L | rtl | software | tap-select | pixels, metrics, accessibility | 1.098 | 41.55 | 2.00 | initial pixels: 1.098% differ (limit 0.5%), max ΔE 26.07 (limit 2.0), 1028 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | hardware | cancel | pixels, metrics | 3.435 | 91.90 | 1.00 | initial pixels: 2.842% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2772 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | hardware | clear | pixels, metrics | 3.984 | 91.90 | 1.00 | initial pixels: 3.984% differ (limit 0.5%), max ΔE 91.90 (limit 2.0), 3942 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | hardware | focus-round-trip | pixels, metrics | 1.526 | 28.74 | 0.67 | initial pixels: 1.526% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1543 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | hardware | submit | pixels, metrics | 1.677 | 91.90 | 1.00 | initial pixels: 1.526% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1543 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | hardware | tap-select | pixels, metrics | 3.804 | 39.47 | 1.00 | initial pixels: 3.804% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 3729 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | hardware | text-to-token | pixels, metrics, animation | 1.964 | 91.90 | 1.00 | initial pixels: 1.526% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1543 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | hardware | token-overflow | pixels, metrics | 15.629 | 28.75 | 5.67 | initial pixels: 15.629% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 11503 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | hardware | type | pixels, metrics | 3.435 | 91.90 | 1.00 | initial pixels: 2.842% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2772 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | software | backspace-delete | pixels, metrics | 3.804 | 28.75 | 1.00 | initial pixels: 3.804% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 3729 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | software | backspace-select | pixels, metrics | 3.804 | 28.75 | 1.00 | initial pixels: 3.804% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 3729 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | software | cancel | pixels, metrics | 3.435 | 91.90 | 1.00 | initial pixels: 2.842% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2772 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | software | clear | pixels, metrics | 3.984 | 91.90 | 1.00 | initial pixels: 3.984% differ (limit 0.5%), max ΔE 91.90 (limit 2.0), 3942 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | software | focus-round-trip | pixels, metrics | 1.526 | 28.74 | 0.67 | initial pixels: 1.526% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1543 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | software | submit | pixels, metrics | 1.677 | 91.90 | 1.00 | initial pixels: 1.526% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1543 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | software | tap-select | pixels, metrics | 3.804 | 39.47 | 1.00 | initial pixels: 3.804% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 3729 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | software | text-to-token | pixels, metrics, animation | 1.964 | 91.90 | 1.00 | initial pixels: 1.526% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1543 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | software | token-overflow | pixels, metrics | 15.629 | 28.75 | 5.67 | initial pixels: 15.629% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 11503 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | ltr | software | type | pixels, metrics | 3.435 | 91.90 | 1.00 | initial pixels: 2.842% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2772 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | hardware | cancel | pixels, metrics, accessibility | 14.590 | 92.46 | 22.33 | initial pixels: 4.483% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 4766 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | hardware | clear | pixels, metrics, accessibility | 22.308 | 100.00 | 52.33 | initial pixels: 22.308% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 26751 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | hardware | focus-round-trip | pixels, metrics | 1.807 | 28.75 | 0.67 | initial pixels: 1.807% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1882 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | hardware | submit | pixels, metrics, accessibility | 1.807 | 92.46 | 1.00 | initial pixels: 1.807% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1882 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 6.627 | 43.91 | 2.00 | initial pixels: 6.627% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 7095 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 2.567 | 92.46 | 2.00 | initial pixels: 1.807% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1882 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | hardware | token-overflow | pixels, metrics, accessibility | 16.521 | 90.59 | 4.67 | initial pixels: 16.437% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 13305 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | hardware | type | pixels, metrics, accessibility | 5.339 | 92.46 | 2.00 | initial pixels: 4.483% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 4766 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 6.627 | 28.75 | 2.00 | initial pixels: 6.627% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 7095 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | software | backspace-select | pixels, metrics, accessibility | 6.627 | 41.55 | 2.00 | initial pixels: 6.627% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 7095 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | software | clear | pixels, metrics, accessibility | 22.308 | 100.00 | 52.33 | initial pixels: 22.308% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 26751 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | software | focus-round-trip | pixels, metrics | 1.807 | 28.75 | 0.67 | initial pixels: 1.807% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1882 px over the limit |
| 17.5 | iPhone 15 | bold-text | L | rtl | software | tap-select | pixels, metrics, accessibility | 6.627 | 43.91 | 2.00 | initial pixels: 6.627% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 7095 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | hardware | cancel | pixels, metrics, accessibility | 13.676 | 84.66 | 23.33 | initial pixels: 3.592% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 3798 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | hardware | clear | pixels, metrics, accessibility | 20.217 | 84.66 | 50.00 | initial pixels: 20.217% differ (limit 0.5%), max ΔE 84.66 (limit 2.0), 24360 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | hardware | focus-round-trip | pixels | 1.081 | 44.32 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 44.32 (limit 2.0), 1158 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | hardware | submit | pixels, accessibility | 1.102 | 84.66 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 44.32 (limit 2.0), 1158 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 5.366 | 45.43 | 2.00 | initial pixels: 5.366% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 5664 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 2.137 | 84.66 | 2.00 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 44.32 (limit 2.0), 1158 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | hardware | token-overflow | pixels, metrics, accessibility | 15.689 | 84.66 | 2.00 | initial pixels: 15.324% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 13781 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | hardware | type | pixels, metrics, accessibility | 4.356 | 84.66 | 2.00 | initial pixels: 3.592% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 3798 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 5.366 | 43.89 | 2.00 | initial pixels: 5.366% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 5664 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | software | backspace-select | pixels, metrics, accessibility | 5.366 | 45.43 | 2.00 | initial pixels: 5.366% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 5664 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | software | clear | pixels, metrics, accessibility | 20.217 | 84.66 | 50.00 | initial pixels: 20.217% differ (limit 0.5%), max ΔE 84.66 (limit 2.0), 24360 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | software | focus-round-trip | pixels | 1.081 | 44.32 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 44.32 (limit 2.0), 1158 px over the limit |
| 17.5 | iPhone 15 | dark | L | rtl | software | tap-select | pixels, metrics, accessibility | 5.366 | 45.43 | 2.00 | initial pixels: 5.366% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 5664 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | hardware | cancel | pixels, metrics, accessibility | 13.703 | 86.27 | 23.33 | initial pixels: 3.641% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 3826 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | hardware | clear | pixels, metrics, accessibility | 20.659 | 100.00 | 50.00 | initial pixels: 20.659% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24910 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | hardware | focus-round-trip | pixels | 1.073 | 41.47 | 0.33 | initial pixels: 1.073% differ (limit 0.5%), max ΔE 41.47 (limit 2.0), 1145 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | hardware | submit | pixels, accessibility | 1.100 | 86.27 | 0.33 | initial pixels: 1.073% differ (limit 0.5%), max ΔE 41.47 (limit 2.0), 1145 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 5.427 | 59.29 | 2.00 | initial pixels: 5.427% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 5703 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 2.135 | 86.27 | 2.00 | initial pixels: 1.073% differ (limit 0.5%), max ΔE 41.47 (limit 2.0), 1145 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | hardware | token-overflow | pixels, metrics, accessibility | 15.474 | 86.27 | 2.00 | initial pixels: 15.157% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 13887 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | hardware | type | pixels, metrics, accessibility | 4.392 | 86.27 | 2.00 | initial pixels: 3.641% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 3826 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 5.427 | 41.02 | 2.00 | initial pixels: 5.427% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 5703 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | software | backspace-select | pixels, metrics, accessibility | 5.427 | 54.61 | 2.00 | initial pixels: 5.427% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 5703 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | software | clear | pixels, metrics, accessibility | 20.659 | 100.00 | 50.00 | initial pixels: 20.659% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24910 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | software | focus-round-trip | pixels | 1.073 | 41.47 | 0.33 | initial pixels: 1.073% differ (limit 0.5%), max ΔE 41.47 (limit 2.0), 1145 px over the limit |
| 17.5 | iPhone 15 | increased-contrast | L | rtl | software | tap-select | pixels, metrics, accessibility | 5.427 | 59.29 | 2.00 | initial pixels: 5.427% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 5703 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | hardware | cancel | pixels, metrics, accessibility | 7.240 | 91.62 | 0.33 | initial pixels: 7.085% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 23140 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | hardware | clear | pixels, metrics, eventLog, accessibility, state | 34.807 | 92.46 | 0.13 | driver: reference: the reference shows no clear button to tap |
| 17.5 | iPhone 15 | light | AX5 | ltr | hardware | focus-round-trip | pixels | 9.018 | 28.75 | 0.00 | initial pixels: 0.334% differ (limit 0.5%), max ΔE 27.52 (limit 2.0), 897 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | hardware | submit | pixels, metrics, accessibility | 0.334 | 27.52 | 0.00 | initial pixels: 0.334% differ (limit 0.5%), max ΔE 27.52 (limit 2.0), 897 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | hardware | tap-select | pixels, metrics, accessibility | 8.111 | 43.91 | 0.13 | initial pixels: 7.846% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 24866 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | hardware | text-to-token | pixels, metrics, accessibility, animation | 1.091 | 27.52 | 0.13 | initial pixels: 0.334% differ (limit 0.5%), max ΔE 27.52 (limit 2.0), 897 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | hardware | token-overflow | pixels, metrics, accessibility | 11.150 | 28.53 | 0.13 | initial pixels: 8.680% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 26442 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | hardware | type | pixels, metrics, accessibility | 7.140 | 28.53 | 0.13 | initial pixels: 7.085% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 23140 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | software | backspace-delete | pixels, metrics, accessibility | 7.846 | 28.53 | 0.13 | initial pixels: 7.846% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 24866 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | software | backspace-select | pixels, metrics, accessibility | 8.952 | 28.53 | 0.13 | initial pixels: 7.846% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 24866 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | software | cancel | pixels, metrics, accessibility | 7.240 | 91.62 | 0.33 | initial pixels: 7.085% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 23140 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | software | clear | pixels, metrics, eventLog, accessibility, state | 34.807 | 92.46 | 0.13 | driver: reference: the reference shows no clear button to tap |
| 17.5 | iPhone 15 | light | AX5 | ltr | software | focus-round-trip | pixels | 9.018 | 28.75 | 0.00 | initial pixels: 0.334% differ (limit 0.5%), max ΔE 27.52 (limit 2.0), 897 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | software | submit | pixels, metrics, accessibility | 0.334 | 27.52 | 0.00 | initial pixels: 0.334% differ (limit 0.5%), max ΔE 27.52 (limit 2.0), 897 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | software | tap-select | pixels, metrics, accessibility | 8.111 | 43.91 | 0.13 | initial pixels: 7.846% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 24866 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | software | text-to-token | pixels, metrics, accessibility, animation | 1.091 | 27.52 | 0.13 | initial pixels: 0.334% differ (limit 0.5%), max ΔE 27.52 (limit 2.0), 897 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | software | token-overflow | pixels, metrics, accessibility | 11.150 | 28.53 | 0.13 | initial pixels: 8.680% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 26442 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | ltr | software | type | pixels, metrics, accessibility | 7.140 | 28.53 | 0.13 | initial pixels: 7.085% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 23140 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | hardware | cancel | pixels, metrics, accessibility | 33.417 | 92.46 | 23.00 | initial pixels: 9.651% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 31182 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | hardware | clear | pixels, metrics, accessibility | 55.394 | 100.00 | 154.67 | initial pixels: 53.763% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 179423 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | hardware | focus-round-trip | pixels, metrics | 9.346 | 28.75 | 0.67 | initial pixels: 2.386% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 7354 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | hardware | submit | pixels, metrics, accessibility | 2.386 | 92.46 | 0.67 | initial pixels: 2.386% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 7354 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | hardware | tap-select | pixels, metrics, accessibility | 12.702 | 43.91 | 5.67 | initial pixels: 12.542% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 39861 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 3.243 | 92.46 | 5.67 | initial pixels: 2.386% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 7354 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | hardware | token-overflow | pixels, metrics, accessibility | 17.749 | 92.46 | 5.67 | initial pixels: 17.337% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 48999 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | hardware | type | pixels, metrics, accessibility | 10.873 | 92.46 | 5.67 | initial pixels: 9.651% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 31182 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | software | backspace-delete | pixels, metrics, accessibility | 12.542 | 28.75 | 5.67 | initial pixels: 12.542% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 39861 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | software | backspace-select | pixels, metrics, accessibility | 12.979 | 43.91 | 5.67 | initial pixels: 12.542% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 39861 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | software | clear | pixels, metrics, accessibility | 55.394 | 100.00 | 154.67 | initial pixels: 53.763% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 179423 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | software | focus-round-trip | pixels, metrics | 9.346 | 28.75 | 0.67 | initial pixels: 2.386% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 7354 px over the limit |
| 17.5 | iPhone 15 | light | AX5 | rtl | software | tap-select | pixels, metrics, accessibility | 12.702 | 43.91 | 5.67 | initial pixels: 12.542% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 39861 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | hardware | cancel | pixels, metrics, accessibility | 13.655 | 92.46 | 23.33 | initial pixels: 3.589% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3770 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | hardware | clear | pixels, metrics, accessibility | 20.654 | 100.00 | 50.00 | initial pixels: 20.654% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24877 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | hardware | focus-round-trip | pixels | 1.081 | 28.74 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | hardware | submit | pixels, accessibility | 1.099 | 92.46 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 5.362 | 43.91 | 2.00 | initial pixels: 5.362% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 2.133 | 92.46 | 2.00 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | hardware | token-overflow | pixels, metrics, accessibility | 15.373 | 92.46 | 2.00 | initial pixels: 14.751% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 13525 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | hardware | type | pixels, metrics, accessibility | 4.353 | 92.46 | 2.00 | initial pixels: 3.589% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3770 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 5.362 | 28.53 | 2.00 | initial pixels: 5.362% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | software | backspace-select | pixels, metrics, accessibility | 5.362 | 41.55 | 2.00 | initial pixels: 5.362% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | software | clear | pixels, metrics, accessibility | 20.654 | 100.00 | 50.00 | initial pixels: 20.654% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24877 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | software | focus-round-trip | pixels | 1.081 | 28.74 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 | light | L | rtl | software | tap-select | pixels, metrics, accessibility | 5.362 | 43.91 | 2.00 | initial pixels: 5.362% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | hardware | cancel | pixels | 2.823 | 91.77 | 0.33 | initial pixels: 2.092% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1410 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | hardware | clear | pixels | 3.223 | 91.77 | 0.33 | initial pixels: 3.220% differ (limit 0.5%), max ΔE 91.77 (limit 2.0), 2451 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | hardware | focus-round-trip | pixels | 0.350 | 20.52 | 0.00 | initial pixels: 0.348% differ (limit 0.5%), max ΔE 20.52 (limit 2.0), 236 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | hardware | submit | pixels | 0.618 | 20.52 | 0.00 | initial pixels: 0.348% differ (limit 0.5%), max ΔE 20.52 (limit 2.0), 236 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | hardware | tap-select | pixels | 3.138 | 39.23 | 0.33 | initial pixels: 3.138% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 2228 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | hardware | text-to-token | pixels, animation | 0.847 | 20.52 | 0.00 | initial pixels: 0.348% differ (limit 0.5%), max ΔE 20.52 (limit 2.0), 236 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | hardware | token-overflow | pixels, metrics | 10.993 | 27.96 | 0.67 | initial pixels: 10.993% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 6610 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | hardware | type | pixels | 2.823 | 91.77 | 0.33 | initial pixels: 2.092% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1410 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | software | backspace-delete | pixels | 3.138 | 27.96 | 0.33 | initial pixels: 3.138% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 2228 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | software | backspace-select | pixels | 3.138 | 27.96 | 0.33 | initial pixels: 3.138% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 2228 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | software | cancel | pixels | 2.823 | 91.77 | 0.33 | initial pixels: 2.092% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1410 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | software | clear | pixels | 3.223 | 91.77 | 0.33 | initial pixels: 3.220% differ (limit 0.5%), max ΔE 91.77 (limit 2.0), 2451 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | software | focus-round-trip | pixels | 0.350 | 20.52 | 0.00 | initial pixels: 0.348% differ (limit 0.5%), max ΔE 20.52 (limit 2.0), 236 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | software | submit | pixels | 0.618 | 20.52 | 0.00 | initial pixels: 0.348% differ (limit 0.5%), max ΔE 20.52 (limit 2.0), 236 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | software | tap-select | pixels | 3.138 | 39.23 | 0.33 | initial pixels: 3.138% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 2228 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | software | text-to-token | pixels, animation | 0.847 | 20.52 | 0.00 | initial pixels: 0.348% differ (limit 0.5%), max ΔE 20.52 (limit 2.0), 236 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | software | token-overflow | pixels, metrics | 10.993 | 27.96 | 0.67 | initial pixels: 10.993% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 6610 px over the limit |
| 17.5 | iPhone 15 | light | XS | ltr | software | type | pixels | 2.823 | 91.77 | 0.33 | initial pixels: 2.092% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1410 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | hardware | cancel | pixels, metrics, accessibility | 13.203 | 91.11 | 23.33 | initial pixels: 3.959% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3517 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | hardware | clear | pixels, metrics, accessibility | 17.962 | 100.00 | 42.00 | initial pixels: 17.962% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 18392 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | hardware | focus-round-trip | pixels | 1.372 | 28.75 | 0.00 | initial pixels: 1.372% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1123 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | hardware | submit | pixels, accessibility | 1.372 | 28.75 | 0.33 | initial pixels: 1.372% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1123 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | hardware | tap-select | pixels, metrics, accessibility | 5.820 | 43.91 | 1.67 | initial pixels: 5.820% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5241 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 2.212 | 42.92 | 1.67 | initial pixels: 1.372% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1123 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | hardware | token-overflow | pixels, metrics, accessibility | 16.167 | 90.68 | 1.67 | initial pixels: 6.966% differ (limit 0.5%), max ΔE 28.05 (limit 2.0), 5932 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | hardware | type | pixels, metrics, accessibility | 3.959 | 91.11 | 1.67 | initial pixels: 3.959% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3517 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | software | backspace-delete | pixels, metrics, accessibility | 5.820 | 28.53 | 1.67 | initial pixels: 5.820% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5241 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | software | backspace-select | pixels, metrics, accessibility | 5.820 | 41.55 | 1.67 | initial pixels: 5.820% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5241 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | software | clear | pixels, metrics, accessibility | 17.962 | 100.00 | 42.00 | initial pixels: 17.962% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 18392 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | software | focus-round-trip | pixels | 1.372 | 28.75 | 0.00 | initial pixels: 1.372% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1123 px over the limit |
| 17.5 | iPhone 15 | light | XS | rtl | software | tap-select | pixels, metrics, accessibility | 5.820 | 43.91 | 1.67 | initial pixels: 5.820% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5241 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | hardware | cancel | pixels | 0.649 | 19.92 | 0.00 | initial pixels: 0.645% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 703 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | hardware | clear | pixels | 0.650 | 19.92 | 0.00 | initial pixels: 0.645% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 703 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | hardware | focus-round-trip | pixels | 0.335 | 19.92 | 0.00 | initial pixels: 0.332% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 411 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | hardware | submit | pixels | 0.634 | 19.92 | 0.00 | initial pixels: 0.332% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 411 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | hardware | tap-select | pixels | 0.721 | 19.92 | 0.00 | initial pixels: 0.658% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 703 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | hardware | text-to-token | pixels, animation | 0.634 | 19.92 | 0.00 | initial pixels: 0.332% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 411 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | hardware | token-overflow | pixels, metrics | 4.859 | 28.02 | 1.33 | initial pixels: 4.859% differ (limit 0.5%), max ΔE 28.02 (limit 2.0), 3219 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | hardware | type | pixels | 0.650 | 19.92 | 0.00 | initial pixels: 0.645% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 703 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | software | backspace-delete | pixels | 0.658 | 19.92 | 0.00 | initial pixels: 0.658% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 703 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | software | backspace-select | pixels | 0.837 | 19.92 | 0.00 | initial pixels: 0.658% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 703 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | software | cancel | pixels | 0.649 | 19.92 | 0.00 | initial pixels: 0.645% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 703 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | software | clear | pixels | 0.650 | 19.92 | 0.00 | initial pixels: 0.645% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 703 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | software | focus-round-trip | pixels | 0.335 | 19.92 | 0.00 | initial pixels: 0.332% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 411 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | software | submit | pixels | 0.634 | 19.92 | 0.00 | initial pixels: 0.332% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 411 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | software | tap-select | pixels | 0.721 | 19.92 | 0.00 | initial pixels: 0.658% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 703 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | software | text-to-token | pixels, animation | 0.634 | 19.92 | 0.00 | initial pixels: 0.332% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 411 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | software | token-overflow | pixels, metrics | 4.859 | 28.02 | 1.33 | initial pixels: 4.859% differ (limit 0.5%), max ΔE 28.02 (limit 2.0), 3219 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | ltr | software | type | pixels | 0.650 | 19.92 | 0.00 | initial pixels: 0.645% differ (limit 0.5%), max ΔE 19.92 (limit 2.0), 703 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | hardware | cancel | pixels, metrics, accessibility | 16.219 | 92.46 | 23.00 | initial pixels: 4.938% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 6712 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | hardware | clear | pixels, metrics, accessibility | 26.535 | 100.00 | 65.00 | initial pixels: 26.535% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 41687 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | hardware | focus-round-trip | pixels, metrics | 1.845 | 28.75 | 0.67 | initial pixels: 1.840% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2572 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | hardware | submit | pixels, metrics, accessibility | 1.840 | 92.46 | 0.67 | initial pixels: 1.840% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2572 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | hardware | tap-select | pixels, metrics, accessibility | 7.310 | 43.91 | 2.67 | initial pixels: 7.310% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 10094 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 3.087 | 92.46 | 2.67 | initial pixels: 1.840% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2572 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | hardware | token-overflow | pixels, metrics, accessibility | 16.328 | 92.46 | 2.67 | initial pixels: 14.461% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 17468 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | hardware | type | pixels, metrics, accessibility | 6.058 | 92.46 | 2.67 | initial pixels: 4.938% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 6712 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | software | backspace-delete | pixels, metrics, accessibility | 7.310 | 28.53 | 2.67 | initial pixels: 7.310% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 10094 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | software | backspace-select | pixels, metrics, accessibility | 7.310 | 43.91 | 2.67 | initial pixels: 7.310% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 10094 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | software | clear | pixels, metrics, accessibility | 26.535 | 100.00 | 65.00 | initial pixels: 26.535% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 41687 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | software | focus-round-trip | pixels, metrics | 1.845 | 28.75 | 0.67 | initial pixels: 1.840% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2572 px over the limit |
| 17.5 | iPhone 15 | light | XXXL | rtl | software | tap-select | pixels, metrics, accessibility | 7.310 | 43.91 | 2.67 | initial pixels: 7.310% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 10094 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | hardware | cancel | pixels, metrics, accessibility | 13.655 | 92.46 | 23.33 | initial pixels: 3.589% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3770 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | hardware | clear | pixels, metrics, accessibility | 20.654 | 100.00 | 50.00 | initial pixels: 20.654% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24877 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | hardware | focus-round-trip | pixels | 1.081 | 28.74 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | hardware | submit | pixels, accessibility | 1.099 | 92.46 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 5.362 | 43.91 | 2.00 | initial pixels: 5.362% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 2.133 | 92.46 | 2.00 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | hardware | token-overflow | pixels, metrics, accessibility | 15.373 | 92.46 | 2.00 | initial pixels: 14.751% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 13525 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | hardware | type | pixels, metrics, accessibility | 4.353 | 92.46 | 2.00 | initial pixels: 3.589% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3770 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 5.362 | 28.53 | 2.00 | initial pixels: 5.362% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | software | backspace-select | pixels, metrics, accessibility | 5.362 | 41.55 | 2.00 | initial pixels: 5.362% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | software | clear | pixels, metrics, accessibility | 20.654 | 100.00 | 50.00 | initial pixels: 20.654% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24877 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | software | focus-round-trip | pixels | 1.081 | 28.74 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 | reduce-transparency | L | rtl | software | tap-select | pixels, metrics, accessibility | 5.362 | 43.91 | 2.00 | initial pixels: 5.362% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | hardware | cancel | pixels, metrics, accessibility | 12.458 | 92.46 | 23.33 | initial pixels: 3.293% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3770 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | hardware | clear | pixels, metrics, accessibility | 18.853 | 100.00 | 50.00 | initial pixels: 18.853% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24877 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | hardware | focus-round-trip | pixels | 0.986 | 28.74 | 0.33 | initial pixels: 0.986% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | hardware | submit | pixels, accessibility | 1.001 | 92.46 | 0.33 | initial pixels: 0.986% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 4.885 | 43.91 | 2.00 | initial pixels: 4.885% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 1.968 | 92.46 | 2.00 | initial pixels: 0.986% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | hardware | token-overflow | pixels, metrics, accessibility | 16.661 | 92.46 | 2.00 | initial pixels: 15.117% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 15312 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | hardware | type | pixels, metrics, accessibility | 3.989 | 92.46 | 2.00 | initial pixels: 3.293% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3770 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 4.885 | 28.53 | 2.00 | initial pixels: 4.885% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | software | backspace-select | pixels, metrics, accessibility | 4.885 | 41.55 | 2.00 | initial pixels: 4.885% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | software | clear | pixels, metrics, accessibility | 18.853 | 100.00 | 50.00 | initial pixels: 18.853% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24877 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | software | focus-round-trip | pixels | 0.986 | 28.74 | 0.33 | initial pixels: 0.986% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 17.5 | iPhone 15 Pro Max | light | L | rtl | software | tap-select | pixels, metrics, accessibility | 4.885 | 43.91 | 2.00 | initial pixels: 4.885% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5628 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | hardware | cancel | pixels | 3.769 | 92.46 | 0.50 | initial pixels: 2.412% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1009 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | hardware | clear | pixels | 4.461 | 92.46 | 0.50 | initial pixels: 4.461% differ (limit 0.5%), max ΔE 92.46 (limit 2.0), 1986 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | hardware | focus-round-trip | pixels | 1.706 | 28.74 | 0.50 | initial pixels: 1.706% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | hardware | submit | pixels | 1.706 | 92.46 | 0.50 | initial pixels: 1.706% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | hardware | tap-select | pixels | 3.712 | 41.78 | 0.50 | initial pixels: 3.712% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1540 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | hardware | text-to-token | pixels, animation | 1.706 | 92.46 | 0.50 | initial pixels: 1.706% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | hardware | token-overflow | pixels | 15.373 | 92.46 | 0.50 | initial pixels: 14.935% differ (limit 0.5%), max ΔE 27.64 (limit 2.0), 3876 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | hardware | type | pixels | 3.769 | 92.46 | 0.50 | initial pixels: 2.412% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1009 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | software | backspace-delete | pixels | 3.712 | 27.58 | 0.50 | initial pixels: 3.712% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1540 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | software | backspace-select | pixels | 3.712 | 41.55 | 0.50 | initial pixels: 3.712% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1540 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | software | cancel | pixels | 3.769 | 92.46 | 0.50 | initial pixels: 2.412% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1009 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | software | clear | pixels | 4.461 | 92.46 | 0.50 | initial pixels: 4.461% differ (limit 0.5%), max ΔE 92.46 (limit 2.0), 1986 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | software | focus-round-trip | pixels | 1.706 | 28.74 | 0.50 | initial pixels: 1.706% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | software | submit | pixels | 1.706 | 92.46 | 0.50 | initial pixels: 1.706% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | software | tap-select | pixels | 3.712 | 41.78 | 0.50 | initial pixels: 3.712% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1540 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | software | text-to-token | pixels, animation | 1.706 | 92.46 | 0.50 | initial pixels: 1.706% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | software | token-overflow | pixels | 15.373 | 92.46 | 0.50 | initial pixels: 14.935% differ (limit 0.5%), max ΔE 27.64 (limit 2.0), 3876 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | ltr | software | type | pixels | 3.769 | 92.46 | 0.50 | initial pixels: 2.412% differ (limit 0.5%), max ΔE 27.58 (limit 2.0), 1009 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | hardware | cancel | pixels, metrics, accessibility | 15.992 | 92.46 | 23.00 | initial pixels: 1.509% differ (limit 0.5%), max ΔE 26.07 (limit 2.0), 635 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | hardware | clear | pixels, metrics, accessibility | 21.752 | 100.00 | 50.50 | initial pixels: 21.752% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 11011 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | hardware | focus-round-trip | pixels | 1.706 | 28.74 | 0.50 | initial pixels: 1.706% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | hardware | submit | pixels, accessibility | 1.706 | 92.46 | 0.50 | initial pixels: 1.706% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 2.459 | 41.55 | 2.00 | initial pixels: 2.459% differ (limit 0.5%), max ΔE 26.07 (limit 2.0), 1028 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 1.706 | 92.46 | 2.00 | initial pixels: 1.706% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | hardware | token-overflow | pixels, metrics, accessibility | 16.652 | 92.46 | 2.00 | initial pixels: 7.916% differ (limit 0.5%), max ΔE 26.37 (limit 2.0), 2439 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | hardware | type | pixels, metrics, accessibility | 5.358 | 92.46 | 2.00 | initial pixels: 1.509% differ (limit 0.5%), max ΔE 26.07 (limit 2.0), 635 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 2.459 | 26.07 | 2.00 | initial pixels: 2.459% differ (limit 0.5%), max ΔE 26.07 (limit 2.0), 1028 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | software | backspace-select | pixels, metrics, accessibility | 2.459 | 41.55 | 2.00 | initial pixels: 2.459% differ (limit 0.5%), max ΔE 26.07 (limit 2.0), 1028 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | software | clear | pixels, metrics, accessibility | 21.752 | 100.00 | 50.50 | initial pixels: 21.752% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 11011 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | software | focus-round-trip | pixels | 1.706 | 28.74 | 0.50 | initial pixels: 1.706% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 733 px over the limit |
| 17.5 | iPhone SE (3rd generation) | light | L | rtl | software | tap-select | pixels, metrics, accessibility | 2.459 | 41.55 | 2.00 | initial pixels: 2.459% differ (limit 0.5%), max ΔE 26.07 (limit 2.0), 1028 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | hardware | cancel | pixels | 1.660 | 92.46 | 0.50 | initial pixels: 1.062% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 993 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | hardware | clear | pixels | 1.980 | 92.46 | 0.50 | initial pixels: 1.980% differ (limit 0.5%), max ΔE 92.46 (limit 2.0), 1970 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | hardware | focus-round-trip | pixels | 0.758 | 28.74 | 0.50 | initial pixels: 0.758% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 734 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | hardware | submit | pixels | 0.758 | 92.46 | 0.50 | initial pixels: 0.758% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 734 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | hardware | tap-select | pixels | 1.636 | 41.55 | 0.50 | initial pixels: 1.636% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 1524 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | hardware | text-to-token | pixels, animation | 0.758 | 92.46 | 0.50 | initial pixels: 0.758% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 734 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | hardware | token-overflow | pixels | 15.941 | 92.46 | 0.50 | initial pixels: 12.231% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 10014 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | software | backspace-delete | pixels | 1.636 | 25.38 | 0.50 | initial pixels: 1.636% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 1524 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | software | backspace-select | pixels | 1.636 | 41.55 | 0.50 | initial pixels: 1.636% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 1524 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | software | cancel | pixels | 1.660 | 92.46 | 0.50 | initial pixels: 1.062% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 993 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | software | clear | pixels | 1.980 | 92.46 | 0.50 | initial pixels: 1.980% differ (limit 0.5%), max ΔE 92.46 (limit 2.0), 1970 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | software | focus-round-trip | pixels | 0.758 | 28.74 | 0.50 | initial pixels: 0.758% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 734 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | software | submit | pixels | 0.758 | 92.46 | 0.50 | initial pixels: 0.758% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 734 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | software | tap-select | pixels | 1.636 | 41.55 | 0.50 | initial pixels: 1.636% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 1524 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | software | text-to-token | pixels, animation | 0.758 | 92.46 | 0.50 | initial pixels: 0.758% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 734 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | software | token-overflow | pixels | 15.941 | 92.46 | 0.50 | initial pixels: 12.231% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 10014 px over the limit |
| 18.6 | iPad (10th generation) | light | L | ltr | software | type | pixels | 1.660 | 92.46 | 0.50 | initial pixels: 1.062% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 993 px over the limit |
| 18.6 | iPad (10th generation) | light | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 0.929 | 25.38 | 2.00 | initial pixels: 0.929% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 1025 px over the limit |
| 18.6 | iPad (10th generation) | light | L | rtl | software | backspace-select | pixels, metrics, accessibility | 0.929 | 41.55 | 2.00 | initial pixels: 0.929% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 1025 px over the limit |
| 18.6 | iPad (10th generation) | light | L | rtl | software | tap-select | pixels, metrics, accessibility | 0.929 | 41.55 | 2.00 | initial pixels: 0.929% differ (limit 0.5%), max ΔE 25.38 (limit 2.0), 1025 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | hardware | cancel | pixels, metrics | 3.411 | 91.90 | 1.00 | initial pixels: 2.665% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2810 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | hardware | clear | pixels, metrics | 3.810 | 91.90 | 1.00 | initial pixels: 3.806% differ (limit 0.5%), max ΔE 91.90 (limit 2.0), 3980 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | hardware | focus-round-trip | pixels, metrics | 1.537 | 28.75 | 0.67 | initial pixels: 1.537% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1542 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | hardware | submit | pixels, metrics | 1.691 | 91.90 | 1.00 | initial pixels: 1.537% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1542 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | hardware | tap-select | pixels, metrics | 3.587 | 39.47 | 1.00 | initial pixels: 3.587% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 3768 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | hardware | text-to-token | pixels, metrics, animation | 1.962 | 91.90 | 1.00 | initial pixels: 1.537% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1542 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | hardware | token-overflow | pixels, metrics | 15.354 | 28.75 | 5.67 | initial pixels: 15.354% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 11535 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | hardware | type | pixels, metrics | 3.411 | 91.90 | 1.00 | initial pixels: 2.665% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2810 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | software | backspace-delete | pixels, metrics | 3.587 | 28.75 | 1.00 | initial pixels: 3.587% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 3768 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | software | backspace-select | pixels, metrics | 3.587 | 28.75 | 1.00 | initial pixels: 3.587% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 3768 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | software | cancel | pixels, metrics | 3.411 | 91.90 | 1.00 | initial pixels: 2.665% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2810 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | software | clear | pixels, metrics | 3.810 | 91.90 | 1.00 | initial pixels: 3.806% differ (limit 0.5%), max ΔE 91.90 (limit 2.0), 3980 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | software | focus-round-trip | pixels, metrics | 1.537 | 28.75 | 0.67 | initial pixels: 1.537% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1542 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | software | submit | pixels, metrics | 1.691 | 91.90 | 1.00 | initial pixels: 1.537% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1542 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | software | tap-select | pixels, metrics | 3.587 | 39.47 | 1.00 | initial pixels: 3.587% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 3768 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | software | text-to-token | pixels, metrics, animation | 1.962 | 91.90 | 1.00 | initial pixels: 1.537% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 1542 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | software | token-overflow | pixels, metrics | 15.354 | 28.75 | 5.67 | initial pixels: 15.354% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 11535 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | ltr | software | type | pixels, metrics | 3.411 | 91.90 | 1.00 | initial pixels: 2.665% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2810 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | hardware | cancel | pixels, metrics, accessibility | 15.466 | 92.46 | 22.33 | initial pixels: 4.926% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 5548 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | hardware | clear | pixels, metrics, eventLog, accessibility | 22.302 | 100.00 | 52.33 | initial pixels: 22.302% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 26853 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | hardware | focus-round-trip | pixels, metrics | 2.169 | 28.75 | 0.67 | initial pixels: 2.169% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2325 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | hardware | submit | pixels, metrics, accessibility | 2.169 | 92.46 | 1.00 | initial pixels: 2.169% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2325 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 7.344 | 43.91 | 2.00 | initial pixels: 7.344% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 8287 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 3.076 | 92.46 | 2.00 | initial pixels: 2.169% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2325 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | hardware | token-overflow | pixels, metrics, accessibility | 19.327 | 92.46 | 4.39 | initial pixels: 18.736% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 16921 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | hardware | type | pixels, metrics, accessibility | 6.214 | 92.46 | 2.00 | initial pixels: 4.926% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 5548 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 7.344 | 28.75 | 2.00 | initial pixels: 7.344% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 8287 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | software | backspace-select | pixels, metrics, accessibility | 7.344 | 41.55 | 2.00 | initial pixels: 7.344% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 8287 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | software | clear | pixels, metrics, eventLog, accessibility | 22.302 | 100.00 | 52.33 | initial pixels: 22.302% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 26853 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | software | focus-round-trip | pixels, metrics | 2.169 | 28.75 | 0.67 | initial pixels: 2.169% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 2325 px over the limit |
| 18.6 | iPhone 15 | bold-text | L | rtl | software | tap-select | pixels, metrics, accessibility | 7.344 | 43.91 | 2.00 | initial pixels: 7.344% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 8287 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | hardware | cancel | pixels, metrics, accessibility | 13.545 | 84.66 | 23.33 | initial pixels: 3.393% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 3797 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | hardware | clear | pixels, metrics, eventLog, accessibility | 20.182 | 84.66 | 50.00 | initial pixels: 20.182% differ (limit 0.5%), max ΔE 84.66 (limit 2.0), 24367 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | hardware | focus-round-trip | pixels | 1.081 | 44.32 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 44.32 (limit 2.0), 1158 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | hardware | submit | pixels, accessibility | 1.100 | 84.66 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 44.32 (limit 2.0), 1158 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 5.055 | 45.43 | 2.00 | initial pixels: 5.055% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 5663 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 2.023 | 84.66 | 2.00 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 44.32 (limit 2.0), 1158 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | hardware | token-overflow | pixels, metrics, accessibility | 16.934 | 84.13 | 2.00 | initial pixels: 14.669% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 13771 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | hardware | type | pixels, metrics, accessibility | 4.224 | 84.66 | 2.00 | initial pixels: 3.393% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 3797 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 5.055 | 43.89 | 2.00 | initial pixels: 5.055% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 5663 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | software | backspace-select | pixels, metrics, accessibility | 5.055 | 45.43 | 2.00 | initial pixels: 5.055% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 5663 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | software | clear | pixels, metrics, eventLog, accessibility | 20.182 | 84.66 | 50.00 | initial pixels: 20.182% differ (limit 0.5%), max ΔE 84.66 (limit 2.0), 24367 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | software | focus-round-trip | pixels | 1.081 | 44.32 | 0.33 | initial pixels: 1.081% differ (limit 0.5%), max ΔE 44.32 (limit 2.0), 1158 px over the limit |
| 18.6 | iPhone 15 | dark | L | rtl | software | tap-select | pixels, metrics, accessibility | 5.055 | 45.43 | 2.00 | initial pixels: 5.055% differ (limit 0.5%), max ΔE 43.89 (limit 2.0), 5663 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | hardware | cancel | pixels, metrics, accessibility | 13.574 | 86.27 | 23.33 | initial pixels: 3.440% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 3822 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | hardware | clear | pixels, metrics, eventLog, accessibility | 20.625 | 100.00 | 50.00 | initial pixels: 20.625% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24909 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | hardware | focus-round-trip | pixels | 1.072 | 41.47 | 0.33 | initial pixels: 1.072% differ (limit 0.5%), max ΔE 41.47 (limit 2.0), 1144 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | hardware | submit | pixels, accessibility | 1.099 | 86.27 | 0.33 | initial pixels: 1.072% differ (limit 0.5%), max ΔE 41.47 (limit 2.0), 1144 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 5.114 | 59.29 | 2.00 | initial pixels: 5.114% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 5699 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 2.021 | 86.27 | 2.00 | initial pixels: 1.072% differ (limit 0.5%), max ΔE 41.47 (limit 2.0), 1144 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | hardware | token-overflow | pixels, metrics, accessibility | 16.726 | 85.85 | 2.00 | initial pixels: 14.400% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 13879 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | hardware | type | pixels, metrics, accessibility | 4.259 | 86.27 | 2.00 | initial pixels: 3.440% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 3822 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 5.114 | 41.02 | 2.00 | initial pixels: 5.114% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 5699 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | software | backspace-select | pixels, metrics, accessibility | 5.114 | 54.61 | 2.00 | initial pixels: 5.114% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 5699 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | software | clear | pixels, metrics, eventLog, accessibility | 20.625 | 100.00 | 50.00 | initial pixels: 20.625% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24909 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | software | focus-round-trip | pixels | 1.072 | 41.47 | 0.33 | initial pixels: 1.072% differ (limit 0.5%), max ΔE 41.47 (limit 2.0), 1144 px over the limit |
| 18.6 | iPhone 15 | increased-contrast | L | rtl | software | tap-select | pixels, metrics, accessibility | 5.114 | 59.29 | 2.00 | initial pixels: 5.114% differ (limit 0.5%), max ΔE 41.02 (limit 2.0), 5699 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | hardware | cancel | pixels, metrics, accessibility | 6.959 | 91.62 | 0.33 | initial pixels: 6.808% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 22457 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | hardware | clear | pixels, metrics, eventLog, accessibility, state | 34.822 | 92.46 | 0.13 | driver: reference: the reference shows no clear button to tap |
| 18.6 | iPhone 15 | light | AX5 | ltr | hardware | focus-round-trip | pixels | 8.984 | 28.75 | 0.00 | initial pixels: 0.189% differ (limit 0.5%), max ΔE 7.37 (limit 2.0), 120 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | hardware | submit | pixels, metrics, accessibility | 0.189 | 7.54 | 0.00 | initial pixels: 0.189% differ (limit 0.5%), max ΔE 7.37 (limit 2.0), 120 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | hardware | tap-select | pixels, metrics, accessibility | 7.636 | 43.91 | 0.13 | initial pixels: 7.489% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 24183 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | hardware | text-to-token | pixels, metrics, accessibility, animation | 0.809 | 21.72 | 0.13 | initial pixels: 0.189% differ (limit 0.5%), max ΔE 7.37 (limit 2.0), 120 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | hardware | token-overflow | pixels, metrics, accessibility | 10.757 | 28.53 | 0.13 | initial pixels: 8.358% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 25754 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | hardware | type | pixels, metrics, accessibility | 6.860 | 28.53 | 0.13 | initial pixels: 6.808% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 22457 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | software | backspace-delete | pixels, metrics, accessibility | 7.489 | 28.53 | 0.13 | initial pixels: 7.489% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 24183 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | software | backspace-select | pixels, metrics, accessibility | 8.512 | 28.53 | 0.13 | initial pixels: 7.489% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 24183 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | software | cancel | pixels, metrics, accessibility | 6.959 | 91.62 | 0.33 | initial pixels: 6.808% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 22457 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | software | clear | pixels, metrics, eventLog, accessibility, state | 34.822 | 92.46 | 0.13 | driver: reference: the reference shows no clear button to tap |
| 18.6 | iPhone 15 | light | AX5 | ltr | software | focus-round-trip | pixels | 8.984 | 28.75 | 0.00 | initial pixels: 0.189% differ (limit 0.5%), max ΔE 7.37 (limit 2.0), 120 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | software | submit | pixels, metrics, accessibility | 0.189 | 7.54 | 0.00 | initial pixels: 0.189% differ (limit 0.5%), max ΔE 7.37 (limit 2.0), 120 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | software | tap-select | pixels, metrics, accessibility | 7.636 | 43.91 | 0.13 | initial pixels: 7.489% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 24183 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | software | text-to-token | pixels, metrics, accessibility, animation | 0.809 | 21.72 | 0.13 | initial pixels: 0.189% differ (limit 0.5%), max ΔE 7.37 (limit 2.0), 120 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | software | token-overflow | pixels, metrics, accessibility | 10.757 | 28.53 | 0.13 | initial pixels: 8.358% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 25754 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | ltr | software | type | pixels, metrics, accessibility | 6.860 | 28.53 | 0.13 | initial pixels: 6.808% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 22457 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | hardware | cancel | pixels, metrics, accessibility | 33.276 | 92.46 | 23.00 | initial pixels: 9.378% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 31345 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | hardware | clear | pixels, metrics, eventLog, accessibility | 55.317 | 100.00 | 154.67 | initial pixels: 53.641% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 179241 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | hardware | focus-round-trip | pixels, metrics | 9.378 | 28.75 | 1.00 | initial pixels: 2.698% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 8130 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | hardware | submit | pixels, metrics, accessibility | 2.698 | 92.46 | 1.00 | initial pixels: 2.698% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 8130 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | hardware | tap-select | pixels, metrics, accessibility | 12.676 | 43.91 | 5.67 | initial pixels: 12.437% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 41483 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 3.543 | 92.46 | 5.67 | initial pixels: 2.698% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 8130 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | hardware | token-overflow | pixels, metrics, accessibility | 17.806 | 92.46 | 5.67 | initial pixels: 17.272% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 50055 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | hardware | type | pixels, metrics, accessibility | 11.030 | 92.46 | 5.67 | initial pixels: 9.378% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 31345 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | software | backspace-delete | pixels, metrics, accessibility | 12.437 | 28.74 | 5.67 | initial pixels: 12.437% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 41483 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | software | backspace-select | pixels, metrics, accessibility | 13.147 | 43.91 | 5.67 | initial pixels: 12.437% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 41483 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | software | clear | pixels, metrics, eventLog, accessibility | 55.317 | 100.00 | 154.67 | initial pixels: 53.641% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 179241 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | software | focus-round-trip | pixels, metrics | 9.378 | 28.75 | 1.00 | initial pixels: 2.698% differ (limit 0.5%), max ΔE 28.75 (limit 2.0), 8130 px over the limit |
| 18.6 | iPhone 15 | light | AX5 | rtl | software | tap-select | pixels, metrics, accessibility | 12.676 | 43.91 | 5.67 | initial pixels: 12.437% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 41483 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | hardware | cancel | pixels, metrics, accessibility | 13.531 | 92.46 | 23.33 | initial pixels: 3.391% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3766 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | hardware | clear | pixels, metrics, eventLog, accessibility | 20.623 | 100.00 | 50.00 | initial pixels: 20.623% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24878 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | hardware | focus-round-trip | pixels | 1.083 | 28.74 | 0.33 | initial pixels: 1.083% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | hardware | submit | pixels, accessibility | 1.099 | 92.46 | 0.33 | initial pixels: 1.083% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | hardware | tap-select | pixels, metrics, accessibility | 5.053 | 43.91 | 2.00 | initial pixels: 5.053% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5624 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 2.021 | 92.46 | 2.00 | initial pixels: 1.083% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | hardware | token-overflow | pixels, metrics, accessibility | 16.329 | 91.77 | 2.00 | initial pixels: 14.040% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 13513 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | hardware | type | pixels, metrics, accessibility | 4.223 | 92.46 | 2.00 | initial pixels: 3.391% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3766 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | software | backspace-delete | pixels, metrics, accessibility | 5.053 | 28.53 | 2.00 | initial pixels: 5.053% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5624 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | software | backspace-select | pixels, metrics, accessibility | 5.053 | 41.55 | 2.00 | initial pixels: 5.053% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5624 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | software | clear | pixels, metrics, eventLog, accessibility | 20.623 | 100.00 | 50.00 | initial pixels: 20.623% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 24878 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | software | focus-round-trip | pixels | 1.083 | 28.74 | 0.33 | initial pixels: 1.083% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 1100 px over the limit |
| 18.6 | iPhone 15 | light | L | rtl | software | tap-select | pixels, metrics, accessibility | 5.053 | 43.91 | 2.00 | initial pixels: 5.053% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5624 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | hardware | cancel | pixels | 2.282 | 91.77 | 0.33 | initial pixels: 1.556% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1055 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | hardware | clear | pixels | 2.684 | 91.77 | 0.33 | initial pixels: 2.684% differ (limit 0.5%), max ΔE 91.77 (limit 2.0), 2096 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | hardware | focus-round-trip | pixels | 0.235 | 6.09 | 0.00 | initial pixels: 0.233% differ (limit 0.5%), max ΔE 6.09 (limit 2.0), 36 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | hardware | submit | pixels | 0.371 | 6.59 | 0.00 | initial pixels: 0.233% differ (limit 0.5%), max ΔE 6.09 (limit 2.0), 36 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | hardware | tap-select | pixels | 2.471 | 39.46 | 0.33 | initial pixels: 2.471% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1872 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | hardware | text-to-token | pixels, animation | 0.464 | 6.59 | 0.00 | initial pixels: 0.233% differ (limit 0.5%), max ΔE 6.09 (limit 2.0), 36 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | hardware | token-overflow | pixels, metrics | 9.789 | 27.96 | 0.67 | initial pixels: 9.789% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 6252 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | hardware | type | pixels | 2.282 | 91.77 | 0.33 | initial pixels: 1.556% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1055 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | software | backspace-delete | pixels | 2.471 | 27.96 | 0.33 | initial pixels: 2.471% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1872 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | software | backspace-select | pixels | 2.471 | 27.96 | 0.33 | initial pixels: 2.471% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1872 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | software | cancel | pixels | 2.282 | 91.77 | 0.33 | initial pixels: 1.556% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1055 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | software | clear | pixels | 2.684 | 91.77 | 0.33 | initial pixels: 2.684% differ (limit 0.5%), max ΔE 91.77 (limit 2.0), 2096 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | software | focus-round-trip | pixels | 0.235 | 6.09 | 0.00 | initial pixels: 0.233% differ (limit 0.5%), max ΔE 6.09 (limit 2.0), 36 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | software | submit | pixels | 0.371 | 6.59 | 0.00 | initial pixels: 0.233% differ (limit 0.5%), max ΔE 6.09 (limit 2.0), 36 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | software | tap-select | pixels | 2.471 | 39.46 | 0.33 | initial pixels: 2.471% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1872 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | software | text-to-token | pixels, animation | 0.464 | 6.59 | 0.00 | initial pixels: 0.233% differ (limit 0.5%), max ΔE 6.09 (limit 2.0), 36 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | software | token-overflow | pixels, metrics | 9.789 | 27.96 | 0.67 | initial pixels: 9.789% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 6252 px over the limit |
| 18.6 | iPhone 15 | light | XS | ltr | software | type | pixels | 2.282 | 91.77 | 0.33 | initial pixels: 1.556% differ (limit 0.5%), max ΔE 27.96 (limit 2.0), 1055 px over the limit |
| 18.6 | iPhone 15 | light | XS | rtl | hardware | cancel | pixels, metrics, accessibility | 13.390 | 91.11 | 23.33 | initial pixels: 3.679% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3316 px over the limit |
| 18.6 | iPhone 15 | light | XS | rtl | hardware | clear | pixels, metrics, eventLog, accessibility | 17.797 | 100.00 | 42.00 | initial pixels: 17.797% differ (limit 0.5%), max ΔE 100.00 (limit 2.0), 18192 px over the limit |
| 18.6 | iPhone 15 | light | XS | rtl | hardware | focus-round-trip | pixels | 1.259 | 28.74 | 0.00 | initial pixels: 1.259% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 925 px over the limit |
| 18.6 | iPhone 15 | light | XS | rtl | hardware | submit | pixels, accessibility | 1.259 | 28.74 | 0.33 | initial pixels: 1.259% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 925 px over the limit |
| 18.6 | iPhone 15 | light | XS | rtl | hardware | tap-select | pixels, metrics, accessibility | 5.438 | 43.91 | 1.67 | initial pixels: 5.438% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5039 px over the limit |
| 18.6 | iPhone 15 | light | XS | rtl | hardware | text-to-token | pixels, metrics, accessibility, animation | 1.996 | 42.92 | 1.67 | initial pixels: 1.259% differ (limit 0.5%), max ΔE 28.74 (limit 2.0), 925 px over the limit |
| 18.6 | iPhone 15 | light | XS | rtl | hardware | token-overflow | pixels, metrics, accessibility | 15.675 | 90.68 | 1.67 | initial pixels: 5.996% differ (limit 0.5%), max ΔE 28.05 (limit 2.0), 5729 px over the limit |
| 18.6 | iPhone 15 | light | XS | rtl | hardware | type | pixels, metrics, accessibility | 4.136 | 91.11 | 1.67 | initial pixels: 3.679% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 3316 px over the limit |
| 18.6 | iPhone 15 | light | XS | rtl | software | backspace-delete | pixels, metrics, accessibility | 5.438 | 28.53 | 1.67 | initial pixels: 5.438% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5039 px over the limit |
| 18.6 | iPhone 15 | light | XS | rtl | software | backspace-select | pixels, metrics, accessibility | 5.438 | 41.56 | 1.67 | initial pixels: 5.438% differ (limit 0.5%), max ΔE 28.53 (limit 2.0), 5039 px over the limit |

...and 202 more in `summary.csv`.
