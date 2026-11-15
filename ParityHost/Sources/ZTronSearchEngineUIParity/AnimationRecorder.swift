import UIKit

/// Records a view frame by frame, to time an animation the same way on both fields.
///
/// Every display refresh it reads what the render server is showing (the presentation layers)
/// and notes whether anything visible changed since the refresh before: the place, the size,
/// the opacity or the fill of any layer that is on screen and draws something. That sees an
/// animation Core Animation runs on its own as well as one a framework drives by updating
/// layers each frame, and it costs nothing to render.
///
/// Layers that draw nothing are not part of the picture: a text field shows and hides empty
/// containers as its selection changes, which moves no pixel. The caret blinks on its own
/// schedule, so slivers are left out too.
@MainActor
final class AnimationRecorder: NSObject {
    private struct Mark: Equatable {
        var owner: String
        var values: [Double]
    }

    private let view: UIView
    private var link: CADisplayLink?
    private var previous: [Mark]?
    private var timestamps: [Double] = []
    private var changed: [Bool] = []
    private var changeLog: [String] = []
    private var framePeriod: Double?
    private var deadline: CFTimeInterval = 0

    init(view: UIView) {
        self.view = view
    }

    var isRecording: Bool { link != nil }

    func start(seconds: Double) {
        stop()
        previous = nil
        timestamps = []
        changed = []
        changeLog = []
        deadline = CACurrentMediaTime() + seconds
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// The recording so far.
    var recording: AnimationRecording {
        var recording = AnimationRecording(timestamps: timestamps, changed: changed, framePeriod: framePeriod)
        recording.changeLog = changeLog
        return recording
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard now < deadline else {
            stop()
            return
        }
        var marks: [Mark] = []
        append(view.layer, x: 0, y: 0, scaleX: 1, scaleY: 1, opacity: 1, to: &marks)
        // The time the frame is shown at, on the display's own clock: a whole number of
        // frames apart, where the time this callback happens to run at jitters.
        timestamps.append(link.targetTimestamp)
        if link.duration > 0 { framePeriod = link.duration }
        let differs = previous.map { $0 != marks } ?? false
        changed.append(differs)
        if differs, let previous, changeLog.count < 12 {
            changeLog.append(Self.describe(from: previous, to: marks, at: link.targetTimestamp - (timestamps.first ?? 0)))
        }
        previous = marks
    }

    /// Adds a layer and what is under it. `x`, `y` and the scales place the layer's own
    /// coordinate space in the recorded view; `opacity` is that of everything above it.
    private func append(_ layer: CALayer, x: Double, y: Double, scaleX: Double, scaleY: Double, opacity: Double, to marks: inout [Mark]) {
        let shown = layer.presentation() ?? layer
        guard !shown.isHidden else { return }
        let alpha = opacity * Double(shown.opacity)
        guard alpha > 0.001 else { return }
        let ownScaleX = scaleX * Double(shown.transform.m11), ownScaleY = scaleY * Double(shown.transform.m22)
        let width = Double(shown.bounds.width) * ownScaleX, height = Double(shown.bounds.height) * ownScaleY
        let left = x + (Double(shown.position.x) + Double(shown.transform.m41)) * scaleX - Double(shown.anchorPoint.x) * width
        let top = y + (Double(shown.position.y) + Double(shown.transform.m42)) * scaleY - Double(shown.anchorPoint.y) * height
        // The caret and its parts: tall slivers.
        let isSliver = shown.bounds.width <= 4 && shown.bounds.height > shown.bounds.width
        if !isSliver, width > 0, height > 0, let fill = Self.fill(of: shown) {
            func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
            let owner = layer.delegate.map { "\(type(of: $0))" } ?? "\(type(of: layer))"
            marks.append(Mark(owner: owner, values: [left, top, width, height, alpha].map(rounded) + fill.map(rounded)))
        }
        guard !isSliver else { return }
        let innerX = left - Double(shown.bounds.origin.x) * ownScaleX, innerY = top - Double(shown.bounds.origin.y) * ownScaleY
        for sublayer in layer.sublayers ?? [] {
            append(sublayer, x: innerX, y: innerY, scaleX: ownScaleX, scaleY: ownScaleY, opacity: alpha, to: &marks)
        }
    }

    /// What a layer fills its bounds with, as numbers; `nil` when the layer draws nothing.
    private static func fill(of layer: CALayer) -> [Double]? {
        var fill: [Double] = []
        var draws = layer.contents != nil || layer.borderWidth > 0
        func add(_ color: CGColor?) {
            guard let color, color.alpha > 0, let components = color.components else { return }
            draws = true
            fill += components.map(Double.init)
        }
        add(layer.backgroundColor)
        if let shape = layer as? CAShapeLayer, shape.path != nil {
            add(shape.fillColor)
            add(shape.strokeColor)
        }
        if layer is CAGradientLayer || layer is CATextLayer { draws = true }
        return draws ? fill : nil
    }

    private static func describe(from old: [Mark], to new: [Mark], at time: Double) -> String {
        var parts: [String] = []
        if old.count != new.count { parts.append("\(old.count) -> \(new.count) drawing layers") }
        var listed = 0
        for index in 0..<min(old.count, new.count) where old[index] != new[index] && listed < 3 {
            parts.append("\(new[index].owner) \(old[index].values) -> \(new[index].values)")
            listed += 1
        }
        if listed == 0, new.count > old.count, let added = new.last { parts.append("last: \(added.owner) \(added.values)") }
        return String(format: "+%.0f ms: ", time * 1000) + parts.joined(separator: "; ")
    }
}
