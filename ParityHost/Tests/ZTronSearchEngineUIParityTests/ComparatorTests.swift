import XCTest
@testable import ZTronSearchEngineUIParity

/// The comparators decide what passes, so they are tested on inputs with known answers before
/// any of their verdicts on the two fields is trusted (specification section 15.7).
final class ComparatorTests: XCTestCase {
    // MARK: Colour distance

    /// CIEDE2000 test pairs of Sharma, Wu and Dalal, "The CIEDE2000 Color-Difference Formula:
    /// Implementation Notes, Supplementary Test Data, and Mathematical Observations" (2005).
    func testCIEDE2000MatchesThePublishedTestData() {
        let pairs: [(LabColor, LabColor, Double)] = [
            (LabColor(l: 50, a: 2.6772, b: -79.7751), LabColor(l: 50, a: 0, b: -82.7485), 2.0425),
            (LabColor(l: 50, a: 3.1571, b: -77.2803), LabColor(l: 50, a: 0, b: -82.7485), 2.8615),
            (LabColor(l: 50, a: 2.8361, b: -74.0200), LabColor(l: 50, a: 0, b: -82.7485), 3.4412),
            (LabColor(l: 50, a: -1.3802, b: -84.2814), LabColor(l: 50, a: 0, b: -82.7485), 1.0000),
            (LabColor(l: 50, a: -1.1848, b: -84.8006), LabColor(l: 50, a: 0, b: -82.7485), 1.0000),
            (LabColor(l: 50, a: -0.9009, b: -85.5211), LabColor(l: 50, a: 0, b: -82.7485), 1.0000),
            (LabColor(l: 50, a: 0, b: 0), LabColor(l: 50, a: -1, b: 2), 2.3669),
            (LabColor(l: 50, a: -1, b: 2), LabColor(l: 50, a: 0, b: 0), 2.3669),
            (LabColor(l: 50, a: 2.49, b: -0.001), LabColor(l: 50, a: -2.49, b: 0.0009), 7.1792),
            (LabColor(l: 50, a: 2.49, b: -0.001), LabColor(l: 50, a: -2.49, b: 0.0011), 7.2195),
            (LabColor(l: 50, a: 2.5, b: 0), LabColor(l: 50, a: 0, b: -2.5), 4.3065),
            (LabColor(l: 50, a: 2.5, b: 0), LabColor(l: 73, a: 25, b: -18), 27.1492),
            (LabColor(l: 50, a: 2.5, b: 0), LabColor(l: 61, a: -5, b: 29), 22.8977),
            (LabColor(l: 50, a: 2.5, b: 0), LabColor(l: 56, a: -27, b: -3), 31.9030),
            (LabColor(l: 50, a: 2.5, b: 0), LabColor(l: 58, a: 24, b: 15), 19.4535),
            (LabColor(l: 50, a: 2.5, b: 0), LabColor(l: 50, a: 3.1736, b: 0.5854), 1.0000),
            (LabColor(l: 50, a: 2.5, b: 0), LabColor(l: 50, a: 3.2972, b: 0), 1.0000),
            (LabColor(l: 60.2574, a: -34.0099, b: 36.2677), LabColor(l: 60.4626, a: -34.1751, b: 39.4387), 1.2644),
            (LabColor(l: 63.0109, a: -31.0961, b: -5.8663), LabColor(l: 62.8187, a: -29.7946, b: -4.0864), 1.2630),
            (LabColor(l: 61.2901, a: 3.7196, b: -5.3901), LabColor(l: 61.4292, a: 2.2480, b: -4.9620), 1.8731),
            (LabColor(l: 35.0831, a: -44.1164, b: 3.7933), LabColor(l: 35.0232, a: -40.0716, b: 1.5901), 1.8645),
            (LabColor(l: 22.7233, a: 20.0904, b: -46.6940), LabColor(l: 23.0331, a: 14.9730, b: -42.5619), 2.0373),
            (LabColor(l: 36.4612, a: 47.8580, b: 18.3852), LabColor(l: 36.2715, a: 50.5065, b: 21.2231), 1.4146),
            (LabColor(l: 90.8027, a: -2.0831, b: 1.4410), LabColor(l: 91.1528, a: -1.6435, b: 0.0447), 1.4441),
            (LabColor(l: 90.9257, a: -0.5406, b: -0.9208), LabColor(l: 88.6381, a: -0.8985, b: -0.7239), 1.5381),
            (LabColor(l: 6.7747, a: -0.2908, b: -2.4247), LabColor(l: 5.8714, a: -0.0985, b: -2.2286), 0.6377),
            (LabColor(l: 2.0776, a: 0.0795, b: -1.1350), LabColor(l: 0.9033, a: -0.0636, b: -0.5514), 0.9082),
        ]
        for (index, pair) in pairs.enumerated() {
            XCTAssertEqual(ColorDifference.ciede2000(pair.0, pair.1), pair.2, accuracy: 0.0001, "pair \(index + 1)")
            XCTAssertEqual(ColorDifference.ciede2000(pair.1, pair.0), pair.2, accuracy: 0.0001, "pair \(index + 1), reversed")
        }
        let color = LabColor(l: 40, a: 12, b: -7)
        XCTAssertEqual(ColorDifference.ciede2000(color, color), 0)
        XCTAssertEqual(ColorDifference.cie76(LabColor(l: 50, a: 0, b: 0), LabColor(l: 53, a: 4, b: 0)), 5, accuracy: 1e-12)
    }

    func testSRGBConvertsToCIELABUnderD65() {
        let white = LabColor(red: 255, green: 255, blue: 255)
        XCTAssertEqual(white.l, 100, accuracy: 0.01)
        XCTAssertEqual(white.a, 0, accuracy: 0.01)
        XCTAssertEqual(white.b, 0, accuracy: 0.01)
        let black = LabColor(red: 0, green: 0, blue: 0)
        XCTAssertEqual(black.l, 0, accuracy: 0.01)
        // The sRGB primaries, as every colour reference tabulates them.
        let red = LabColor(red: 255, green: 0, blue: 0)
        XCTAssertEqual(red.l, 53.24, accuracy: 0.02)
        XCTAssertEqual(red.a, 80.09, accuracy: 0.02)
        XCTAssertEqual(red.b, 67.20, accuracy: 0.02)
        let blue = LabColor(red: 0, green: 0, blue: 255)
        XCTAssertEqual(blue.l, 32.30, accuracy: 0.02)
        XCTAssertEqual(blue.a, 79.19, accuracy: 0.02)
        XCTAssertEqual(blue.b, -107.86, accuracy: 0.02)
        // One step of one channel of a mid grey is far below the threshold.
        let step = ColorDifference.ciede2000(LabColor(red: 128, green: 128, blue: 128), LabColor(red: 129, green: 128, blue: 128))
        XCTAssertGreaterThan(step, 0)
        XCTAssertLessThan(step, 1)
    }

    // MARK: Pixels

    func testIdenticalSnapshotsPass() {
        let image = PixelImage(width: 40, height: 10, red: 238, green: 238, blue: 240)
        let result = PixelComparator.compare(reference: image, clone: image).comparison
        XCTAssertTrue(result.passes)
        XCTAssertEqual(result.differingPixels, 0)
        XCTAssertEqual(result.maxDeltaE, 0)
        XCTAssertEqual(result.comparedPixels, 400)
    }

    func testThePixelCountLimitIsHalfAPercent() {
        // 1000 pixels: 5 faint differences are exactly 0.5%, 6 are over.
        let reference = PixelImage(width: 100, height: 10, red: 200, green: 200, blue: 200)
        var clone = reference
        for x in 0..<5 { clone[x, 0] = (201, 200, 200) }
        var result = PixelComparator.compare(reference: reference, clone: clone).comparison
        XCTAssertEqual(result.differingPixels, 5)
        XCTAssertEqual(result.differingPercent, 0.5, accuracy: 1e-9)
        XCTAssertLessThan(result.maxDeltaE, 1)
        XCTAssertTrue(result.passes, "0.5% of pixels, each well under ΔE 2")
        clone[5, 0] = (201, 200, 200)
        result = PixelComparator.compare(reference: reference, clone: clone).comparison
        XCTAssertFalse(result.passes, "0.6% of pixels differ")
    }

    func testASinglePixelOverDeltaETwoFails() {
        let reference = PixelImage(width: 100, height: 100, red: 200, green: 200, blue: 200)
        var clone = reference
        clone[50, 50] = (180, 200, 200)
        let (result, difference) = PixelComparator.compare(reference: reference, clone: clone)
        XCTAssertEqual(result.differingPixels, 1)
        XCTAssertEqual(result.differingPercent, 0.01, accuracy: 1e-9)
        XCTAssertGreaterThan(result.maxDeltaE, 2)
        XCTAssertEqual(result.pixelsOverThreshold, 1)
        XCTAssertEqual(result.worstX, 50)
        XCTAssertEqual(result.worstY, 50)
        XCTAssertFalse(result.passes, "one pixel in ten thousand, but past ΔE 2")
        XCTAssertEqual(difference?[50, 50].red, 230, "the difference image marks it red")
    }

    func testMaskedPixelsAreLeftOutOfTheComparisonAndOfTheTotal() {
        let reference = PixelImage(width: 100, height: 10, red: 255, green: 255, blue: 255)
        var clone = reference
        for y in 0..<10 { clone[20, y] = (0, 122, 255) }
        XCTAssertFalse(PixelComparator.compare(reference: reference, clone: clone).comparison.passes)
        let masked = PixelComparator.compare(reference: reference, clone: clone, masks: [PixelRect(x: 19, y: 0, width: 3, height: 10)]).comparison
        XCTAssertTrue(masked.passes)
        XCTAssertEqual(masked.maskedPixels, 30)
        XCTAssertEqual(masked.comparedPixels, 970)
        // A rectangle in points covers every pixel it touches.
        XCTAssertEqual(PixelRect(CGRect(x: 10.4, y: 2, width: 2, height: 5.2), scale: 3, margin: 1), PixelRect(x: 30, y: 5, width: 9, height: 18))
    }

    func testSnapshotsOfDifferentSizesDoNotCompare() {
        let result = PixelComparator.compare(
            reference: PixelImage(width: 10, height: 10, red: 0, green: 0, blue: 0),
            clone: PixelImage(width: 10, height: 12, red: 0, green: 0, blue: 0)
        ).comparison
        XCTAssertFalse(result.passes)
        XCTAssertNotNil(result.sizeMismatch)
    }

    func testCroppingKeepsThePixels() {
        var image = PixelImage(width: 4, height: 4, red: 0, green: 0, blue: 0)
        image[2, 1] = (9, 8, 7)
        let cropped = image.cropped(to: PixelRect(x: 1, y: 1, width: 2, height: 2))
        XCTAssertEqual(cropped.width, 2)
        XCTAssertEqual(cropped.height, 2)
        XCTAssertEqual(cropped[1, 0].red, 9)
        XCTAssertEqual(image.cropped(to: PixelRect(x: 3, y: 3, width: 5, height: 5)).width, 1, "clamped to the image")
        XCTAssertNotNil(image.pngData())
        if let round = image.cgImage.flatMap({ PixelImage($0) }) { XCTAssertEqual(round, image) }
    }

    // MARK: Metrics

    func testMetricsWithinHalfAPointPass() {
        let reference = LayoutMetrics(frames: ["glyph": RectValue(x: 6, y: 8.33, width: 20.33, height: 18.67)], lengths: ["baseline": 24.33])
        var clone = LayoutMetrics(frames: ["glyph": RectValue(x: 6.5, y: 8.0, width: 20.0, height: 18.67)], lengths: ["baseline": 24.0])
        var result = MetricsComparator.compare(reference: reference, clone: clone)
        XCTAssertTrue(result.passes)
        XCTAssertEqual(result.worstDeviation, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.worstName, "glyph.x")
        XCTAssertEqual(result.comparedValues, 5)

        clone.lengths["baseline"] = 23.8
        result = MetricsComparator.compare(reference: reference, clone: clone)
        XCTAssertFalse(result.passes)
        XCTAssertEqual(result.failures.map(\.name), ["baseline"])
        XCTAssertEqual(result.failures.first?.deviation ?? 0, 0.53, accuracy: 1e-9)
    }

    func testAnElementOnlyOneFieldHasFailsTheMetrics() {
        let reference = LayoutMetrics(frames: ["field": RectValue(x: 0, y: 0, width: 377, height: 36), "clearButton": RectValue(x: 351, y: 8, width: 20, height: 19)])
        let clone = LayoutMetrics(frames: ["field": RectValue(x: 0, y: 0, width: 377, height: 36)])
        let result = MetricsComparator.compare(reference: reference, clone: clone)
        XCTAssertFalse(result.passes)
        XCTAssertEqual(result.missing, ["clearButton (reference only)"])
        XCTAssertTrue(result.failures.isEmpty)
    }

    // MARK: Event logs

    func testIdenticalLogsPassAndTheFirstDifferenceIsLocated() {
        let log: [ParityEvent] = [
            .shouldBeginEditing(allowed: true), .didBeginEditing,
            .shouldChange(location: 0, length: 0, replacement: "m", allowed: true), .editingChanged(text: "m"),
        ]
        XCTAssertTrue(EventLogComparator.compare(reference: log, clone: log, comparesTextSelection: true).passes)
        var other = log
        other[3] = .editingChanged(text: "n")
        let result = EventLogComparator.compare(reference: log, clone: other, comparesTextSelection: true)
        XCTAssertFalse(result.passes)
        XCTAssertEqual(result.firstDifference, 3)
        // A log that stops early differs where it stops.
        XCTAssertEqual(EventLogComparator.compare(reference: log, clone: Array(log.prefix(2)), comparesTextSelection: true).firstDifference, 2)
        XCTAssertEqual(EventLogComparator.compare(reference: [], clone: log, comparesTextSelection: true).firstDifference, 0)
    }

    func testBelowIOS18SelectionEntriesAreReducedToTokenSelectionChanges() {
        // UIKit reports the caret after every key; the clone reports token selection only.
        let reference: [ParityEvent] = [
            .shouldChange(location: 0, length: 0, replacement: "m", allowed: true),
            .didChangeSelection(tokens: [], textLocation: 1, textLength: 0),
            .editingChanged(text: "m"),
            .shouldChange(location: -1, length: 1, replacement: "", allowed: true),
            .didChangeSelection(tokens: ["Tips"], textLocation: 0, textLength: 0),
            .didChangeSelection(tokens: ["Tips"], textLocation: 0, textLength: 0),
            .tokensChanged(["Maps"]),
            .didChangeSelection(tokens: [], textLocation: 0, textLength: 0),
        ]
        let clone: [ParityEvent] = [
            .shouldChange(location: 0, length: 0, replacement: "m", allowed: true),
            .editingChanged(text: "m"),
            .shouldChange(location: -1, length: 1, replacement: "", allowed: true),
            .didChangeSelection(tokens: ["Tips"], textLocation: nil, textLength: nil),
            .tokensChanged(["Maps"]),
            .didChangeSelection(tokens: [], textLocation: nil, textLength: nil),
        ]
        let tolerant = EventLogComparator.compare(reference: reference, clone: clone, comparesTextSelection: false)
        XCTAssertTrue(tolerant.passes)
        XCTAssertEqual(tolerant.comparedReference, clone)
        XCTAssertEqual(tolerant.appliedDeviations.count, 1)
        XCTAssertEqual(tolerant.reference, reference, "the recorded log is kept as it was")
        // From iOS 18 the text range is part of the comparison, so the same logs differ.
        let strict = EventLogComparator.compare(reference: reference, clone: clone, comparesTextSelection: true)
        XCTAssertFalse(strict.passes)
        XCTAssertEqual(strict.firstDifference, 1)
        XCTAssertTrue(strict.appliedDeviations.isEmpty)
    }

    func testOnlyTheNotificationOfARevertedChangeIsDropped() {
        let reference: [ParityEvent] = [
            .shouldChange(location: 2, length: 0, replacement: "1", allowed: false),
            .shouldChange(location: 2, length: 0, replacement: "c", allowed: true), .editingChanged(text: "abc"),
        ]
        let clone: [ParityEvent] = [
            .shouldChange(location: 2, length: 0, replacement: "1", allowed: false), .editingChanged(text: "ab"),
            .shouldChange(location: 2, length: 0, replacement: "c", allowed: true), .editingChanged(text: "abc"),
        ]
        let result = EventLogComparator.compare(reference: reference, clone: clone, comparesTextSelection: true)
        XCTAssertTrue(result.passes)
        XCTAssertEqual(result.comparedClone, reference)
        XCTAssertEqual(result.appliedDeviations.count, 1)
        // An extra notification anywhere else is a difference.
        let extra = clone + [.editingChanged(text: "abc")]
        XCTAssertFalse(EventLogComparator.compare(reference: reference, clone: extra, comparesTextSelection: true).passes)
    }

    func testASentinelInTheLogFailsEvenWhenTheLogsAgree() {
        let leaking: [ParityEvent] = [.editingChanged(text: "\u{200B}map")]
        let result = EventLogComparator.compare(reference: leaking, clone: leaking, comparesTextSelection: true)
        XCTAssertTrue(result.sentinelLeaked)
        XCTAssertFalse(result.passes)
        XCTAssertTrue(ParityEvent.tokensChanged(["a\u{200B}"]).containsSentinel)
        XCTAssertTrue(ParityEvent.shouldChange(location: 0, length: 0, replacement: "\u{200B}", allowed: true).containsSentinel)
        XCTAssertFalse(ParityEvent.editingChanged(text: "map").containsSentinel)
        XCTAssertEqual(ParityEvent.editingChanged(text: "\u{200B}a\"").description, "editingChanged(\"\\u{200B}a\\\"\")", "invisible characters show in a log")
    }

    // MARK: Accessibility

    private func node(_ type: String, _ label: String, value: String? = nil, actions: [String] = [], selected: Bool = false) -> AccessibilityNode {
        AccessibilityNode(
            type: type, label: label, value: value, placeholder: nil, identifier: "", isSelected: selected, isEnabled: true,
            depth: 0, frame: RectValue(x: 0, y: 0, width: 1, height: 1), actions: actions
        )
    }

    func testAccessibilityTreesCompareLabelsValuesTraitsAndActionsInOrder() {
        let reference = [node("SearchField", "Search", value: "Maps, harbor"), node("Other", "Maps"), node("Button", "Clear text")]
        XCTAssertTrue(AccessibilityComparator.compare(reference: reference, clone: reference).passes)
        // Scaffolding is skipped; frames and depth are not compared.
        var clone = [node("ScrollView", ""), node("SearchField", "Search", value: "Maps, harbor"), node("Other", ""), node("Other", "Maps"), node("Button", "Clear text")]
        clone[1].depth = 3
        clone[1].frame = RectValue(x: 9, y: 9, width: 9, height: 9)
        XCTAssertTrue(AccessibilityComparator.compare(reference: reference, clone: clone).passes)

        let different = [node("SearchField", "Search", value: "harbor"), node("Button", "Maps", actions: ["Delete"], selected: true), node("Button", "Clear")]
        let result = AccessibilityComparator.compare(reference: reference, clone: different)
        XCTAssertFalse(result.passes)
        XCTAssertEqual(result.differences.count, 5, "value; type, selected and actions of the token; label of the clear button")
        let shorter = AccessibilityComparator.compare(reference: reference, clone: Array(reference.prefix(2)))
        XCTAssertFalse(shorter.passes)
        XCTAssertTrue(shorter.differences.contains { $0.hasPrefix("reference only") })
    }

    // MARK: Animation

    func testAnimationDurationsWithinOneFramePass() {
        func recording(_ duration: Double) -> AnimationRecording {
            AnimationRecording(duration: duration, changedFrames: 2, sampledFrames: 60, medianFrameInterval: 1.0 / 60, longestFrameInterval: 1.0 / 60)
        }
        XCTAssertTrue(AnimationComparator.compare(reference: recording(0.250), clone: recording(0.266), sameFinalFrame: true).passes)
        XCTAssertFalse(AnimationComparator.compare(reference: recording(0.250), clone: recording(0.270), sameFinalFrame: true).passes, "20 ms apart")
        XCTAssertFalse(AnimationComparator.compare(reference: recording(0.250), clone: recording(0.250), sameFinalFrame: false).passes)
        XCTAssertFalse(AnimationComparator.compare(reference: recording(0), clone: recording(0.25), sameFinalFrame: true).passes)

        // A recording is timed from its first changed frame to its last.
        let timed = AnimationRecording(timestamps: [0, 0.016, 0.033, 0.05, 0.066], changed: [false, true, true, true, false])
        XCTAssertEqual(timed.duration, 0.034, accuracy: 1e-9)
        XCTAssertEqual(timed.changedFrames, 3)
        let instant = AnimationRecording(timestamps: [0, 0.016, 0.033], changed: [false, true, false])
        XCTAssertEqual(instant.duration, 0, "one changed frame: nothing animates")
        // A display shows whole frames. A simulator's display link reports refreshes a few
        // milliseconds off the frame period; the duration is the nearest whole number of
        // frames, and the time as reported is kept beside it.
        let jittery = AnimationRecording(timestamps: [0, 0.0167, 0.0361, 0.05], changed: [false, true, true, false], framePeriod: 1.0 / 60)
        XCTAssertEqual(jittery.duration, 1.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(jittery.rawDuration, 0.0194, accuracy: 1e-9)
        let skipped = AnimationRecording(timestamps: [0, 0.0167, 0.0500, 0.0667], changed: [false, true, true, false], framePeriod: 1.0 / 60)
        XCTAssertEqual(skipped.duration, 2.0 / 60, accuracy: 1e-9, "a refresh that was skipped is still a frame on screen")
        let still = AnimationRecording(timestamps: [0, 0.016], changed: [false, false])
        XCTAssertFalse(AnimationComparator.compare(reference: still, clone: instant, sameFinalFrame: true).passes, "nothing recorded on the reference")
    }

    // MARK: Scripts and cells

    func testEveryScriptOfTheMatrixIsDefinedAndEndsAtACheckpoint() {
        XCTAssertEqual(ParityScript.allCases.map(\.rawValue), [
            "type", "backspace-select", "backspace-delete", "tap-select", "clear", "submit", "cancel", "text-to-token",
            "token-overflow", "focus-round-trip",
        ])
        for script in ParityScript.allCases {
            guard case .checkpoint = script.actions.last else {
                return XCTFail("\(script.rawValue) does not end at a checkpoint")
            }
            let names = script.actions.compactMap { action -> String? in
                if case .checkpoint(let name) = action { return name }
                return nil
            }
            XCTAssertEqual(Set(names).count, names.count, "\(script.rawValue) names a checkpoint twice")
            XCTAssertFalse(names.contains("initial"), "every script is compared in its initial state already")
        }
        XCTAssertTrue(ParityScript.cancel.setup.cancelButton)
        XCTAssertFalse(ParityScript.type.setup.cancelButton, "only the cancel script shows the Cancel button")
        XCTAssertEqual(ParityScript.textToToken.setup.tokenLabel(for: "map "), "map")
        XCTAssertNil(ParityScript.textToToken.setup.tokenLabel(for: " "))
        XCTAssertNil(ParityScript.type.setup.tokenLabel(for: "map "))
    }

    func testACellKnowsWhereItsResultLivesAndWhatEnvironmentItNeeds() {
        let cell = ParityCell(os: "17.5", device: "iPhone SE (3rd generation)", appearance: .boldText, contentSize: .ax5, direction: .rtl, input: .hardware, script: .tapSelect)
        XCTAssertEqual(cell.relativePath, "ios-17.5/iPhone-SE-3rd-generation/bold-text/AX5/rtl/hardware/tap-select")
        var environment = HostEnvironment(
            osVersion: "17.5", modelIdentifier: "iPhone14,6", screenWidth: 375, screenHeight: 667, scale: 2,
            contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL", isDark: false, isHighContrast: false,
            isReduceTransparencyEnabled: false, isBoldTextEnabled: true, isRightToLeft: true, language: "ar-SA", locale: "ar_SA"
        )
        XCTAssertEqual(environment.mismatches(with: cell), [])
        environment.isBoldTextEnabled = false
        environment.contentSizeCategory = "UICTContentSizeCategoryL"
        XCTAssertEqual(environment.mismatches(with: cell).count, 2)
        XCTAssertEqual(ParityAppearance.specified.count, 5)
        XCTAssertTrue(ParityAppearance.darkIncreasedContrast.isDark && ParityAppearance.darkIncreasedContrast.isHighContrast)
    }

    func testAResultSurvivesARoundTripThroughItsFile() throws {
        let cell = ParityCell(os: "17.5", device: "iPhone 15", appearance: .light, contentSize: .l, direction: .ltr, input: .software, script: .type)
        var result = CellResult(cell: cell, status: .fail, reason: "typed pixels: 1.2% differ", driver: "test")
        result.worstDeltaE = .infinity
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try result.write(under: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent(cell.relativePath + ".json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "fail")
        XCTAssertEqual(object["worstDeltaE"] as? String, "inf", "a size mismatch has no finite distance")
        XCTAssertEqual((object["cell"] as? [String: Any])?["script"] as? String, "type")
    }
}
