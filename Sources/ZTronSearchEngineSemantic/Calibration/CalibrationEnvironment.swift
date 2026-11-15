import Foundation

/// Everything the calibration gate reads from the outside world.
///
/// Production uses ``LiveCalibrationEnvironment``; tests inject a scripted one, so the gate's
/// decisions are deterministic.
public protocol CalibrationEnvironment: Sendable {
    /// The wall clock: verdicts are dated with it and memory warnings compared against it.
    func now() async -> Date
    /// A monotonic clock, in nanoseconds, for timing the calibration pass.
    func uptimeNanoseconds() async -> UInt64
    /// Physical memory of the device, in bytes.
    func physicalMemory() async -> UInt64
    /// When the last memory warning was received, if one was.
    func lastMemoryWarning() async -> Date?
    /// Identifies the app version, the app build and the OS version. A verdict is only reused
    /// under the fingerprint it was measured with, so an app or OS update measures again.
    func fingerprint() async -> String
}

/// The real device: system clocks, `ProcessInfo`, the main bundle's version and a
/// ``MemoryWarningMonitor``.
public struct LiveCalibrationEnvironment: CalibrationEnvironment {
    private let memoryWarnings: MemoryWarningMonitor

    /// - Parameter memoryWarnings: The monitor to ask for the last memory warning. A monitor
    ///   only knows the warnings received since it was created, so create the gate when the app
    ///   launches, not when the first query is typed.
    public init(memoryWarnings: MemoryWarningMonitor = MemoryWarningMonitor()) {
        self.memoryWarnings = memoryWarnings
    }

    /// The system's wall clock.
    public func now() async -> Date {
        Date()
    }

    /// The system's monotonic clock.
    public func uptimeNanoseconds() async -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// `ProcessInfo.physicalMemory`.
    public func physicalMemory() async -> UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// The last warning the monitor recorded.
    public func lastMemoryWarning() async -> Date? {
        await memoryWarnings.lastWarning()
    }

    /// The main bundle's version and build, and the OS version string, build number included.
    public func fingerprint() async -> String {
        Self.fingerprint(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    /// The fingerprint of an app version, an app build and an OS version.
    public static func fingerprint(appVersion: String?, appBuild: String?, systemVersion: String) -> String {
        "app \(appVersion ?? "-") (\(appBuild ?? "-")), os \(systemVersion)"
    }
}

/// Remembers when the system last warned about memory.
///
/// The warning is observed by name, `UIApplicationDidReceiveMemoryWarningNotification`, so
/// nothing here imports UIKit. Observation starts when the monitor is created and stops when it
/// is released.
public final class MemoryWarningMonitor: Sendable {
    /// The name UIKit posts memory warnings under.
    public static let notificationName = Notification.Name("UIApplicationDidReceiveMemoryWarningNotification")

    private actor Record {
        private(set) var last: Date?

        func note(_ date: Date) {
            last = date
        }
    }

    private let record = Record()
    private let observation: Task<Void, Never>

    /// - Parameters:
    ///   - center: The notification center to observe.
    ///   - now: The clock warnings are dated with.
    public init(center: NotificationCenter = .default, now: @escaping @Sendable () -> Date = { Date() }) {
        let record = self.record
        // The observer is registered here, synchronously, when the iterator is made: a warning
        // posted right after the monitor is created is not missed.
        let warnings = center.notifications(named: Self.notificationName).makeAsyncIterator()
        observation = Task {
            while await warnings.next() != nil {
                await record.note(now())
            }
        }
    }

    deinit {
        observation.cancel()
    }

    /// When the last memory warning since the monitor was created arrived.
    public func lastWarning() async -> Date? {
        await record.last
    }
}

/// Where the calibration verdict is kept between launches.
public protocol CalibrationVerdictStore: Sendable {
    func verdictData(forKey key: String) async -> Data?
    /// Stores `data` under `key`; `nil` removes what is stored.
    func setVerdictData(_ data: Data?, forKey key: String) async
}

/// Keeps the verdict in `UserDefaults`. The default store.
public struct UserDefaultsVerdictStore: CalibrationVerdictStore {
    private let suiteName: String?

    /// - Parameter suiteName: The defaults suite; `nil` uses the standard defaults.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// The data stored under `key`, if any.
    public func verdictData(forKey key: String) async -> Data? {
        defaults.data(forKey: key)
    }

    /// Stores `data` under `key`; `nil` removes what is stored.
    public func setVerdictData(_ data: Data?, forKey key: String) async {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
