import Foundation

/// Text normalization (specification section 5, rule 4).
///
/// NFKC, then `folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
/// locale:)`, per field language. The original string is kept by the caller for highlighting.
///
/// One step follows the specification's two: the dotless `ı` (U+0131) folds to `i`. Foundation's
/// folding leaves `ı` alone because it has no canonical decomposition, which makes
/// case-insensitivity incoherent for Turkish and Azeri: under a `tr` locale `İstanbul` folds to
/// `ıstanbul` while the typed `istanbul` stays `istanbul`, and under any other locale `IŞIK`
/// folds to `isik` while `ışık` folds to `ısık`. Folding `ı` to `i` treats the dot the way the
/// rule already treats every other diacritic, and makes the result independent of that quirk.
public enum SearchNormalizer {
    /// Recorded in persisted index files; a mismatch discards the file and rebuilds.
    public static let version = 1

    static let foldingOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Normalizes text for matching.
    public static func normalize(_ string: String, locale: Locale? = nil) -> String {
        var utf8 = string.utf8
        if let fast = utf8.withContiguousStorageIfAvailable({ asciiFold($0) }) ?? asciiFoldSlow(&utf8) {
            return fast
        }
        let composed = string.precomposedStringWithCompatibilityMapping
        let folded = composed.folding(options: foldingOptions, locale: locale)
        guard folded.unicodeScalars.contains(where: { $0.value == 0x0131 }) else { return folded }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(folded.unicodeScalars.count)
        for scalar in folded.unicodeScalars {
            scalars.append(scalar.value == 0x0131 ? "i" : scalar)
        }
        return String(scalars)
    }

    /// Normalizes text in the language named by a BCP 47 tag.
    public static func normalize(_ string: String, language: String?) -> String {
        normalize(string, locale: language.map { Locale(identifier: $0) })
    }

    /// ASCII needs neither NFKC nor diacritic or width folding, and with `ı` folded to `i` its
    /// case folding is the same in every locale: plain lowercasing. `nil` when the bytes are not
    /// all ASCII.
    private static func asciiFold(_ bytes: UnsafeBufferPointer<UInt8>) -> String? {
        var needsLowercasing = false
        for byte in bytes {
            if byte >= 0x80 { return nil }
            if byte >= 0x41 && byte <= 0x5A { needsLowercasing = true }
        }
        if !needsLowercasing {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(unsafeUninitializedCapacity: bytes.count) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
            }
            return bytes.count
        }
    }

    private static func asciiFoldSlow(_ utf8: inout String.UTF8View) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(utf8.count)
        for byte in utf8 {
            if byte >= 0x80 { return nil }
            bytes.append((byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Unicode classification the tokenizer and the fuzzy channel share.
enum ScriptClass {
    /// `true` for scalars of scripts written without word spacing (CJK, Thai and their kin).
    /// Fields in these scripts also emit character bigrams so prefix matching works.
    @inline(__always)
    static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0E7F,     // Thai
             0x0E80...0x0EFF,     // Lao
             0x1000...0x109F,     // Myanmar
             0x1780...0x17FF,     // Khmer
             0x2E80...0x2FDF,     // CJK radicals
             0x3005...0x3007,     // iteration mark, ideographic zero
             0x3040...0x309F,     // Hiragana
             0x30A0...0x30FF,     // Katakana
             0x31F0...0x31FF,     // Katakana phonetic extensions
             0x3400...0x4DBF,     // CJK extension A
             0x4E00...0x9FFF,     // CJK unified ideographs
             0xF900...0xFAFF,     // CJK compatibility ideographs
             0xFF66...0xFF9F,     // halfwidth Katakana
             0x20000...0x2FA1F,   // CJK extensions B and beyond
             0x30000...0x3134F:
            return true
        default:
            return false
        }
    }

    @inline(__always)
    static func isUnspaced(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        return isUnspaced(first)
    }

    /// `true` when a normalized term must match exactly only: it contains a digit or one of
    /// `-`, `_`, `.` (IDs, URLs, model numbers). Such terms are never fuzzed and never reached
    /// by prefix expansion.
    static func isExactOnly(_ term: String) -> Bool {
        for byte in term.utf8 {
            switch byte {
            case 0x30...0x39, 0x2D, 0x5F, 0x2E:
                return true
            default:
                continue
            }
        }
        // Non-ASCII decimal digits (Arabic-Indic, Devanagari, ...) survive NFKC.
        if term.utf8.contains(where: { $0 >= 0x80 }) {
            return term.unicodeScalars.contains { $0.properties.numericType == .decimal }
        }
        return false
    }

    /// ``isExactOnly(_:)`` over the UTF-8 bytes of a normalized term.
    static func isExactOnly(utf8 bytes: UnsafeRawBufferPointer) -> Bool {
        var hasNonASCII = false
        for byte in bytes {
            switch byte {
            case 0x30...0x39, 0x2D, 0x5F, 0x2E: return true
            case 0x80...0xFF: hasNonASCII = true
            default: continue
            }
        }
        return hasNonASCII && isExactOnly(String(decoding: bytes, as: UTF8.self))
    }

    /// The characters that join the parts of an identifier: `m1911-a1`, `ray_gun`, `example.com`.
    @inline(__always)
    static func isConnector(_ character: Character) -> Bool {
        character == "-" || character == "_" || character == "." || character == "\u{2010}" || character == "\u{2011}"
    }
}
