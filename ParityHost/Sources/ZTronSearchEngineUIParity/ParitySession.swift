import UIKit

/// The app side of the channel: executes the commands of a driver on the stage, keeps what a
/// script captured, and compares it when the driver says the cell is finished.
@MainActor
public final class ParitySession {
    public let stage: ParityStageController
    public let channel: ParityChannel
    private var nextRequest = 1
    private var timer: Timer?
    private var isBusy = false

    private var captures: [FieldSide: [CapturedField]] = [:]
    private var logs: [FieldSide: [ParityEvent]] = [:]
    private var keyPresses: [FieldSide: Int] = [:]
    private var recordings: [FieldSide: AnimationRecording] = [:]
    private var recorder: (side: FieldSide, recorder: AnimationRecorder)?
    private var cellStart = Date()

    public init(stage: ParityStageController, channel: ParityChannel) {
        self.stage = stage
        self.channel = channel
    }

    /// Starts answering requests. They are numbered from 1 and answered in order.
    public func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard !isBusy, let request = channel.read(ParityRequest.self, from: channel.requestURL(nextRequest)) else { return }
        isBusy = true
        Task { @MainActor in
            var response = ParityResponse(id: request.id)
            do {
                try await self.execute(request.command, into: &response)
            } catch {
                response.error = String(describing: error)
            }
            try? self.channel.write(response, to: self.channel.responseURL(request.id))
            self.nextRequest = request.id + 1
            self.isBusy = false
        }
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func execute(_ command: ParityCommand, into response: inout ParityResponse) async throws {
        switch command {
        case .environment:
            response.environment = stage.hostEnvironment
        case .begin(let setup):
            captures = [:]
            logs = [:]
            keyPresses = [:]
            recordings = [:]
            recorder = nil
            cellStart = Date()
            try await rebuild(setup)
        case .rebuild(let setup):
            finishRecording()
            try await rebuild(setup)
        case .geometry(let side):
            response.geometry = stage.geometry(side)
        case .perform(let side, let step):
            try await perform(step, on: side)
        case .capture(let side, let checkpoint, let nodes):
            await Self.pause(0.05)
            if let recorder, !recorder.recorder.isRecording { finishRecording() }
            captures[side, default: []].append(try stage.capture(side, checkpoint: checkpoint, nodes: nodes))
            logs[side] = side == .reference ? stage.reference.events : stage.clone.events
            keyPresses[side] = ParityWindow.keyPressCount
        case .finish(let cell, let options):
            finishRecording()
            let result = try compare(cell, options: options)
            try result.write(under: URL(fileURLWithPath: options.resultsDirectory))
            response.summary = CellSummary(status: result.status, failures: result.failures, path: cell.relativePath + ".json")
        case .sample:
            response.sample = try await ReferenceSampler(stage: stage).sample()
        case .dump(let name):
            if name.hasPrefix("symbol-lab-") {
                let lines = await SymbolLab(stage: stage).run(symbol: String(name.dropFirst("symbol-lab-".count)))
                try lines.joined(separator: "\n").write(to: channel.directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            } else {
                try dump(named: name)
            }
        }
    }

    private func rebuild(_ setup: FieldSetup) async throws {
        stage.rebuild(setup)
        ParityWindow.resetKeyPressCount()
        await Self.pause(0.25)
        guard stage.reference.isObserving else {
            throw ParityError("the search bar took its text field's delegate back: the reference's log would be empty")
        }
    }

    // MARK: In-process steps

    private func perform(_ step: ScriptStep, on side: FieldSide) async throws {
        switch step {
        case .setFocus(let focused):
            switch side {
            case .reference:
                let field = stage.reference.textField
                _ = focused ? field.becomeFirstResponder() : field.resignFirstResponder()
            case .clone:
                stage.clone.setFocus(focused)
            }
            await Self.pause(0.35)
        case .settle(let seconds):
            await Self.pause(seconds)
        case .watchAnimation(let seconds):
            finishRecording()
            let recorder = AnimationRecorder(view: side == .reference ? stage.reference.searchBar : stage.clone.view)
            recorder.start(seconds: seconds)
            self.recorder = (side, recorder)
        case .tapField, .tapText, .type, .backspace, .submit, .tapToken, .tapTokenTrailingHalf, .tapClear, .tapCancel:
            throw ParityError("\(step) is an input event: the UI test delivers it, the app does not fake it")
        }
    }

    private func finishRecording() {
        guard let recorder else { return }
        recorder.recorder.stop()
        recordings[recorder.side] = recorder.recorder.recording
        self.recorder = nil
    }

    // MARK: Comparison

    private func compare(_ cell: ParityCell, options: FinishOptions) throws -> CellResult {
        let environment = stage.hostEnvironment
        let mismatches = environment.mismatches(with: cell)
        guard mismatches.isEmpty else {
            return CellResult(
                cell: cell, status: .notRunnable,
                reason: "the simulator is not in the cell's configuration: " + mismatches.joined(separator: "; "),
                environment: environment, driver: options.driver
            )
        }
        var result = CellResult(cell: cell, status: .pass, reason: nil, environment: environment, driver: options.driver)
        result.referenceKeyPresses = keyPresses[.reference] ?? 0
        result.cloneKeyPresses = keyPresses[.clone] ?? 0
        result.failures += options.driverProblems.map { "driver: \($0)" }

        let reference = captures[.reference] ?? []
        let clone = captures[.clone] ?? []
        if reference.count != clone.count {
            result.failures.append("checkpoints: the reference reached \(reference.map(\.capture.checkpoint)), the clone \(clone.map(\.capture.checkpoint))")
        }
        let artifacts = URL(fileURLWithPath: options.resultsDirectory).appendingPathComponent(cell.relativePath)
        try? FileManager.default.removeItem(at: artifacts)
        for (first, second) in zip(reference, clone) {
            let name = first.capture.checkpoint
            guard name == second.capture.checkpoint else {
                result.failures.append("checkpoints: the reference is at \(name), the clone at \(second.capture.checkpoint)")
                continue
            }
            var checkpoint = compare(first, second)
            if options.keepsAllSnapshots || !checkpoint.pixels.passes {
                checkpoint.artifacts = try writeSnapshots(first, second, checkpoint: name, to: artifacts)
            }
            if let directory = options.referenceSnapshotsDirectory, let png = first.image.pngData() {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(cell.relativePath).appendingPathComponent("\(name).png")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: url)
            }
            record(checkpoint, handles: first.capture.selectionHandles.count, in: &result)
            result.checkpoints.append(checkpoint)
        }

        let log = EventLogComparator.compare(
            reference: logs[.reference] ?? [], clone: logs[.clone] ?? [],
            comparesTextSelection: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 18
        )
        result.eventLog = log
        result.toleratedDeviations += log.appliedDeviations
        if log.sentinelLeaked { result.failures.append("event log: the clone's log carries the sentinel U+200B") }
        if let index = log.firstDifference {
            let first = index < log.comparedReference.count ? log.comparedReference[index].description : "(end of log)"
            let second = index < log.comparedClone.count ? log.comparedClone[index].description : "(end of log)"
            result.failures.append("event log: entry \(index) is \(first) on the reference, \(second) on the clone")
        }

        if let first = recordings[.reference], let second = recordings[.clone] {
            let final = result.checkpoints.last?.pixels.passes ?? false
            let animation = AnimationComparator.compare(reference: first, clone: second, sameFinalFrame: final)
            result.animation = animation
            if !animation.passes {
                result.failures.append(String(
                    format: "animation: reference %.0f ms (%d changed frames), clone %.0f ms (%d), difference %.1f ms, final frame %@",
                    first.duration * 1000, first.changedFrames, second.duration * 1000, second.changedFrames,
                    animation.durationDifference * 1000, final ? "same" : "different"
                ))
            }
        } else if recordings[.reference] != nil || recordings[.clone] != nil {
            result.failures.append("animation: recorded on one field only")
        }

        // The sentinel must not reach the text binding or the accessibility tree either.
        for capture in clone.map(\.capture) {
            if capture.text.unicodeScalars.contains("\u{200B}") {
                result.failures.append("\(capture.checkpoint): the clone's text binding carries the sentinel U+200B")
            }
            if capture.accessibility.contains(where: { ($0.label + ($0.value ?? "")).unicodeScalars.contains("\u{200B}") }) {
                result.failures.append("\(capture.checkpoint): the clone's accessibility tree carries the sentinel U+200B")
            }
        }

        result.status = result.failures.isEmpty ? .pass : .fail
        result.reason = result.failures.first
        // A script the driver could not deliver to either field was not run: what was compared
        // before it stopped stays in the result, but the cell is neither a pass nor a failure
        // of the clone.
        let undelivered = options.driverProblems.filter { $0.contains(Self.missingKeyMarker) || $0.contains(Self.undeliveredKeyMarker) }
        if !undelivered.isEmpty, undelivered.count == options.driverProblems.count {
            result.status = .notRunnable
            result.reason = "the driver could not deliver the script's keys to either field: " + undelivered.joined(separator: "; ")
        }
        if let stalled = options.driverProblems.first(where: { $0.contains(Self.stalledMarker) }) {
            result.status = .notRunnable
            result.reason = "the script was cut short: " + stalled
        }
        result.durationSeconds = Date().timeIntervalSince(cellStart)
        return result
    }

    /// How the driver words a key it did not find on the on-screen keyboard, and a key of the
    /// hardware keyboard that XCUITest did not deliver.
    public static let missingKeyMarker = "the on-screen keyboard shows no"
    public static let undeliveredKeyMarker = "XCUITest did not deliver the hardware keyboard's"
    /// How the driver words an app process that stopped reporting itself idle.
    public static let stalledMarker = "the app stopped reporting itself idle"

    private func masks(_ reference: CapturedField, _ clone: CapturedField) -> (carets: [PixelRect], handles: [PixelRect]) {
        let scale = reference.scale
        // The caret blinks: wherever either field shows one is left out of both snapshots.
        let carets = [reference.capture.caret, clone.capture.caret].compactMap { $0 }.map {
            PixelRect($0.cgRect, scale: scale, margin: Int(scale.rounded(.up)))
        }
        let handles = reference.capture.selectionHandles.map { PixelRect($0.cgRect, scale: scale, margin: 1) }
        return (carets, handles)
    }

    private func compare(_ reference: CapturedField, _ clone: CapturedField) -> CheckpointResult {
        let (carets, handles) = masks(reference, clone)
        let pixels = PixelComparator.compare(reference: reference.image, clone: clone.image, masks: carets + handles).comparison
        let caretOnly = handles.isEmpty ? nil : PixelComparator.compare(reference: reference.image, clone: clone.image, masks: carets).comparison
        return CheckpointResult(
            name: reference.capture.checkpoint,
            state: StateComparison.compare(reference: reference.capture, clone: clone.capture),
            pixels: pixels, pixelsCaretOnly: caretOnly,
            metrics: MetricsComparator.compare(reference: reference.capture.metrics, clone: clone.capture.metrics),
            accessibility: AccessibilityComparator.compare(reference: reference.capture.accessibility, clone: clone.capture.accessibility),
            referenceCaret: reference.capture.caret, cloneCaret: clone.capture.caret,
            selectionHandles: reference.capture.selectionHandles,
            artifacts: []
        )
    }

    private func record(_ checkpoint: CheckpointResult, handles: Int, in result: inout CellResult) {
        let name = checkpoint.name
        for difference in checkpoint.state.differences { result.failures.append("\(name) state: \(difference)") }
        if !checkpoint.pixels.passes {
            if let mismatch = checkpoint.pixels.sizeMismatch {
                result.failures.append("\(name) pixels: snapshot sizes differ (\(mismatch))")
            } else {
                result.failures.append(String(
                    format: "%@ pixels: %.3f%% differ (limit %.1f%%), max ΔE %.2f (limit %.1f), %d px over the limit",
                    name, checkpoint.pixels.differingPercent, PixelComparator.maximumDifferingPercent,
                    checkpoint.pixels.maxDeltaE, PixelComparator.maximumDeltaE, checkpoint.pixels.pixelsOverThreshold
                ))
            }
        }
        if let strict = checkpoint.pixelsCaretOnly {
            result.toleratedDeviations.append(String(
                format: "12.5 range selection: %d part(s) of the reference's range-selection display (handles, their shadows, squared token corners) masked at %@; with the caret alone masked %.3f%% differ, max ΔE %.2f",
                handles, name, strict.differingPercent, strict.maxDeltaE
            ))
        }
        if !checkpoint.metrics.passes {
            for failure in checkpoint.metrics.failures.prefix(6) {
                result.failures.append(String(
                    format: "%@ metrics: %@ reference %.2f, clone %.2f, off by %.2f pt",
                    name, failure.name, failure.reference ?? .nan, failure.clone ?? .nan, failure.deviation ?? .nan
                ))
            }
            for missing in checkpoint.metrics.missing { result.failures.append("\(name) metrics: \(missing)") }
        }
        for difference in checkpoint.accessibility.differences { result.failures.append("\(name) accessibility: \(difference)") }
        if checkpoint.pixels.sizeMismatch == nil {
            result.worstPixelPercent = max(result.worstPixelPercent, checkpoint.pixels.differingPercent)
            result.worstDeltaE = max(result.worstDeltaE, checkpoint.pixels.maxDeltaE)
        }
        result.worstMetricDeviation = max(result.worstMetricDeviation, checkpoint.metrics.worstDeviation)
    }

    private func writeSnapshots(_ reference: CapturedField, _ clone: CapturedField, checkpoint: String, to directory: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        func write(_ image: PixelImage?, _ suffix: String) throws {
            guard let data = image?.pngData() else { return }
            let name = "\(checkpoint)-\(suffix).png"
            try data.write(to: directory.appendingPathComponent(name))
            written.append(name)
        }
        try write(reference.image, "reference")
        try write(clone.image, "clone")
        let (carets, handles) = masks(reference, clone)
        try write(PixelComparator.compare(reference: reference.image, clone: clone.image, masks: carets + handles).difference, "difference")
        return written
    }

    // MARK: Diagnosis

    private func dump(named name: String) throws {
        let reference = stage.reference
        let clone = stage.clone
        reference.noteTokens()
        var lines: [String] = []
        lines.append("== reference: text=\(ParityEvent.quoted(reference.text)) tokens=\(reference.labels) selected=\(reference.selectedLabels) editing=\(reference.textField.isEditing) observing=\(reference.isObserving) keyPresses=\(ParityWindow.keyPressCount)")
        lines.append("-- events")
        lines += reference.events.map(\.description)
        lines.append("-- trace")
        lines += reference.trace
        lines.append("== clone: text=\(ParityEvent.quoted(clone.text)) tokens=\(clone.labels) selected=\(clone.selectedLabels) focused=\(clone.isFocused) inner=\(ParityEvent.quoted(clone.innerTextField?.text ?? "nil"))")
        lines.append("-- events")
        lines += clone.events.map(\.description)
        lines.append("== slots: reference=\(RectValue(stage.slot(.reference))) clone=\(RectValue(stage.slot(.clone)))")
        for side in FieldSide.allCases {
            let metrics = side == .reference ? reference.metrics(in: stage.view, slot: stage.slot(side)) : clone.metrics(in: stage.view, slot: stage.slot(side))
            lines.append("== \(side.rawValue) metrics")
            for (key, value) in metrics.frames.sorted(by: { $0.key < $1.key }) { lines.append("  \(key) = \(value)") }
            for (key, value) in metrics.lengths.sorted(by: { $0.key < $1.key }) { lines.append("  \(key) = \(String(format: "%.2f", value))") }
        }
        lines.append("== reference hierarchy (stage coordinates)")
        lines += ViewDump.lines(of: reference.searchBar, relativeTo: stage.view)
        lines.append("== clone hierarchy (stage coordinates)")
        lines += ViewDump.lines(of: clone.view, relativeTo: stage.view)
        // Whatever else draws where the fields are: effects hosted outside the fields' own views.
        for window in stage.view.window?.windowScene?.windows ?? [] {
            lines.append("== window \(type(of: window)) level=\(window.windowLevel.rawValue)")
            lines += ViewDump.lines(of: window, relativeTo: window, skipping: [reference.searchBar, clone.view])
        }
        try lines.joined(separator: "\n").write(to: channel.directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)

        let image = UIGraphicsImageRenderer(bounds: stage.view.bounds).image { _ in
            stage.view.drawHierarchy(in: stage.view.bounds, afterScreenUpdates: true)
        }
        try image.pngData()?.write(to: channel.directory.appendingPathComponent("\(name).png"))
    }
}

extension ParityStageController {
    static let referenceIdentifier = "parity.reference"
    static let cloneIdentifier = "parity.clone"

    /// Where a UI test taps on one field, in screen points.
    func geometry(_ side: FieldSide) -> FieldGeometry {
        let slot = slot(side)
        func onScreen(_ rect: CGRect, from view: UIView) -> RectValue {
            RectValue(view.convert(rect, to: nil))
        }
        let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        /// A small rectangle halfway between the end of the content and the far end of the
        /// text area: on no token and on no button, so a tap there puts the caret at the end.
        func textPoint(contentEnd: CGFloat, farEnd: CGFloat, midY: CGFloat) -> CGRect {
            CGRect(x: (contentEnd + farEnd) / 2 - 1, y: midY - 1, width: 2, height: 2)
        }
        func width(of text: String, in field: UITextField) -> CGFloat {
            guard let font = field.font, !text.isEmpty else { return 0 }
            return (text as NSString).size(withAttributes: [.font: font]).width
        }
        switch side {
        case .reference:
            let field = reference.textField
            let tokenRects = reference.tokenViews.mapValues { $0.convert($0.bounds, to: field) }
            let clear = reference.clearButton.map { $0.convert($0.bounds, to: field) }
            let textRect = field.isEditing ? field.editingRect(forBounds: field.bounds) : field.textRect(forBounds: field.bounds)
            var contentEnd = rightToLeft ? textRect.maxX : textRect.minX
            for rect in tokenRects.values { contentEnd = rightToLeft ? min(contentEnd, rect.minX) : max(contentEnd, rect.maxX) }
            let typed = width(of: field.text ?? "", in: field)
            let textRun = typed > 0 ? CGRect(x: rightToLeft ? contentEnd - typed : contentEnd, y: textRect.minY, width: typed, height: textRect.height) : nil
            contentEnd += (rightToLeft ? -1 : 1) * typed
            let farEnd: CGFloat
            if rightToLeft {
                farEnd = max(textRect.minX, clear.map { $0.maxX + 4 } ?? textRect.minX)
            } else {
                farEnd = min(textRect.maxX, clear.map { $0.minX - 4 } ?? textRect.maxX)
            }
            reference.noteTokens()
            return FieldGeometry(
                slot: onScreen(slot, from: view),
                textPoint: onScreen(textPoint(contentEnd: contentEnd, farEnd: farEnd, midY: field.bounds.midY), from: field),
                textRun: textRun.map { onScreen($0, from: field) },
                tokens: tokenRects.mapValues { onScreen($0, from: field) },
                clearButton: clear.map { onScreen($0, from: field) },
                cancelButton: reference.cancelButton.map { onScreen($0.bounds, from: $0) },
                isEditing: field.isEditing, text: reference.text, tokenLabels: reference.labels,
                selectedLabels: reference.selectedLabels, events: reference.events, isRightToLeft: rightToLeft, containerIdentifier: Self.referenceIdentifier
            )
        case .clone:
            // The same touch as on the reference: halfway between the end of the clone's own
            // content and the far end of its text area, which lies in the clone's field where
            // the reference's lies in its own.
            let host = clone.view
            let field = clone.fieldFrame ?? host.bounds
            let model = reference.textField
            let isEditing = clone.innerTextField?.isFirstResponder ?? false
            let area = isEditing ? model.editingRect(forBounds: model.bounds) : model.textRect(forBounds: model.bounds)
            let left = field.minX + area.minX, right = field.maxX - (model.bounds.maxX - area.maxX)
            var contentEnd = rightToLeft ? right : left
            for rect in clone.tokenFrames.values { contentEnd = rightToLeft ? min(contentEnd, rect.minX) : max(contentEnd, rect.maxX) }
            var textRun: CGRect?
            if let input = clone.innerTextField {
                let frame = input.convert(input.bounds, to: host)
                let typed = width(of: clone.text, in: input)
                if typed > 0 {
                    textRun = CGRect(x: rightToLeft ? frame.maxX - typed : frame.minX, y: frame.minY, width: typed, height: frame.height)
                    contentEnd = rightToLeft ? min(contentEnd, frame.maxX - typed) : max(contentEnd, frame.minX + typed)
                }
            }
            let clear = clone.clearButtonFrame
            let farEnd = rightToLeft ? max(left, clear.map { $0.maxX + 4 } ?? left) : min(right, clear.map { $0.minX - 4 } ?? right)
            return FieldGeometry(
                slot: onScreen(slot, from: view),
                textPoint: onScreen(textPoint(contentEnd: contentEnd, farEnd: farEnd, midY: field.midY), from: host),
                textRun: textRun.map { onScreen($0, from: host) },
                tokens: clone.tokenFrames.mapValues { onScreen($0, from: host) },
                clearButton: clone.clearButtonFrame.map { onScreen($0, from: host) },
                cancelButton: clone.cancelButtonFrame.map { onScreen($0, from: host) },
                isEditing: clone.innerTextField?.isFirstResponder ?? false, text: clone.text, tokenLabels: clone.labels,
                selectedLabels: clone.selectedLabels, events: clone.events, isRightToLeft: rightToLeft, containerIdentifier: Self.cloneIdentifier
            )
        }
    }

    static func descendants<T: UIView>(of view: UIView, ofType type: T.Type) -> [T] {
        var found: [T] = []
        for subview in view.subviews {
            if let match = subview as? T { found.append(match) }
            found += descendants(of: subview, ofType: type)
        }
        return found
    }
}
