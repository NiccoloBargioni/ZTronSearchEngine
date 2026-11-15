import GameController
import UIKit

/// Entry point of the parity host app: builds the stage and, when the environment names a
/// channel directory, starts answering a driver's commands.
@MainActor
public enum ParityHost {
    /// Environment variable: the directory of the command channel (see ``ParityChannel``).
    public static let channelVariable = "ZTRON_PARITY_CHANNEL"

    private static var session: ParitySession?

    public static func makeRootViewController(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UIViewController {
        let stage = ParityStageController()
        if let path = environment[channelVariable], !path.isEmpty {
            let session = ParitySession(stage: stage, channel: ParityChannel(directory: URL(fileURLWithPath: path)))
            session.start()
            self.session = session
        }
        return stage
    }
}

/// The host's window. It counts the key presses that reach the app, which is how a run proves
/// which input path it exercised: a hardware keyboard delivers `UIPress` events with a key, the
/// on-screen keyboard delivers none.
@MainActor
public final class ParityWindow: UIWindow {
    public private(set) static var keyPressCount = 0

    public static func resetKeyPressCount() {
        keyPressCount = 0
    }

    public override func sendEvent(_ event: UIEvent) {
        if let presses = event as? UIPressesEvent {
            for press in presses.allPresses where press.phase == .began && press.key != nil {
                Self.keyPressCount += 1
            }
        }
        super.sendEvent(event)
    }

    /// Whether the system sees a hardware keyboard.
    static var hardwareKeyboardConnected: Bool { GCKeyboard.coalesced != nil }
}
