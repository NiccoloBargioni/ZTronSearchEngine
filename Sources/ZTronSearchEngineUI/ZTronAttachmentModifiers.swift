import SwiftUI
import ZTronSearchEngine

// Attachment modifiers (specification section 13.1).
//
// The modifier wires, the model owns, the host lays out. A modifier never creates state: state
// created inside a modifier lives and dies with the modified view's identity and is silently
// recreated on structural changes. Each modifier is thin: binding forwarding, environment
// injection and appear/disappear lifecycle. No layout, no presentation, no logic worth testing
// on its own; the models remain the unit under test.

private struct IsZTronSearchingKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// `true` while a search is in flight. A derived, read-only projection of
    /// `ZTronSearchResultsModel.isLoading`; the model remains the source of truth.
    var isZTronSearching: Bool {
        get { self[IsZTronSearchingKey.self] }
        set { self[IsZTronSearchingKey.self] = newValue }
    }
}

private struct ZTronSearchAttachment<Schema: SearchSchema>: ViewModifier {
    @ObservedObject var results: ZTronSearchResultsModel<Schema>
    @Binding var text: String
    @Binding var tokens: [ZTronSearchToken<Schema>]

    func body(content: Content) -> some View {
        content
            .onChange(of: text) { results.update(text: $0, tokens: tokens) }
            .onChange(of: tokens) { results.update(text: text, tokens: $0) }
            .onAppear { results.update(text: text, tokens: tokens) }
            .environmentObject(results)
            .environment(\.isZTronSearching, results.isLoading)
    }
}

private struct ZTronResultsAttachment<Schema: SearchSchema>: ViewModifier {
    @ObservedObject var results: ZTronSearchResultsModel<Schema>

    func body(content: Content) -> some View {
        content
            .environmentObject(results)
            .environment(\.isZTronSearching, results.isLoading)
    }
}

private struct ZTronSuggestionsAttachment<Schema: SearchSchema>: ViewModifier {
    let suggestions: ZTronSuggestionsModel<Schema>
    @Binding var text: String

    func body(content: Content) -> some View {
        content
            .onChange(of: text) { suggestions.update(prefix: $0) }
            .onAppear { suggestions.update(prefix: text) }
            .environmentObject(suggestions)
    }
}

private struct ZTronChatAttachment<Schema: SearchSchema>: ViewModifier {
    let chat: ZTronChatModel<Schema>
    let policy: DownloadPolicy?

    func body(content: Content) -> some View {
        content
            .onAppear { if let policy { chat.prepare(policy: policy) } }
            .onDisappear { chat.cancel() }
            .environmentObject(chat)
    }
}

public extension View {
    /// Drives `results` from any text input, `ZTronSearchField` or the host's own, and injects
    /// it for descendants. Forwards every text and token change, and sets `isZTronSearching`.
    func zTronSearch<Schema: SearchSchema>(
        _ results: ZTronSearchResultsModel<Schema>,
        text: Binding<String>,
        tokens: Binding<[ZTronSearchToken<Schema>]>
    ) -> some View {
        modifier(ZTronSearchAttachment(results: results, text: text, tokens: tokens))
    }

    /// Injection only, when the host forwards updates itself.
    func zTronResults<Schema: SearchSchema>(_ results: ZTronSearchResultsModel<Schema>) -> some View {
        modifier(ZTronResultsAttachment(results: results))
    }

    /// On the row or footer that marks the end of the host's list: loads the next page when it
    /// appears. The model's cursor and generation guards make an early or repeated trigger harmless.
    func zTronLoadsNextPage<Schema: SearchSchema>(of results: ZTronSearchResultsModel<Schema>) -> some View {
        onAppear { results.loadNextPage() }
    }

    /// Drives `suggestions` from `text` and injects it; presenting them stays with the host.
    func zTronSuggestions<Schema: SearchSchema>(
        _ suggestions: ZTronSuggestionsModel<Schema>,
        for text: Binding<String>
    ) -> some View {
        modifier(ZTronSuggestionsAttachment(suggestions: suggestions, text: text))
    }

    /// Injects `chat` for descendants; prepares it on appear under `policy` (`nil` = the host
    /// calls prepare); cancels generation on disappear.
    func zTronChat<Schema: SearchSchema>(_ chat: ZTronChatModel<Schema>, prepare policy: DownloadPolicy? = nil) -> some View {
        modifier(ZTronChatAttachment(chat: chat, policy: policy))
    }
}
