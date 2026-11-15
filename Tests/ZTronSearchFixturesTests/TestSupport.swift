import Foundation
import XCTest
import ZTronSearchEngine
@testable import ZTronSearchFixtures

/// Helpers shared by the fixture tests.
enum TestSupport {
    /// Everything observable about an item, as one string: two items with the same fingerprint
    /// are the same item for every purpose of the fixtures.
    static func fingerprint(_ item: AnySearchable<CatalogKind>) -> String {
        var parts = [item.searchID.rawValue, item.searchKind.rawValue]
        parts.append(contentsOf: GoldenQuery.surfaces(of: item.base))
        parts.append(GoldenQuery.filters(of: item.base).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","))
        if let temporal = item.base as? any TemporalSearchable {
            parts.append("\(temporal.createdAt.timeIntervalSince1970)/\(temporal.updatedAt.timeIntervalSince1970)")
        }
        if let localized = item.base as? any LocalizedSearchable {
            parts.append((localized.searchLanguage ?? "-") + ":" + localized.searchLocalizations.keys.sorted().joined(separator: ","))
        }
        return parts.joined(separator: "\u{1F}")
    }

    static func fingerprint(_ query: GoldenQuery) -> String {
        let tokens = query.tokens.map { token -> String in
            switch token {
            case .kind(let kind): return "kind:\(kind.rawValue)"
            case .filter(let filter): return "filter:\(filter.key)=\(filter.value)"
            case .phrase(let phrase): return "phrase:\(phrase)"
            }
        }
        let judgments = query.judgments.map { "\($0.key.rawValue)=\($0.value)" }.sorted()
        let allowed = query.allowedIDs.map { $0.map(\.rawValue).sorted().joined(separator: ",") } ?? "-"
        return [
            query.id, query.queryClass.rawValue, query.text, tokens.joined(separator: ","), query.locale, query.language,
            judgments.joined(separator: ","), query.kind.rawValue, query.sourceID.rawValue, query.variant, allowed,
        ].joined(separator: "\u{1F}")
    }

    /// A stable checksum of a list of strings: FNV-1a, the same in every process.
    static func checksum(_ strings: [String]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for string in strings {
            for byte in string.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
            hash = (hash ^ 0xFF) &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    /// Lowercased words of a text, split on everything that is not a letter or a digit. Written
    /// here, independently of the fixtures, so the tests do not check the fixtures with themselves.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    /// Damerau-Levenshtein distance, optimal string alignment. A small independent
    /// implementation for the typo tests.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }

    /// The edit budget of specification section 7.2 for a token of `length` characters.
    static func editBudget(_ length: Int) -> Int {
        length <= 2 ? 0 : (length <= 5 ? 1 : 2)
    }

    /// Every string of a golden entry, base and localized.
    static func allWords(of entry: GoldenEntry) -> Set<String> {
        Set(entry.allSurfaces.flatMap(words))
    }
}
