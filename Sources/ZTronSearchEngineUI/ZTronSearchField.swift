import SwiftUI
import ZTronSearchEngine

/// A pure SwiftUI search field with native search tokens (specification section 12).
///
/// It is built from `TextField`, `FocusState` and an asset catalog, all available on iOS 15,
/// and never from a platform view. Layout is search glyph, tokens, text input, clear button, in
/// that order: tokens always precede text, so the textual range is the trailing input and the
/// `text` binding never contains a token.
///
/// Every length the layout uses comes from ``ZTronSearchFieldMetrics``, sampled from the UIKit
/// field per iOS version and per content size; nothing here is a constant of its own.
///
/// Focus, submit and keyboard use SwiftUI's own modifiers: `.focused($isFocused)` on the field
/// reaches its inner input, `.onSubmit` fires on the search key, and `.submitLabel(.search)` is
/// applied by default. The field never debounces and never talks to a results model.
public struct ZTronSearchField<Schema: SearchSchema>: View {
    @Binding private var text: String
    @Binding private var tokens: [ZTronSearchToken<Schema>]
    private let prompt: Text?
    private let externalSelection: Binding<Set<UUID>>?

    @State private var core = ZTronSearchFieldCore<Schema>()
    /// What the inner input holds: the text behind a sentinel, or behind two (see `setBuffer`).
    @State private var buffer = ZTronSearchFieldCore<Schema>.sentinel
    /// The text the inner input was last given.
    @State private var inputRecord = ZTronSearchInputRecord()
    @State private var ownSelection: Set<UUID> = []
    @State private var allowsInput = true
    /// The begin-editing request was already put to the policy and logged, by a tap.
    @State private var beginRequested = false
    /// The search key was pressed and focus is to stay, where the reference keeps it.
    @State private var restoresFocus = false
    /// A token was tapped while the field was not editing: it is selected once editing began.
    @State private var tappedWhileIdle: UUID?
    /// Width of the Cancel button's title, as laid out.
    @State private var cancelTitleWidth: CGFloat = 0
    /// The selection of the inner input, where the system reports it (iOS 18 and later).
    @State private var inputSelection: Any?
    /// Counts the times the inner input reported its selection.
    @State private var inputSelectionReports = 0
    @FocusState private var isFocused: Bool

    @Environment(\.zTronSearchField) private var configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection

    /// The coordinate space of the text area: where a token is, relative to the edges that cut it.
    private let textArea = "ztron.search.textArea"

    /// - Parameters:
    ///   - text: the textual portion only, never a token.
    ///   - tokens: the tokens, in order.
    ///   - prompt: localized by the host; `nil` = "Search".
    ///   - tokenSelection: `nil` = the field owns selection.
    public init(
        text: Binding<String>,
        tokens: Binding<[ZTronSearchToken<Schema>]>,
        prompt: Text? = nil,
        tokenSelection: Binding<Set<UUID>>? = nil
    ) {
        _text = text
        _tokens = tokens
        self.prompt = prompt
        externalSelection = tokenSelection
    }

    private var metrics: ZTronSearchFieldMetrics {
        .metrics(forMajorVersion: ZTronSearchFieldMetrics.runningMajorVersion, contentSize: .init(dynamicTypeSize))
    }

    public var body: some View {
        let metrics = metrics
        HStack(alignment: .top, spacing: 0) {
            field(metrics)
            if showsCancelButton {
                cancelButton(metrics)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(height: metrics.fieldHeight)
        .animation(.easeInOut(duration: metrics.cancelAnimationDuration), value: showsCancelButton)
        .onAppear(perform: synchronize)
        .onChange(of: text) { _ in synchronize() }
        .onChange(of: tokens) { _ in synchronize() }
        .onChange(of: externalSelection?.wrappedValue) { _ in synchronize() }
        // What the inner input holds is passed up as a preference, and a change the user made
        // to it is acted on from there: SwiftUI applies what a preference's action changes in
        // the frame it is in, where it applies what an `onChange` action changes a frame later.
        .preference(key: ZTronSearchInputKey.self, value: buffer)
        .onPreferenceChange(ZTronSearchInputKey.self) { raw in
            guard let held = inputRecord.held else { return }
            inputRecord.held = nil
            inputChanged(from: held, to: raw)
        }
        .onChange(of: inputSelectionReports) { _ in inputSelectionMoved() }
        .onChange(of: isFocused) { focusChanged(to: $0) }
    }

    // MARK: Layout

    private var selection: Set<UUID> {
        externalSelection?.wrappedValue ?? ownSelection
    }

    private var isNative: Bool { configuration.style == .native }

    private var hasContent: Bool { !text.isEmpty || !tokens.isEmpty }

    private var showsCancelButton: Bool {
        configuration.cancelButtonMode == .automatic && core.isEditing
    }

    private var showsClearButton: Bool {
        guard hasContent else { return false }
        switch configuration.clearButtonMode {
        case .never: return false
        case .whileEditing: return core.isEditing
        case .unlessEditing: return !core.isEditing
        case .always: return true
        }
    }

    private var showsGlyph: Bool {
        metrics.showsGlyphWithContent || !hasContent
    }

    /// The rounded box: background, text area, glyph, tokens and clear button, each placed from
    /// the field's own edges so that the layout mirrors under a right-to-left direction.
    ///
    /// The row of tokens and text is laid out twice, once to show the input and once to show
    /// the tokens, so that the views come in the order the reference lists its accessibility
    /// elements in: the field, the glyph, the tokens, the clear button.
    private func field(_ metrics: ZTronSearchFieldMetrics) -> some View {
        background(metrics)
            .frame(height: metrics.fieldHeight)
            .zTronPart(.field)
            .overlay(alignment: .topLeading) { content(metrics, showing: .input) }
            .overlay(alignment: .topLeading) {
                if showsGlyph { glyph(metrics) }
            }
            .overlay(alignment: .topLeading) { content(metrics, showing: .tokens) }
            .overlay(alignment: .topTrailing) {
                if showsClearButton { clearButton(metrics) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: tappedOutsideTokens)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func background(_ metrics: ZTronSearchFieldMetrics) -> some View {
        if isNative {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .fill(ZTronSearchColor.searchFieldFill.color)
        } else {
            Color.clear
        }
    }

    private func glyph(_ metrics: ZTronSearchFieldMetrics) -> some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: metrics.fontSize))
            .imageScale(metrics.glyphScale.imageScale)
            .foregroundColor(.secondary)
            .frame(width: metrics.glyphWidth, height: metrics.glyphHeight)
            .zTronPart(.glyph)
            .padding(.leading, isNative ? metrics.glyphLeading : 0)
            .padding(.top, metrics.glyphTop)
            .accessibilityIdentifier("magnifyingglass")
    }

    private func clearButton(_ metrics: ZTronSearchFieldMetrics) -> some View {
        Button {
            perform { $0.clear(policies: policies) }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: metrics.fontSize))
                .imageScale(metrics.clearButtonScale.imageScale)
                .foregroundColor(ZTronSearchColor.clearGlyph.color)
                .frame(width: metrics.clearButtonWidth, height: metrics.clearButtonHeight)
        }
        .buttonStyle(.plain)
        .zTronPart(.clearButton)
        .padding(.trailing, isNative ? metrics.clearButtonTrailing : 0)
        .padding(.top, metrics.clearButtonTop)
        .accessibilityLabel(Text(ZTronSearchFieldStrings.clearText))
        // From iOS 18 a button made of a symbol is identified by the symbol's name; the
        // reference's clear button has no identifier.
        .accessibilityIdentifier("")
    }

    /// The Cancel button. The reference's is a system button whose title sits in a label of
    /// its own: as wide as the title rounded up to whole points, and placed where the bar
    /// puts it, which is not the middle of the button.
    private func cancelButton(_ metrics: ZTronSearchFieldMetrics) -> some View {
        Button {
            perform { $0.cancel(policies: policies) }
        } label: {
            Text(ZTronSearchStrings.cancel)
                .font(.system(size: metrics.cancelFontSize))
                .lineLimit(1)
                .fixedSize()
                .background(GeometryReader { title in
                    Color.clear.preference(key: ZTronCancelTitleWidthKey.self, value: title.size.width)
                })
                .frame(width: cancelTitleWidth > 0 ? cancelTitleWidth.rounded(.up) : nil, alignment: .leading)
                .frame(height: metrics.cancelTitleHeight)
                .padding(.top, metrics.cancelTitleTop - metrics.cancelButtonTop)
                .frame(height: metrics.cancelButtonHeight, alignment: .top)
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
        .onPreferenceChange(ZTronCancelTitleWidthKey.self) { cancelTitleWidth = $0 }
        .zTronPart(.cancelButton)
        .padding(.leading, metrics.cancelButtonSpacing)
        .padding(.top, metrics.cancelButtonTop)
    }

    /// Which part of the row a copy of it shows; the other part only takes its place.
    private enum RowPart {
        case input
        case tokens
    }

    /// The text area: tokens, then the text input, in one row. While the field is editing, a
    /// row wider than the area shows its end, where the caret is. While it is not, the row
    /// shows from its left end, as the reference's does: its start under a left-to-right
    /// layout, its end under a right-to-left one. A token cut by an edge of the area fades
    /// out toward it.
    private func content(_ metrics: ZTronSearchFieldMetrics, showing part: RowPart) -> some View {
        let leading = hasContent ? metrics.contentLeading : metrics.textLeading
        let trailing = showsClearButton ? metrics.textTrailingWithClearButton : metrics.textTrailing
        return GeometryReader { area in
            row(metrics, showing: part, areaWidth: area.size.width)
                .frame(minWidth: area.size.width, alignment: .topLeading)
                .fixedSize(horizontal: true, vertical: false)
                .frame(
                    width: area.size.width, height: area.size.height,
                    alignment: core.isEditing || layoutDirection == .rightToLeft ? .topTrailing : .topLeading
                )
                .clipped()
        }
        .coordinateSpace(name: textArea)
        .padding(.leading, isNative ? leading : leading - metrics.glyphLeading)
        .padding(.trailing, isNative ? trailing : trailing - metrics.clearButtonTrailing)
        .frame(height: metrics.fieldHeight)
    }

    private func row(_ metrics: ZTronSearchFieldMetrics, showing part: RowPart, areaWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(tokens.enumerated()), id: \.element.id) { index, token in
                Group {
                    if part == .tokens {
                        tokenChip(token, metrics, areaWidth: areaWidth)
                    } else {
                        tokenShape(token, metrics, areaWidth: areaWidth, isSelected: false).hidden()
                    }
                }
                .padding(.leading, index == 0 ? metrics.tokenLeadingInset : metrics.tokenSpacing)
                .padding(.top, metrics.tokenTop)
            }
            input(metrics, isLive: part == .input)
        }
    }

    /// The text input. A SwiftUI `TextField` takes whatever width it is offered, so a hidden
    /// copy of what it shows gives it the least width it needs: the text, or the placeholder
    /// while there is none. Under a left-to-right layout it takes what is left of the text
    /// area beyond that, as the reference's editor does, so that a touch past the end of the
    /// text places the caret there. Under a right-to-left layout it does not: a touch on that
    /// side of an input that holds only the sentinel would put the caret in front of the
    /// sentinel, where a backspace finds nothing to delete; there the touch falls on the
    /// field, which gives the input focus with its caret at the end. Its vertical place is the
    /// sampled baseline, not a guess at the input's own height.
    ///
    /// The input always holds the sentinel, so its own placeholder never shows: the visible
    /// placeholder is text drawn over it, on the same baseline. The input still carries the
    /// prompt, which is what assistive technologies read as its placeholder.
    private func input(_ metrics: ZTronSearchFieldMetrics, isLive: Bool) -> some View {
        let showsPlaceholder = !hasContent
        let room: CGFloat = text.isEmpty ? (tokens.isEmpty ? 0 : metrics.caretRoomAfterToken) : metrics.caretRoomAfterText
        let spacing: CGFloat = tokens.isEmpty || text.isEmpty ? 0 : metrics.tokenTextSpacing
        let place = (showsPlaceholder ? promptText : Text(verbatim: text))
            .font(.system(size: metrics.fontSize))
            .lineLimit(1)
            .fixedSize()
            .hidden()
            .padding(.trailing, room)
            .frame(maxWidth: layoutDirection == .leftToRight ? .infinity : nil, alignment: .topLeading)
            .frame(height: metrics.fieldHeight, alignment: .top)
        return Group {
            if isLive {
                place
                    .overlay(alignment: .topLeading) {
                        textField(metrics)
                            .alignmentGuide(.top) { $0[.firstTextBaseline] - metrics.baseline }
                    }
                    .overlay(alignment: .topLeading) {
                        placeholder(metrics)
                            .opacity(showsPlaceholder ? 1 : 0)
                            .alignmentGuide(.top) { $0[.firstTextBaseline] - metrics.baseline }
                    }
                    .overlay(editingGate)
            } else {
                place
            }
        }
        .padding(.leading, spacing)
    }

    /// The visible placeholder. It is a picture of the prompt, not an accessibility element:
    /// the input itself reports the prompt as its placeholder.
    private func placeholder(_ metrics: ZTronSearchFieldMetrics) -> some View {
        promptText
            .font(.system(size: metrics.fontSize))
            .foregroundColor(ZTronSearchColor.placeholderText.color)
            .lineLimit(1)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityRepresentation { EmptyView() }
    }

    private var promptText: Text {
        prompt ?? Text(ZTronSearchStrings.search)
    }

    private func textField(_ metrics: ZTronSearchFieldMetrics) -> some View {
        Group {
            if #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
                TextField("", text: inputBinding, selection: inputSelectionBinding, prompt: promptText)
            } else {
                TextField("", text: inputBinding, prompt: promptText)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: metrics.fontSize))
        .foregroundColor(.primary)
        // A selected token is the selection: the reference shows no caret then.
        .tint(selection.isEmpty ? nil : Color.clear)
        .focused($isFocused)
        .submitLabel(.search)
        .disableAutocorrection(true)
        .zTronKeyboard(configuration.keyboard, content: configuration.textContent)
        .disabled(!allowsInput || !isEnabled)
        .onSubmit(submitted)
        .zTronDeleteKey { deleteKeyPressed() }
        // A touch on the input places its caret and, as any touch outside the tokens,
        // deselects a selected token.
        .simultaneousGesture(TapGesture().onEnded(tappedInput))
        .accessibilityAddTraits(.isSearchField)
        .accessibilityLabel(promptText)
        .accessibilityValue(Text(verbatim: accessibilityValue))
    }

    /// What the inner input edits. A change the user makes is noted here and acted on as the
    /// view updates (see `body`), in the same frame: what the field makes of it (a token for
    /// the typed text, the sentinel put back) is on screen with the keystroke, as in the
    /// reference. It cannot be acted on right here: SwiftUI does not give its input a new text
    /// in the update that follows a change the input reported itself.
    private var inputBinding: Binding<String> {
        Binding(
            get: {
                inputRecord.given = buffer
                return buffer
            },
            set: { raw in
                guard raw != buffer else { return }
                // What the input held before the first change not yet acted on.
                if inputRecord.held == nil { inputRecord.held = buffer }
                buffer = raw
            }
        )
    }

    /// The shortest change that counts as an animation: six frames of the 60 Hz display the
    /// durations were sampled on. Anything shorter is drawing in steps, which nobody sees as
    /// motion and which varies by a frame or two from one run to the next.
    private static var shortestAnimation: Double { 0.1 }

    private static var sentinelScalar: Unicode.Scalar { ZTronSearchFieldCore<Schema>.sentinelScalar }

    /// How many sentinels a string of the inner input begins with.
    private static func leadingSentinels(in raw: String) -> Int {
        raw.unicodeScalars.prefix { $0 == sentinelScalar }.count
    }

    /// The inner input went from holding `held` to holding `raw`.
    private func inputChanged(from held: String, to raw: String) {
        // Behind two sentinels, a backspace at the start of the text takes one of them and
        // leaves the text as it was: the same key as the one that takes the only sentinel.
        let lostSentinel = raw.unicodeScalars.filter { $0 == Self.sentinelScalar }.count
            < held.unicodeScalars.filter { $0 == Self.sentinelScalar }.count
        if lostSentinel, ZTronSearchFieldCore<Schema>.strip(raw) == core.text {
            perform { $0.deleteBackwardAtStart(policies: policies) }
        } else {
            perform { $0.inputChanged(to: raw, policies: policies) }
        }
    }

    /// The inner input's selection. The input reports its selection before it reports the
    /// change of text that moved it, so a report is only noted here and looked at once the
    /// text is in.
    @available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    private var inputSelectionBinding: Binding<TextSelection?> {
        Binding(
            get: { inputSelection as? TextSelection },
            set: { selection in
                inputSelection = selection
                inputSelectionReports &+= 1
            }
        )
    }

    /// The inner input's selection moved. A change of the text reports the caret itself, in
    /// the reference's order; what is reported from here is a selection that moved on its own.
    private func inputSelectionMoved() {
        guard #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        guard ZTronSearchFieldCore<Schema>.strip(buffer) == core.text, let selection = inputSelection as? TextSelection,
              case .selection(let range) = selection.indices,
              let units = Self.utf16Offsets(of: range, in: buffer) else { return }
        let sentinels = Self.leadingSentinels(in: buffer)
        let text = max(units.lowerBound - sentinels, 0)..<max(units.upperBound - sentinels, 0)
        guard text != core.textSelection else { return }
        perform { $0.textSelectionChanged(to: text, policies: policies) }
    }

    /// The UTF-16 offsets of a range the inner input reported, in `string`: what the input
    /// holds, as far as the field knows.
    ///
    /// The range's indices belong to the input's own copy of its text. Using an index on a
    /// string it does not lie within stops the program, so whether it lies within `string` is
    /// decided first, and without using it: comparing two indices only compares positions,
    /// and an index no further on than the end of a string of as many ASCII characters as
    /// `string` has UTF-16 units lies within `string`, whichever encoding it counts in.
    private static func utf16Offsets(of range: Range<String.Index>, in string: String) -> Range<Int>? {
        let units = string.utf16
        let limit = String(repeating: " ", count: units.count).endIndex
        guard range.upperBound <= limit else { return nil }
        return units.distance(from: units.startIndex, to: range.lowerBound)..<units.distance(from: units.startIndex, to: range.upperBound)
    }

    /// Puts the core's text in the inner input, behind the sentinel, unless the input holds
    /// just that already.
    ///
    /// SwiftUI gives its input a new text when the text the input is bound to is not the one
    /// it was bound to before, and otherwise leaves the input alone. That is not enough here:
    /// when a backspace takes the sentinel and the field puts it back, the bound text is what
    /// it was, and the input would be left without a sentinel. So when the text to give is the
    /// text last given, it is given behind two sentinels instead of one, which is a different
    /// string and looks the same; every sentinel is stripped from what the input reports.
    ///
    /// Where the input's selection is a binding too (iOS 18 and later) the selection is set
    /// with the text, to where the core has the caret, so that the selection the input is
    /// given is always one of the text it is given.
    private func setBuffer(from next: ZTronSearchFieldCore<Schema>) {
        if Self.leadingSentinels(in: buffer) > 0, ZTronSearchFieldCore<Schema>.strip(buffer) == next.text { return }
        var given = next.buffer
        if given == inputRecord.given { given = ZTronSearchFieldCore<Schema>.sentinel + given }
        buffer = given
        guard #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else { return }
        guard next.isEditing else {
            inputSelection = nil
            return
        }
        let units = given.utf16
        let sentinels = Self.leadingSentinels(in: given)
        let lower = units.index(units.startIndex, offsetBy: min(sentinels + next.textSelection.lowerBound, units.count))
        let upper = units.index(units.startIndex, offsetBy: min(sentinels + next.textSelection.upperBound, units.count))
        inputSelection = lower == upper ? TextSelection(insertionPoint: lower) : TextSelection(range: lower..<upper)
    }

    /// What the reference tells assistive technologies the field holds: the labels of the
    /// tokens, then the field's content, in which every token is an object replacement
    /// character, then the text. Copied from the reference's accessibility tree.
    private var accessibilityValue: String {
        guard !tokens.isEmpty else { return text }
        return tokens.map(\.text).joined(separator: ", ") + ", "
            + String(repeating: "\u{FFFC}", count: tokens.count) + text
    }

    /// When the host supplies an editing policy the inner input starts disabled; this gate asks
    /// the policy first and only then enables and focuses it, so a denial shows no focus flicker.
    @ViewBuilder private var editingGate: some View {
        if configuration.editingPolicy != nil && !core.isEditing {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: requestFocus)
        }
    }

    /// A token as it is drawn: icon, label and rounded background.
    private func tokenShape(_ token: ZTronSearchToken<Schema>, _ metrics: ZTronSearchFieldMetrics, areaWidth: CGFloat, isSelected: Bool) -> some View {
        let fill = isSelected
            ? ZTronSearchColor.tokenSelectedFill.color
            : (configuration.tokenBackground ?? ZTronSearchColor.tokenFill.color)
        return HStack(alignment: .firstTextBaseline, spacing: metrics.tokenIconSpacing) {
            if let systemImage = token.systemImage {
                tokenIcon(systemImage, metrics)
            }
            Text(token.text)
                .font(.system(size: metrics.tokenFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundColor((isSelected ? ZTronSearchColor.tokenSelectedText : ZTronSearchColor.tokenText).color)
        .padding(.horizontal, metrics.tokenHorizontalPadding)
        .frame(height: metrics.tokenHeight)
        .frame(maxWidth: max(0, metrics.tokenWidthLimitShare * areaWidth + metrics.tokenWidthLimitExtra))
        .background(RoundedRectangle(cornerRadius: metrics.tokenCornerRadius, style: .continuous).fill(fill))
        .fixedSize(horizontal: true, vertical: false)
    }

    /// A token's icon: the symbol at the small scale, at the label's point size. That is what
    /// the reference shows, pixel for pixel, although the image it holds is the regular one.
    ///
    /// It is drawn as text. An `Image` of a one-layer symbol in a plain color is drawn as a
    /// vector shape, whose edges are antialiased a shade differently from the rasterized
    /// symbol the reference shows; inside `Text` the symbol is rasterized the same way.
    private func tokenIcon(_ name: String, _ metrics: ZTronSearchFieldMetrics) -> some View {
        Text(Image(systemName: name))
            .font(.system(size: metrics.tokenFontSize))
            .imageScale(.small)
    }

    /// A token on screen: drawn, faded where an edge of the text area cuts it, tappable, and
    /// one accessibility element with the token's label, as in the reference's tree.
    private func tokenChip(_ token: ZTronSearchToken<Schema>, _ metrics: ZTronSearchFieldMetrics, areaWidth: CGFloat) -> some View {
        let isSelected = selection.contains(token.id)
        return tokenShape(token, metrics, areaWidth: areaWidth, isSelected: isSelected)
            .zTronPart(.token(token.id))
            .mask(edgeFade(metrics, areaWidth: areaWidth))
            .accessibilityRepresentation { EmptyView() }
            .overlay(
                // The reference selects a token from a touch on its leading half; a touch on
                // the trailing half does nothing at all.
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { tappedToken(token.id) }
                    Color.clear.contentShape(Rectangle()).onTapGesture {}
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(token.text))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            )
    }

    /// The opacity of a token across its width: full, except toward an edge of the text area
    /// that cuts it, where it falls to nothing at the edge.
    private func edgeFade(_ metrics: ZTronSearchFieldMetrics, areaWidth: CGFloat) -> some View {
        GeometryReader { token in
            let frame = token.frame(in: .named(textArea))
            let length = metrics.overflowFadeLength
            if frame.width > 0, frame.minX < 0, frame.maxX > 0 {
                // Cut by the left edge: clear up to the edge, opaque one fade length past it.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: -frame.minX / frame.width),
                        .init(color: .black, location: (length - frame.minX) / frame.width),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .environment(\.layoutDirection, .leftToRight)
            } else if frame.width > 0, frame.minX < areaWidth, frame.maxX > areaWidth {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: (areaWidth - length - frame.minX) / frame.width),
                        .init(color: .clear, location: (areaWidth - frame.minX) / frame.width),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .environment(\.layoutDirection, .leftToRight)
            } else {
                Color.black
            }
        }
    }

    // MARK: Behavior

    private var behavior: ZTronSearchFieldBehavior {
        ZTronSearchFieldBehavior.behavior(forMajorVersion: ZTronSearchFieldMetrics.runningMajorVersion) ?? .newestSampled
    }

    private var policies: ZTronSearchFieldCore<Schema>.Policies {
        let schema = ObjectIdentifier(Schema.self)
        var policies = ZTronSearchFieldCore<Schema>.Policies()
        policies.deletion = configuration.tokenDeletion
        policies.textInputPolicy = configuration.textInputPolicy
        policies.editingPolicy = configuration.editingPolicy
        policies.onClear = configuration.onClear
        if let rule = configuration.textToToken[schema] {
            policies.textToToken = { rule($0) as? ZTronSearchToken<Schema> }
        }
        if let veto = configuration.onTokenDelete[schema] {
            policies.onTokenDelete = { veto($0) }
        }
        policies.behavior = behavior
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
            policies.reportsTextSelection = true
        }
        return policies
    }

    /// Runs one input through the core and applies what it did to the bindings.
    private func perform(_ action: (inout ZTronSearchFieldCore<Schema>) -> ZTronSearchFieldCore<Schema>.Outcome) {
        var next = core
        next.adopt(text: text, tokens: tokens, selection: selection)
        let outcome = action(&next)
        apply(next, outcome)
    }

    private func apply(_ next: ZTronSearchFieldCore<Schema>, _ outcome: ZTronSearchFieldCore<Schema>.Outcome) {
        let update = {
            core = next
            if tokens != next.tokens { tokens = next.tokens }
            if text != next.text { text = next.text }
        }
        let duration = metrics.tokenInsertionDuration
        if outcome.insertedToken, duration >= Self.shortestAnimation {
            // The typed text becomes a token with the system's insertion animation, where the
            // reference animates it. A reference that is done within a few frames animates
            // nothing: it draws the token in steps (its background, its label, its selection),
            // where SwiftUI draws it at once.
            withAnimation(.easeOut(duration: duration), update)
        } else {
            update()
        }
        setBuffer(from: next)
        if selection != next.selection {
            if let externalSelection { externalSelection.wrappedValue = next.selection } else { ownSelection = next.selection }
        }
        for event in outcome.events {
            for observer in configuration.onEvent { observer(event) }
        }
        if outcome.selectionChanged {
            let selection = next.hostSelection(policies: policies)
            for observer in configuration.onSelectionChanged { observer(selection) }
        }
        if outcome.resignsFocus { isFocused = false }
        if outcome.takesFocus { requestFocus() }
        if outcome.cancelled {
            for action in configuration.onSearchCancel { action() }
        }
    }

    /// The bindings changed from outside the field.
    private func synchronize() {
        var next = core
        next.adopt(text: text, tokens: tokens, selection: selection)
        core = next
        setBuffer(from: next)
        allowsInput = configuration.editingPolicy == nil || core.isEditing
    }

    private func deleteKeyPressed() -> Bool {
        guard !selection.isEmpty else { return false }
        perform { $0.deleteSelection(policies: policies) }
        return true
    }

    private func submitted() {
        // SwiftUI's input gives up focus on the search key; the reference keeps it where the
        // parity host recorded that it does, so focus is put back without a word in the log.
        restoresFocus = behavior.submitKeepsEditing && core.isEditing
        perform { $0.submit(policies: policies) }
    }

    private func tappedToken(_ id: UUID) {
        guard !core.isEditing else {
            perform { $0.tapToken(id, policies: policies) }
            return
        }
        // The reference begins editing first and selects the token then.
        tappedWhileIdle = id
        requestFocus()
        if !beginRequested { tappedWhileIdle = nil }
    }

    private func tappedOutsideTokens() {
        tappedInput()
        requestFocus()
    }

    private func tappedInput() {
        guard !selection.isEmpty else { return }
        perform { $0.deselect(policies: policies) }
        // The touch may have moved the input's caret away from the end of the text.
        inputSelectionMoved()
    }

    private func requestFocus() {
        guard !core.isEditing, !beginRequested else { return }
        let request = core.mayBeginEditing(policies: policies)
        for observer in configuration.onEvent { observer(request.event) }
        guard request.allowed else { return }
        beginRequested = true
        allowsInput = true
        isFocused = true
    }

    private func focusChanged(to focused: Bool) {
        if !focused, restoresFocus {
            // The search key took focus away; it comes straight back.
            isFocused = true
            return
        }
        if focused, restoresFocus {
            restoresFocus = false
            return
        }
        var next = core
        next.adopt(text: text, tokens: tokens, selection: selection)
        if focused && !core.isEditing && !beginRequested {
            // Focus arrived on its own (the host's `.focused`, a tap on the input itself).
            let request = next.mayBeginEditing(policies: policies)
            for observer in configuration.onEvent { observer(request.event) }
        }
        beginRequested = false
        let result = next.focusChanged(to: focused, policies: policies)
        apply(next, result.outcome)
        if result.keepsFocus {
            // The policy refused to end editing.
            isFocused = true
            return
        }
        if result.outcome.events.contains(.didBeginEditing) || result.outcome.events.contains(.didEndEditing) {
            for observer in configuration.onEditingChanged { observer(focused) }
        }
        if !focused { allowsInput = configuration.editingPolicy == nil }
        if let id = tappedWhileIdle {
            tappedWhileIdle = nil
            if focused { perform { $0.tapToken(id, policies: policies) } }
        }
        // The input may have placed its caret before the field knew it was editing.
        if focused { inputSelectionMoved() }
    }
}

/// Notes about the field's inner input. A record, not state: taking a note must not
/// invalidate the view.
@MainActor
final class ZTronSearchInputRecord {
    /// The text the input was last given, noted as SwiftUI reads the binding.
    var given: String?
    /// The text the input held before the user changed it, until the change is acted on.
    var held: String?
}

/// What the inner input holds, as a preference (see `ZTronSearchField.body`).
private struct ZTronSearchInputKey: PreferenceKey {
    static var defaultValue: String { "" }

    static func reduce(value: inout String, nextValue: () -> String) {
        value = nextValue()
    }
}

/// The laid-out width of the Cancel button's title.
private struct ZTronCancelTitleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Strings of the field that are not part of the package's public string table.
enum ZTronSearchFieldStrings {
    /// The accessibility label of the clear button: the reference calls it "Clear text".
    static var clearText: String {
        Bundle.module.localizedString(forKey: "Clear text", value: "Clear text", table: nil)
    }
}

// MARK: - Layout anchors

/// The parts of the field whose frames the parity host compares with the UIKit reference's
/// (specification section 15.7: field height, glyph, token and clear-button frames).
enum ZTronSearchFieldPart: Hashable, Sendable {
    /// The rounded background: the field itself, without the Cancel button.
    case field
    case glyph
    case token(UUID)
    case clearButton
    case cancelButton
}

/// The bounds of the field's parts, as anchors. Nothing in the product reads this key: it
/// exists so that the parity host can measure the layout without knowing how it is built.
struct ZTronSearchFieldPartsKey: PreferenceKey {
    static var defaultValue: [ZTronSearchFieldPart: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [ZTronSearchFieldPart: Anchor<CGRect>], nextValue: () -> [ZTronSearchFieldPart: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    /// Publishes the view's bounds under a part's name, next to what its subviews published.
    func zTronPart(_ part: ZTronSearchFieldPart) -> some View {
        transformAnchorPreference(key: ZTronSearchFieldPartsKey.self, value: .bounds) { $0[part] = $1 }
    }
}

// MARK: - Platform shims

private extension View {
    /// Keyboard, content type and capitalization exist on iOS only. Autocapitalization is always
    /// off so identifiers survive typing.
    @ViewBuilder
    func zTronKeyboard(_ keyboard: ZTronKeyboard, content: ZTronTextContent) -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .keyboardType({
                switch keyboard {
                case .default: return .default
                case .asciiCapable: return .asciiCapable
                case .numbersAndPunctuation: return .numbersAndPunctuation
                case .url: return .URL
                case .numberPad: return .numberPad
                case .phonePad: return .phonePad
                case .namePhonePad: return .namePhonePad
                case .emailAddress: return .emailAddress
                case .decimalPad: return .decimalPad
                case .twitter: return .twitter
                case .webSearch: return .webSearch
                case .asciiCapableNumberPad: return .asciiCapableNumberPad
                }
            }())
            .textContentType({
                switch content {
                case .none: return nil
                case .name: return .name
                case .emailAddress: return .emailAddress
                case .url: return .URL
                case .location: return .location
                case .organizationName: return .organizationName
                }
            }())
        #else
        self
        #endif
    }

    /// On iOS 17 and later a hardware keyboard reports the delete key directly.
    @ViewBuilder
    func zTronDeleteKey(_ action: @escaping () -> Bool) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            onKeyPress(.delete) { action() ? .handled : .ignored }
        } else {
            self
        }
    }
}
