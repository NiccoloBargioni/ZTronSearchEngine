import SwiftUI

/// Insets, sizes and spacing of the search field: the single source the layout reads
/// (specification section 12.4).
///
/// The values are sampled from the UIKit reference by the parity host
/// (`ParityHost/Tools/sample.sh`), per iOS major version and per content size, not typed from
/// memory; `ZTronSearchFieldMetrics+Sampled.swift` is generated from those samples. Every
/// length is in points, measured from the field's own edges: "leading" and "top" are distances
/// from the field's leading and top edge, "trailing" from its trailing edge.
///
/// UIKit does not scale the field by one factor under Dynamic Type, so there is no base size
/// to multiply: each content size has its own set of metrics.
public struct ZTronSearchFieldMetrics: Sendable, Hashable {
    /// The scale of an SF Symbol, as UIKit picks it for the field's glyph and clear button.
    public enum SymbolScale: Sendable, Hashable {
        case small
        case medium
        case large

        var imageScale: Image.Scale {
            switch self {
            case .small: return .small
            case .medium: return .medium
            case .large: return .large
            }
        }
    }

    /// The content sizes of Dynamic Type, by the names SwiftUI gives them.
    public enum ContentSize: String, Sendable, Hashable, CaseIterable {
        case xSmall
        case small
        case medium
        case large
        case xLarge
        case xxLarge
        case xxxLarge
        case accessibility1
        case accessibility2
        case accessibility3
        case accessibility4
        case accessibility5

        public init(_ size: DynamicTypeSize) {
            switch size {
            case .xSmall: self = .xSmall
            case .small: self = .small
            case .medium: self = .medium
            case .large: self = .large
            case .xLarge: self = .xLarge
            case .xxLarge: self = .xxLarge
            case .xxxLarge: self = .xxxLarge
            case .accessibility1: self = .accessibility1
            case .accessibility2: self = .accessibility2
            case .accessibility3: self = .accessibility3
            case .accessibility4: self = .accessibility4
            case .accessibility5: self = .accessibility5
            @unknown default: self = .large
            }
        }
    }

    // MARK: The field

    /// Height of the field.
    public var fieldHeight: CGFloat
    public var cornerRadius: CGFloat

    // MARK: The search glyph

    /// The box of the search glyph: its leading and top edges, its width and height.
    public var glyphLeading: CGFloat
    public var glyphTop: CGFloat
    public var glyphWidth: CGFloat
    public var glyphHeight: CGFloat
    /// The glyph is drawn at the font's point size, at this scale.
    public var glyphScale: SymbolScale
    /// Whether the glyph stays while the field holds tokens or text. At the largest content
    /// sizes UIKit hides it and gives its room to the content.
    public var showsGlyphWithContent: Bool

    // MARK: Text

    /// Where the placeholder starts.
    public var textLeading: CGFloat
    /// Where tokens and text start.
    public var contentLeading: CGFloat
    /// Where the text area ends, without and with the clear button.
    public var textTrailing: CGFloat
    public var textTrailingWithClearButton: CGFloat
    /// The first baseline of the text.
    public var baseline: CGFloat
    /// Point size of the text and of the placeholder: the body style at this content size.
    public var fontSize: CGFloat

    // MARK: The clear button

    public var clearButtonWidth: CGFloat
    public var clearButtonHeight: CGFloat
    public var clearButtonTop: CGFloat
    public var clearButtonTrailing: CGFloat
    /// The clear symbol is drawn at the font's point size, at this scale.
    public var clearButtonScale: SymbolScale

    // MARK: Tokens

    public var tokenHeight: CGFloat
    public var tokenTop: CGFloat
    public var tokenCornerRadius: CGFloat
    /// Inset between a token's edge and its content, on each side.
    public var tokenHorizontalPadding: CGFloat
    /// Between a token's icon and its label.
    public var tokenIconSpacing: CGFloat
    /// Top of the label inside the token.
    public var tokenLabelTop: CGFloat
    /// Point size of a token's label.
    public var tokenFontSize: CGFloat
    /// Between two tokens.
    public var tokenSpacing: CGFloat
    /// From where the content starts to the first token.
    public var tokenLeadingInset: CGFloat
    /// From the last token to the text that follows it.
    public var tokenTextSpacing: CGFloat
    /// Widest a token gets before its label truncates with a tail ellipsis: this share of the
    /// text area's width, plus this many points.
    public var tokenWidthLimitShare: CGFloat
    public var tokenWidthLimitExtra: CGFloat
    /// While editing, content wider than the text area scrolls until its end, plus this much
    /// room for the caret, meets the end of the area: after a token, and after text.
    public var caretRoomAfterToken: CGFloat
    public var caretRoomAfterText: CGFloat
    /// A token cut by the edge of the text area fades out over this length.
    public var overflowFadeLength: CGFloat

    // MARK: The Cancel button

    /// Between the field and the Cancel button.
    public var cancelButtonSpacing: CGFloat
    /// Top of the Cancel button, from the field's top; it can be negative.
    public var cancelButtonTop: CGFloat
    public var cancelButtonHeight: CGFloat
    /// Top and height of the label that holds the Cancel button's title, from the field's top.
    public var cancelTitleTop: CGFloat
    public var cancelTitleHeight: CGFloat
    /// Point size of the Cancel button's title. UIKit does not scale it with Dynamic Type.
    public var cancelFontSize: CGFloat

    // MARK: Animations

    /// Duration of the text-to-token insertion animation, in seconds; 0 when UIKit does not
    /// animate it.
    public var tokenInsertionDuration: Double
    /// Duration of the Cancel button's appearance and disappearance, in seconds.
    public var cancelAnimationDuration: Double

    public init(
        fieldHeight: CGFloat, cornerRadius: CGFloat,
        glyphLeading: CGFloat, glyphTop: CGFloat, glyphWidth: CGFloat, glyphHeight: CGFloat,
        glyphScale: SymbolScale, showsGlyphWithContent: Bool,
        textLeading: CGFloat, contentLeading: CGFloat, textTrailing: CGFloat, textTrailingWithClearButton: CGFloat,
        baseline: CGFloat, fontSize: CGFloat,
        clearButtonWidth: CGFloat, clearButtonHeight: CGFloat, clearButtonTop: CGFloat, clearButtonTrailing: CGFloat,
        clearButtonScale: SymbolScale,
        tokenHeight: CGFloat, tokenTop: CGFloat, tokenCornerRadius: CGFloat, tokenHorizontalPadding: CGFloat,
        tokenIconSpacing: CGFloat, tokenLabelTop: CGFloat, tokenFontSize: CGFloat, tokenSpacing: CGFloat,
        tokenLeadingInset: CGFloat, tokenTextSpacing: CGFloat, tokenWidthLimitShare: CGFloat, tokenWidthLimitExtra: CGFloat,
        caretRoomAfterToken: CGFloat, caretRoomAfterText: CGFloat, overflowFadeLength: CGFloat,
        cancelButtonSpacing: CGFloat, cancelButtonTop: CGFloat, cancelButtonHeight: CGFloat,
        cancelTitleTop: CGFloat, cancelTitleHeight: CGFloat, cancelFontSize: CGFloat,
        tokenInsertionDuration: Double, cancelAnimationDuration: Double
    ) {
        self.fieldHeight = fieldHeight
        self.cornerRadius = cornerRadius
        self.glyphLeading = glyphLeading
        self.glyphTop = glyphTop
        self.glyphWidth = glyphWidth
        self.glyphHeight = glyphHeight
        self.glyphScale = glyphScale
        self.showsGlyphWithContent = showsGlyphWithContent
        self.textLeading = textLeading
        self.contentLeading = contentLeading
        self.textTrailing = textTrailing
        self.textTrailingWithClearButton = textTrailingWithClearButton
        self.baseline = baseline
        self.fontSize = fontSize
        self.clearButtonWidth = clearButtonWidth
        self.clearButtonHeight = clearButtonHeight
        self.clearButtonTop = clearButtonTop
        self.clearButtonTrailing = clearButtonTrailing
        self.clearButtonScale = clearButtonScale
        self.tokenHeight = tokenHeight
        self.tokenTop = tokenTop
        self.tokenCornerRadius = tokenCornerRadius
        self.tokenHorizontalPadding = tokenHorizontalPadding
        self.tokenIconSpacing = tokenIconSpacing
        self.tokenLabelTop = tokenLabelTop
        self.tokenFontSize = tokenFontSize
        self.tokenSpacing = tokenSpacing
        self.tokenLeadingInset = tokenLeadingInset
        self.tokenTextSpacing = tokenTextSpacing
        self.tokenWidthLimitShare = tokenWidthLimitShare
        self.tokenWidthLimitExtra = tokenWidthLimitExtra
        self.caretRoomAfterToken = caretRoomAfterToken
        self.caretRoomAfterText = caretRoomAfterText
        self.overflowFadeLength = overflowFadeLength
        self.cancelButtonSpacing = cancelButtonSpacing
        self.cancelButtonTop = cancelButtonTop
        self.cancelButtonHeight = cancelButtonHeight
        self.cancelTitleTop = cancelTitleTop
        self.cancelTitleHeight = cancelTitleHeight
        self.cancelFontSize = cancelFontSize
        self.tokenInsertionDuration = tokenInsertionDuration
        self.cancelAnimationDuration = cancelAnimationDuration
    }

    /// The major version of the OS the process runs on.
    static var runningMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// The sampled version nearest to an OS major version; the newer one on a tie.
    static func nearestSampledVersion(to version: Int) -> Int? {
        sampledVersions.min { first, second in
            let a = abs(first - version), b = abs(second - version)
            return a == b ? first > second : a < b
        }
    }

    /// The metrics for the OS the process runs on, at the default content size.
    public static var current: ZTronSearchFieldMetrics {
        metrics(forMajorVersion: runningMajorVersion, contentSize: .large)
    }

    /// The metrics sampled for an iOS major version and a content size; those of the nearest
    /// sampled version when that one was never sampled.
    public static func metrics(forMajorVersion version: Int, contentSize: ContentSize) -> ZTronSearchFieldMetrics {
        guard let nearest = nearestSampledVersion(to: version), let table = sampled(forMajorVersion: nearest) else { return fallback }
        return table[contentSize] ?? table[.large] ?? fallback
    }
}

/// What the UIKit reference does where the specification says "recorded, never assumed"
/// (section 12.2, rule 5). The parity host records it per iOS major version; the field follows
/// the record of the version it runs on.
public struct ZTronSearchFieldBehavior: Sendable, Hashable {
    /// The clear button removes the tokens along with the text.
    public var clearRemovesTokens: Bool
    /// The clear button, tapped while the field is not editing, gives it focus.
    public var clearBeginsEditing: Bool
    /// Typing while a token is selected replaces the token.
    public var typingReplacesSelectedTokens: Bool
    /// The search key leaves the field editing.
    public var submitKeepsEditing: Bool
    /// A token made from the typed text comes out selected.
    public var conversionSelectsToken: Bool

    public init(
        clearRemovesTokens: Bool, clearBeginsEditing: Bool, typingReplacesSelectedTokens: Bool, submitKeepsEditing: Bool,
        conversionSelectsToken: Bool
    ) {
        self.clearRemovesTokens = clearRemovesTokens
        self.clearBeginsEditing = clearBeginsEditing
        self.typingReplacesSelectedTokens = typingReplacesSelectedTokens
        self.submitKeepsEditing = submitKeepsEditing
        self.conversionSelectsToken = conversionSelectsToken
    }

    /// The behavior recorded for an iOS major version; that of the nearest sampled version when
    /// that one was never sampled.
    public static func behavior(forMajorVersion version: Int) -> ZTronSearchFieldBehavior? {
        ZTronSearchFieldMetrics.nearestSampledVersion(to: version).flatMap { sampled[$0] }
    }
}

/// The named colors of the asset catalog (specification section 12.4).
///
/// SwiftUI has no semantic fill colors on iOS 15, so the package ships an asset catalog whose
/// colors carry light, dark and increased-contrast variants copied from the UIKit values.
public enum ZTronSearchColor: String, CaseIterable, Sendable {
    /// UIKit's tertiary system fill: the field's background.
    case searchFieldFill
    case tokenFill
    /// The label and icon of a token that is not selected.
    case tokenText
    case tokenSelectedFill
    case tokenSelectedText
    case placeholderText
    case clearGlyph

    public var color: Color {
        Color(rawValue, bundle: .module)
    }
}
