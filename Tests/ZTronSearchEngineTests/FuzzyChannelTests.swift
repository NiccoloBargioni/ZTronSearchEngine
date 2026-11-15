import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// The fuzzy channel's candidate generation (specification section 7.2): whatever shortcut finds
/// the candidates, the result is what verifying every vocabulary term would give.
final class FuzzyChannelTests: XCTestCase {
    // MARK: Distance

    func testTheBitVectorDistanceEqualsTheTable() {
        var random = TestRandom(seed: 71)
        let alphabets: [[String]] = [
            ["a", "b"],
            ["a", "b", "c", "d"],
            ["a", "é", "日", "𝒳", "z"],
        ]
        var scratch = EditDistance.Scratch()
        var compared = 0
        for _ in 0..<60_000 {
            let alphabet = random.pick(alphabets)
            let first = (0..<random.int(1..<15)).map { _ in random.pick(alphabet) }.joined()
            let second = (0..<random.int(0..<15)).map { _ in random.pick(alphabet) }.joined()
            let maximum = random.int(0..<4)
            let a = EditDistance.scalars(first)
            let b = EditDistance.scalars(second)
            guard let pattern = EditPattern(a) else { return XCTFail("a term of \(a.count) scalars fits one word") }
            let expected = EditDistance.bounded(a, b, maximum: maximum, scratch: &scratch)
            XCTAssertEqual(pattern.distance(to: second, maximum: maximum), expected, "\(first) -> \(second), maximum \(maximum)")
            compared += 1
        }
        XCTAssertEqual(compared, 60_000)
    }

    func testTheBitVectorCoversSixtyFourScalarsAndNoMore() {
        let long = String(repeating: "ab", count: 32)
        XCTAssertNotNil(EditPattern(EditDistance.scalars(long)))
        XCTAssertNil(EditPattern(EditDistance.scalars(long + "a")))
        XCTAssertNil(EditPattern([]))
        let pattern = EditPattern(EditDistance.scalars(long))
        var changed = Array(long)
        changed.swapAt(62, 63)
        XCTAssertEqual(pattern?.distance(to: String(changed), maximum: 2), 1, "the last pair is a transposition away")
        changed[0] = "x"
        XCTAssertEqual(pattern?.distance(to: String(changed), maximum: 2), 2)
        changed[10] = "x"
        XCTAssertNil(pattern?.distance(to: String(changed), maximum: 2))
    }

    // MARK: Candidates

    /// Brute force: every vocabulary term, verified by the table.
    private func expectedCandidates(for query: String, maximumEdits: Int, vocabulary: [String: Int]) -> [String: Int] {
        let scalars = EditDistance.scalars(query)
        var scratch = EditDistance.Scratch()
        var expected: [String: Int] = [:]
        for (term, frequency) in vocabulary where frequency > 0 && !ScriptClass.isExactOnly(term) {
            if let edits = EditDistance.bounded(scalars, EditDistance.scalars(term), maximum: maximumEdits, scratch: &scratch), edits > 0 {
                expected[term] = edits
            }
        }
        return expected
    }

    private func word(_ random: inout TestRandom, alphabet: [String], length: Range<Int>) -> String {
        (0..<random.int(length)).map { _ in random.pick(alphabet) }.joined()
    }

    private func mutated(_ word: String, _ random: inout TestRandom, alphabet: [String]) -> String {
        var characters = Array(word)
        for _ in 0..<random.int(1..<3) {
            switch random.int(0..<4) {
            case 0 where characters.count > 1:
                characters.remove(at: random.int(0..<characters.count))
            case 1:
                characters.insert(Character(random.pick(alphabet)), at: random.int(0..<(characters.count + 1)))
            case 2 where !characters.isEmpty:
                characters[random.int(0..<characters.count)] = Character(random.pick(alphabet))
            default:
                if characters.count > 1 {
                    let position = random.int(0..<(characters.count - 1))
                    characters.swapAt(position, position + 1)
                }
            }
        }
        return String(characters)
    }

    /// Runs the generator of the indexed strategy over the given segments.
    private func candidates(for query: String, maximumEdits: Int, entries: [IndexEntry], scratch: FuzzyScratch) -> [String: Int] {
        SegmentMerger.withViews(entries.map(\.segment)) { views in
            let source = IndexTermSource(entries: entries, views: views, scratch: scratch)
            var result: [String: Int] = [:]
            for candidate in source.fuzzyCandidates(for: query, maximumEdits: maximumEdits, limit: .max) {
                XCTAssertNil(result[candidate.reference.term], "\(candidate.reference.term) is reported twice for \(query)")
                result[candidate.reference.term] = candidate.edits
            }
            return result
        }
    }

    /// The live vocabulary of some segments with its document frequencies.
    private func vocabulary(of entries: [IndexEntry]) -> [String: Int] {
        SegmentMerger.withViews(entries.map(\.segment)) { views in
            var vocabulary: [String: Int] = [:]
            for (index, view) in views.enumerated() {
                for term in 0..<view.segment.termCount {
                    vocabulary[view.termString(term), default: 0] += entries[index].documentFrequency(term, in: view)
                }
            }
            return vocabulary
        }
    }

    private func segment(of words: [String], prefix: String, perDocument: Int = 6) throws -> IndexSegment {
        var documents: [SearchDocument] = []
        var index = 0
        while index < words.count {
            let slice = words[index..<min(words.count, index + perDocument)]
            documents.append(SearchDocument(id: SearchableID("\(prefix)\(index)"), kind: "tool", text: slice.joined(separator: " ")))
            index += perDocument
        }
        return try IndexSegment(data: SegmentBuilder.build([DocumentTokenizer.tokenize(documents)]))
    }

    func testCandidatesEqualBruteForceOverDenseVocabularies() throws {
        var random = TestRandom(seed: 3)
        let alphabets: [[String]] = [
            ["a", "b", "c"],
            ["a", "b", "c", "d", "e", "f"],
            ["a", "e", "n", "r", "s", "t", "é", "ü"],
            // Wide alphabets: most terms differ from a token by too many letters to be read.
            ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p"],
            ["а", "б", "в", "г", "д", "е", "ж", "з", "и", "к", "a", "b", "c", "d"],
        ]
        let scratches = [FuzzyScratch(strategy: .lists), FuzzyScratch(strategy: .scan), FuzzyScratch()]
        var checked = 0
        var withCandidates = 0
        for alphabet in alphabets {
            var words = Set<String>()
            while words.count < 1_800 {
                words.insert(word(&random, alphabet: alphabet, length: 2..<13))
            }
            // Terms that match exactly only never come back as corrections.
            for _ in 0..<60 { words.insert(word(&random, alphabet: alphabet, length: 3..<8) + "7") }
            let list = words.sorted()
            let entries = [IndexEntry(segment: try segment(of: list, prefix: "d"))]
            let known = vocabulary(of: entries)
            XCTAssertGreaterThan(known.count, 1_500)

            for round in 0..<420 {
                let query: String
                switch round % 3 {
                case 0: query = word(&random, alphabet: alphabet, length: 3..<15)
                case 1: query = mutated(random.pick(list), &random, alphabet: alphabet)
                default: query = random.pick(list)
                }
                let length = query.unicodeScalars.count
                let budget = EditDistance.allowedEdits(forLength: length)
                guard budget > 0, !ScriptClass.isExactOnly(query) else { continue }
                let expected = expectedCandidates(for: query, maximumEdits: budget, vocabulary: known)
                for scratch in scratches {
                    let actual = candidates(for: query, maximumEdits: budget, entries: entries, scratch: scratch)
                    XCTAssertEqual(actual, expected, "query '\(query)' (\(length) scalars, \(budget) edits), \(scratch.strategy)")
                }
                checked += 1
                if !expected.isEmpty { withCandidates += 1 }
            }
        }
        XCTAssertGreaterThan(checked, 1_500)
        XCTAssertGreaterThan(withCandidates, 700, "the vocabularies are dense enough to exercise every path")
    }

    func testEveryTokenLengthUsesALosslessScheme() throws {
        var random = TestRandom(seed: 19)
        let alphabet = ["a", "b", "c", "d"]
        var words = Set<String>()
        // Neighbourhoods around a seed word of every length, so each scheme has work to do.
        var seeds: [String] = []
        for length in 2...70 {
            let seed = (0..<length).map { _ in random.pick(alphabet) }.joined()
            seeds.append(seed)
            words.insert(seed)
            for _ in 0..<40 { words.insert(mutated(seed, &random, alphabet: alphabet)) }
        }
        let entries = [IndexEntry(segment: try segment(of: words.sorted(), prefix: "d"))]
        let known = vocabulary(of: entries)
        for scratch in [FuzzyScratch(strategy: .lists), FuzzyScratch(strategy: .scan), FuzzyScratch()] {
            for seed in seeds where seed.count >= 3 {
                for query in [seed, mutated(seed, &random, alphabet: alphabet)] {
                    let length = query.unicodeScalars.count
                    guard length >= 3 else { continue }
                    let budget = EditDistance.allowedEdits(forLength: length)
                    XCTAssertEqual(
                        candidates(for: query, maximumEdits: budget, entries: entries, scratch: scratch),
                        expectedCandidates(for: query, maximumEdits: budget, vocabulary: known),
                        "length \(length), \(scratch.strategy)"
                    )
                }
            }
        }
    }

    func testAnyEditBudgetIsLossless() throws {
        var random = TestRandom(seed: 23)
        let alphabet = ["a", "b", "c"]
        var words = Set<String>()
        while words.count < 600 { words.insert(word(&random, alphabet: alphabet, length: 2..<12)) }
        let entries = [IndexEntry(segment: try segment(of: words.sorted(), prefix: "d"))]
        let known = vocabulary(of: entries)
        for scratch in [FuzzyScratch(strategy: .lists), FuzzyScratch()] {
            for _ in 0..<120 {
                let query = word(&random, alphabet: alphabet, length: 3..<14)
                for budget in 1...3 {
                    XCTAssertEqual(
                        candidates(for: query, maximumEdits: budget, entries: entries, scratch: scratch),
                        expectedCandidates(for: query, maximumEdits: budget, vocabulary: known),
                        "query '\(query)', \(budget) edits, \(scratch.strategy)"
                    )
                }
            }
        }
    }

    func testCandidatesAcrossSegmentsFollowTheLiveDocuments() throws {
        var random = TestRandom(seed: 41)
        let alphabet = ["a", "b", "c", "d", "e"]
        var words = Set<String>()
        while words.count < 900 { words.insert(word(&random, alphabet: alphabet, length: 2..<11)) }
        let list = words.sorted()
        // Three segments with overlapping vocabularies; documents are then deleted from two.
        var entries = [
            IndexEntry(segment: try segment(of: Array(list[0..<500]), prefix: "a")),
            IndexEntry(segment: try segment(of: Array(list[300..<800]), prefix: "b")),
            IndexEntry(segment: try segment(of: Array(list[700..<900]), prefix: "c")),
        ]
        for ordinal in 0..<entries[0].segment.documentCount where ordinal % 3 == 0 { entries[0].delete(ordinal) }
        for ordinal in 0..<entries[1].segment.documentCount where ordinal % 2 == 0 { entries[1].delete(ordinal) }
        let known = vocabulary(of: entries)
        XCTAssertTrue(known.values.contains(0), "some terms live only in deleted documents")

        let scratches = [FuzzyScratch(strategy: .lists), FuzzyScratch(strategy: .scan), FuzzyScratch()]
        var total = 0
        for round in 0..<300 {
            let query = round % 2 == 0 ? random.pick(list) : mutated(random.pick(list), &random, alphabet: alphabet)
            let length = query.unicodeScalars.count
            let budget = EditDistance.allowedEdits(forLength: length)
            guard budget > 0 else { continue }
            let expected = expectedCandidates(for: query, maximumEdits: budget, vocabulary: known)
            for scratch in scratches {
                XCTAssertEqual(candidates(for: query, maximumEdits: budget, entries: entries, scratch: scratch), expected, "query '\(query)', \(scratch.strategy)")
            }
            total += expected.count
        }
        XCTAssertGreaterThan(total, 500)
    }

    func testTheScratchIsCleanBetweenTokens() throws {
        // The same token twice, and tokens of different lengths in between, give the same answer:
        // nothing a token leaves behind leaks into the next.
        var random = TestRandom(seed: 57)
        let alphabet = ["a", "b", "c"]
        var words = Set<String>()
        while words.count < 700 { words.insert(word(&random, alphabet: alphabet, length: 2..<10)) }
        let entries = [IndexEntry(segment: try segment(of: words.sorted(), prefix: "d"))]
        let shared = FuzzyScratch(strategy: .lists)
        let queries = (0..<80).map { _ in word(&random, alphabet: alphabet, length: 3..<12) }
        var first: [[String: Int]] = []
        for query in queries {
            first.append(candidates(for: query, maximumEdits: EditDistance.allowedEdits(forLength: query.count), entries: entries, scratch: shared))
        }
        for (index, query) in queries.enumerated().reversed() {
            let fresh = candidates(for: query, maximumEdits: EditDistance.allowedEdits(forLength: query.count), entries: entries, scratch: FuzzyScratch(strategy: .lists))
            let again = candidates(for: query, maximumEdits: EditDistance.allowedEdits(forLength: query.count), entries: entries, scratch: shared)
            XCTAssertEqual(first[index], fresh)
            XCTAssertEqual(again, fresh)
        }
    }

    func testCandidatesAreRankedByEditsThenFrequencyThenTermAndCapped() throws {
        // "harbor" with a frequent and a rare neighbour at one edit, and more at two.
        var documents: [SearchDocument] = []
        func add(_ text: String, times: Int) {
            for _ in 0..<times {
                documents.append(SearchDocument(id: SearchableID("d\(documents.count)"), kind: "tool", text: text))
            }
        }
        add("harbor", times: 2)
        add("harbour", times: 5)
        add("harbir", times: 1)
        add("harber", times: 1)
        add("barbar", times: 9)
        add("harb", times: 3)
        let entries = [IndexEntry(segment: try IndexSegment(data: SegmentBuilder.build([DocumentTokenizer.tokenize(documents)])))]
        let ranked = SegmentMerger.withViews(entries.map(\.segment)) { views in
            IndexTermSource(entries: entries, views: views, scratch: nil).fuzzyCandidates(for: "harbor", maximumEdits: 2, limit: 8)
        }
        XCTAssertEqual(ranked.map(\.reference.term), ["harbour", "harber", "harbir", "barbar", "harb"])
        XCTAssertEqual(ranked.map(\.edits), [1, 1, 1, 2, 2])
        XCTAssertEqual(ranked.map(\.reference.documentFrequency), [5, 1, 1, 9, 3])
        let capped = SegmentMerger.withViews(entries.map(\.segment)) { views in
            IndexTermSource(entries: entries, views: views, scratch: nil).fuzzyCandidates(for: "harbor", maximumEdits: 2, limit: 2)
        }
        XCTAssertEqual(capped.map(\.reference.term), ["harbour", "harber"])
    }
}
