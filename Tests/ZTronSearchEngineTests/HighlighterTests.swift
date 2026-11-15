import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// Highlights are found by tokenizing only the words of a surface that can hold a match. These
/// tests hold that shortcut against tokenizing everything.
final class HighlighterTests: XCTestCase {
    private struct Piece: Hashable {
        let term: String
        let start: Int
        let length: Int
        let kind: UInt8
        let isExactOnly: Bool
        let isCompoundPart: Bool
    }

    private func pieces(_ text: String, language: String?, session: TokenizerSession, offset: Int = 0) -> [Piece] {
        let bytes = text.utf8
        return session.tokenize(text, language: language).map { token in
            Piece(
                term: token.term,
                start: offset + bytes.distance(from: bytes.startIndex, to: token.range.lowerBound),
                length: bytes.distance(from: token.range.lowerBound, to: token.range.upperBound),
                kind: token.kind.rawValue,
                isExactOnly: token.isExactOnly,
                isCompoundPart: token.isCompoundPart
            )
        }
    }

    /// The whitespace-delimited runs of an ASCII string, as byte ranges.
    private func runs(of text: String) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (index, byte) in text.utf8.enumerated() {
            if MatchTerms.isWhitespace(byte) {
                if let lower = start { result.append(lower..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let lower = start { result.append(lower..<text.utf8.count) }
        return result
    }

    private func randomText(_ random: inout TestRandom) -> String {
        let words = ["frozen", "Harbor", "m1911-a1", "ray_gun", "example.com", "don't", "rock'n'roll", "U.S.A.", "3.14", "10,000",
                     "e-mail", "C++", "A&B", "v2", "x", "it's", "end.", "(maps)", "\"quoted\"", "semi;colon", "a/b", "#tag", "@home",
                     "50%", "one--two", "trail-", "-lead", "dot..dot", "under__score", "MixedCASE", "ALLCAPS", "1st", "2nd", "über"]
        let separators = [" ", " ", " ", "  ", "\t", "\n", " \n ", ", ", ". ", "; ", ": ", " - ", "! ", "? "]
        var text = ""
        for index in 0..<random.int(1..<14) {
            if index > 0 { text += random.pick(separators) }
            var word = random.pick(words)
            if word == "über" { word = "uber" }
            if random.chance(0.15) {
                let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.'")
                word = String((0..<random.int(1..<10)).map { _ in random.pick(letters) })
            }
            text += word
        }
        return text
    }

    func testAPlainRunIsExactlyOneTokenWhereverItStands() {
        // The shortcut the highlighter takes: a whitespace-delimited run of ASCII letters, with
        // at most an opening bracket or quote before and closing punctuation after, is one word
        // token made of the letters, in every language the tokenizer may be told.
        var random = TestRandom(seed: 97)
        let session = TokenizerSession()
        let languages: [String?] = [nil, "en", "it", "de", "fr", "es", "pt", "nl", "sv", "pl", "ja", "zh-Hans", "zh-Hant", "ko", "th", "ar", "he", "ru", "tr", "hi"]
        var plainRuns = 0
        var otherRuns = 0
        for _ in 0..<4_000 {
            let text = randomText(&random)
            XCTAssertFalse(text.utf8.contains { $0 >= 0x80 })
            let language = random.pick(languages)
            let whole = pieces(text, language: language, session: session)
            var copy = text
            copy.withUTF8 { bytes in
                for run in runs(of: text) {
                    guard let word = MatchTerms.plainWord(in: run, of: bytes) else {
                        otherRuns += 1
                        continue
                    }
                    plainRuns += 1
                    let inside = whole.filter { $0.start < run.upperBound && $0.start + $0.length > run.lowerBound }
                    let letters = String(decoding: UnsafeBufferPointer(rebasing: bytes[word]), as: UTF8.self)
                    XCTAssertEqual(
                        inside,
                        [Piece(term: letters.lowercased(), start: word.lowerBound, length: word.count, kind: SearchToken.Kind.word.rawValue,
                               isExactOnly: false, isCompoundPart: false)],
                        "run '\(String(decoding: UnsafeBufferPointer(rebasing: bytes[run]), as: UTF8.self))' of '\(text)' in \(language ?? "no language")"
                    )
                }
            }
        }
        XCTAssertGreaterThan(plainRuns, 5_000)
        XCTAssertGreaterThan(otherRuns, 4_000, "the sample also holds the runs the shortcut refuses")
    }

    func testOnlyPlainRunsAreTakenAsTheirOwnToken() {
        func word(_ text: String) -> String? {
            var copy = text
            return copy.withUTF8 { bytes in
                MatchTerms.plainWord(in: 0..<bytes.count, of: bytes).map { String(decoding: UnsafeBufferPointer(rebasing: bytes[$0]), as: UTF8.self) }
            }
        }
        XCTAssertEqual(word("Harbor"), "Harbor")
        XCTAssertEqual(word("harbor,"), "harbor")
        XCTAssertEqual(word("(maps)"), "maps")
        XCTAssertEqual(word("\"quoted\"?"), "quoted")
        XCTAssertEqual(word("ready!?"), "ready")
        for other in ["don't", "m1911", "ray_gun", "example.com", "e-mail", "end.", "3.14", "A&B", "x/y", "#tag", "(", "!?", "'tis", "co-op,"] {
            XCTAssertNil(word(other), other)
        }
    }

    /// The description as it would be with every surface tokenized in full.
    private func reference(_ document: SearchDocument, matchTerms: [String: Double], fieldWeights: [Double], session: TokenizerSession) -> MatchDescription {
        struct Found {
            let surface: DocumentSurface
            var spans: [(Int, Int)] = []
            var weight = 0.0
        }
        var found: [Found] = []
        var totals = [Double](repeating: 0, count: SearchField.count)
        document.forEachSurface { surface in
            var entry = Found(surface: surface)
            let bytes = surface.text.utf8
            for token in session.tokenize(surface.text, language: surface.language) {
                guard let weight = matchTerms[token.term] else { continue }
                entry.spans.append((
                    bytes.distance(from: bytes.startIndex, to: token.range.lowerBound),
                    bytes.distance(from: token.range.lowerBound, to: token.range.upperBound)
                ))
                entry.weight += weight
            }
            guard !entry.spans.isEmpty else { return }
            totals[surface.field.ordinal] += entry.weight * fieldWeights[surface.field.ordinal]
            found.append(entry)
        }
        var best: SearchField?
        var bestTotal = 0.0
        for field in SearchField.ordered where totals[field.ordinal] > bestTotal {
            best = field
            bestTotal = totals[field.ordinal]
        }
        guard let field = best, let surface = document.surface(for: field) else { return .none }
        var ranges: [Range<String.Index>] = []
        var language: String?
        var strongest = -Double.infinity
        let utf8 = surface.utf8
        for entry in found where entry.surface.field == field {
            if entry.weight > strongest {
                strongest = entry.weight
                language = entry.surface.language
            }
            for (start, length) in entry.spans {
                let lower = utf8.index(utf8.startIndex, offsetBy: entry.surface.surfaceOffset + start)
                ranges.append(lower..<utf8.index(lower, offsetBy: length))
            }
        }
        return MatchDescription(field: field, language: language, highlights: Highlighter.coalesce(ranges))
    }

    func testDescriptionsEqualTheOnesFromFullTokenization() {
        var random = TestRandom(seed: 131)
        let session = TokenizerSession()
        let weights = SearchPipeline.fieldWeights(.default)
        let vocabulary = ["frozen", "harbor", "harbour", "map", "maps", "ray", "gun", "ray_gun", "m1911", "a1", "m1911-a1", "example.com",
                          "example", "com", "tool", "tools", "guide", "zombie", "résumé", "resume", "東京", "タワー", "город", "ночь",
                          "don't", "e", "mail", "the", "of"]
        var described = 0
        var matched = 0
        for index in 0..<1_500 {
            func text(_ range: Range<Int>) -> String {
                (0..<random.int(range)).map { _ in
                    let word = random.chance(0.6) ? random.pick(vocabulary) : randomText(&random)
                    return random.chance(0.3) ? word.capitalized : word
                }.joined(separator: random.chance(0.8) ? " " : ", ")
            }
            let document = SearchDocument(
                id: SearchableID("d\(index)"),
                kind: "tool",
                title: random.chance(0.8) ? text(1..<4) : nil,
                text: text(0..<25),
                keywords: (0..<random.int(0..<4)).map { _ in text(1..<3) },
                caption: random.chance(0.4) ? text(1..<8) : nil,
                ocrText: random.chance(0.2) ? text(1..<8) : nil,
                localizedAlt: (0..<random.int(0..<3)).map { _ in text(1..<6) }
            )
            var matchTerms: [String: Double] = [:]
            for _ in 0..<random.int(1..<7) {
                matchTerms[SearchNormalizer.normalize(random.pick(vocabulary))] = random.pick([1.0, 0.7, 0.5, 1.0 / 3.0])
            }
            var terms = MatchTerms(matchTerms)
            let actual = Highlighter.describe(document, terms: &terms, fieldWeights: weights, session: session)
            let expected = reference(document, matchTerms: matchTerms, fieldWeights: weights, session: session)
            XCTAssertEqual(actual, expected, "document \(index): \(document) with \(matchTerms.keys.sorted())")
            described += 1
            if expected.field != nil { matched += 1 }
        }
        XCTAssertEqual(described, 1_500)
        XCTAssertGreaterThan(matched, 900)
    }

    func testAMatchInARunTheShortcutRefusesStillComesFromTheTokenizer() {
        let session = TokenizerSession()
        let weights = SearchPipeline.fieldWeights(.default)
        let document = SearchDocument(id: "d", kind: "tool", title: "The e-mail guide", text: "Send an e-mail, then read example.com. Don't wait.")
        func ranges(_ terms: [String: Double]) -> [String] {
            let description = Highlighter.describe(document, matchTerms: terms, fieldWeights: weights, session: session)
            guard let field = description.field, let surface = document.surface(for: field) else { return [] }
            return ["\(field)"] + description.highlights.map { String(surface[$0]) }
        }
        XCTAssertEqual(ranges(["mail": 1]), ["title", "mail"])
        XCTAssertEqual(ranges(["e-mail": 1]), ["title", "e-mail"])
        XCTAssertEqual(ranges(["example.com": 1]), ["text", "example.com"])
        XCTAssertEqual(ranges(["don": 1]), ["text", "Don"], "a word is split at its apostrophe")
        XCTAssertEqual(ranges(["guide": 1, "wait": 0.5]), ["title", "guide"])
        XCTAssertEqual(ranges(["wait": 1]), ["text", "wait"], "'wait.' ends in a full stop the shortcut does not strip; the tokenizer finds the word")
    }

    func testAScanContextHighlightsFromItsStoredPositionsAsTheTokenizerWould() {
        // A scan context keeps where every token sits and never tokenizes a hit again.
        var random = TestRandom(seed: 211)
        let session = TokenizerSession()
        let weights = SearchPipeline.fieldWeights(.default)
        let vocabulary = ["frozen", "harbor", "harbour", "map", "maps", "ray", "gun", "ray_gun", "m1911", "a1", "m1911-a1", "example.com",
                          "example", "com", "tool", "guide", "résumé", "resume", "東京", "タワー", "東京タワー", "город", "ночь", "don't", "the", "of"]
        var documents: [SearchDocument] = []
        for index in 0..<240 {
            func text(_ range: Range<Int>) -> String {
                (0..<random.int(range)).map { _ in
                    let word = random.chance(0.7) ? random.pick(vocabulary) : randomText(&random)
                    return random.chance(0.3) ? word.capitalized : word
                }.joined(separator: random.chance(0.8) ? " " : ", ")
            }
            documents.append(SearchDocument(
                id: SearchableID("d\(index)"), kind: "tool",
                title: random.chance(0.8) ? text(1..<4) : nil,
                text: text(0..<20),
                keywords: (0..<random.int(0..<4)).map { _ in text(1..<3) },
                caption: random.chance(0.4) ? text(1..<8) : nil,
                ocrText: random.chance(0.2) ? text(1..<8) : nil,
                localizedAlt: (0..<random.int(0..<3)).map { _ in text(1..<6) },
                languages: SearchFieldLanguages(title: "en", text: random.chance(0.5) ? "ja" : nil, localizedAlt: ["it", "ja", nil])
            ))
        }
        let engine = ScanEngine(documents: documents, session: session)
        var matched = 0
        for _ in 0..<300 {
            var matchTerms: [String: Double] = [:]
            for _ in 0..<random.int(1..<7) {
                matchTerms[SearchNormalizer.normalize(random.pick(vocabulary + ["absent", "タ"]))] = random.pick([1.0, 0.7, 0.5, 1.0 / 3.0])
            }
            let ids = (0..<20).map { _ in documents[random.int(0..<documents.count)].id }
            let stored = engine.describe(ids, matchTerms: matchTerms, fieldWeights: weights, session: session)
            for (id, description) in zip(ids, stored) {
                let document = documents.first { $0.id == id }!
                XCTAssertEqual(description, reference(document, matchTerms: matchTerms, fieldWeights: weights, session: session), "\(id) with \(matchTerms.keys.sorted())")
                if description.field != nil { matched += 1 }
            }
        }
        XCTAssertGreaterThan(matched, 3_000)
        XCTAssertEqual(engine.describe(["d1", "nope"], matchTerms: [:], fieldWeights: weights), [.none, .none])
        XCTAssertEqual(engine.describe(["nope"], matchTerms: ["map": 1], fieldWeights: weights), [.none])
    }

    func testRunsHoldEveryOccurrenceAndNothingBetween() {
        var terms = MatchTerms(["harbor": 1, "map": 0.7, "東京": 1])
        XCTAssertEqual(terms.runs(in: "Frozen HARBOR at dawn"), [7..<13])
        XCTAssertEqual(terms.runs(in: "maps of the harbor, remapped"), [0..<4, 12..<19, 20..<28], "a run reaches to the next whitespace")
        XCTAssertEqual(terms.runs(in: "nothing here"), [])
        XCTAssertEqual(terms.runs(in: ""), [])
        XCTAssertNil(terms.runs(in: "Frozen harbör"), "a surface with a non-ASCII byte is tokenized in full")
        XCTAssertEqual(terms.runs(in: "harbor harbor\tharbor\nharbor"), [0..<6, 7..<13, 14..<20, 21..<27])
        let many = Array(repeating: "map", count: MatchTerms.maximumRuns + 1).joined(separator: " ")
        XCTAssertNil(terms.runs(in: many), "past the limit the whole surface is cheaper")
        var none = MatchTerms([:])
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(none.runs(in: "anything"), [])
    }
}
