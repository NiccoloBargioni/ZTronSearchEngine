import Foundation
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// SplitMix64: a small deterministic generator for property tests.
struct TestRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: Range<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[int(0..<values.count)]
    }
}

/// Random corpora and queries for the strategy-parity and incremental-indexing properties.
///
/// The vocabulary is built so that the interesting paths actually fire: words that share
/// prefixes, words one or two edits apart, identifiers, a few CJK words and repeated terms.
struct RandomCorpus {
    static let stems = [
        "map", "maps", "mapper", "mapping", "mystery", "mastery", "misery", "box", "boxes", "boxer", "round", "rounds",
        "sound", "bound", "harbor", "harbour", "arbor", "temple", "temper", "simple", "frozen", "frost", "front", "power",
        "tower", "lower", "switch", "stitch", "door", "doors", "floor", "timer", "times", "tamer", "guide", "glide",
        "weapon", "weapons", "wagon", "shield", "shields", "field", "yield", "secret", "secrets", "sector", "perk",
        "park", "pack", "punch", "bunch", "lunch", "zombie", "zombies", "survival", "survivor", "revival", "tracker",
        "cracker", "tricker", "damage", "manage", "calculator", "calculation", "layout", "payout", "spawn", "span",
        "the", "of", "and", "to", "in", "for", "with", "how", "best", "all", "steps", "song", "easter", "egg",
    ]
    static let identifiers = ["m1911-a1", "v1.2.3", "ray_gun", "mk2", "example.com", "dlc-4", "a-10", "r2d2"]
    static let cjk = ["東京", "東京タワー", "地図", "神殿", "宝箱", "攻略", "北京大学", "大学"]

    var random: TestRandom

    init(seed: UInt64) {
        random = TestRandom(seed: seed)
    }

    mutating func word() -> String {
        let roll = random.int(0..<100)
        if roll < 6 { return random.pick(Self.identifiers) }
        if roll < 10 { return random.pick(Self.cjk) }
        return random.pick(Self.stems)
    }

    mutating func words(_ range: Range<Int>) -> String {
        (0..<random.int(range)).map { _ in word() }.joined(separator: " ")
    }

    mutating func filters() -> Set<CatalogFilter> {
        var filters: Set<CatalogFilter> = []
        if random.chance(0.6) { filters.insert(.platform(random.pick(Platform.allCases))) }
        if random.chance(0.3) { filters.insert(.platform(random.pick(Platform.allCases))) }
        if random.chance(0.5) { filters.insert(.category(random.pick(Category.allCases))) }
        if random.chance(0.2) { filters.insert(.string(key: "tier", value: random.pick(["free", "pro"]))) }
        return filters
    }

    mutating func localizations() -> [String: SearchLocalization] {
        guard random.chance(0.3) else { return [:] }
        var result: [String: SearchLocalization] = [:]
        for tag in ["it", "de", "ja"] where random.chance(0.5) {
            result[tag] = SearchLocalization(
                title: random.chance(0.8) ? words(1..<4) : nil,
                text: random.chance(0.5) ? words(3..<10) : nil,
                keywords: random.chance(0.3) ? [word(), word()] : [],
                caption: random.chance(0.2) ? words(2..<5) : nil
            )
        }
        return result
    }

    mutating func item(id: String) -> AnySearchable<CatalogKind> {
        switch random.int(0..<5) {
        case 0:
            return AnySearchable(Tool(id: id, title: words(1..<5), text: words(4..<30), keywords: (0..<random.int(0..<4)).map { _ in word() },
                                      filters: filters(), localizations: localizations()))
        case 1:
            return AnySearchable(Tip(id: id, title: words(1..<5), text: words(4..<30),
                                     updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(random.int(0..<50_000_000))),
                                     localizations: localizations()))
        case 2:
            return AnySearchable(MapItem(id: id, title: words(1..<4), text: words(4..<20), filters: filters(), localizations: localizations()))
        case 3:
            return AnySearchable(Game(id: id, title: words(1..<4), text: words(4..<20), keywords: (0..<random.int(0..<3)).map { _ in word() },
                                      filters: filters(), localizations: localizations()))
        default:
            return AnySearchable(ImageItem(id: id, title: words(1..<4), altText: words(2..<10), tags: (0..<random.int(0..<4)).map { _ in word() },
                                           caption: random.chance(0.7) ? words(2..<8) : nil, ocrText: random.chance(0.3) ? words(1..<5) : nil,
                                           localizations: localizations()))
        }
    }

    mutating func items(_ count: Int, prefix: String = "doc") -> [AnySearchable<CatalogKind>] {
        (0..<count).map { item(id: "\(prefix)-\($0)") }
    }

    /// One random edit: insertion, deletion, substitution or adjacent transposition.
    mutating func mutate(_ word: String) -> String {
        var characters = Array(word)
        guard characters.count >= 3, characters.allSatisfy({ $0.isLetter && $0.isASCII }) else { return word }
        let position = random.int(0..<characters.count)
        switch random.int(0..<4) {
        case 0: characters.insert(random.pick(Array("abcdefghijklmnopqrstuvwxyz")), at: position)
        case 1: characters.remove(at: position)
        case 2: characters[position] = random.pick(Array("abcdefghijklmnopqrstuvwxyz"))
        default: if position + 1 < characters.count { characters.swapAt(position, position + 1) }
        }
        return String(characters)
    }

    /// A query that exercises exact terms, prefixes, typos, phrases, identifiers, filters and kinds.
    mutating func query() -> SearchQuery<CatalogSchema> {
        var parts: [String] = []
        for _ in 0..<random.int(1..<4) {
            var term = word()
            let roll = random.int(0..<10)
            if roll < 3 { term = mutate(term) }
            if roll == 3 { term = mutate(mutate(term)) }
            parts.append(term)
        }
        var text = parts.joined(separator: " ")
        if random.chance(0.35), let last = parts.last, last.count > 2 {
            // The last token is still being typed.
            text = (parts.dropLast() + [String(last.prefix(random.int(1..<last.count)))]).joined(separator: " ")
        }
        if random.chance(0.1) { text += " " }
        if random.chance(0.1) { text = "\"\(word()) \(word())\" " + text }
        var tokens: [SearchQueryToken<CatalogSchema>] = []
        if random.chance(0.2) { tokens.append(.filter(.platform(random.pick(Platform.allCases)))) }
        if random.chance(0.1) { tokens.append(.filter(.category(random.pick(Category.allCases)))) }
        if random.chance(0.15) { tokens.append(.kind(random.pick(CatalogKind.allCases))) }
        if random.chance(0.08) { tokens.append(.phrase("\(word()) \(word())")) }
        if random.chance(0.05) { text = "" }
        var query = SearchQuery<CatalogSchema>(text: text, tokens: tokens)
        query.limit = 50
        return query
    }
}

/// What two result lists must agree on for the strategies to "rank identically".
struct RankingFingerprint: Equatable, CustomStringConvertible {
    let ids: [String]
    let scores: [Double]
    let channels: [Set<SearchChannel>]
    let fields: [SearchField?]
    let highlightCounts: [Int]

    init<Schema: SearchSchema>(_ snapshot: SearchSnapshot<Schema>?) {
        let hits = snapshot?.hits ?? []
        ids = hits.map(\.id.rawValue)
        scores = hits.map(\.score)
        channels = hits.map(\.channels)
        fields = hits.map(\.matchedField)
        highlightCounts = hits.map(\.highlights.count)
    }

    var description: String {
        zip(ids, scores).prefix(8).map { "\($0)=\($1)" }.joined(separator: ", ")
    }
}
