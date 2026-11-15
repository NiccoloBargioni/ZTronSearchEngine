import SwiftUI
import UIKit
import XCTest
@testable import ZTronSearchEngineUIParity

/// Finds out what the bundle this test runs in can exercise, and writes it down.
///
/// A Swift package's test bundle runs on the simulator without an app around it. The parity
/// measurements need three things such a bundle does not have: a render server (for pixel
/// snapshots), the accessibility runtime (for the accessibility tree), and a keyboard that
/// delivers keys to the first responder the way a user's keys arrive. This test measures each
/// of them, so the reason the matrix runs in the host app is a recorded fact per iOS version,
/// not folklore. With `ZTRON_PARITY_RESULTS` set it writes
/// `host-capabilities-ios-<version>.json` there.
@MainActor
final class HostCapabilityTests: XCTestCase {
    private struct Capabilities: Codable {
        var osVersion: String
        var process: String
        var hasApplication: Bool
        /// `drawHierarchy(in:afterScreenUpdates:)` produced the window's pixels.
        var rendersSnapshots: Bool
        var becomesFirstResponder: Bool
        /// Text inserted through `UIKeyInput` raised the field's `editingChanged` control event.
        var deliversEditingEvents: Bool
        /// The text field asked its delegate about the inserted text.
        var consultsTheDelegate: Bool
        /// The text reached the binding of a SwiftUI `TextField`.
        var reachesSwiftUIBindings: Bool
        /// UIKit's accessibility is loaded: the search field describes itself.
        var hasAccessibilityRuntime: Bool
        var canRunTheMatrix: Bool
    }

    private final class Delegate: NSObject, UITextFieldDelegate {
        var asked = false
        var edits = 0

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            asked = true
            return true
        }

        @objc func editingChanged() { edits += 1 }
    }

    private final class Model: ObservableObject {
        @Published var text = ""
    }

    private struct Screen: View {
        @ObservedObject var model: Model
        var body: some View { TextField("", text: $model.text) }
    }

    func testWhatThisBundleCanExercise() async throws {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let hasApplication = UIApplication.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() != nil

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        let controller = UIViewController()
        controller.view.backgroundColor = .white
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let field = UISearchTextField(frame: CGRect(x: 10, y: 10, width: 300, height: 36))
        let delegate = Delegate()
        field.delegate = delegate
        field.addTarget(delegate, action: #selector(Delegate.editingChanged), for: .editingChanged)
        field.text = "parity"
        controller.view.addSubview(field)
        window.layoutIfNeeded()

        // A snapshot that shows the field has pixels that are not the white background.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        var rendersSnapshots = false
        if let cgImage = image.cgImage, let pixels = PixelImage(cgImage) {
            rendersSnapshots = pixels.bytes.enumerated().contains { $0.offset % 4 != 3 && $0.element < 250 }
        }

        let becomesFirstResponder = field.becomeFirstResponder() && field.isFirstResponder
        field.insertText("x")
        try? await Task.sleep(nanoseconds: 200_000_000)
        let hasAccessibilityRuntime = field.isAccessibilityElement && field.accessibilityTraits.contains(.searchField)
        field.resignFirstResponder()

        let model = Model()
        let host = UIHostingController(rootView: Screen(model: model))
        host.view.frame = CGRect(x: 10, y: 60, width: 300, height: 40)
        controller.addChild(host)
        controller.view.addSubview(host.view)
        window.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let inner = ParityStageController.descendants(of: host.view, ofType: UITextField.self).first {
            _ = inner.becomeFirstResponder()
            inner.insertText("y")
            try? await Task.sleep(nanoseconds: 300_000_000)
            inner.resignFirstResponder()
        }

        let capabilities = Capabilities(
            osVersion: "\(version.majorVersion).\(version.minorVersion)",
            process: ProcessInfo.processInfo.processName,
            hasApplication: hasApplication,
            rendersSnapshots: rendersSnapshots,
            becomesFirstResponder: becomesFirstResponder,
            deliversEditingEvents: delegate.edits > 0,
            consultsTheDelegate: delegate.asked,
            reachesSwiftUIBindings: model.text == "y",
            hasAccessibilityRuntime: hasAccessibilityRuntime,
            canRunTheMatrix: rendersSnapshots && delegate.asked && hasAccessibilityRuntime
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(capabilities)
        print(String(decoding: data, as: UTF8.self))
        if let results = ProcessInfo.processInfo.environment["ZTRON_PARITY_RESULTS"] {
            let directory = URL(fileURLWithPath: results)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("host-capabilities-ios-\(capabilities.osVersion).json"))
        }
        window.isHidden = true

        // Whatever the bundle can do, it must say so consistently: a bundle that cannot render
        // or cannot hear keys the way a user sends them cannot run the matrix.
        XCTAssertEqual(capabilities.canRunTheMatrix, rendersSnapshots && delegate.asked && hasAccessibilityRuntime)
        if !hasApplication {
            XCTAssertFalse(capabilities.canRunTheMatrix, "a bundle without an application was found able to run the matrix: move the matrix here")
        }
    }
}
