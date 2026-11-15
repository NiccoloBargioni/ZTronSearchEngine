import Foundation

/// Bounded Damerau-Levenshtein distance on normalized Unicode scalars (specification section 7.2).
///
/// This is the optimal-string-alignment variant: an insertion, a deletion, a substitution and
/// a transposition of two adjacent scalars each cost one edit, and no substring is edited twice.
enum EditDistance {
    /// Edits a token of `length` normalized scalars may absorb: none for 1 to 2, one for 3 to 5,
    /// two for 6 or more.
    @inline(__always)
    static func allowedEdits(forLength length: Int) -> Int {
        if length <= 2 { return 0 }
        if length <= 5 { return 1 }
        return 2
    }

    /// Reusable rows, so verifying thousands of candidates allocates nothing.
    struct Scratch {
        var previous2: [Int] = []
        var previous: [Int] = []
        var current: [Int] = []
    }

    /// The distance between `a` and `b` when it is `maximum` or less, otherwise `nil`.
    static func bounded(_ a: [UInt32], _ b: [UInt32], maximum: Int, scratch: inout Scratch) -> Int? {
        let n = a.count
        let m = b.count
        // Length pre-check: every missing or extra scalar costs an edit.
        if abs(n - m) > maximum { return nil }
        if n == 0 { return m <= maximum ? m : nil }
        if m == 0 { return n <= maximum ? n : nil }

        if scratch.previous.count < m + 1 {
            scratch.previous2 = [Int](repeating: 0, count: m + 1)
            scratch.previous = [Int](repeating: 0, count: m + 1)
            scratch.current = [Int](repeating: 0, count: m + 1)
        }
        for j in 0...m { scratch.previous[j] = j }

        for i in 1...n {
            scratch.current[0] = i
            var rowMinimum = i
            let ai = a[i - 1]
            for j in 1...m {
                let bj = b[j - 1]
                let cost = ai == bj ? 0 : 1
                var value = min(scratch.previous[j] + 1, scratch.current[j - 1] + 1, scratch.previous[j - 1] + cost)
                if i > 1 && j > 1 && ai == b[j - 2] && a[i - 2] == bj {
                    value = min(value, scratch.previous2[j - 2] + 1)
                }
                scratch.current[j] = value
                if value < rowMinimum { rowMinimum = value }
            }
            // Every later cell derives from this row, so the distance can only grow from here.
            if rowMinimum > maximum { return nil }
            swap(&scratch.previous2, &scratch.previous)
            swap(&scratch.previous, &scratch.current)
        }
        let distance = scratch.previous[m]
        return distance <= maximum ? distance : nil
    }

    static func bounded(_ a: String, _ b: String, maximum: Int) -> Int? {
        var scratch = Scratch()
        return bounded(scalars(a), scalars(b), maximum: maximum, scratch: &scratch)
    }

    @inline(__always)
    static func scalars(_ string: String) -> [UInt32] {
        string.unicodeScalars.map(\.value)
    }
}

/// A query term prepared for verifying thousands of vocabulary terms (Hyyrö's bit-vector
/// algorithm, in its optimal-string-alignment form).
///
/// The distance it reports is exactly ``EditDistance/bounded(_:_:maximum:scratch:)``'s: one
/// machine word holds a whole column of the dynamic-programming table, so a candidate costs a
/// handful of instructions per scalar and no memory. Terms longer than 64 scalars do not fit in
/// a word; callers fall back to the table for them.
struct EditPattern {
    /// Scalars in the term.
    let length: Int
    /// Bit `i` of entry `b` is set when scalar `i` of the term is the ASCII scalar `b`.
    private let ascii: [UInt64]
    private let otherScalars: [UInt32]
    private let otherMasks: [UInt64]
    private let last: UInt64

    init?(_ scalars: [UInt32]) {
        guard !scalars.isEmpty, scalars.count <= 64 else { return nil }
        length = scalars.count
        last = 1 << UInt64(scalars.count - 1)
        var ascii = [UInt64](repeating: 0, count: 128)
        var otherScalars: [UInt32] = []
        var otherMasks: [UInt64] = []
        for (position, scalar) in scalars.enumerated() {
            let bit: UInt64 = 1 << UInt64(position)
            if scalar < 128 {
                ascii[Int(scalar)] |= bit
            } else if let index = otherScalars.firstIndex(of: scalar) {
                otherMasks[index] |= bit
            } else {
                otherScalars.append(scalar)
                otherMasks.append(bit)
            }
        }
        self.ascii = ascii
        self.otherScalars = otherScalars
        self.otherMasks = otherMasks
    }

    @inline(__always)
    private func mask(_ scalar: UInt32) -> UInt64 {
        for index in otherScalars.indices where otherScalars[index] == scalar {
            return otherMasks[index]
        }
        return 0
    }

    /// The distance to the term whose normalized UTF-8 bytes are `bytes`, when it is `maximum`
    /// or less; otherwise `nil`.
    func distance(toUTF8 bytes: UnsafeRawBufferPointer, maximum: Int) -> Int? {
        ascii.withUnsafeBufferPointer { table -> Int? in
            var vp = ~UInt64(0)
            var vn: UInt64 = 0
            var d0: UInt64 = 0
            var previous: UInt64 = 0
            var distance = length
            var index = 0
            let count = bytes.count
            while index < count {
                let lead = bytes[index]
                let current: UInt64
                if lead < 0x80 {
                    current = table[Int(lead)]
                    index += 1
                } else {
                    // Stored terms are valid UTF-8; the bounds checks only keep a damaged file
                    // from reading past its section.
                    let width = lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4)
                    guard index + width <= count else { return nil }
                    var scalar: UInt32
                    switch width {
                    case 2:
                        scalar = UInt32(lead & 0x1F) << 6 | UInt32(bytes[index + 1] & 0x3F)
                    case 3:
                        scalar = UInt32(lead & 0x0F) << 12 | UInt32(bytes[index + 1] & 0x3F) << 6 | UInt32(bytes[index + 2] & 0x3F)
                    default:
                        scalar = UInt32(lead & 0x07) << 18 | UInt32(bytes[index + 1] & 0x3F) << 12
                        scalar |= UInt32(bytes[index + 2] & 0x3F) << 6 | UInt32(bytes[index + 3] & 0x3F)
                    }
                    current = mask(scalar)
                    index += width
                }
                let transposition = ((~d0 & current) << 1) & previous
                d0 = ((((current & vp) &+ vp) ^ vp) | current | vn) | transposition
                var hp = vn | ~(d0 | vp)
                var hn = d0 & vp
                if hp & last != 0 { distance += 1 }
                if hn & last != 0 { distance -= 1 }
                hp = (hp << 1) | 1
                hn = hn << 1
                vp = hn | ~(d0 | hp)
                vn = hp & d0
                previous = current
            }
            return distance <= maximum ? distance : nil
        }
    }

    /// The distance to `string`, for tests and for callers that hold no bytes.
    func distance(to string: String, maximum: Int) -> Int? {
        var copy = string
        return copy.withUTF8 { distance(toUTF8: UnsafeRawBufferPointer($0), maximum: maximum) }
    }
}

/// Which scalars a term contains, folded into one word: scalar `s` sets bit `s mod 64`, which
/// keeps the letters of any one alphabet apart (Latin, Cyrillic, Greek, Arabic and Hebrew each
/// span fewer than 64 consecutive code points).
///
/// Two terms within `k` edits differ by at most `k` scalars in each direction: every scalar one
/// has and the other lacks costs an edit of its own. So when more than `k` bits of one
/// signature are missing from the other, the distance need not be computed. Scalars that share
/// a bit only make the test more lenient, never wrong.
enum TermSignature {
    @inline(__always)
    static func bit(_ scalar: UInt32) -> UInt64 {
        1 << UInt64(scalar & 63)
    }

    static func of(_ scalars: [UInt32]) -> UInt64 {
        var signature: UInt64 = 0
        for scalar in scalars { signature |= bit(scalar) }
        return signature
    }

    /// The signature of a term given as valid UTF-8.
    static func of(utf8 bytes: UnsafeRawBufferPointer) -> UInt64 {
        var signature: UInt64 = 0
        var index = 0
        let count = bytes.count
        while index < count {
            let lead = bytes[index]
            if lead < 0x80 {
                signature |= 1 << UInt64(lead & 63)
                index += 1
                continue
            }
            let width = lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4)
            guard index + width <= count else { break }
            // Only the low six bits of the scalar matter, and they are the low six bits of
            // the last byte of its encoding.
            signature |= 1 << UInt64(bytes[index + width - 1] & 0x3F)
            index += width
        }
        return signature
    }

    /// `false` when the two terms cannot be within `maximum` edits of each other.
    @inline(__always)
    static func mayBeWithin(_ maximum: Int, _ a: UInt64, _ b: UInt64) -> Bool {
        (a & ~b).nonzeroBitCount <= maximum && (b & ~a).nonzeroBitCount <= maximum
    }
}

/// Padded character trigrams over the vocabulary: the candidate generator of the fuzzy channel.
///
/// A term of `n` scalars padded with two sentinels on each side has `n + 2` trigrams. One edit
/// destroys at most four of them (a transposition; three for a substitution or a deletion, two
/// for an insertion), so two terms within `k` edits share at least `n + 2 - 4k` trigrams. That
/// bound is at least 1 for every length and edit budget the channel allows except one: a
/// six-scalar term with two edits, where the only pair that shares nothing is the term with its
/// first two and its last two scalars swapped. The generator looks that single variant up
/// directly, which makes "shares a trigram, then verify" lossless against brute force.
enum Trigram {
    /// Sentinel scalar used for padding; never present in normalized text.
    static let pad: UInt32 = 0x1F

    @inline(__always)
    static func key(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt64 {
        (UInt64(a) << 42) | (UInt64(b) << 21) | UInt64(c)
    }

    /// The distinct padded trigrams of a term.
    static func keys(of scalars: [UInt32]) -> [UInt64] {
        guard !scalars.isEmpty else { return [] }
        var padded: [UInt32] = [pad, pad]
        padded.reserveCapacity(scalars.count + 4)
        padded.append(contentsOf: scalars)
        padded.append(pad)
        padded.append(pad)
        var keys: [UInt64] = []
        keys.reserveCapacity(padded.count - 2)
        for index in 0..<(padded.count - 2) {
            keys.append(key(padded[index], padded[index + 1], padded[index + 2]))
        }
        keys.sort()
        var unique: [UInt64] = []
        unique.reserveCapacity(keys.count)
        for key in keys where unique.last != key {
            unique.append(key)
        }
        return unique
    }

    /// Appends the distinct padded trigrams of the term whose normalized UTF-8 bytes are `bytes`,
    /// in ascending order. Nothing is appended for a term of fewer than two scalars: no token
    /// the channel corrects is within its edit budget of one.
    static func appendKeys(ofUTF8 bytes: UnsafeRawBufferPointer, scalars: inout [UInt32], into keys: inout [UInt64]) {
        scalars.removeAll(keepingCapacity: true)
        scalars.append(pad)
        scalars.append(pad)
        var index = 0
        let count = bytes.count
        while index < count {
            let lead = bytes[index]
            if lead < 0x80 {
                scalars.append(UInt32(lead))
                index += 1
                continue
            }
            let width = lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4)
            guard index + width <= count else { break }
            var scalar: UInt32
            switch width {
            case 2:
                scalar = UInt32(lead & 0x1F) << 6 | UInt32(bytes[index + 1] & 0x3F)
            case 3:
                scalar = UInt32(lead & 0x0F) << 12 | UInt32(bytes[index + 1] & 0x3F) << 6 | UInt32(bytes[index + 2] & 0x3F)
            default:
                scalar = UInt32(lead & 0x07) << 18 | UInt32(bytes[index + 1] & 0x3F) << 12
                scalar |= UInt32(bytes[index + 2] & 0x3F) << 6 | UInt32(bytes[index + 3] & 0x3F)
            }
            scalars.append(scalar)
            index += width
        }
        guard scalars.count >= 4 else { return }
        scalars.append(pad)
        scalars.append(pad)
        let first = keys.count
        for position in 0..<(scalars.count - 2) {
            let candidate = key(scalars[position], scalars[position + 1], scalars[position + 2])
            // Insertion into the short sorted run of this term, skipping repeats.
            var slot = keys.count
            var duplicate = false
            while slot > first {
                let existing = keys[slot - 1]
                if existing == candidate { duplicate = true; break }
                if existing < candidate { break }
                slot -= 1
            }
            if !duplicate { keys.insert(candidate, at: slot) }
        }
    }

    /// The one candidate that can share no trigram with a six-scalar term yet sit two edits
    /// away: the term with its first two and its last two scalars swapped.
    static func doubleTranspositionVariant(of scalars: [UInt32]) -> [UInt32]? {
        guard scalars.count == 6, scalars[0] != scalars[1], scalars[4] != scalars[5] else { return nil }
        var variant = scalars
        variant.swapAt(0, 1)
        variant.swapAt(4, 5)
        return variant
    }

    /// `true` when two terms share at least one padded trigram.
    static func shareAny(_ a: [UInt64], _ b: [UInt64]) -> Bool {
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { return true }
            if a[i] < b[j] { i += 1 } else { j += 1 }
        }
        return false
    }
}
