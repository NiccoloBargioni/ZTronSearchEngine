import Foundation
import ZTronSearchEngine

/// A search token: the SwiftUI counterpart of `UISearchToken` (specification section 12.2).
///
/// Tokens always precede the text of a field. Their display label is localized by the host and
/// wraps a canonical value; tokens never take part in fuzzy expansion or prefix matching.
public struct ZTronSearchToken<Schema: SearchSchema>: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Hard constraint; a case of the host's filter enum.
        case filter(Schema.Filter)
        /// Restricts results to one class of item.
        case kind(Schema.Kind)
        /// Exact phrase, no fuzzy or prefix.
        case phrase(String)
    }

    public let id: UUID
    public let kind: Kind
    /// Localized display label.
    public let text: String
    /// SF Symbol name for the token icon.
    public let systemImage: String?

    public init(id: UUID = UUID(), kind: Kind, text: String, systemImage: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.systemImage = systemImage
    }

    /// The engine-side token this chip stands for.
    public var queryToken: SearchQueryToken<Schema> {
        switch kind {
        case .filter(let filter): return .filter(filter)
        case .kind(let kind): return .kind(kind)
        case .phrase(let phrase): return .phrase(phrase)
        }
    }
}

extension SearchQuery {
    /// Token-to-query mapping, a pure function (section 12.2, rule 10): `.filter` joins
    /// `filters`, `.kind` joins `kinds`, `.phrase` becomes a required exact phrase.
    @_disfavoredOverload
    public init(text: String, tokens: [ZTronSearchToken<Schema>]) {
        self.init(text: text, tokens: tokens.map(\.queryToken))
    }
}
