import Foundation

/// Where and in which language a hit matched (specification section 5, rule 11).
struct MatchDescription: Sendable, Hashable {
    var field: SearchField?
    var language: String?
    /// Ranges into `SearchDocument.surface(for: field)`.
    var highlights: [Range<String.Index>] = []

    static let none = MatchDescription()
}

/// The terms a query can match, prepared once for every hit of a page.
struct MatchTerms {
    let weights: [String: Double]
    /// The all-ASCII terms as bytes: the only ones a token of an all-ASCII surface can equal.
    private let ascii: [[UInt8]]
    private var lowered: [UInt8] = []

    /// More runs than this and tokenizing the whole surface is the cheaper way.
    static let maximumRuns = 12

    init(_ weights: [String: Double]) {
        self.weights = weights
        ascii = weights.keys.compactMap { term in
            let bytes = Array(term.utf8)
            return bytes.contains { $0 >= 0x80 } ? nil : bytes
        }
    }

    var isEmpty: Bool { weights.isEmpty }

    /// Where the tokens of `text` that can equal a term are, found without tokenizing: the byte
    /// ranges of the whitespace-delimited runs that hold an occurrence of a term, ascending and
    /// disjoint. Empty when no token can match. `nil` when the whole surface has to be
    /// tokenized: it holds a non-ASCII byte, or too many runs.
    ///
    /// A token is a stretch of consecutive characters of the surface, and the normalized form of
    /// an ASCII stretch is that stretch in lower case. So a token equal to a term lies inside a
    /// run that holds the term, and a word never crosses whitespace.
    mutating func runs(in text: String) -> [Range<Int>]? {
        var text = text
        return text.withUTF8 { bytes -> [Range<Int>]? in
            lowered.removeAll(keepingCapacity: true)
            lowered.reserveCapacity(bytes.count)
            for byte in bytes {
                if byte >= 0x80 { return nil }
                lowered.append(byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte)
            }
            var runs: [Range<Int>] = []
            let complete: Bool = lowered.withUnsafeBytes { haystack -> Bool in
                guard let base = haystack.baseAddress else { return true }
                let count = haystack.count
                for term in ascii where term.count <= count && !term.isEmpty {
                    var from = 0
                    while from + term.count <= count {
                        let hit = term.withUnsafeBytes { needle in
                            memmem(base + from, count - from, needle.baseAddress, needle.count)
                        }
                        guard let hit else { break }
                        let position = base.distance(to: UnsafeRawPointer(hit))
                        var lower = position
                        while lower > 0 && !Self.isWhitespace(haystack[lower - 1]) { lower -= 1 }
                        var upper = position + term.count
                        while upper < count && !Self.isWhitespace(haystack[upper]) { upper += 1 }
                        runs.append(lower..<upper)
                        if runs.count > Self.maximumRuns { return false }
                        from = upper
                    }
                }
                return true
            }
            guard complete else { return nil }
            guard runs.count > 1 else { return runs }
            runs.sort { $0.lowerBound < $1.lowerBound }
            var merged: [Range<Int>] = [runs[0]]
            for run in runs.dropFirst() where run.lowerBound >= merged[merged.count - 1].upperBound {
                merged.append(run)
            }
            return merged
        }
    }

    @inline(__always)
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// The one word of a plain run, as a byte range of the surface: ASCII letters only, with
    /// at most an opening bracket or quote before and closing punctuation after. Such a run is
    /// exactly one token, the letters, wherever it stands, so it needs no tokenizer. `nil` for
    /// any other run (digits, apostrophes, connectors, anything unusual): the caller tokenizes.
    static func plainWord(in run: Range<Int>, of bytes: UnsafeBufferPointer<UInt8>) -> Range<Int>? {
        var lower = run.lowerBound
        var upper = run.upperBound
        while lower < upper, bytes[lower] == 0x28 || bytes[lower] == 0x22 { lower += 1 }
        while upper > lower {
            let byte = bytes[upper - 1]
            // ) " , ; : ! ?
            guard byte == 0x29 || byte == 0x22 || byte == 0x2C || byte == 0x3B || byte == 0x3A || byte == 0x21 || byte == 0x3F else { break }
            upper -= 1
        }
        guard lower < upper else { return nil }
        for index in lower..<upper {
            let byte = bytes[index] | 0x20
            guard byte >= 0x61 && byte <= 0x7A else { return nil }
        }
        return lower..<upper
    }
}

enum Highlighter {
    /// Finds the surface that matched best and the tokens of it that matched.
    ///
    /// The field is the one whose matching tokens weigh most under the profile's field weights;
    /// ranges cover whole tokens of the original, un-normalized string.
    static func describe(
        _ document: SearchDocument,
        matchTerms: [String: Double],
        fieldWeights: [Double],
        session: TokenizerSession
    ) -> MatchDescription {
        var terms = MatchTerms(matchTerms)
        return describe(document, terms: &terms, fieldWeights: fieldWeights, session: session)
    }

    /// The same, for a page of hits that share one prepared set of terms.
    static func describe(
        _ document: SearchDocument,
        terms: inout MatchTerms,
        fieldWeights: [Double],
        session: TokenizerSession
    ) -> MatchDescription {
        guard !terms.isEmpty else { return .none }
        let matchTerms = terms.weights
        var pieces: [MatchedPiece] = []
        var tokens: [SearchToken] = []

        document.forEachSurface { surface in
            var piece = MatchedPiece(surface: surface)
            let text = surface.text
            var needsTokenizer = true
            if let runs = terms.runs(in: text) {
                // Most surfaces of a hit hold no match, and the ones that do hold it in a word
                // or two. A plain word is its own token; anything else sends the whole surface
                // to the tokenizer, as a surface with non-ASCII text always does.
                needsTokenizer = false
                var copy = text
                copy.withUTF8 { bytes in
                    for run in runs {
                        guard let word = MatchTerms.plainWord(in: run, of: bytes) else {
                            needsTokenizer = true
                            return
                        }
                        let term = String(unsafeUninitializedCapacity: word.count) { buffer in
                            for index in 0..<word.count { buffer[index] = bytes[word.lowerBound + index] | 0x20 }
                            return word.count
                        }
                        guard term.utf8.count <= TokenizerSession.maximumTermBytes, let weight = matchTerms[term] else { continue }
                        piece.spans.append((word.lowerBound, word.count))
                        piece.weight += weight
                    }
                }
                if needsTokenizer {
                    piece.spans.removeAll()
                    piece.weight = 0
                }
            }
            if needsTokenizer {
                tokens.removeAll(keepingCapacity: true)
                session.tokenize(text, language: surface.language, into: &tokens)
                let bytes = text.utf8
                for token in tokens {
                    guard let weight = matchTerms[token.term] else { continue }
                    piece.spans.append((
                        bytes.distance(from: bytes.startIndex, to: token.range.lowerBound),
                        bytes.distance(from: token.range.lowerBound, to: token.range.upperBound)
                    ))
                    piece.weight += weight
                }
            }
            if !piece.spans.isEmpty { pieces.append(piece) }
        }
        return summarize(document, pieces: pieces, fieldWeights: fieldWeights)
    }

    /// A surface of a document with the tokens of it that matched.
    struct MatchedPiece {
        let surface: DocumentSurface
        /// UTF-8 offset and length of each matching token inside the surface's text.
        var spans: [(start: Int, length: Int)] = []
        /// Sum of the weights of the matching tokens.
        var weight: Double = 0
    }

    /// Picks the field whose matching tokens weigh most and turns its spans into ranges.
    static func summarize(_ document: SearchDocument, pieces: [MatchedPiece], fieldWeights: [Double]) -> MatchDescription {
        guard !pieces.isEmpty else { return .none }
        var totals = [Double](repeating: 0, count: SearchField.count)
        for piece in pieces {
            totals[piece.surface.field.ordinal] += piece.weight * fieldWeights[piece.surface.field.ordinal]
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
        for piece in pieces where piece.surface.field == field {
            if piece.weight > strongest {
                strongest = piece.weight
                language = piece.surface.language
            }
            for span in piece.spans {
                let start = piece.surface.surfaceOffset + span.start
                guard start >= 0, start + span.length <= utf8.count else { continue }
                let lower = utf8.index(utf8.startIndex, offsetBy: start)
                ranges.append(lower..<utf8.index(lower, offsetBy: span.length))
            }
        }
        return MatchDescription(field: field, language: language, highlights: coalesce(ranges))
    }

    /// Sorts ranges and merges the ones that overlap (a compound and its parts, bigrams).
    static func coalesce(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        guard ranges.count > 1 else { return ranges }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// `true` when `document` contains every phrase as consecutive words of one surface.
    static func containsPhrases(_ phrases: [[String]], in document: SearchDocument, session: TokenizerSession) -> Bool {
        guard !phrases.isEmpty else { return true }
        var remaining = phrases
        var tokens: [SearchToken] = []
        document.forEachSurface { surface in
            guard !remaining.isEmpty else { return }
            tokens.removeAll(keepingCapacity: true)
            session.tokenize(surface.text, language: surface.language, into: &tokens)
            let words = tokens.compactMap { $0.kind == .word ? $0.term : nil }
            remaining.removeAll { contains(words, phrase: $0) }
        }
        return remaining.isEmpty
    }

    @inline(__always)
    static func contains(_ words: [String], phrase: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return phrase.isEmpty }
        let first = phrase[0]
        for start in 0...(words.count - phrase.count) where words[start] == first {
            var matches = true
            for offset in 1..<phrase.count where words[start + offset] != phrase[offset] {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }
}
