import UIKit

/// A rectangle that survives a round trip through JSON.
public struct RectValue: Codable, Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ rect: CGRect) {
        x = Double(rect.minX)
        y = Double(rect.minY)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public var description: String {
        String(format: "(%.2f, %.2f, %.2f, %.2f)", x, y, width, height)
    }
}

/// Text dumps of a view hierarchy, for finding out what UIKit and SwiftUI built.
@MainActor
enum ViewDump {
    static func lines(of view: UIView, relativeTo root: UIView? = nil, skipping skipped: [UIView] = []) -> [String] {
        var lines: [String] = []
        append(view, root: root ?? view, depth: 0, skipping: skipped, to: &lines)
        return lines
    }

    private static func append(_ view: UIView, root: UIView, depth: Int, skipping skipped: [UIView] = [], to lines: inout [String]) {
        if skipped.contains(where: { $0 === view }) {
            lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) (listed above)")
            return
        }
        let frame = RectValue(view.convert(view.bounds, to: root))
        var line = String(repeating: "  ", count: depth) + "\(type(of: view)) \(frame)"
        if view.isHidden { line += " hidden" }
        if view.alpha != 1 { line += " alpha=\(view.alpha)" }
        if view.layer.cornerRadius != 0 { line += " corner=\(view.layer.cornerRadius)/\(view.layer.cornerCurve.rawValue)" }
        if let color = view.backgroundColor { line += " bg=\(describe(color, in: view))" }
        if view.layer.shadowOpacity > 0 {
            line += " shadow=\(view.layer.shadowOpacity)/r\(view.layer.shadowRadius)/\(view.layer.shadowOffset.width),\(view.layer.shadowOffset.height)"
        }
        if let mask = view.layer.mask {
            line += " mask=\(type(of: mask)) \(RectValue(mask.frame))"
            if let gradient = mask as? CAGradientLayer {
                let alphas = (gradient.colors ?? []).map { color -> String in
                    let alpha = (color as AnyObject as? UIColor)?.cgColor.alpha ?? CGColor.alpha(of: color)
                    return String(format: "%.2f", alpha)
                }
                line += " gradient \(gradient.startPoint)->\(gradient.endPoint) alphas=\(alphas) locations=\(gradient.locations ?? [])"
            }
        }
        if view.clipsToBounds { line += " clips" }
        if let label = view as? UILabel {
            line += " text=\(ParityEvent.quoted(label.text ?? "")) font=\(label.font.fontName)/\(label.font.pointSize) color=\(describe(label.textColor, in: view))"
        }
        if let image = view as? UIImageView, let picture = image.image {
            line += " image=\(picture.size.width)x\(picture.size.height) tint=\(describe(image.tintColor, in: view))"
            if let configuration = picture.symbolConfiguration { line += " symbol=\(configuration)" }
        }
        if let field = view as? UITextField {
            line += " text=\(ParityEvent.quoted(field.text ?? "")) font=\(field.font?.fontName ?? "nil")/\(field.font?.pointSize ?? 0) firstResponder=\(field.isFirstResponder)"
        }
        if view.layer.borderWidth > 0 { line += " border=\(view.layer.borderWidth)" }
        if type(of: view.layer) != CALayer.self { line += " layer=\(type(of: view.layer))" }
        if view.layer.contents != nil { line += " contents" }
        if let filters = view.layer.filters, !filters.isEmpty { line += " filters=\(filters)" }
        if let filter = view.layer.compositingFilter { line += " compositing=\(filter)" }
        if let field = view as? UITextField {
            line += " borderStyle=\(field.borderStyle.rawValue) background=\(field.background.map { "\($0.size)" } ?? "nil")"
        }
        lines.append(line)
        // Layers that are not the backing layer of a subview draw too.
        for layer in view.layer.sublayers ?? [] where !view.subviews.contains(where: { $0.layer === layer }) {
            append(layer, in: view, root: root, depth: depth + 1, to: &lines)
        }
        for subview in view.subviews { append(subview, root: root, depth: depth + 1, skipping: skipped, to: &lines) }
    }

    private static func append(_ layer: CALayer, in view: UIView, root: UIView, depth: Int, to lines: inout [String]) {
        let frame = RectValue(view.layer.convert(layer.frame, to: root.layer))
        var line = String(repeating: "  ", count: depth) + "~\(type(of: layer)) \(frame)"
        if let owner = layer.delegate { line += " of \(type(of: owner))" }
        if layer.isHidden { line += " hidden" }
        if layer.opacity != 1 { line += " opacity=\(layer.opacity)" }
        if layer.cornerRadius != 0 { line += " corner=\(layer.cornerRadius)/\(layer.cornerCurve.rawValue)" }
        if let color = layer.backgroundColor { line += " bg=\(describe(color))" }
        if layer.borderWidth > 0 { line += " border=\(layer.borderWidth) \(layer.borderColor.map(describe) ?? "nil")" }
        if layer.shadowOpacity > 0 {
            line += " shadow=\(layer.shadowOpacity)/r\(layer.shadowRadius)/\(layer.shadowOffset.width),\(layer.shadowOffset.height)"
        }
        if layer.contents != nil { line += " contents" }
        if layer.masksToBounds { line += " clips" }
        if let filters = layer.filters, !filters.isEmpty { line += " filters=\(filters)" }
        if let filter = layer.compositingFilter { line += " compositing=\(filter)" }
        if let shape = layer as? CAShapeLayer {
            line += " fill=\(shape.fillColor.map(describe) ?? "nil") stroke=\(shape.strokeColor.map(describe) ?? "nil") line=\(shape.lineWidth)"
            if let path = shape.path { line += " path=\(RectValue(path.boundingBoxOfPath))" }
        }
        if let gradient = layer as? CAGradientLayer {
            line += " gradient \(gradient.startPoint)->\(gradient.endPoint) colors=\((gradient.colors ?? []).count) locations=\(gradient.locations ?? [])"
        }
        lines.append(line)
        for sublayer in layer.sublayers ?? [] { append(sublayer, in: view, root: root, depth: depth + 1, to: &lines) }
    }

    static func describe(_ color: CGColor) -> String {
        guard let converted = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let components = converted.components, components.count == 4 else { return "\(color)" }
        return String(format: "rgba(%.4f, %.4f, %.4f, %.4f)", components[0], components[1], components[2], components[3])
    }

    /// A color resolved for the view that shows it, as sRGB components.
    static func describe(_ color: UIColor, in view: UIView) -> String {
        let resolved = color.resolvedColor(with: view.traitCollection)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "\(resolved)" }
        return String(format: "rgba(%.4f, %.4f, %.4f, %.4f)", red, green, blue, alpha)
    }
}

private extension CGColor {
    /// The alpha of something that should be a `CGColor` (the element type of a gradient's colors).
    static func alpha(of value: Any) -> CGFloat {
        let object = value as AnyObject
        guard CFGetTypeID(object) == CGColor.typeID else { return -1 }
        return unsafeDowncast(object, to: CGColor.self).alpha
    }
}
