import Foundation
import ZTronSearchEngine

/// A deterministic fake of a shared multilingual embedding space, driven by the lexicon
/// (specification section 7.3: "tests use a deterministic fake").
///
/// Every concept of ``FixtureLexicon`` owns one unit vector. A text is embedded by adding up
/// the vectors of the concepts it mentions, so an English lemma, its synonyms and its Italian,
/// German and Japanese forms all land in the same place: a paraphrase or a foreign-language
/// query is close to an item it shares no token with. Words the lexicon does not know add a
/// small hashed component, so unrelated texts still differ from one another.
///
/// The space is a pure function of the lexicon, the dimension and the weight of unknown words.
/// Nothing is random at run time and nothing depends on the process, so the same text yields the
/// same vector on every run and on every platform.
///
/// Concept vectors are orthonormal in groups of `dimensions` concepts. With 384 dimensions the
/// whole lexicon fits in one group and distinct concepts never interfere. With the default 64
/// the lexicon needs several groups, and concepts of different groups overlap by about
/// `1/sqrt(64)`: queries of two or more concepts still find their item, but a query of a single
/// concept is noisy. Prefer 384 for relevance gates, and whenever distractors compete with the
/// golden items.
public struct FakeEmbeddingProvider: Sendable {
    /// Dimensions of the space when none is asked for.
    public static let defaultDimensions = 64
    /// The ceiling the specification puts on the embedding space.
    public static let maximumDimensions = 384

    /// Dimensions of every vector.
    public let dimensions: Int
    /// Weight of a word the lexicon does not know, against 1 for a concept.
    public let unknownTokenWeight: Float
    /// Identity of the space; changes with every parameter that changes the vectors.
    public let modelID: String
    /// Words of an item's text that enter its composition as the "short description".
    public let shortDescriptionWordLimit: Int
    /// Whether ``queryVector(for:)`` guesses at words the lexicon does not know, the way a
    /// subword model does: the beginning of a word counts as the words it may become, a typo as
    /// the nearest word. Off by default: unknown words are noise, exactly as in ``vector(for:)``.
    public let recognizesPartialWords: Bool

    /// Concept vectors, row-major: concept `c` occupies `c * dimensions ..< (c + 1) * dimensions`.
    private let conceptVectors: [Float]
    private let conceptCount: Int

    /// Creates a space. `dimensions` is clamped to `8...384`.
    public init(
        dimensions: Int = FakeEmbeddingProvider.defaultDimensions,
        unknownTokenWeight: Float = 0.3,
        recognizesPartialWords: Bool = false
    ) {
        let clamped = min(max(dimensions, 8), Self.maximumDimensions)
        self.dimensions = clamped
        self.unknownTokenWeight = unknownTokenWeight
        self.recognizesPartialWords = recognizesPartialWords
        self.shortDescriptionWordLimit = 24
        self.conceptCount = FixtureLexicon.concepts.count
        self.conceptVectors = Self.makeConceptVectors(count: FixtureLexicon.concepts.count, dimensions: clamped)
        self.modelID = "fake-lexicon-embedding-v1-c\(FixtureLexicon.concepts.count)-d\(clamped)-u\(Int((unknownTokenWeight * 1000).rounded()))"
    }

    // MARK: Encoding

    /// The unit vector of a text in English, Italian, German or Japanese.
    ///
    /// Latin-script text is lowercased, stripped of diacritics and split on everything that is
    /// not a letter; Japanese text is matched against the lexicon's forms by substring. Each
    /// mention of a concept adds that concept's vector, so repeating a word weighs it more. A
    /// text with no letters at all maps to a fixed unit vector.
    public func vector(for text: String) -> [Float] {
        encode(text, partialWords: false)
    }

    /// The unit vector of a query. The same as ``vector(for:)``, except that with
    /// ``recognizesPartialWords`` a Latin-script word the lexicon does not know is first tried
    /// as the beginning of lexicon words, then as a typo of one, before it counts as noise.
    ///
    /// Item vectors never go through this: only queries are typed by people.
    public func queryVector(for text: String) -> [Float] {
        encode(text, partialWords: recognizesPartialWords)
    }

    private func encode(_ text: String, partialWords: Bool) -> [Float] {
        var sum = [Float](repeating: 0, count: dimensions)
        let index = FixtureLexicon.index
        let dimensions = self.dimensions
        let weight = unknownTokenWeight
        conceptVectors.withUnsafeBufferPointer { concepts in
            sum.withUnsafeMutableBufferPointer { sum in
                func addConcept(_ id: Int) {
                    let row = id * dimensions
                    for position in 0..<dimensions {
                        sum[position] += concepts[row + position]
                    }
                }
                func addConcept(_ id: Int, weight: Float) {
                    let row = id * dimensions
                    for position in 0..<dimensions {
                        sum[position] += weight * concepts[row + position]
                    }
                }
                // An unknown word touches four coordinates picked by its hash.
                func addUnknown(_ hash: UInt64) {
                    let mixed = SeededGenerator.mix(hash)
                    let share = weight / 2
                    for slot in 0..<4 {
                        let position = Int((mixed >> UInt64(slot * 12)) & 0xFFF) % dimensions
                        let negative = (mixed >> UInt64(60 + slot)) & 1 == 1
                        sum[position] += negative ? -share : share
                    }
                }
                FixtureText.scan(text) { piece in
                    switch piece {
                    case .latin(let bytes):
                        if let id = index.table.lookup(bytes) {
                            addConcept(id)
                        } else {
                            let guesses = partialWords ? index.partialMatches(bytes) : []
                            if guesses.isEmpty {
                                addUnknown(FixtureText.hash(bytes))
                            } else {
                                for guess in guesses { addConcept(guess.concept, weight: guess.weight) }
                            }
                        }
                    case .japanese(let scalars):
                        index.matchJapanese(scalars, onConcept: addConcept, onUnknown: { addUnknown(FixtureText.hash($0)) })
                    }
                }
            }
        }
        return Self.normalized(sum)
    }

    /// The unit vector of one concept.
    public func conceptVector(for conceptID: Int) -> [Float] {
        precondition(conceptID >= 0 && conceptID < conceptCount, "unknown concept")
        return Array(conceptVectors[(conceptID * dimensions)..<((conceptID + 1) * dimensions)])
    }

    // MARK: Items

    /// The text an item is embedded from: type, title, tags, short description and caption, in
    /// that order, from the base surfaces (specification sections 5 and 7.3).
    ///
    /// The composition is assembled from the capabilities the item has, the same way for every
    /// kind. The short description is the first ``shortDescriptionWordLimit`` words of the
    /// item's text: what comes after them does not reach the vector. An item's own
    /// `embeddingText` is not consulted, so that one rule holds for the kinds that declare one
    /// and the kinds that do not.
    public func composition<Item: Searchable>(for item: Item) -> String {
        let base: any Searchable = (item as? AnySearchable<Item.Kind>)?.base ?? item
        var parts = [item.searchKind.rawValue]
        if let titled = base as? any TitledSearchable {
            parts.append(titled.searchTitle)
        }
        if let keyworded = base as? any KeywordSearchable {
            parts.append(contentsOf: keyworded.searchKeywords)
        }
        parts.append(shortDescription(of: base.searchText))
        if let captioned = base as? any CaptionedSearchable, let caption = captioned.searchCaption {
            parts.append(caption)
        }
        return parts.joined(separator: " ")
    }

    /// The unit vector of an item: ``vector(for:)`` of its ``composition(for:)``.
    public func itemVector<Item: Searchable>(for item: Item) -> [Float] {
        vector(for: composition(for: item))
    }

    /// The vectors of many items, keyed by id: what `SemanticSearching.upsert` takes.
    public func itemVectors<Item: Searchable>(for items: [Item]) -> [SearchableID: [Float]] {
        var vectors: [SearchableID: [Float]] = [:]
        vectors.reserveCapacity(items.count)
        for item in items {
            vectors[item.searchID] = itemVector(for: item)
        }
        return vectors
    }

    /// Catalog items with their vector attached where the type can carry one: tips and images.
    ///
    /// A scan context compares the query with the vectors its items carry, so this is how the
    /// semantic channel gets something to search in a small context.
    public func embedded(_ items: [AnySearchable<CatalogKind>]) -> [AnySearchable<CatalogKind>] {
        items.map { item in
            if var tip = item.base as? Tip {
                tip.embedding = itemVector(for: tip)
                return AnySearchable(tip)
            }
            if var image = item.base as? ImageItem {
                image.embedding = itemVector(for: image)
                return AnySearchable(image)
            }
            return item
        }
    }

    private func shortDescription(of text: String) -> String {
        var words = 0
        var end = text.startIndex
        var inWord = false
        for index in text.indices {
            if text[index].isWhitespace {
                if inWord {
                    words += 1
                    inWord = false
                    if words == shortDescriptionWordLimit { return String(text[..<end]) }
                }
            } else {
                inWord = true
                end = text.index(after: index)
            }
        }
        return text
    }

    // MARK: Arithmetic

    /// Cosine similarity of two vectors of the same length; `0` when either is zero.
    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        precondition(lhs.count == rhs.count, "vectors of different dimensions")
        var dot: Float = 0
        var lhsSquares: Float = 0
        var rhsSquares: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsSquares += lhs[index] * lhs[index]
            rhsSquares += rhs[index] * rhs[index]
        }
        guard lhsSquares > 0, rhsSquares > 0 else { return 0 }
        return dot / (lhsSquares.squareRoot() * rhsSquares.squareRoot())
    }

    /// The vector scaled to unit length. A zero vector becomes the first axis, so the result is
    /// always a unit vector.
    static func normalized(_ vector: [Float]) -> [Float] {
        var squares: Float = 0
        for value in vector { squares += value * value }
        guard squares > 0 else {
            var axis = [Float](repeating: 0, count: vector.count)
            if !axis.isEmpty { axis[0] = 1 }
            return axis
        }
        let scale = 1 / squares.squareRoot()
        return vector.map { $0 * scale }
    }

    /// Builds the concept vectors: pseudo-random unit vectors derived from the concept id with
    /// SplitMix64, orthonormal inside each group of `dimensions` consecutive concepts.
    ///
    /// The space is cut into blocks whose sizes are the powers of two that add up to
    /// `dimensions` (384 is 256 + 128). Inside a block, the vector of a concept is one row of
    /// the Hadamard matrix of that size, multiplied entry by entry with a sign pattern drawn
    /// for the concept's group, and scaled to unit length. Rows of a Hadamard matrix are
    /// orthogonal and the signs cancel in a product of two rows of one group, so a group is
    /// exactly orthonormal; two groups use different signs, so their vectors overlap like random
    /// ones, by about `1 / sqrt(dimensions)`.
    ///
    /// Every entry is `+1/sqrt(size)` or `-1/sqrt(size)` and nothing is accumulated, so the
    /// result is bit-identical on every platform.
    private static func makeConceptVectors(count: Int, dimensions: Int) -> [Float] {
        // Blocks, largest first.
        var blocks: [(offset: Int, size: Int)] = []
        var offset = 0
        var bit = 1
        while bit * 2 <= dimensions { bit *= 2 }
        while bit >= 1 {
            if dimensions & bit != 0 {
                blocks.append((offset, bit))
                offset += bit
            }
            bit /= 2
        }

        var result = [Float](repeating: 0, count: count * dimensions)
        var signs = [Bool](repeating: false, count: dimensions)
        for concept in 0..<count {
            let row = concept % dimensions
            if row == 0 {
                // A new group: draw its sign pattern.
                var generator = SeededGenerator.stream(seed: 0x5EED_C0DE_C0FF_EE00, UInt64(concept / dimensions))
                var bits: UInt64 = 0
                for position in 0..<dimensions {
                    if position % 64 == 0 { bits = generator.next() }
                    signs[position] = (bits >> UInt64(position % 64)) & 1 == 1
                }
            }
            guard let block = blocks.last(where: { $0.offset <= row }) else { continue }
            let local = row - block.offset
            let magnitude = 1 / Float(block.size).squareRoot()
            for column in 0..<block.size {
                let hadamardNegative = (local & column).nonzeroBitCount & 1 == 1
                let negative = hadamardNegative != signs[block.offset + column]
                result[concept * dimensions + block.offset + column] = negative ? -magnitude : magnitude
            }
        }
        return result
    }
}
