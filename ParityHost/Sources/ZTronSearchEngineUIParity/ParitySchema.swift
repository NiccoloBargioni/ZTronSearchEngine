import Foundation
import ZTronSearchEngine
import ZTronSearchEngineUI

// The parity host's own schema. The root package's fixtures are not a product, so the host
// declares the smallest schema that exercises every token kind.

public enum ParityKind: String, SearchItemKind, CaseIterable {
    case map
    case tip
    case tool
}

public enum ParityFilter: SearchFilter {
    case platform(String)

    public var key: String { "platform" }

    public var value: String {
        switch self { case .platform(let value): return value }
    }

    public init?(key: String, value: String) {
        guard key == "platform" else { return nil }
        self = .platform(value)
    }
}

public enum ParitySchema: SearchSchema {
    public typealias Kind = ParityKind
    public typealias Filter = ParityFilter
}

public typealias ParityToken = ZTronSearchToken<ParitySchema>

/// A token as the scripts describe it: what both fields are asked to show.
public struct ParityTokenSpec: Codable, Hashable, Sendable {
    public var label: String
    /// SF Symbol name of the icon; `nil` = a token without an icon.
    public var symbol: String?

    public init(_ label: String, symbol: String? = nil) {
        self.label = label
        self.symbol = symbol
    }

    /// The clone's token. The id is derived from the position so that a script can address it.
    func cloneToken(index: Int) -> ParityToken {
        ParityToken(id: ParityTokenSpec.id(index: index), kind: .phrase(label), text: label, systemImage: symbol)
    }

    static func id(index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index)) ?? UUID()
    }
}
