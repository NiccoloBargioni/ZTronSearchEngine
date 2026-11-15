import SwiftUI
import ZTronSearchEngine

/// Everything the field-scoped modifiers configure. It travels through the environment, so the
/// modifiers are no-ops on views that hold no `ZTronSearchField`, like `.submitLabel`.
struct ZTronSearchFieldConfiguration {
    var style: ZTronSearchFieldStyle = .native
    var tokenBackground: Color?
    var clearButtonMode: ZTronClearButtonMode = .whileEditing
    var keyboard: ZTronKeyboard = .default
    var textContent: ZTronTextContent = .none
    var cancelButtonMode: ZTronCancelButtonMode = .automatic
    var tokenDeletion: ZTronTokenDeletionPolicy = .enabled
    var tokenCopying: ZTronTokenCopyingPolicy = .disabled

    var onEditingChanged: [(Bool) -> Void] = []
    var editingPolicy: ((ZTronEditingRequest) -> Bool)?
    var textInputPolicy: ((ZTronTextChange) -> Bool)?
    var onSelectionChanged: [(ZTronSearchSelection) -> Void] = []
    var onClear: (() -> Bool)?
    var onSearchCancel: [() -> Void] = []
    var onEvent: [(ZTronSearchFieldEvent) -> Void] = []
    /// Token-typed closures, erased; keyed by the schema they were declared for.
    var textToToken: [ObjectIdentifier: (String) -> Any?] = [:]
    var onTokenDelete: [ObjectIdentifier: (Any) -> Bool] = [:]
    var tokenCopyProvider: [ObjectIdentifier: (Any) -> String] = [:]
}

private struct ZTronSearchFieldConfigurationKey: EnvironmentKey {
    static var defaultValue: ZTronSearchFieldConfiguration { ZTronSearchFieldConfiguration() }
}

extension EnvironmentValues {
    var zTronSearchField: ZTronSearchFieldConfiguration {
        get { self[ZTronSearchFieldConfigurationKey.self] }
        set { self[ZTronSearchFieldConfigurationKey.self] = newValue }
    }
}

// MARK: - Appearance. Defaults reproduce UIKit (specification section 12.4).

public extension View {
    /// `.native` (default) or `.plain`.
    func searchFieldStyle(_ style: ZTronSearchFieldStyle) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.style = style }
    }

    /// `tokenBackgroundColor`; `nil` = system.
    func tokenBackground(_ color: Color?) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.tokenBackground = color }
    }

    /// `.never`, `.whileEditing` (default), `.unlessEditing`, `.always`.
    func clearButtonMode(_ mode: ZTronClearButtonMode) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.clearButtonMode = mode }
    }

    /// The keyboard, as a package enum: the host never sees a platform type.
    func searchKeyboard(_ keyboard: ZTronKeyboard) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.keyboard = keyboard }
    }

    /// The content type, as a package enum.
    func searchTextContent(_ content: ZTronTextContent) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.textContent = content }
    }

    /// `.automatic` (while editing, as the system search bar) or `.never`.
    func searchCancelButton(_ mode: ZTronCancelButtonMode) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.cancelButtonMode = mode }
    }

    /// `.enabled` (default) or `.disabled`: the counterpart of `allowsDeletingTokens`.
    func tokenDeletion(_ policy: ZTronTokenDeletionPolicy) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.tokenDeletion = policy }
    }

    /// `.disabled` (default) or `.enabled`: the counterpart of `allowsCopyingTokens`.
    func tokenCopying(_ policy: ZTronTokenCopyingPolicy) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.tokenCopying = policy }
    }
}

// MARK: - Events. One modifier per UIKit callback (specification section 12.3).

public extension View {
    /// `textFieldDidBeginEditing` and `textFieldDidEndEditing`.
    func onEditingChanged(_ action: @escaping (Bool) -> Void) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.onEditingChanged.append(action) }
    }

    /// `textFieldShouldBeginEditing` and `textFieldShouldEndEditing`. Evaluated before the inner
    /// input is enabled, so a denial shows no focus flicker.
    func editingPolicy(_ policy: @escaping (ZTronEditingRequest) -> Bool) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.editingPolicy = policy }
    }

    /// `textField(_:shouldChangeCharactersIn:replacementString:)`. A denied change is reverted.
    func textInputPolicy(_ policy: @escaping (ZTronTextChange) -> Bool) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.textInputPolicy = policy }
    }

    /// `textFieldDidChangeSelection`.
    func onSelectionChanged(_ action: @escaping (ZTronSearchSelection) -> Void) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.onSelectionChanged.append(action) }
    }

    /// `textFieldShouldClear` and the clear button. Returning `false` keeps the text.
    func onClear(_ action: @escaping () -> Bool) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.onClear = action }
    }

    /// The Cancel button.
    func onSearchCancel(_ action: @escaping () -> Void) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.onSearchCancel.append(action) }
    }

    /// Converts the typed text into a token: `replaceTextualPortion(of:with:at:)`. Evaluated on
    /// every text change and on submit.
    func textToToken<Schema: SearchSchema>(_ rule: @escaping (String) -> ZTronSearchToken<Schema>?) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.textToToken[ObjectIdentifier(Schema.self)] = { rule($0) } }
    }

    /// A per-token veto on deletion.
    func onTokenDelete<Schema: SearchSchema>(_ action: @escaping (ZTronSearchToken<Schema>) -> Bool) -> some View {
        transformEnvironment(\.zTronSearchField) { configuration in
            configuration.onTokenDelete[ObjectIdentifier(Schema.self)] = { token in
                (token as? ZTronSearchToken<Schema>).map(action) ?? true
            }
        }
    }

    /// `searchTextField(_:itemProviderForCopying:)`: the text a copied token carries.
    func tokenCopyProvider<Schema: SearchSchema>(_ provider: @escaping (ZTronSearchToken<Schema>) -> String) -> some View {
        transformEnvironment(\.zTronSearchField) { configuration in
            configuration.tokenCopyProvider[ObjectIdentifier(Schema.self)] = { token in
                (token as? ZTronSearchToken<Schema>).map(provider) ?? ""
            }
        }
    }

    /// Every event, in order: the parity log.
    func onSearchFieldEvent(_ action: @escaping (ZTronSearchFieldEvent) -> Void) -> some View {
        transformEnvironment(\.zTronSearchField) { $0.onEvent.append(action) }
    }
}
