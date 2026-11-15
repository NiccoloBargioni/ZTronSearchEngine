import Foundation

/// The appearance axis of the matrix (specification section 12.5). Every value but `dark` is
/// a variation of the light appearance; `darkIncreasedContrast` is an extra value the host
/// adds because the asset catalog carries that variant too.
public enum ParityAppearance: String, Codable, CaseIterable, Sendable {
    case light
    case dark
    case increasedContrast = "increased-contrast"
    case reduceTransparency = "reduce-transparency"
    case boldText = "bold-text"
    case darkIncreasedContrast = "dark-increased-contrast"

    /// The five values the specification lists.
    public static let specified: [ParityAppearance] = [.light, .dark, .increasedContrast, .reduceTransparency, .boldText]

    public var isDark: Bool { self == .dark || self == .darkIncreasedContrast }
    public var isHighContrast: Bool { self == .increasedContrast || self == .darkIncreasedContrast }
}

/// The content size axis: XS, L (default), XXXL, AX5.
public enum ParityContentSize: String, Codable, CaseIterable, Sendable {
    case xs = "XS"
    case l = "L"
    case xxxl = "XXXL"
    case ax5 = "AX5"

    /// The raw value of the `UIContentSizeCategory` this size stands for.
    public var categoryName: String {
        switch self {
        case .xs: return "UICTContentSizeCategoryXS"
        case .l: return "UICTContentSizeCategoryL"
        case .xxxl: return "UICTContentSizeCategoryXXXL"
        case .ax5: return "UICTContentSizeCategoryAccessibilityXXXL"
        }
    }

    /// The name `xcrun simctl ui <device> content_size` takes.
    public var simctlName: String {
        switch self {
        case .xs: return "extra-small"
        case .l: return "large"
        case .xxxl: return "extra-extra-extra-large"
        case .ax5: return "accessibility-extra-extra-extra-large"
        }
    }
}

/// The layout direction axis: LTR, and RTL with an Arabic locale.
public enum ParityDirection: String, Codable, CaseIterable, Sendable {
    case ltr
    case rtl

    public var language: String { self == .ltr ? "en" : "ar" }
    public var region: String { self == .ltr ? "US" : "SA" }
}

/// One cell of the parity matrix.
public struct ParityCell: Codable, Hashable, Sendable {
    /// The iOS version of the simulator, as `major.minor`.
    public var os: String
    /// The simulator's device type, as the matrix names it ("iPhone 15").
    public var device: String
    public var appearance: ParityAppearance
    public var contentSize: ParityContentSize
    public var direction: ParityDirection
    public var input: ParityInput
    public var script: ParityScript

    public init(
        os: String, device: String, appearance: ParityAppearance, contentSize: ParityContentSize,
        direction: ParityDirection, input: ParityInput, script: ParityScript
    ) {
        self.os = os
        self.device = device
        self.appearance = appearance
        self.contentSize = contentSize
        self.direction = direction
        self.input = input
        self.script = script
    }

    /// Where the cell's result lives under the results directory.
    public var relativePath: String {
        let deviceName = device.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        return "ios-\(os)/\(deviceName)/\(appearance.rawValue)/\(contentSize.rawValue)/\(direction.rawValue)/\(input.rawValue)/\(script.rawValue)"
    }
}

/// What the host app actually runs under: the facts a cell's requested axes are checked
/// against before any comparison is trusted.
public struct HostEnvironment: Codable, Hashable, Sendable {
    public var osVersion: String
    public var modelIdentifier: String
    public var screenWidth: Double
    public var screenHeight: Double
    public var scale: Double
    public var contentSizeCategory: String
    public var isDark: Bool
    public var isHighContrast: Bool
    public var isReduceTransparencyEnabled: Bool
    public var isBoldTextEnabled: Bool
    public var isRightToLeft: Bool
    public var language: String
    public var locale: String

    /// Why the environment is not the one a cell asks for; empty when it is.
    public func mismatches(with cell: ParityCell) -> [String] {
        var problems: [String] = []
        if !osVersion.hasPrefix(cell.os) { problems.append("iOS \(osVersion) is not \(cell.os)") }
        if contentSizeCategory != cell.contentSize.categoryName {
            problems.append("content size is \(contentSizeCategory), not \(cell.contentSize.categoryName)")
        }
        if isDark != cell.appearance.isDark { problems.append("dark appearance is \(isDark)") }
        if isHighContrast != cell.appearance.isHighContrast { problems.append("increased contrast is \(isHighContrast)") }
        if isReduceTransparencyEnabled != (cell.appearance == .reduceTransparency) {
            problems.append("reduce transparency is \(isReduceTransparencyEnabled)")
        }
        if isBoldTextEnabled != (cell.appearance == .boldText) { problems.append("bold text is \(isBoldTextEnabled)") }
        if isRightToLeft != (cell.direction == .rtl) { problems.append("right-to-left layout is \(isRightToLeft)") }
        if !language.hasPrefix(cell.direction.language) { problems.append("language is \(language), not \(cell.direction.language)") }
        return problems
    }
}
