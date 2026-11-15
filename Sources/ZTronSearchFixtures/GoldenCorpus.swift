import Foundation
import ZTronSearchEngine

/// One golden item together with what the fixtures know about it.
public struct GoldenEntry: Sendable, Identifiable {
    /// Identifier of the item.
    public let id: SearchableID
    /// Kind of the item.
    public let kind: CatalogKind
    /// The base title, in English.
    public let title: String
    /// Concepts of the title, in title order.
    public let titleConceptIDs: [Int]
    /// Concepts of the base keywords or tags, in keyword order. Empty for maps and tips.
    public let keywordConceptIDs: [Int]
    /// Every concept the item is about: title first, then keywords, then the ones its text and
    /// caption mention. No duplicates.
    public let conceptIDs: [Int]
    /// Base keywords or tags. Empty for maps and tips.
    public let keywords: [String]
    /// Filters of the item. Empty for tips and images, which are not filterable.
    public let filters: Set<CatalogFilter>
    /// BCP 47 tags the item is localized in, sorted. Empty for a base-only item.
    public let localizedLanguages: [String]
    /// The item itself, type-erased.
    public let item: AnySearchable<CatalogKind>

    let titles: [String: String]
    let surfaces: [String: [String]]

    /// `true` when the item carries no localization at all.
    public var isBaseOnly: Bool { localizedLanguages.isEmpty }

    /// `true` when the item is localized in `language`. English is the base language, not a
    /// localization.
    public func isLocalized(in language: String) -> Bool {
        localizedLanguages.contains(language)
    }

    /// The title in a language: the base title for `"en"`, the localized one otherwise, `nil`
    /// when the item is not localized in that language.
    public func title(in language: String) -> String? {
        titles[language]
    }

    /// Every string of the item in one language: title, text, keywords, caption and, for the
    /// base language, recognized text. Empty when the item is not localized in that language.
    public func surfaces(in language: String) -> [String] {
        surfaces[language] ?? []
    }

    /// Every string of the item, base and localized.
    public var allSurfaces: [String] {
        FixtureLexicon.languages.flatMap { surfaces[$0] ?? [] }
    }
}

/// The curated golden corpus: fully judged items of the five kinds, built from the lexicon.
///
/// - At least 80 items of each kind, every one with a unique English title of two to four words.
/// - A majority is localized in Italian, German and Japanese; some items in one or two of them;
///   a deliberate minority in none (base-only items).
/// - No title's words are a subset of another title's words, so an exact-title query has exactly
///   one item that contains all of it.
/// - Base-only items are titled with reserved concepts that no localized item uses, so their
///   translations never reach an index.
///
/// The corpus is curated, not sampled: it is the same in every process, with no seed to pass.
public enum GoldenCorpus {
    /// Every golden item with its metadata, in a fixed order: maps, tips, tools, games, images.
    public static var entries: [GoldenEntry] { storage.entries }
    /// Every golden item, type-erased, in the order of ``entries``.
    public static var items: [AnySearchable<CatalogKind>] { storage.items }
    /// The golden maps, in corpus order.
    public static var maps: [MapItem] { storage.maps }
    /// The golden tips, in corpus order.
    public static var tips: [Tip] { storage.tips }
    /// The golden tools, in corpus order.
    public static var tools: [Tool] { storage.tools }
    /// The golden games, in corpus order.
    public static var games: [Game] { storage.games }
    /// The golden images, in corpus order.
    public static var images: [ImageItem] { storage.images }

    /// The newest moment any golden date refers to. Tips are created and updated before it; pass
    /// it as the engine's clock to make freshness deterministic.
    public static let referenceDate = Date(timeIntervalSince1970: 1_760_000_000)

    /// The entry of an item, or `nil` when the id is not golden.
    public static func entry(for id: SearchableID) -> GoldenEntry? {
        storage.positions[id].map { storage.entries[$0] }
    }

    /// The concepts an item is about; empty when the id is not golden.
    public static func conceptIDs(for id: SearchableID) -> [Int] {
        entry(for: id)?.conceptIDs ?? []
    }

    /// The entries of one kind, in corpus order.
    public static func entries(of kind: CatalogKind) -> [GoldenEntry] {
        storage.entries.filter { $0.kind == kind }
    }

    /// `true` for the ids of golden items. Every golden id starts with `gold-`.
    public static func isGolden(_ id: SearchableID) -> Bool {
        id.rawValue.hasPrefix(idPrefix)
    }

    static let idPrefix = "gold-"
    static let languages = ["it", "de", "ja"]

    struct Storage: Sendable {
        var entries: [GoldenEntry] = []
        var items: [AnySearchable<CatalogKind>] = []
        var maps: [MapItem] = []
        var tips: [Tip] = []
        var tools: [Tool] = []
        var games: [Game] = []
        var images: [ImageItem] = []
        var positions: [SearchableID: Int] = [:]
    }

    static let storage: Storage = {
        var builder = GoldenCorpusBuilder()
        return builder.build()
    }()

    // MARK: Validation

    /// Checks the properties listed on ``GoldenCorpus`` and returns one line per problem.
    public static func validate() -> [String] {
        var problems: [String] = []
        let entries = self.entries

        for kind in CatalogKind.allCases {
            let ofKind = entries.filter { $0.kind == kind }
            if ofKind.count < 80 { problems.append("\(kind.rawValue): only \(ofKind.count) items") }
            let full = ofKind.filter { $0.localizedLanguages.count == languages.count }.count
            if full * 2 <= ofKind.count { problems.append("\(kind.rawValue): no majority of fully localized items") }
            let baseOnly = ofKind.filter(\.isBaseOnly).count
            if baseOnly == 0 || baseOnly * 2 >= ofKind.count {
                problems.append("\(kind.rawValue): \(baseOnly) base-only items is not a deliberate minority")
            }
        }

        if Set(entries.map(\.id)).count != entries.count { problems.append("duplicate ids") }
        for entry in entries where !isGolden(entry.id) { problems.append("\(entry.id): id without the golden prefix") }

        // Titles: unique after folding, two to four words, and never a subset of another title.
        var tokenSets: [(id: SearchableID, tokens: Set<String>)] = []
        var seenTitles: [String: SearchableID] = [:]
        for entry in entries {
            let words = entry.title.split(separator: " ")
            if words.count < 2 || words.count > 4 { problems.append("\(entry.id): title '\(entry.title)' is not two to four words") }
            let folded = entry.title.lowercased()
            if let other = seenTitles[folded] { problems.append("\(entry.id) and \(other) share the title '\(entry.title)'") }
            seenTitles[folded] = entry.id
            tokenSets.append((entry.id, Set(words.map { $0.lowercased() })))
        }
        for (index, lhs) in tokenSets.enumerated() {
            for rhs in tokenSets[(index + 1)...] where lhs.tokens.isSubset(of: rhs.tokens) || rhs.tokens.isSubset(of: lhs.tokens) {
                problems.append("the title of \(lhs.id) and the title of \(rhs.id) contain one another")
            }
        }
        for language in languages {
            var seen: [String: SearchableID] = [:]
            for entry in entries {
                guard let title = entry.title(in: language) else { continue }
                if let other = seen[title.lowercased()] { problems.append("\(entry.id) and \(other) share the \(language) title '\(title)'") }
                seen[title.lowercased()] = entry.id
            }
        }

        // What the items say must be what the fixtures believe they are about.
        for entry in entries {
            let expected = Set(entry.conceptIDs)
            for language in ["en"] + entry.localizedLanguages {
                let found = Set(entry.surfaces(in: language).flatMap(FixtureLexicon.conceptIDs(in:)))
                if found != expected {
                    let extra = found.subtracting(expected).map { FixtureLexicon.concept($0).lemma }.sorted()
                    let missing = expected.subtracting(found).map { FixtureLexicon.concept($0).lemma }.sorted()
                    problems.append("\(entry.id) [\(language)]: unexpected \(extra), missing \(missing)")
                }
            }
            if !entry.isBaseOnly, entry.conceptIDs.contains(where: { FixtureLexicon.concept($0).isReserved }) {
                problems.append("\(entry.id): a localized item uses a reserved concept")
            }
            for surface in entry.allSurfaces where surface.contains("'") || surface.contains("\u{2019}") {
                problems.append("\(entry.id): '\(surface)' contains an apostrophe")
            }
        }
        return problems
    }
}

// MARK: - Builder

/// Enumerates every tuple of a small grid exactly once, in a scattered but fixed order.
struct GridEnumerator {
    private let sizes: [Int]
    private let total: Int
    private var position = 0
    /// A prime larger than any grid here, hence coprime to its size: multiplying by it is a
    /// permutation of the grid.
    private static let multiplier = 7_919

    init(_ sizes: [Int]) {
        self.sizes = sizes
        self.total = sizes.reduce(1, *)
        precondition(total > 0 && total % Self.multiplier != 0)
    }

    /// The next tuple of indices, or `nil` once the grid is exhausted.
    mutating func next() -> [Int]? {
        guard position < total else { return nil }
        var value = (position * Self.multiplier) % total
        position += 1
        var tuple = [Int](repeating: 0, count: sizes.count)
        for slot in stride(from: sizes.count - 1, through: 0, by: -1) {
            tuple[slot] = value % sizes[slot]
            value /= sizes[slot]
        }
        return tuple
    }
}

struct GoldenCorpusBuilder {
    private struct Draft {
        var kind: CatalogKind
        var pattern: GoldenTitlePattern
        var title: [FixtureConcept]
        var keywords: [FixtureConcept] = []
        var objects: [FixtureConcept] = []
        var actions: [FixtureConcept] = []
        var place: FixtureConcept?
        var languages: [String] = []
    }

    private let descriptors = FixtureLexicon.concepts(in: .descriptor)
    private let places = FixtureLexicon.concepts(in: .place)
    private let themes = FixtureLexicon.concepts(in: .theme)
    private let objects = FixtureLexicon.concepts(in: .object)
    private let rareObjects = FixtureLexicon.concepts(in: .rareObject)
    private let actions = FixtureLexicon.concepts(in: .action)
    private let mapNouns = FixtureLexicon.concepts(in: .mapNoun)
    private let tipNouns = FixtureLexicon.concepts(in: .tipNoun)
    private let toolNouns = FixtureLexicon.concepts(in: .toolNoun)
    private let viewNouns = FixtureLexicon.concepts(in: .viewNoun)
    private let tags = FixtureLexicon.concepts(in: .tag)
    private let reservedModifiers = FixtureLexicon.concepts(in: .reservedModifier)
    private let reservedPlaces = FixtureLexicon.concepts(in: .reservedPlace)
    private let reservedObjects = FixtureLexicon.concepts(in: .reservedObject)
    private let reservedThemes = FixtureLexicon.concepts(in: .reservedTheme)

    /// Word sets of the titles accepted so far.
    private var titleWords: [Set<String>] = []
    private var storage = GoldenCorpus.Storage()

    private static let localizedPerKind = 72
    private static let sharedLocations = 30
    private static let platforms: [Platform] = [.ios, .mac, .tv, .web]
    private static let regions: [ISOCountry] = [.italy, .germany, .japan, .unitedStates]
    private static let seed: UInt64 = 0x5EED_0F_601D

    // MARK: Titles

    /// Accepts a title unless its words equal, contain or are contained in an accepted title's.
    private mutating func accept(_ pattern: GoldenTitlePattern, _ concepts: [FixtureConcept]) -> Bool {
        var words = Set(concepts.map(\.lemma))
        guard words.count == concepts.count else { return false }
        if case .modifierHeadNumber(let number) = pattern { words.insert("\(number)") }
        for other in titleWords where words.isSubset(of: other) || other.isSubset(of: words) {
            return false
        }
        titleWords.append(words)
        return true
    }

    /// Draws tuples from a grid until `count` titles have been accepted.
    private mutating func drafts(
        _ kind: CatalogKind,
        count: Int,
        from grid: inout GridEnumerator,
        _ make: (Int, [Int]) -> (GoldenTitlePattern, [FixtureConcept])
    ) -> [Draft] {
        var result: [Draft] = []
        while result.count < count, let tuple = grid.next() {
            let (pattern, concepts) = make(result.count, tuple)
            if accept(pattern, concepts) {
                result.append(Draft(kind: kind, pattern: pattern, title: concepts))
            }
        }
        precondition(result.count == count, "the lexicon is too small for \(count) \(kind.rawValue) titles")
        return result
    }

    // MARK: Building

    mutating func build() -> GoldenCorpus.Storage {
        // Local copies: the closures below must not read `self` while a title is being accepted.
        let descriptors = self.descriptors, places = self.places, themes = self.themes
        let objects = self.objects, actions = self.actions, tags = self.tags
        let mapNouns = self.mapNouns, tipNouns = self.tipNouns, toolNouns = self.toolNouns, viewNouns = self.viewNouns
        let reservedModifiers = self.reservedModifiers, reservedPlaces = self.reservedPlaces
        let reservedObjects = self.reservedObjects, reservedThemes = self.reservedThemes

        // Locations shared by a map, an image and a tip: the families behind graded judgments.
        var locationGrid = GridEnumerator([descriptors.count, places.count])
        var locations: [(FixtureConcept, FixtureConcept)] = []
        while locations.count < Self.sharedLocations, let tuple = locationGrid.next() {
            locations.append((descriptors[tuple[0]], places[tuple[1]]))
        }
        var reservedLocationGrid = GridEnumerator([reservedModifiers.count, reservedPlaces.count])
        var reservedObjectGrid = GridEnumerator([reservedModifiers.count, reservedObjects.count])

        // Maps.
        var maps: [Draft] = []
        for (index, location) in locations.enumerated() {
            let concepts = [location.0, location.1, mapNouns[index % mapNouns.count]]
            let accepted = accept(.modifierHeadNoun, concepts)
            precondition(accepted, "shared location titles must be unique")
            maps.append(Draft(kind: .map, pattern: .modifierHeadNoun, title: concepts))
        }
        maps += drafts(.map, count: Self.localizedPerKind - maps.count, from: &locationGrid) { _, tuple in
            (.modifierHead, [descriptors[tuple[0]], places[tuple[1]]])
        }
        maps += drafts(.map, count: 12, from: &reservedLocationGrid) { _, tuple in
            (.modifierHead, [reservedModifiers[tuple[0]], reservedPlaces[tuple[1]]])
        }

        // Tips.
        var tips: [Draft] = []
        for (index, location) in locations.enumerated() {
            let concepts = [location.0, location.1, tipNouns[index % tipNouns.count]]
            let accepted = accept(.modifierHeadNoun, concepts)
            precondition(accepted, "shared location titles must be unique")
            tips.append(Draft(kind: .tip, pattern: .modifierHeadNoun, title: concepts))
        }
        var activityGrid = GridEnumerator([actions.count, tipNouns.count])
        tips += drafts(.tip, count: 22, from: &activityGrid) { _, tuple in
            (.headNoun, [actions[tuple[0]], tipNouns[tuple[1]]])
        }
        var objectTipGrid = GridEnumerator([objects.count, tipNouns.count])
        tips += drafts(.tip, count: Self.localizedPerKind - tips.count, from: &objectTipGrid) { _, tuple in
            (.headNoun, [objects[tuple[0]], tipNouns[tuple[1]]])
        }
        let reservedTips = drafts(.tip, count: 12, from: &reservedLocationGrid) { index, tuple in
            (.modifierHeadNoun, [reservedModifiers[tuple[0]], reservedPlaces[tuple[1]], tipNouns[index % tipNouns.count]])
        }
        tips += reservedTips

        // Images.
        var images: [Draft] = []
        for (index, location) in locations.enumerated() {
            let concepts = [location.0, location.1, viewNouns[index % viewNouns.count]]
            let accepted = accept(.modifierHeadNoun, concepts)
            precondition(accepted, "shared location titles must be unique")
            images.append(Draft(kind: .image, pattern: .modifierHeadNoun, title: concepts))
        }
        var objectImageGrid = GridEnumerator([descriptors.count, objects.count])
        images += drafts(.image, count: Self.localizedPerKind - images.count, from: &objectImageGrid) { _, tuple in
            (.modifierHead, [descriptors[tuple[0]], objects[tuple[1]]])
        }
        // Six reserved images picture the place of a reserved tip: a family without localization.
        for (index, tip) in reservedTips.prefix(6).enumerated() {
            let concepts = [tip.title[0], tip.title[1], viewNouns[(index * 3 + 1) % viewNouns.count]]
            let accepted = accept(.modifierHeadNoun, concepts)
            precondition(accepted, "shared location titles must be unique")
            images.append(Draft(kind: .image, pattern: .modifierHeadNoun, title: concepts))
        }
        images += drafts(.image, count: 6, from: &reservedObjectGrid) { _, tuple in
            (.modifierHead, [reservedModifiers[tuple[0]], reservedObjects[tuple[1]]])
        }

        // Tools.
        var toolGrid = GridEnumerator([objects.count, toolNouns.count])
        var tools = drafts(.tool, count: 48, from: &toolGrid) { _, tuple in
            (.headNoun, [objects[tuple[0]], toolNouns[tuple[1]]])
        }
        var describedToolGrid = GridEnumerator([descriptors.count, objects.count, toolNouns.count])
        tools += drafts(.tool, count: Self.localizedPerKind - tools.count, from: &describedToolGrid) { _, tuple in
            (.modifierHeadNoun, [descriptors[tuple[0]], objects[tuple[1]], toolNouns[tuple[2]]])
        }
        tools += drafts(.tool, count: 12, from: &reservedObjectGrid) { index, tuple in
            (.modifierHeadNoun, [reservedModifiers[tuple[0]], reservedObjects[tuple[1]], toolNouns[index % toolNouns.count]])
        }

        // Games.
        var gameGrid = GridEnumerator([descriptors.count, themes.count])
        var games = drafts(.game, count: 44, from: &gameGrid) { _, tuple in
            (.modifierHead, [descriptors[tuple[0]], themes[tuple[1]]])
        }
        var genreGrid = GridEnumerator([tags.count, themes.count])
        games += drafts(.game, count: 12, from: &genreGrid) { _, tuple in
            (.headNoun, [tags[tuple[0]], themes[tuple[1]]])
        }
        games += drafts(.game, count: Self.localizedPerKind - games.count, from: &gameGrid) { index, tuple in
            (.modifierHeadNumber(2 + index % 2), [descriptors[tuple[0]], themes[tuple[1]]])
        }
        var reservedThemeGrid = GridEnumerator([reservedModifiers.count, reservedThemes.count])
        games += drafts(.game, count: 12, from: &reservedThemeGrid) { _, tuple in
            (.modifierHead, [reservedModifiers[tuple[0]], reservedThemes[tuple[1]]])
        }

        // Emit in the order of `CatalogKind`.
        for (ordinal, draft) in maps.enumerated() { emit(detailed(draft, ordinal), ordinal) }
        for (ordinal, draft) in tips.enumerated() { emit(detailed(draft, ordinal), ordinal) }
        for (ordinal, draft) in tools.enumerated() { emit(detailed(draft, ordinal), ordinal) }
        for (ordinal, draft) in games.enumerated() { emit(detailed(draft, ordinal), ordinal) }
        for (ordinal, draft) in images.enumerated() { emit(detailed(draft, ordinal), ordinal) }
        for (position, entry) in storage.entries.enumerated() { storage.positions[entry.id] = position }
        return storage
    }

    // MARK: Details

    /// Localizations of the item at `ordinal` within its kind: all three for most, one or two
    /// for every sixth, none past the localized block.
    private static func languages(forOrdinal ordinal: Int) -> [String] {
        guard ordinal < localizedPerKind else { return [] }
        guard ordinal % 6 == 5 else { return GoldenCorpus.languages }
        switch (ordinal / 6) % 4 {
        case 0: return ["it"]
        case 1: return ["de"]
        case 2: return ["ja"]
        default: return ["it", "de"]
        }
    }

    /// Picks `count` distinct concepts of a pool that the draft does not already use.
    private func pick(_ pool: [FixtureConcept], _ count: Int, _ draft: Draft, _ ordinal: Int, salt: UInt64) -> [FixtureConcept] {
        var generator = SeededGenerator.stream(
            seed: Self.seed, (UInt64(Self.kindIndex(draft.kind)) << 32) | (UInt64(ordinal) << 8) | salt
        )
        var taken = Set((draft.title + draft.keywords + draft.objects + draft.actions + [draft.place].compactMap { $0 }).map(\.id))
        var result: [FixtureConcept] = []
        while result.count < count {
            let candidate = pool[generator.index(below: pool.count)]
            if taken.insert(candidate.id).inserted { result.append(candidate) }
        }
        return result
    }

    private static func kindIndex(_ kind: CatalogKind) -> Int {
        CatalogKind.allCases.firstIndex(of: kind) ?? 0
    }

    /// Fills in keywords, the concepts of the body and the localizations of a draft.
    private func detailed(_ draft: Draft, _ ordinal: Int) -> Draft {
        var draft = draft
        draft.languages = Self.languages(forOrdinal: ordinal)
        // Items at these ordinals carry a keyword no other item has.
        let rareSlot = [4, 22, 40].firstIndex(of: ordinal)

        switch draft.kind {
        case .map:
            draft.objects = pick(objects, 3, draft, ordinal, salt: 1)
            draft.actions = pick(actions, 1, draft, ordinal, salt: 2)

        case .tip:
            draft.objects = pick(objects, 2, draft, ordinal, salt: 1)
            if case .headNoun = draft.pattern {
                draft.place = pick(places, 1, draft, ordinal, salt: 3).first
            } else {
                draft.actions = pick(actions, 1, draft, ordinal, salt: 2)
            }

        case .tool:
            // A tool always carries what it is as a keyword; every fourth one a second tool noun.
            let noun = draft.title[draft.title.count - 1]
            draft.keywords = [noun, tags[(ordinal * 7 + 3) % tags.count]]
            if ordinal % 4 == 0, let position = toolNouns.firstIndex(of: noun) {
                draft.keywords.append(toolNouns[(position + 3) % toolNouns.count])
            }
            if let rareSlot { draft.keywords.append(rareObjects[rareSlot]) }
            draft.actions = pick(actions, 2, draft, ordinal, salt: 2)

        case .game:
            if case .headNoun = draft.pattern {
                draft.keywords = [draft.title[0]]
            } else {
                draft.keywords = [tags[(ordinal * 5 + 1) % tags.count]]
            }
            if ordinal % 2 == 0 {
                let second = tags[(ordinal * 11 + 6) % tags.count]
                if !draft.keywords.contains(second) { draft.keywords.append(second) }
            }
            if let rareSlot { draft.keywords.append(rareObjects[3 + rareSlot]) }
            draft.place = pick(places, 1, draft, ordinal, salt: 3).first
            draft.actions = pick(actions, 2, draft, ordinal, salt: 2)
            draft.objects = pick(objects, 1, draft, ordinal, salt: 1)

        case .image:
            if draft.title.count > 2 {
                // A picture of a place: tagged with what kind of picture it is.
                draft.keywords = [draft.title[2], tags[(ordinal * 9 + 2) % tags.count]]
                draft.objects = pick(objects, 1, draft, ordinal, salt: 1)
            } else {
                draft.keywords = [viewNouns[ordinal % viewNouns.count], tags[(ordinal * 9 + 2) % tags.count]]
                draft.place = pick(places, 1, draft, ordinal, salt: 3).first
            }
            if let rareSlot { draft.keywords.append(rareObjects[6 + rareSlot]) }
        }
        return draft
    }

    private func filters(_ draft: Draft, _ ordinal: Int) -> Set<CatalogFilter> {
        var filters: Set<CatalogFilter> = []
        let platforms = Self.platforms
        switch draft.kind {
        case .map:
            filters.insert(.category(.maps))
            filters.insert(.platform(platforms[ordinal % 4]))
            if ordinal % 3 == 0 { filters.insert(.platform(platforms[(ordinal + 1) % 4])) }
            if ordinal % 5 < 4 { filters.insert(.region(Self.regions[ordinal % 5])) }
        case .tool:
            let category: ZTronSearchFixtures.Category
            switch draft.title[draft.title.count - 1].lemma {
            case "calculator", "counter", "timer": category = .calculators
            case "planner": category = .guides
            default: category = .trackers
            }
            filters.insert(.category(category))
            filters.insert(.platform(platforms[(ordinal * 3 + 1) % 4]))
            if ordinal % 4 == 0 { filters.insert(.platform(platforms[(ordinal * 3 + 2) % 4])) }
        case .game:
            filters.insert(.platform(platforms[ordinal % 4]))
            if ordinal % 2 == 0 { filters.insert(.platform(platforms[(ordinal + 2) % 4])) }
            filters.insert(.region(Self.regions[ordinal % 4]))
            if let genre = draft.keywords.first {
                filters.insert(.string(key: GoldenCorpus.genreFilterKey, value: genre.lemma))
            }
        case .tip, .image:
            break
        }
        return filters
    }

    // MARK: Emitting

    private mutating func emit(_ draft: Draft, _ ordinal: Int) {
        let number = String(ordinal + 1)
        let id = GoldenCorpus.idPrefix + draft.kind.rawValue + "-" + String(repeating: "0", count: max(0, 3 - number.count)) + number
        let body = GoldenPhrases.Body(
            pattern: draft.pattern, title: draft.title, objects: draft.objects, actions: draft.actions,
            place: draft.place, tag: draft.keywords.first
        )
        // Every third image has recognized text: its subject and a sign, as the pixels spell them.
        let ocrText: String? = draft.kind == .image && ordinal % 3 == 0
            ? "\(draft.title[1].lemma.uppercased()) ZONE \(ordinal % 9 + 1)"
            : nil

        func text(_ phrases: GoldenPhrases) -> String {
            switch draft.kind {
            case .map: return phrases.mapText(body)
            case .tip: return phrases.tipText(body)
            case .tool: return phrases.toolText(body)
            case .game: return phrases.gameText(body)
            case .image: return phrases.imageAltText(body)
            }
        }

        let english = GoldenPhrases(language: "en")
        let title = english.title(draft.pattern, draft.title)
        let baseText = text(english)
        let baseKeywords = draft.keywords.map(\.lemma)
        let baseCaption: String? = draft.kind == .image ? english.imageCaption(body) : nil

        var titles = ["en": title]
        var surfaces = ["en": [title, baseText] + baseKeywords + [baseCaption, ocrText].compactMap { $0 }]
        var localizations: [String: SearchLocalization] = [:]
        for language in draft.languages {
            let phrases = GoldenPhrases(language: language)
            let localized = SearchLocalization(
                title: phrases.title(draft.pattern, draft.title),
                text: text(phrases),
                keywords: draft.keywords.map(phrases.word),
                caption: draft.kind == .image ? phrases.imageCaption(body) : nil
            )
            localizations[language] = localized
            titles[language] = localized.title
            surfaces[language] = [localized.title, localized.text, localized.caption].compactMap { $0 } + localized.keywords
        }

        let filters = self.filters(draft, ordinal)
        let item: AnySearchable<CatalogKind>
        switch draft.kind {
        case .map:
            let map = MapItem(id: id, title: title, text: baseText, filters: filters, language: "en", localizations: localizations)
            storage.maps.append(map)
            item = AnySearchable(map)
        case .tip:
            let day: TimeInterval = 86_400
            let created = GoldenCorpus.referenceDate.addingTimeInterval(-day * Double(30 + ordinal * 9))
            let tip = Tip(
                id: id, title: title, text: baseText, createdAt: created,
                updatedAt: created.addingTimeInterval(day * Double((ordinal % 5) * 3)),
                language: "en", localizations: localizations
            )
            storage.tips.append(tip)
            item = AnySearchable(tip)
        case .tool:
            let tool = Tool(
                id: id, title: title, text: baseText, keywords: baseKeywords, filters: filters,
                language: "en", localizations: localizations
            )
            storage.tools.append(tool)
            item = AnySearchable(tool)
        case .game:
            let game = Game(
                id: id, title: title, text: baseText, keywords: baseKeywords, filters: filters,
                language: "en", localizations: localizations
            )
            storage.games.append(game)
            item = AnySearchable(game)
        case .image:
            let image = ImageItem(
                id: id, title: title, altText: baseText, tags: baseKeywords, caption: baseCaption, ocrText: ocrText,
                language: "en", localizations: localizations
            )
            storage.images.append(image)
            item = AnySearchable(image)
        }

        var conceptIDs: [Int] = []
        let mentioned = draft.title + draft.keywords + draft.objects + draft.actions + [draft.place].compactMap { $0 }
        for concept in mentioned where !conceptIDs.contains(concept.id) {
            conceptIDs.append(concept.id)
        }
        storage.entries.append(GoldenEntry(
            id: SearchableID(id), kind: draft.kind, title: title,
            titleConceptIDs: draft.title.map(\.id), keywordConceptIDs: draft.keywords.map(\.id),
            conceptIDs: conceptIDs, keywords: baseKeywords, filters: filters,
            localizedLanguages: draft.languages.sorted(), item: item, titles: titles, surfaces: surfaces
        ))
        storage.items.append(item)
    }
}

extension GoldenCorpus {
    /// Key of the ad-hoc string filter games carry: `.string(key: "genre", value: <tag>)`.
    public static let genreFilterKey = "genre"
}
