import UIKit

// Where the parts of the UIKit reference are. `UISearchTextField` publishes no frames for its
// glyph, its tokens or its clear button, so they are found in its view hierarchy by what they
// are: an image view, a label next to an image view, a button. Only the handles of a range
// selection have no such shape and are found by the name of their class.

extension ReferenceField {
    /// The search glyph: the image view the text field owns directly.
    var glyphView: UIImageView? {
        textField.subviews.lazy.compactMap { $0 as? UIImageView }.first
    }

    /// The clear button, when it is on screen.
    var clearButton: UIButton? {
        let field = textField
        return ParityStageController.descendants(of: field, ofType: UIButton.self).first { Self.isVisible($0) }
    }

    /// The Cancel button of the search bar, when it is on screen.
    var cancelButton: UIButton? {
        let field = textField
        return ParityStageController.descendants(of: searchBar, ofType: UIButton.self).first {
            !$0.isDescendant(of: field) && Self.isVisible($0)
        }
    }

    private static func isVisible(_ view: UIView) -> Bool {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return false }
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha < 0.01 { return false }
            current = candidate.superview
        }
        return true
    }

    /// The view that draws each token, by token index. A token is a view that holds an image
    /// view and a label with the token's text; tokens the text layout has not materialized
    /// (scrolled out of the field) have none.
    var tokenViews: [Int: UIView] {
        let field = textField
        let labels = ParityStageController.descendants(of: field, ofType: UILabel.self).filter { label in
            guard let parent = label.superview else { return false }
            return parent.subviews.contains { $0 is UIImageView }
        }
        // Visual order, leading to trailing.
        let rightToLeft = field.effectiveUserInterfaceLayoutDirection == .rightToLeft
        var candidates = labels.sorted {
            let a = $0.convert($0.bounds, to: field).minX, b = $1.convert($1.bounds, to: field).minX
            return rightToLeft ? a > b : a < b
        }
        var views: [Int: UIView] = [:]
        for (index, label) in self.labels.enumerated() {
            guard let position = candidates.firstIndex(where: { $0.text == label }) else { continue }
            views[index] = candidates.remove(at: position).superview
        }
        return views
    }

    /// What the reference draws for a range selection, and only for one: the handles the text
    /// field puts at the two ends of a non-empty selection (`_UITextSelectionLollipopView` on
    /// the iOS versions sampled so far), each a stem and a dot, and the corners of the selected
    /// tokens, which the selection highlight behind them squares off.
    ///
    /// The dot casts a soft shadow well past its own frame, so every part of a handle is
    /// returned with the reach of its shadow: two blur radii, plus the shadow's offset. A
    /// token selected without handles (after `replaceTextualPortion`) keeps its round corners
    /// and nothing is returned for it.
    func selectionHandles(in stage: UIView, slot: CGRect) -> [RectValue] {
        let field = textField
        guard field.isFirstResponder, let range = field.selectedTextRange, !range.isEmpty else { return [] }
        var handles: [RectValue] = []
        for view in ParityStageController.descendants(of: field, ofType: UIView.self) {
            let name = String(describing: type(of: view))
            guard name.contains("Lollipop"), Self.isVisible(view) else { continue }
            for part in [view] + view.subviews where part.bounds.width > 0 && part.bounds.height > 0 {
                var reach: CGFloat = 0
                if part.layer.shadowOpacity > 0 {
                    reach = 2 * part.layer.shadowRadius + max(abs(part.layer.shadowOffset.width), abs(part.layer.shadowOffset.height))
                }
                let frame = part.convert(part.bounds, to: stage).insetBy(dx: -reach, dy: -reach)
                handles.append(RectValue(frame.offsetBy(dx: -slot.minX, dy: -slot.minY)))
            }
        }
        guard !handles.isEmpty else { return [] }
        let selected = Set(selectedLabels)
        for (index, view) in tokenViews where index < labels.count && selected.contains(labels[index]) {
            // A continuous corner leaves the straight edge about 1.53 radii from the corner.
            let radius = ([view] + view.subviews).map(\.layer.cornerRadius).max() ?? 0
            let side = (radius * 1.6).rounded(.up)
            guard side > 0 else { continue }
            let frame = view.convert(view.bounds, to: stage).offsetBy(dx: -slot.minX, dy: -slot.minY)
            for x in [frame.minX, frame.maxX - side] {
                for y in [frame.minY, frame.maxY - side] {
                    handles.append(RectValue(CGRect(x: x, y: y, width: side, height: side)))
                }
            }
        }
        return handles
    }

    /// The layout of the reference, in the coordinates of its slot.
    func metrics(in stage: UIView, slot: CGRect) -> LayoutMetrics {
        var metrics = LayoutMetrics()
        func frame(_ view: UIView) -> RectValue {
            RectValue(view.convert(view.bounds, to: stage).offsetBy(dx: -slot.minX, dy: -slot.minY))
        }
        let field = textField
        metrics.frames["field"] = frame(field)
        if let glyph = glyphView { metrics.frames["glyph"] = frame(glyph) }
        for (index, view) in tokenViews { metrics.frames["token.\(index)"] = frame(view) }
        if let clear = clearButton { metrics.frames["clearButton"] = frame(clear) }
        if let cancel = cancelButton { metrics.frames["cancelButton"] = frame(cancel) }
        if let baseline = ParityStageController.firstBaseline(of: field, in: stage) {
            metrics.lengths["baseline"] = Double(baseline - slot.minY)
        }
        return metrics
    }
}
