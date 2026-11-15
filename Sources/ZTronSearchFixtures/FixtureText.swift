import Foundation

/// Crude, deterministic text handling shared by the lexicon, the fake embedding and the golden
/// set: folding, tokenizing and edit distance.
///
/// It is deliberately independent of the engine's tokenizer and of `NaturalLanguage`. The fakes
/// must not agree with the engine by construction, and every result here is the same on every
/// platform: no locale, no ICU, no hash that varies per process.
public enum FixtureText {
    // MARK: Folding

    /// Folds one Unicode scalar of Latin text: lowercases ASCII and strips the diacritics of
    /// Latin-1 letters (`ü` becomes `u`, `à` becomes `a`, `ß` becomes `ss`).
    ///
    /// Appends the folded bytes and returns `true`, or returns `false` when the scalar is not a
    /// Latin letter this table knows.
    @inline(__always)
    static func foldLatin(_ value: UInt32, into bytes: inout [UInt8]) -> Bool {
        switch value {
        case 0x61...0x7A:
            bytes.append(UInt8(value))
        case 0x41...0x5A:
            bytes.append(UInt8(value) | 0x20)
        case 0xC0...0xC5, 0xE0...0xE5:
            bytes.append(0x61) // a
        case 0xC7, 0xE7:
            bytes.append(0x63) // c
        case 0xC8...0xCB, 0xE8...0xEB:
            bytes.append(0x65) // e
        case 0xCC...0xCF, 0xEC...0xEF:
            bytes.append(0x69) // i
        case 0xD1, 0xF1:
            bytes.append(0x6E) // n
        case 0xD2...0xD6, 0xD8, 0xF2...0xF6, 0xF8:
            bytes.append(0x6F) // o
        case 0xD9...0xDC, 0xF9...0xFC:
            bytes.append(0x75) // u
        case 0xDD, 0xFD, 0xFF:
            bytes.append(0x79) // y
        case 0xDF:
            bytes.append(0x73) // ss
            bytes.append(0x73)
        case 0xC6, 0xE6:
            bytes.append(0x61) // ae
            bytes.append(0x65)
        default:
            return false
        }
        return true
    }

    /// `true` for the scalars of Japanese text: kana, CJK ideographs and the prolonged sound mark.
    @inline(__always)
    static func isJapanese(_ value: UInt32) -> Bool {
        switch value {
        case 0x3005...0x3007, 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    @inline(__always)
    static func isHiragana(_ value: UInt32) -> Bool {
        value >= 0x3040 && value <= 0x309F
    }

    /// Katakana, including the prolonged sound mark `ー`.
    @inline(__always)
    static func isKatakana(_ value: UInt32) -> Bool {
        value >= 0x30A0 && value <= 0x30FF
    }

    // MARK: Scanning

    /// One piece of scanned text.
    enum Piece {
        /// A folded Latin token: lowercase ASCII letters (plus any other alphabetic scalars, as
        /// UTF-8). Never empty.
        case latin(UnsafeBufferPointer<UInt8>)
        /// A maximal run of Japanese scalars. Never empty.
        case japanese(UnsafeBufferPointer<UInt32>)
    }

    /// Splits text into folded Latin tokens and runs of Japanese scalars, in reading order.
    ///
    /// Everything that is not a letter separates tokens and is dropped, digits included. The
    /// buffers handed to `body` are only valid during the call.
    static func scan(_ text: String, _ body: (Piece) -> Void) {
        var token: [UInt8] = []
        token.reserveCapacity(32)
        var run: [UInt32] = []

        func flushToken() {
            guard !token.isEmpty else { return }
            token.withUnsafeBufferPointer { body(.latin($0)) }
            token.removeAll(keepingCapacity: true)
        }
        func flushRun() {
            guard !run.isEmpty else { return }
            run.withUnsafeBufferPointer { body(.japanese($0)) }
            run.removeAll(keepingCapacity: true)
        }

        var copy = text
        copy.withUTF8 { utf8 in
            let count = utf8.count
            var index = 0
            while index < count {
                let byte = utf8[index]
                if byte < 0x80 {
                    // ASCII fast path.
                    if byte >= 0x61 && byte <= 0x7A {
                        if !run.isEmpty { flushRun() }
                        token.append(byte)
                    } else if byte >= 0x41 && byte <= 0x5A {
                        if !run.isEmpty { flushRun() }
                        token.append(byte | 0x20)
                    } else {
                        flushToken()
                        flushRun()
                    }
                    index += 1
                    continue
                }
                // Decode one multi-byte scalar. Swift strings are valid UTF-8.
                var value: UInt32
                var length: Int
                if byte & 0xE0 == 0xC0 {
                    value = UInt32(byte & 0x1F)
                    length = 2
                } else if byte & 0xF0 == 0xE0 {
                    value = UInt32(byte & 0x0F)
                    length = 3
                } else {
                    value = UInt32(byte & 0x07)
                    length = 4
                }
                if index + length > count { length = count - index }
                var offset = 1
                while offset < length {
                    value = (value << 6) | UInt32(utf8[index + offset] & 0x3F)
                    offset += 1
                }

                if isJapanese(value) {
                    flushToken()
                    run.append(value)
                } else {
                    if !run.isEmpty { flushRun() }
                    if !foldLatin(value, into: &token) {
                        if let scalar = Unicode.Scalar(value), scalar.properties.isAlphabetic {
                            for position in 0..<length { token.append(utf8[index + position]) }
                        } else {
                            flushToken()
                        }
                    }
                }
                index += length
            }
        }
        flushToken()
        flushRun()
    }

    /// The folded Latin tokens of a text, in order: lowercase, diacritics stripped, split on
    /// everything that is not a letter. Japanese text yields no token here.
    public static func latinTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        scan(text) { piece in
            if case .latin(let bytes) = piece {
                tokens.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        return tokens
    }

    /// The maximal runs of Japanese scalars in a text, in order.
    public static func japaneseRuns(_ text: String) -> [String] {
        var runs: [String] = []
        scan(text) { piece in
            if case .japanese(let scalars) = piece {
                var view = String.UnicodeScalarView()
                for value in scalars {
                    if let scalar = Unicode.Scalar(value) { view.append(scalar) }
                }
                runs.append(String(view))
            }
        }
        return runs
    }

    /// Folds a single word the way ``latinTokens(_:)`` folds text. A word that would split into
    /// several tokens is joined back together, so the result is always one token.
    public static func fold(_ word: String) -> String {
        latinTokens(word).joined()
    }

    // MARK: Edit distance

    /// Edits a token of `length` characters may absorb (specification section 7.2): none for
    /// 1 to 2 characters, one for 3 to 5, two for 6 or more.
    public static func allowedEdits(forLength length: Int) -> Int {
        if length <= 2 { return 0 }
        if length <= 5 { return 1 }
        return 2
    }

    /// Damerau-Levenshtein distance in its optimal-string-alignment form: an insertion, a
    /// deletion, a substitution and a transposition of two adjacent characters cost one edit
    /// each, and no substring is edited twice.
    public static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs.unicodeScalars)
        let b = Array(rhs.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
            }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }

    /// The same distance on bytes, or `nil` as soon as it is known to exceed `maximum`.
    static func boundedEditDistance(_ a: [UInt8], _ b: [UInt8], maximum: Int) -> Int? {
        if abs(a.count - b.count) > maximum { return nil }
        if a.isEmpty { return b.count <= maximum ? b.count : nil }
        if b.isEmpty { return a.count <= maximum ? a.count : nil }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                if value < rowMinimum { rowMinimum = value }
            }
            if rowMinimum > maximum { return nil }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count] <= maximum ? previous[b.count] : nil
    }

    /// The words of a text as a phrase is matched against them: folded letters and whole
    /// numbers, in order. Unlike ``latinTokens(_:)`` it keeps digits, because the engine does.
    public static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            let folded = fold(current)
            words.append(folded.isEmpty ? current : folded)
            current = ""
        }
        var digits = false
        for character in text {
            if character.isNumber {
                if !digits { flush() }
                digits = true
                current.append(character)
            } else if character.isLetter {
                if digits { flush() }
                digits = false
                current.append(character)
            } else {
                flush()
                digits = false
            }
        }
        flush()
        return words
    }

    // MARK: Hashing

    /// FNV-1a over bytes: a stable 64-bit hash, the same in every process and on every platform.
    @inline(__always)
    static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// FNV-1a over scalars.
    @inline(__always)
    static func hash(_ scalars: UnsafeBufferPointer<UInt32>) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for scalar in scalars {
            hash = (hash ^ UInt64(scalar)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// A stable 64-bit hash of a string's UTF-8 bytes.
    public static func stableHash(_ string: String) -> UInt64 {
        var copy = string
        return copy.withUTF8 { hash($0) }
    }
}
