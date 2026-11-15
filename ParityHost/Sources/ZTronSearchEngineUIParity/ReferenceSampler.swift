import UIKit

/// What the UIKit reference measures under one environment (one iOS version, one content size,
/// one appearance): the values the clone's defaults are generated from
/// (specification section 12.4, "sampled from UIKit, not typed from memory").
public struct ReferenceSample: Codable, Sendable {
    public var majorVersion: Int
    public var osVersion: String
    public var modelIdentifier: String
    public var scale: Double
    /// The raw value of the content size category the sample was taken at.
    public var contentSizeCategory: String
    public var isDark: Bool
    public var isHighContrast: Bool
    /// The clone's layout metrics, in points (see `ZTronSearchFieldMetrics`).
    public var metrics: [String: Double] = [:]
    /// The named colors, each resolved from the `UIColor` the reference draws with, for the
    /// four appearances: light, dark, lightHighContrast, darkHighContrast. sRGB components.
    public var colors: [String: [String: [Double]]] = [:]
    /// The same colors solved from pixels (rendered over white and over black) under the
    /// appearance the sample was taken in: an independent check of `colors`.
    public var renderedColors: [String: [Double]] = [:]
    /// UIKit's own defaults that are not lengths: `clearButtonMode`, fonts, symbol names.
    public var defaults: [String: String] = [:]
    /// Every rectangle the metrics were derived from, for the record.
    public var rects: [String: RectValue] = [:]
    /// What could not be measured, and why.
    public var notes: [String] = []
}

/// Measures the reference field on the stage. It rebuilds the stage several times; nothing of
/// a running script survives it.
@MainActor
struct ReferenceSampler {
    let stage: ParityStageController

    private var bar: UISearchBar { stage.reference.searchBar }
    private var field: UISearchTextField { stage.reference.textField }

    private func settle(_ seconds: Double = 0.25) async {
        stage.view.layoutIfNeeded()
        await ParitySession.pause(seconds)
        stage.view.layoutIfNeeded()
    }

    /// A view's frame in the text field's coordinates.
    private func inField(_ view: UIView) -> CGRect {
        view.convert(view.bounds, to: field)
    }

    func sample() async throws -> ReferenceSample {
        let environment = stage.hostEnvironment
        var sample = ReferenceSample(
            majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            osVersion: environment.osVersion, modelIdentifier: environment.modelIdentifier, scale: environment.scale,
            contentSizeCategory: environment.contentSizeCategory, isDark: environment.isDark,
            isHighContrast: environment.isHighContrast
        )
        try await sampleEmptyField(into: &sample)
        try await sampleTokens(into: &sample)
        try await sampleEditing(into: &sample)
        try await sampleOverflow(into: &sample)
        try await sampleCancelButton(into: &sample)
        try await sampleAnimations(into: &sample)
        return sample
    }

    // MARK: Empty field: height, corner radius, glyph, placeholder

    private func sampleEmptyField(into sample: inout ReferenceSample) async throws {
        stage.rebuild(FieldSetup(prompt: "Search"))
        await settle()
        let field = field
        let frameInBar = field.convert(field.bounds, to: bar)
        sample.rects["bar"] = RectValue(bar.bounds)
        sample.rects["fieldInBar"] = RectValue(frameInBar)
        sample.metrics["fieldHeight"] = Double(field.bounds.height)
        sample.metrics["barHeight"] = Double(bar.bounds.height)
        sample.metrics["barLeadingInset"] = Double(leading(of: frameInBar, in: bar.bounds))
        sample.metrics["barTopInset"] = Double(frameInBar.minY)
        sample.defaults["clearButtonMode"] = Self.name(of: field.clearButtonMode)
        sample.defaults["standaloneClearButtonMode"] = Self.name(of: UISearchTextField().clearButtonMode)
        sample.defaults["textFont"] = field.font.map(Self.describe) ?? "nil"

        // The background: the first subview that rounds its corners.
        guard let background = ParityStageController.descendants(of: field, ofType: UIView.self).first(where: { $0.layer.cornerRadius > 0 }) else {
            throw ParityError("the reference field has no rounded background view")
        }
        sample.metrics["cornerRadius"] = Double(background.layer.cornerRadius)
        sample.defaults["cornerCurve"] = background.layer.cornerCurve.rawValue
        sample.rects["background"] = RectValue(inField(background))
        if let fill = background.backgroundColor {
            sample.colors["searchFieldFill"] = resolve(fill)
        } else {
            sample.notes.append("the field's background view has no background color to resolve")
        }

        guard let glyph = stage.reference.glyphView, let image = glyph.image else {
            throw ParityError("the reference field has no search glyph")
        }
        let glyphFrame = inField(glyph)
        sample.rects["glyph"] = RectValue(glyphFrame)
        sample.metrics["glyphLeading"] = Double(leading(of: glyphFrame, in: field.bounds))
        sample.metrics["glyphTop"] = Double(glyphFrame.minY)
        sample.metrics["glyphWidth"] = Double(glyphFrame.width)
        sample.metrics["glyphHeight"] = Double(glyphFrame.height)
        recordSymbol(image, named: "glyph", into: &sample)
        sample.colors["glyph"] = resolve(glyph.tintColor)

        if let placeholder = ParityStageController.descendants(of: field, ofType: UILabel.self).first(where: { $0.text == "Search" }) {
            let frame = inField(placeholder)
            sample.rects["placeholderLabel"] = RectValue(frame)
            sample.metrics["textLeading"] = Double(leading(of: frame, in: field.bounds))
            sample.defaults["placeholderFont"] = Self.describe(placeholder.font)
            sample.colors["placeholderText"] = resolve(placeholder.textColor)
        } else {
            sample.notes.append("no placeholder label was found in the empty field")
        }
        let bounds = field.bounds
        sample.rects["textRect"] = RectValue(field.textRect(forBounds: bounds))
        sample.rects["placeholderRect"] = RectValue(field.placeholderRect(forBounds: bounds))
        sample.rects["editingRect"] = RectValue(field.editingRect(forBounds: bounds))
        sample.rects["clearButtonRect"] = RectValue(field.clearButtonRect(forBounds: bounds))
        sample.rects["leftViewRect"] = RectValue(field.leftViewRect(forBounds: bounds))
        sample.metrics["textTrailing"] = Double(trailing(of: field.textRect(forBounds: bounds), in: bounds))
        sample.metrics["fontSize"] = Double(field.font?.pointSize ?? 0)
        sample.metrics["glyphBaseline"] = Double(glyphFrame.maxY - (image.baselineOffsetFromBottom ?? 0))
        identifySymbol(image, named: "magnifyingglass", key: "glyph", shownAt: glyphFrame.size, into: &sample)
        if let baseline = ParityStageController.firstBaseline(of: field, in: stage.view) {
            sample.metrics["baseline"] = Double(baseline - field.convert(field.bounds, to: stage.view).minY)
        }
        if let rendered = try renderedColor(at: CGPoint(x: bounds.midX, y: bounds.maxY - 3), in: field) {
            sample.renderedColors["searchFieldFill"] = rendered
        }
    }

    // MARK: Tokens

    private func sampleTokens(into sample: inout ReferenceSample) async throws {
        stage.rebuild(FieldSetup(text: "harbor", tokens: [ParityScript.maps, ParityScript.tips]))
        await settle()
        let field = field
        let views = stage.reference.tokenViews
        guard let first = views[0], let second = views[1] else {
            throw ParityError("the reference field shows no token views (\(views.count) found for 2 tokens)")
        }
        let firstFrame = inField(first), secondFrame = inField(second)
        sample.rects["token0"] = RectValue(firstFrame)
        sample.rects["token1"] = RectValue(secondFrame)
        sample.metrics["tokenHeight"] = Double(firstFrame.height)
        sample.metrics["tokenTop"] = Double(firstFrame.minY)
        sample.metrics["tokenCornerRadius"] = Double(first.layer.cornerRadius)
        sample.defaults["tokenCornerCurve"] = first.layer.cornerCurve.rawValue
        sample.metrics["tokenSpacing"] = Double(distance(from: firstFrame, to: secondFrame))
        // Tokens sit in layout views that reserve the space around them; the first one starts
        // where the content starts. At accessibility sizes that is not where the placeholder
        // starts: the field gives the glyph's room to its content.
        guard let firstLayout = first.superview, firstLayout !== field else {
            throw ParityError("the reference's token views are not inside layout views")
        }
        let firstLayoutFrame = inField(firstLayout)
        sample.rects["tokenLayout0"] = RectValue(firstLayoutFrame)
        sample.metrics["contentLeading"] = Double(leading(of: firstLayoutFrame, in: field.bounds))
        sample.metrics["tokenLeadingInset"] = Double(leading(of: firstFrame, in: firstLayoutFrame))
        let glyphShown = stage.reference.glyphView.map { glyph in
            glyph.window != nil && !glyph.isHidden && glyph.alpha > 0.01 && glyph.bounds.width > 0
        } ?? false
        sample.metrics["glyphShownWithContent"] = glyphShown ? 1 : 0
        if let glyph = stage.reference.glyphView { sample.rects["glyphWithContent"] = RectValue(inField(glyph)) }

        guard let label = first.subviews.lazy.compactMap({ $0 as? UILabel }).first,
              let icon = first.subviews.lazy.compactMap({ $0 as? UIImageView }).first else {
            throw ParityError("a token view of the reference holds no label or no image view")
        }
        let labelFrame = label.convert(label.bounds, to: first), iconFrame = icon.convert(icon.bounds, to: first)
        sample.rects["tokenLabel"] = RectValue(labelFrame)
        sample.rects["tokenIcon"] = RectValue(iconFrame)
        sample.metrics["tokenHorizontalPadding"] = Double(leading(of: iconFrame, in: first.bounds))
        sample.metrics["tokenIconSpacing"] = Double(distance(from: iconFrame, to: labelFrame))
        sample.metrics["tokenIconWidth"] = Double(iconFrame.width)
        sample.metrics["tokenIconHeight"] = Double(iconFrame.height)
        sample.metrics["tokenTrailingPadding"] = Double(trailing(of: labelFrame, in: first.bounds))
        sample.metrics["tokenFontSize"] = Double(label.font.pointSize)
        sample.metrics["tokenLabelHeight"] = Double(labelFrame.height)
        sample.defaults["tokenFont"] = Self.describe(label.font)
        sample.metrics["tokenIconTop"] = Double(iconFrame.minY)
        sample.metrics["tokenLabelTop"] = Double(labelFrame.minY)
        sample.defaults["tokenLabelLineBreakMode"] = "\(label.lineBreakMode.rawValue)"
        sample.defaults["tokenIconContentMode"] = "\(icon.contentMode.rawValue)"
        if let image = icon.image {
            recordSymbol(image, named: "tokenIcon", into: &sample)
            sample.metrics["tokenIconScale"] = Double(iconFrame.width / image.size.width)
            identifySymbol(image, named: "map", key: "tokenIcon", shownAt: iconFrame.size, into: &sample)
        }
        sample.colors["tokenText"] = resolve(label.textColor)
        sample.colors["tokenIconTint"] = resolve(icon.tintColor)
        if let fill = first.subviews.first(where: { $0.backgroundColor != nil })?.backgroundColor ?? first.backgroundColor {
            sample.colors["tokenFill"] = resolve(fill)
        } else {
            sample.notes.append("a token view of the reference has no background color to resolve")
        }
        // The token without an icon: where its label starts.
        if let plain = second.subviews.lazy.compactMap({ $0 as? UILabel }).first {
            sample.metrics["tokenPlainPadding"] = Double(leading(of: plain.convert(plain.bounds, to: second), in: second.bounds))
        }
        // Tokens sit in a layout view that reserves the space around them.
        if let layout = second.superview, layout !== field {
            let layoutFrame = inField(layout)
            sample.rects["tokenLayout1"] = RectValue(layoutFrame)
            sample.metrics["tokenTrailingInset"] = Double(trailing(of: secondFrame, in: layoutFrame))
        }
        if let rendered = try renderedColor(at: CGPoint(x: firstFrame.minX + 2, y: firstFrame.midY), in: field) {
            sample.renderedColors["tokenFill"] = rendered
        }

        if let clear = stage.reference.clearButton {
            let frame = inField(clear)
            sample.rects["clearButton"] = RectValue(frame)
            sample.metrics["clearButtonWidth"] = Double(frame.width)
            sample.metrics["clearButtonHeight"] = Double(frame.height)
            sample.metrics["clearButtonTop"] = Double(frame.minY)
            sample.metrics["clearButtonTrailing"] = Double(trailing(of: frame, in: field.bounds))
            if let image = ParityStageController.descendants(of: clear, ofType: UIImageView.self).first?.image {
                recordSymbol(image, named: "clear", into: &sample)
                sample.metrics["clearButtonBaseline"] = Double(frame.maxY - (image.baselineOffsetFromBottom ?? 0))
                identifySymbol(image, named: "xmark.circle.fill", key: "clear", shownAt: frame.size, into: &sample)
            }
            // Inside the disc, clear of the cross: a fifth of the way in.
            if let rendered = try renderedColor(at: CGPoint(x: frame.minX + frame.width * 0.2, y: frame.midY), in: field, over: "searchFieldFill", sample: sample) {
                sample.renderedColors["clearGlyph"] = rendered
                // The button's image carries its color where no API reads it back; the pixels
                // say which system color it is, and the system gives its exact components.
                if let match = systemColor(matching: rendered) {
                    sample.colors["clearGlyph"] = resolve(match.color)
                    sample.defaults["clearGlyphSource"] = String(
                        format: "UIColor.%@, identified from pixels rendered over white and over black (largest component difference %.4f)",
                        match.name, match.distance
                    )
                }
            }
        } else {
            sample.notes.append("the reference shows no clear button while it holds content and is not editing")
        }
    }

    // MARK: Editing: text position, selected token

    private func sampleEditing(into sample: inout ReferenceSample) async throws {
        stage.rebuild(FieldSetup(text: "harbor", tokens: [ParityScript.maps, ParityScript.tips]))
        await settle()
        let field = field
        guard field.becomeFirstResponder() else {
            sample.notes.append("the reference field refused first responder: editing metrics not sampled")
            return
        }
        await settle(0.4)
        // Text-input rectangles are in the coordinates of the view that draws the text.
        let textRect = field.textInputView.convert(field.firstRect(for: field.textualRange), to: field)
        if !textRect.isNull, !textRect.isInfinite {
            sample.rects["editingText"] = RectValue(textRect)
            if let last = stage.reference.tokenViews[1] {
                sample.metrics["tokenToTextSpacing"] = Double(distance(from: inField(last), to: textRect))
            }
        }
        let caret = field.textInputView.convert(field.caretRect(for: field.endOfDocument), to: field)
        if !caret.isNull, !caret.isInfinite {
            sample.rects["caret"] = RectValue(caret)
            sample.metrics["caretWidth"] = Double(caret.width)
            sample.metrics["caretHeight"] = Double(caret.height)
        }
        if let clear = stage.reference.clearButton {
            sample.rects["clearButtonEditing"] = RectValue(inField(clear))
            // How far the text area ends before the clear button.
            let editing = field.editingRect(forBounds: field.bounds)
            sample.rects["editingRectWithClear"] = RectValue(editing)
            sample.metrics["textTrailingWithClearButton"] = Double(trailing(of: editing, in: field.bounds))
        }
        if let baseline = ParityStageController.firstBaseline(of: field, in: stage.view) {
            sample.metrics["baselineEditing"] = Double(baseline - field.convert(field.bounds, to: stage.view).minY)
        }

        sample.colors["tint"] = resolve(field.tintColor)
        field.resignFirstResponder()
        await settle()
    }

    // MARK: Overflow: the fade of a clipped token, the width of the longest token

    private func sampleOverflow(into sample: inout ReferenceSample) async throws {
        stage.rebuild(FieldSetup(tokens: ParityScript.many))
        await settle()
        let field = field
        let clipped = ParityStageController.descendants(of: field, ofType: UIView.self).first { $0.layer.mask is CAGradientLayer }
        if let clipped, let gradient = clipped.layer.mask as? CAGradientLayer, let locations = gradient.locations?.map({ CGFloat(truncating: $0) }) {
            let alphas = (gradient.colors ?? []).map { color -> CGFloat in
                let object = color as AnyObject
                return CFGetTypeID(object) == CGColor.typeID ? unsafeDowncast(object, to: CGColor.self).alpha : -1
            }
            // The stops between which the opacity falls from 1 to 0, in the field's coordinates.
            let origin = clipped.convert(gradient.frame, to: field).minX
            for index in 0..<(min(alphas.count, locations.count) - 1) where alphas[index] == 1 && alphas[index + 1] == 0 {
                let start = origin + locations[index] * gradient.frame.width
                let end = origin + locations[index + 1] * gradient.frame.width
                sample.metrics["overflowFadeLength"] = Double(end - start)
                sample.metrics["overflowFadeTrailing"] = Double(field.bounds.maxX - end)
            }
            sample.defaults["overflowFade"] = "alphas=\(alphas) locations=\(locations) frame=\(RectValue(gradient.frame))"
        } else {
            sample.notes.append("no token carries a gradient mask when the tokens overflow the field")
        }

        // Editing: the content scrolls so that its end, with room for the caret, meets the end
        // of the text area. How much room, after a token and after text.
        if field.becomeFirstResponder() {
            await settle(0.4)
            let containerEnd = field.editingRect(forBounds: field.bounds)
            if let last = stage.reference.tokenViews[ParityScript.many.count - 1] {
                sample.metrics["caretRoomAfterToken"] = Double(trailing(of: inField(last), in: containerEnd))
            } else {
                sample.notes.append("the last of the overflowing tokens has no view while editing")
            }
            field.text = "x"
            await settle(0.3)
            // After text the room is counted from where the text ends when its width is
            // rounded up to whole pixels, which is how a text view is sized.
            let textRect = field.textInputView.convert(field.firstRect(for: field.textualRange), to: field)
            if !textRect.isNull, !textRect.isInfinite, let font = field.font {
                let scale = stage.view.window?.windowScene?.screen.scale ?? UIScreen.main.scale
                let advance = ("x" as NSString).size(withAttributes: [.font: font]).width
                let width = (advance * scale).rounded(.up) / scale
                let start = isRightToLeft ? textRect.maxX : textRect.minX
                let end = isRightToLeft ? start - width : start + width
                let area = field.editingRect(forBounds: field.bounds)
                sample.metrics["caretRoomAfterText"] = Double(isRightToLeft ? end - area.minX : area.maxX - end)
            }
            field.resignFirstResponder()
            await settle()
        } else {
            sample.notes.append("the reference field refused first responder: the caret's room was not sampled")
        }

        // The widest a token gets, at two widths of the field: a token is limited to a share
        // of the text area plus a constant, and two widths tell the two apart.
        let long = String(repeating: "Wide token label ", count: 6).trimmingCharacters(in: .whitespaces)
        var limits: [(area: CGFloat, token: CGFloat)] = []
        for reduction in [CGFloat(0), 60] {
            stage.rebuild(FieldSetup(tokens: [ParityTokenSpec(long)]))
            stage.widthReduction = reduction
            await settle()
            guard let view = stage.reference.tokenViews[0] else {
                sample.notes.append("a token wider than the field has no view")
                continue
            }
            let field = self.field
            let frame = inField(view)
            limits.append((field.textRect(forBounds: field.bounds).width, frame.width))
            if reduction == 0 {
                sample.rects["longToken"] = RectValue(frame)
                sample.metrics["longTokenWidth"] = Double(frame.width)
                sample.metrics["longTokenTextAreaWidth"] = Double(field.textRect(forBounds: field.bounds).width)
                if let label = view.subviews.lazy.compactMap({ $0 as? UILabel }).first {
                    sample.metrics["longTokenLabelWidth"] = Double(label.bounds.width)
                    sample.metrics["longTokenNaturalLabelWidth"] = Double(label.intrinsicContentSize.width)
                }
            }
        }
        stage.widthReduction = 0
        if limits.count == 2, limits[0].area != limits[1].area {
            let share = (limits[0].token - limits[1].token) / (limits[0].area - limits[1].area)
            sample.metrics["tokenWidthLimitShare"] = Double(share)
            sample.metrics["tokenWidthLimitExtra"] = Double(limits[0].token - share * limits[0].area)
            sample.defaults["tokenWidthLimit"] = limits.map { "area \($0.area) -> token \($0.token)" }.joined(separator: "; ")
        } else {
            sample.notes.append("the widest token could not be measured at two field widths")
        }
    }

    // MARK: Cancel button

    private func sampleCancelButton(into sample: inout ReferenceSample) async throws {
        stage.rebuild(FieldSetup(cancelButton: true))
        await settle()
        let resting = field.convert(field.bounds, to: bar)
        bar.setShowsCancelButton(true, animated: false)
        await settle()
        guard let cancel = stage.reference.cancelButton else {
            sample.notes.append("the search bar shows no Cancel button after setShowsCancelButton(true)")
            return
        }
        let cancelFrame = cancel.convert(cancel.bounds, to: bar)
        let fieldFrame = field.convert(field.bounds, to: bar)
        sample.rects["cancelButton"] = RectValue(cancelFrame)
        sample.rects["fieldWithCancel"] = RectValue(fieldFrame)
        sample.metrics["cancelButtonSpacing"] = Double(distance(from: fieldFrame, to: cancelFrame))
        sample.metrics["cancelButtonWidth"] = Double(cancelFrame.width)
        sample.metrics["cancelButtonHeight"] = Double(cancelFrame.height)
        // Past the resting field's far edge when positive: the button reaches into the bar's margin.
        sample.metrics["cancelButtonOverhang"] = Double(-trailing(of: cancelFrame, in: resting))
        sample.metrics["cancelButtonTop"] = Double(cancelFrame.minY - resting.minY)
        if let title = cancel.titleLabel {
            sample.rects["cancelTitle"] = RectValue(title.convert(title.bounds, to: bar))
            sample.defaults["cancelFont"] = Self.describe(title.font)
            sample.metrics["cancelFontSize"] = Double(title.font.pointSize)
            sample.metrics["cancelTitleTop"] = Double(title.convert(title.bounds, to: bar).minY - resting.minY)
            sample.metrics["cancelTitleHeight"] = Double(title.bounds.height)
            sample.defaults["cancelTitle"] = title.text ?? ""
            sample.metrics["cancelTitleInset"] = Double(leading(of: title.convert(title.bounds, to: cancel), in: cancel.bounds))
            sample.defaults["cancelEnabledWhileNotEditing"] = "\(cancel.isEnabled)"
            sample.colors["cancelTitleNotEditing"] = resolve(title.textColor)
            // The button is live only while the field edits.
            if field.becomeFirstResponder() {
                await settle(0.4)
                sample.colors["cancelTitle"] = resolve(title.textColor)
                field.resignFirstResponder()
                await settle()
            }
        }
    }

    // MARK: Animations

    private func sampleAnimations(into sample: inout ReferenceSample) async throws {
        // Text to token: replaceTextualPortion(of:with:at:), while editing, as a host calls it.
        stage.rebuild(FieldSetup(text: "map"))
        await settle()
        let field = field
        if field.becomeFirstResponder() {
            await settle(0.4)
            let recorder = AnimationRecorder(view: bar)
            recorder.start(seconds: 1.5)
            await ParitySession.pause(0.2)
            field.replaceTextualPortion(of: field.textualRange, with: ReferenceField.token(ParityTokenSpec("map")), at: 0)
            await ParitySession.pause(1.4)
            recorder.stop()
            let recording = recorder.recording
            sample.metrics["tokenInsertionDuration"] = recording.duration
            sample.defaults["tokenInsertionRecording"] = "\(recording.changedFrames) changed of \(recording.sampledFrames) frames, median interval \(Int(recording.medianFrameInterval * 1000)) ms"
            // The new token comes out selected, and without the handles a touch would bring:
            // the one state in which the selected fill can be read from pixels undisturbed.
            sample.defaults["selectedAfterConversion"] = "\(stage.reference.selectedLabels)"
            sample.metrics["handlesAfterConversion"] = Double(stage.reference.selectionHandles(in: stage.view, slot: .zero).count)
            if let selected = stage.reference.tokenViews[0], !stage.reference.selectedLabels.isEmpty {
                if let fill = selected.subviews.first(where: { $0.backgroundColor != nil })?.backgroundColor ?? selected.backgroundColor {
                    sample.colors["tokenSelectedFill"] = resolve(fill)
                    sample.defaults["tokenSelectedFillSource"] = "\(fill)"
                }
                if let label = selected.subviews.lazy.compactMap({ $0 as? UILabel }).first {
                    sample.colors["tokenSelectedText"] = resolve(label.textColor)
                }
                let frame = inField(selected)
                if let rendered = try renderedColor(at: CGPoint(x: frame.minX + 2, y: frame.midY), in: field) {
                    sample.renderedColors["tokenSelectedFill"] = rendered
                }
            } else {
                sample.notes.append("the token made by replaceTextualPortion is not selected: the selected colors were not sampled")
            }
            field.resignFirstResponder()
        } else {
            sample.notes.append("the reference field refused first responder: the insertion animation was not sampled")
        }

        // The Cancel button sliding in.
        stage.rebuild(FieldSetup(cancelButton: true))
        await settle()
        let recorder = AnimationRecorder(view: bar)
        recorder.start(seconds: 1.5)
        await ParitySession.pause(0.2)
        bar.setShowsCancelButton(true, animated: true)
        await ParitySession.pause(1.4)
        recorder.stop()
        let recording = recorder.recording
        sample.metrics["cancelAnimationDuration"] = recording.duration
        sample.defaults["cancelAnimationRecording"] = "\(recording.changedFrames) changed of \(recording.sampledFrames) frames, median interval \(Int(recording.medianFrameInterval * 1000)) ms"
    }

    // MARK: Geometry in reading order

    private var isRightToLeft: Bool { stage.view.effectiveUserInterfaceLayoutDirection == .rightToLeft }

    /// Distance from the container's leading edge to the rectangle's.
    private func leading(of rect: CGRect, in container: CGRect) -> CGFloat {
        isRightToLeft ? container.maxX - rect.maxX : rect.minX - container.minX
    }

    /// Distance from the rectangle's trailing edge to the container's.
    private func trailing(of rect: CGRect, in container: CGRect) -> CGFloat {
        isRightToLeft ? rect.minX - container.minX : container.maxX - rect.maxX
    }

    /// The gap between a rectangle and the one that follows it in reading order.
    private func distance(from first: CGRect, to second: CGRect) -> CGFloat {
        isRightToLeft ? first.minX - second.maxX : second.minX - first.maxX
    }

    // MARK: Colors

    /// A dynamic color resolved for the four appearances the asset catalog carries.
    private func resolve(_ color: UIColor) -> [String: [Double]] {
        var resolved: [String: [Double]] = [:]
        for (name, dark, contrast) in [("light", false, false), ("dark", true, false), ("lightHighContrast", false, true), ("darkHighContrast", true, true)] {
            let traits = UITraitCollection(traitsFrom: [
                field.traitCollection,
                UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
                UITraitCollection(accessibilityContrast: contrast ? .high : .normal),
            ])
            resolved[name] = Self.components(of: color.resolvedColor(with: traits))
        }
        return resolved
    }

    /// The semantic system color whose components, under the field's traits, are the ones a
    /// rendering solved for, to within what 8-bit pixels can tell.
    private func systemColor(matching rendered: [Double]) -> (name: String, color: UIColor, distance: Double)? {
        guard rendered.count == 4 else { return nil }
        let candidates: [(String, UIColor)] = [
            ("label", .label), ("secondaryLabel", .secondaryLabel), ("tertiaryLabel", .tertiaryLabel),
            ("quaternaryLabel", .quaternaryLabel), ("placeholderText", .placeholderText),
            ("systemGray", .systemGray), ("systemGray2", .systemGray2), ("systemGray3", .systemGray3),
            ("systemGray4", .systemGray4), ("systemGray5", .systemGray5), ("systemGray6", .systemGray6),
            ("systemFill", .systemFill), ("secondarySystemFill", .secondarySystemFill),
            ("tertiarySystemFill", .tertiarySystemFill), ("quaternarySystemFill", .quaternarySystemFill),
        ]
        var best: (name: String, color: UIColor, distance: Double)?
        for (name, color) in candidates {
            let components = Self.components(of: color.resolvedColor(with: field.traitCollection))
            guard components.count == 4 else { continue }
            let distance = zip(components, rendered).map { abs($0 - $1) }.max() ?? 1
            if distance <= 0.02, distance < best?.distance ?? 1 { best = (name, color, distance) }
        }
        return best
    }

    static func components(of color: UIColor) -> [Double] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return [] }
        return [Double(red), Double(green), Double(blue), Double(alpha)]
    }

    /// The color drawn at a point of the field, solved from two renderings: the stage over
    /// white and over black. With `C` the color and `a` its opacity, a pixel reads
    /// `a*C + (1-a)` over white and `a*C` over black, so `a = 1 - (white - black)` and
    /// `C = black / a`. When the color sits on another translucent one (`over`), that layer is
    /// removed first.
    private func renderedColor(at point: CGPoint, in view: UIView, over base: String? = nil, sample: ReferenceSample? = nil) throws -> [Double]? {
        let original = stage.view.backgroundColor
        defer { stage.view.backgroundColor = original }
        let location = view.convert(point, to: stage.view)
        func pixel(_ background: UIColor) -> [Double]? {
            stage.view.backgroundColor = background
            stage.view.layoutIfNeeded()
            let scale = stage.view.window?.windowScene?.screen.scale ?? UIScreen.main.scale
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: stage.view.bounds, format: format).image { _ in
                stage.view.drawHierarchy(in: stage.view.bounds, afterScreenUpdates: true)
            }
            guard let cgImage = image.cgImage, let pixels = PixelImage(cgImage) else { return nil }
            let x = Int(location.x * scale), y = Int(location.y * scale)
            guard x >= 0, y >= 0, x < pixels.width, y < pixels.height else { return nil }
            let value = pixels[x, y]
            return [Double(value.red) / 255, Double(value.green) / 255, Double(value.blue) / 255]
        }
        guard let white = pixel(.white), let black = pixel(.black) else { return nil }
        let alpha = 1 - ((white[0] - black[0]) + (white[1] - black[1]) + (white[2] - black[2])) / 3
        guard alpha > 0.001 else { return [0, 0, 0, 0] }
        var color = black.map { min(1, $0 / alpha) }
        var opacity = alpha
        if let base, let under = sample?.renderedColors[base], under.count == 4, under[3] < 1 {
            // Remove the layer underneath: combined = top over under.
            let top = (alpha - under[3]) / (1 - under[3])
            guard top > 0.001 else { return [0, 0, 0, 0] }
            for index in 0..<3 {
                let premultiplied = black[index] - (1 - top) * under[3] * under[index]
                color[index] = min(1, max(0, premultiplied / top))
            }
            opacity = top
        }
        return color + [opacity]
    }

    // MARK: Descriptions

    private func recordSymbol(_ image: UIImage, named name: String, into sample: inout ReferenceSample) {
        sample.metrics["\(name)ImageWidth"] = Double(image.size.width)
        sample.metrics["\(name)ImageHeight"] = Double(image.size.height)
        let insets = image.alignmentRectInsets
        sample.metrics["\(name)InsetTop"] = Double(insets.top)
        sample.metrics["\(name)InsetLeft"] = Double(insets.left)
        sample.metrics["\(name)InsetBottom"] = Double(insets.bottom)
        sample.metrics["\(name)InsetRight"] = Double(insets.right)
        sample.defaults["\(name)Symbol"] = "symbol=\(image.isSymbolImage) rendering=\(image.renderingMode.rawValue) baseline=\(image.baselineOffsetFromBottom ?? -1) configuration=\(image.configuration.map { "\($0)" } ?? "nil")"
    }

    /// Finds the symbol configuration that reproduces an image UIKit shows: the point size and
    /// scale at which the named symbol has the image's size, and those at which it has the
    /// size it is shown at. Candidates are generated by UIKit itself, never assumed.
    private func identifySymbol(_ image: UIImage, named name: String, key: String, shownAt shown: CGSize, into sample: inout ReferenceSample) {
        func search(_ target: CGSize) -> [(Double, String)] {
            var matches: [(Double, String)] = []
            for (scale, scaleName) in [(UIImage.SymbolScale.medium, "medium"), (.small, "small"), (.large, "large")] {
                for step in 10...180 {
                    let pointSize = CGFloat(step) / 2
                    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: scale)
                    guard let candidate = UIImage(systemName: name, withConfiguration: configuration) else { continue }
                    if abs(candidate.size.width - target.width) < 0.01, abs(candidate.size.height - target.height) < 0.01 {
                        matches.append((Double(pointSize), scaleName))
                    }
                }
            }
            return matches
        }
        let natural = search(image.size)
        sample.defaults["\(key)SymbolMatches"] = natural.map { "\($0.0)pt/\($0.1)" }.joined(separator: ", ")
        let scaleIndex = ["small": 0.0, "medium": 1.0, "large": 2.0]
        if let best = natural.first(where: { $0.1 == "medium" }) ?? natural.first {
            sample.metrics["\(key)PointSize"] = best.0
            sample.metrics["\(key)ScaleIndex"] = scaleIndex[best.1]
            sample.defaults["\(key)SymbolScale"] = best.1
        } else {
            sample.notes.append("no configuration of \(name) has the size of the \(key) image (\(image.size))")
        }
        if abs(shown.width - image.size.width) > 0.01 || abs(shown.height - image.size.height) > 0.01 {
            let fitted = search(shown)
            sample.defaults["\(key)ShownSymbolMatches"] = fitted.map { "\($0.0)pt/\($0.1)" }.joined(separator: ", ")
            // Among the configurations of that size, the one drawn at the font's point size.
            let fontSize = sample.metrics["fontSize"] ?? 0
            if let best = fitted.first(where: { abs($0.0 - fontSize) < 0.01 }) ?? fitted.first {
                sample.metrics["\(key)ShownPointSize"] = best.0
                sample.metrics["\(key)ShownScaleIndex"] = scaleIndex[best.1]
                sample.defaults["\(key)ShownSymbolScale"] = best.1
            }
        } else {
            sample.metrics["\(key)ShownPointSize"] = sample.metrics["\(key)PointSize"]
            sample.metrics["\(key)ShownScaleIndex"] = sample.metrics["\(key)ScaleIndex"]
        }
    }

    static func describe(_ font: UIFont) -> String {
        let weight = (font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        return "\(font.fontName) \(font.pointSize) weight=\(weight.map { String(format: "%.2f", $0) } ?? "?") lineHeight=\(String(format: "%.2f", font.lineHeight)) ascender=\(String(format: "%.2f", font.ascender)) descender=\(String(format: "%.2f", font.descender))"
    }

    static func name(of mode: UITextField.ViewMode) -> String {
        switch mode {
        case .never: return "never"
        case .whileEditing: return "whileEditing"
        case .unlessEditing: return "unlessEditing"
        case .always: return "always"
        @unknown default: return "unknown(\(mode.rawValue))"
        }
    }
}
