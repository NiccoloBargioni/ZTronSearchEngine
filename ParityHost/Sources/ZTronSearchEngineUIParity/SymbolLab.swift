import UIKit

/// A diagnostic: finds out how the reference draws a token's icon.
///
/// The reference shows the icon in an image view smaller than the image. Whether it squeezes
/// the picture, or draws the symbol again at a smaller size, decides how the clone must draw
/// it; this lab renders candidates with UIKit itself, next to the real token, and counts the
/// pixels by which each differs from the real icon.
@MainActor
struct SymbolLab {
    let stage: ParityStageController

    /// How the search bar draws the title of its Cancel button, against plain labels.
    func runCancel() async -> [String] {
        var lines: [String] = []
        stage.rebuild(FieldSetup(cancelButton: true))
        await ParitySession.pause(0.3)
        let bar = stage.reference.searchBar
        bar.setShowsCancelButton(true, animated: false)
        _ = stage.reference.textField.becomeFirstResponder()
        await ParitySession.pause(0.6)
        guard let button = stage.reference.cancelButton, let title = button.titleLabel else { return ["no cancel button"] }
        let scale = stage.view.window?.windowScene?.screen.scale ?? 3
        let frame = title.convert(title.bounds, to: stage.view)
        lines.append("title label \(RectValue(frame)) font \(title.font!) alignment \(title.textAlignment.rawValue) lineBreak \(title.lineBreakMode.rawValue) attributed \(title.attributedText?.attributes(at: 0, effectiveRange: nil).keys.map(\.rawValue) ?? [])")
        func pixels(_ rect: CGRect) -> PixelImage? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: stage.view.bounds, format: format).image { _ in
                stage.view.drawHierarchy(in: stage.view.bounds, afterScreenUpdates: true)
            }
            return image.cgImage.flatMap { PixelImage($0) }?.cropped(to: PixelRect(rect, scale: scale))
        }
        guard let real = pixels(frame) else { return ["could not render"] }
        func compare(_ name: String, _ make: () -> UILabel) {
            let label = make()
            label.textColor = title.textColor
            label.frame = CGRect(x: 40, y: 400, width: frame.width, height: frame.height)
            stage.view.addSubview(label)
            defer { label.removeFromSuperview() }
            guard let candidate = pixels(label.frame), candidate.width == real.width, candidate.height == real.height else {
                lines.append("\(name): size mismatch")
                return
            }
            var differing = 0, worst = 0
            for index in stride(from: 0, to: real.bytes.count, by: 4) {
                let delta = max(abs(Int(real.bytes[index]) - Int(candidate.bytes[index])), abs(Int(real.bytes[index + 1]) - Int(candidate.bytes[index + 1])), abs(Int(real.bytes[index + 2]) - Int(candidate.bytes[index + 2])))
                if delta > 0 { differing += 1; worst = max(worst, delta) }
            }
            lines.append("\(name): \(differing) px differ, worst \(worst); natural width \(label.intrinsicContentSize.width)")
        }
        compare("UILabel, the title's own font, natural alignment") {
            let label = UILabel()
            label.text = title.text
            label.font = title.font
            return label
        }
        compare("UILabel, the title's own font, centered") {
            let label = UILabel()
            label.text = title.text
            label.font = title.font
            label.textAlignment = .center
            return label
        }
        compare("UILabel, systemFont(ofSize: 17)") {
            let label = UILabel()
            label.text = title.text
            label.font = .systemFont(ofSize: 17)
            return label
        }
        compare("UILabel, body text style") {
            let label = UILabel()
            label.text = title.text
            label.font = .preferredFont(forTextStyle: .body)
            return label
        }
        compare("UILabel, the title's attributed text") {
            let label = UILabel()
            label.attributedText = title.attributedText
            return label
        }
        compare("UILabel, middle truncation") {
            let label = UILabel()
            label.text = title.text
            label.font = title.font
            label.lineBreakMode = .byTruncatingMiddle
            return label
        }
        return lines
    }

    func run(symbol: String = "map") async -> [String] {
        if symbol == "cancel" { return await runCancel() }
        var lines: [String] = []
        stage.rebuild(FieldSetup(tokens: [ParityTokenSpec("Maps", symbol: symbol)]))
        await ParitySession.pause(0.3)
        guard let token = stage.reference.tokenViews[0],
              let icon = token.subviews.lazy.compactMap({ $0 as? UIImageView }).first,
              let fill = token.subviews.first(where: { $0.backgroundColor != nil })?.backgroundColor else {
            return ["no token icon found"]
        }
        let scale = stage.view.window?.windowScene?.screen.scale ?? 3
        let iconFrame = icon.convert(icon.bounds, to: stage.view)
        lines.append("icon view \(RectValue(iconFrame)) image \(icon.image?.size ?? .zero) contentMode \(icon.contentMode.rawValue) font \(stage.reference.textField.font?.pointSize ?? 0)")
        // A patch of the token's fill, big enough for any candidate, on the pixel grid.
        let patch = UIView(frame: CGRect(x: 40, y: 300, width: 60, height: 60))
        patch.backgroundColor = fill
        stage.view.addSubview(patch)
        defer { patch.removeFromSuperview() }

        func pixels(_ rect: CGRect) -> PixelImage? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: stage.view.bounds, format: format).image { _ in
                stage.view.drawHierarchy(in: stage.view.bounds, afterScreenUpdates: true)
            }
            return image.cgImage.flatMap { PixelImage($0) }?.cropped(to: PixelRect(rect, scale: scale))
        }
        /// The pixels that are not the fill: bounding box and count.
        func ink(_ image: PixelImage) -> String {
            let background = image[0, 0]
            var minX = image.width, minY = image.height, maxX = -1, maxY = -1, count = 0
            for y in 0..<image.height {
                for x in 0..<image.width where image[x, y] != background {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); count += 1
                }
            }
            return "ink x \(minX)...\(maxX) y \(minY)...\(maxY) (\(maxX - minX + 1)x\(maxY - minY + 1) px, \(count) px)"
        }
        // The real icon, with a margin of fill around it.
        let margin: CGFloat = 2
        let window = iconFrame.insetBy(dx: -margin, dy: -margin)
        guard let real = pixels(window) else { return ["could not render"] }
        lines.append("real icon: \(ink(real))")

        var results: [(Int, Int, String)] = []
        for (symbolScale, scaleName) in [(UIImage.SymbolScale.small, "small"), (.medium, "medium")] {
            for step in stride(from: 11.0, through: 17.0, by: 0.0625) {
                let configuration = UIImage.SymbolConfiguration(pointSize: step, weight: .regular, scale: symbolScale)
                guard let image = UIImage(systemName: symbol, withConfiguration: configuration) else { continue }
                // Centred where the real icon is centred within its window, snapped to pixels.
                let view = UIImageView(image: image)
                view.tintColor = icon.tintColor
                let size = image.size
                var origin = CGPoint(x: window.width / 2 - size.width / 2, y: window.height / 2 - size.height / 2)
                origin.x = (origin.x * scale).rounded() / scale
                origin.y = (origin.y * scale).rounded() / scale
                for (dx, dy) in [(0.0, 0.0), (1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                    view.frame = CGRect(origin: CGPoint(x: origin.x + dx / scale, y: origin.y + dy / scale), size: size)
                    patch.subviews.forEach { $0.removeFromSuperview() }
                    patch.addSubview(view)
                    guard let candidate = pixels(CGRect(origin: patch.frame.origin, size: window.size)), candidate.width == real.width, candidate.height == real.height else { continue }
                    var differing = 0, worst = 0
                    for index in stride(from: 0, to: real.bytes.count, by: 4) {
                        let delta = max(abs(Int(real.bytes[index]) - Int(candidate.bytes[index])), abs(Int(real.bytes[index + 1]) - Int(candidate.bytes[index + 1])), abs(Int(real.bytes[index + 2]) - Int(candidate.bytes[index + 2])))
                        if delta > 0 { differing += 1; worst = max(worst, delta) }
                    }
                    results.append((differing, worst, "\(scaleName) \(step) pt size \(size.width)x\(size.height) shift (\(dx),\(dy)) px: \(differing) px differ, worst \(worst); \(ink(candidate))"))
                }
            }
        }
        results.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        lines += results.prefix(12).map(\.2)

        // The same image the token holds, in an image view of the icon's size: what plain
        // squeezing by an image view gives.
        if let image = icon.image {
            for mode in [UIView.ContentMode.scaleToFill, .scaleAspectFit, .center] {
                let view = UIImageView(image: image)
                view.contentMode = mode
                view.tintColor = icon.tintColor
                view.frame = CGRect(origin: CGPoint(x: margin, y: margin), size: iconFrame.size)
                patch.subviews.forEach { $0.removeFromSuperview() }
                patch.addSubview(view)
                if let candidate = pixels(CGRect(origin: patch.frame.origin, size: window.size)), candidate.width == real.width {
                    var differing = 0, worst = 0
                    for index in stride(from: 0, to: real.bytes.count, by: 4) {
                        let delta = max(abs(Int(real.bytes[index]) - Int(candidate.bytes[index])), abs(Int(real.bytes[index + 1]) - Int(candidate.bytes[index + 1])), abs(Int(real.bytes[index + 2]) - Int(candidate.bytes[index + 2])))
                        if delta > 0 { differing += 1; worst = max(worst, delta) }
                    }
                    lines.append("image view, content mode \(mode.rawValue), same frame: \(differing) px differ, worst \(worst); \(ink(candidate))")
                }
            }
        }
        return lines
    }
}
