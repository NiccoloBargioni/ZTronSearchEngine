import SwiftUI
import UIKit

/// Which of the two fields.
public enum FieldSide: String, Codable, Hashable, Sendable, CaseIterable {
    case reference
    case clone
}

/// The screen of the parity host: the UIKit reference above, the SwiftUI clone below, at
/// identical sizes (specification section 12.5).
///
/// The reference is laid out by its search bar across the width of the screen. The clone gets
/// exactly the rectangle the reference field occupies inside that bar, so the two are compared
/// at the size UIKit chose, never at a size the host made up.
@MainActor
public final class ParityStageController: UIViewController {
    public private(set) var reference: ReferenceField
    public private(set) var clone: CloneField
    /// The reference field's frame inside its bar while the Cancel button is hidden.
    public private(set) var restingFieldFrame: CGRect = .zero

    /// Narrows the stage: the sampler uses it to see which lengths follow the field's width.
    public var widthReduction: CGFloat = 0 {
        didSet {
            restingFieldFrame = .zero
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

    private let gap: CGFloat = 24

    public init(setup: FieldSetup = FieldSetup()) {
        reference = ReferenceField(setup: setup)
        clone = CloneField(setup: setup, clearButtonMode: reference.textField.clearButtonMode)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("the parity stage is built in code")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        install()
    }

    /// Replaces both fields with fresh ones in the state `setup` describes.
    public func rebuild(_ setup: FieldSetup) {
        view.endEditing(true)
        reference.searchBar.removeFromSuperview()
        clone.controller.willMove(toParent: nil)
        clone.view.removeFromSuperview()
        clone.controller.removeFromParent()
        reference = ReferenceField(setup: setup)
        clone = CloneField(setup: setup, clearButtonMode: reference.textField.clearButtonMode)
        restingFieldFrame = .zero
        install()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func install() {
        // The identifiers let a UI test find each field's subtree in the accessibility tree.
        reference.searchBar.accessibilityIdentifier = Self.referenceIdentifier
        clone.view.accessibilityIdentifier = Self.cloneIdentifier
        view.addSubview(reference.searchBar)
        addChild(clone.controller)
        view.addSubview(clone.view)
        clone.controller.didMove(toParent: self)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width - widthReduction
        let bar = reference.searchBar
        let barHeight = bar.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        bar.frame = CGRect(x: 0, y: view.safeAreaInsets.top + gap, width: width, height: barHeight)
        bar.layoutIfNeeded()
        if restingFieldFrame == .zero, !bar.showsCancelButton {
            restingFieldFrame = reference.textField.convert(reference.textField.bounds, to: bar)
        }
        // The clone's slot: as wide as the reference field, and tall enough that a clone of
        // the wrong height shows as a difference instead of being clipped to the right one. It
        // sits a whole number of pixels below the reference, so both fields fall on the pixel
        // grid the same way.
        let scale = view.window?.windowScene?.screen.scale ?? UIScreen.main.scale
        let offset = ((barHeight + gap) * scale).rounded(.up) / scale
        clone.view.frame = CGRect(
            x: restingFieldFrame.minX, y: bar.frame.minY + restingFieldFrame.minY + offset,
            width: restingFieldFrame.width, height: restingFieldFrame.height + gap
        )
    }

    /// The rectangle of one field in the stage's coordinates: what a snapshot of it covers.
    public func slot(_ side: FieldSide) -> CGRect {
        switch side {
        case .reference:
            return restingFieldFrame.offsetBy(dx: reference.searchBar.frame.minX, dy: reference.searchBar.frame.minY)
        case .clone:
            return CGRect(origin: clone.view.frame.origin, size: restingFieldFrame.size)
        }
    }
}
