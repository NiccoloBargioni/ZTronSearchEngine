import Foundation

/// One step of text normalization, as Hugging Face `tokenizer.json` files describe them.
enum TextNormalizer: Sendable, Hashable {
    case nfc
    case nfd
    case nfkc
    case nfkd
    case lowercase
    /// Removes combining marks; meant to follow a decomposition.
    case stripAccents
    case strip(left: Bool, right: Bool)
    case replaceString(String, with: String)
    case replaceRegex(String, with: String)
    /// SentencePiece's default normalization (`nmt_nfkc`), which `tokenizer.json` carries as a
    /// precompiled character map.
    ///
    /// The map is not interpreted. It is reproduced by what it was compiled from: Unicode NFKC,
    /// followed by SentencePiece's rules for whitespace and control characters. The two agree
    /// except on a handful of rare code points where SentencePiece deviates from NFKC.
    case sentencePiece
    /// The normalization of BERT tokenizers.
    case bert(cleanText: Bool, handleChineseCharacters: Bool, stripAccents: Bool, lowercase: Bool)
    case sequence([TextNormalizer])

    func apply(_ text: String) -> String {
        switch self {
        case .nfc:
            return text.precomposedStringWithCanonicalMapping
        case .nfd:
            return text.decomposedStringWithCanonicalMapping
        case .nfkc:
            return text.precomposedStringWithCompatibilityMapping
        case .nfkd:
            return text.decomposedStringWithCompatibilityMapping
        case .lowercase:
            return text.lowercased()
        case .stripAccents:
            return Self.removingCombiningMarks(text)
        case .strip(let left, let right):
            var scalars = Substring.UnicodeScalarView(text.unicodeScalars)
            if left {
                while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
            }
            if right {
                while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
            }
            return String(scalars)
        case .replaceString(let pattern, let content):
            return pattern.isEmpty ? text : text.replacingOccurrences(of: pattern, with: content)
        case .replaceRegex(let pattern, let content):
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
            return expression.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: content)
            )
        case .sentencePiece:
            return Self.sentencePieceNormalized(text)
        case .bert(let cleanText, let handleChineseCharacters, let stripAccents, let lowercase):
            var result = text
            if cleanText { result = Self.bertCleaned(result) }
            if handleChineseCharacters { result = Self.spacingIdeographs(result) }
            if stripAccents { result = Self.removingCombiningMarks(result.decomposedStringWithCanonicalMapping) }
            if lowercase { result = result.lowercased() }
            return result
        case .sequence(let steps):
            return steps.reduce(text) { $1.apply($0) }
        }
    }

    /// `true` when every regular expression of the pipeline compiles.
    var isValid: Bool {
        switch self {
        case .replaceRegex(let pattern, _):
            return (try? NSRegularExpression(pattern: pattern)) != nil
        case .sequence(let steps):
            return steps.allSatisfy(\.isValid)
        default:
            return true
        }
    }

    private static func removingCombiningMarks(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar.properties.generalCategory != .nonspacingMark {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func sentencePieceNormalized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0C, 0x0D, 0x1680, 0x200B...0x200F, 0x2028, 0x2029, 0x2581, 0xFEFF, 0xFFFD:
                // Tabs, line breaks, zero-width characters, the metaspace marker itself and the
                // replacement character all become a plain space.
                scalars.append(" ")
            case 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F, 0x8F, 0x9F:
                continue
            default:
                scalars.append(scalar.properties.isWhitespace ? " " : scalar)
            }
        }
        return String(scalars)
    }

    private static func bertCleaned(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD { continue }
            if scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar.properties.generalCategory == .spaceSeparator {
                scalars.append(" ")
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Puts a space on both sides of every CJK ideograph, so each becomes a word of its own.
    private static func spacingIdeographs(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isIdeograph(scalar) {
                scalars.append(" ")
                scalars.append(scalar)
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func isIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F,
             0x2B740...0x2B81F, 0x2B820...0x2CEAF, 0xF900...0xFAFF, 0x2F800...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

/// Where a metaspace pre-tokenizer puts its marker in front of a text.
enum MetaspacePrepend: Sendable, Hashable {
    /// In front of every piece that does not start with one.
    case always
    /// Only in front of the first piece.
    case first
    case never
}

/// One step that cuts normalized text into the pieces a model segments one by one.
enum TextPreTokenizer: Sendable, Hashable {
    /// Cuts at whitespace.
    case whitespaceSplit
    /// Cuts at whitespace and makes every punctuation mark a piece of its own, as BERT does.
    case bert
    /// The SentencePiece convention: spaces become the marker `▁`, which stays attached to the
    /// word that follows it.
    case metaspace(marker: Unicode.Scalar, prepend: MetaspacePrepend, split: Bool)
    case sequence([TextPreTokenizer])

    func apply(_ pieces: [String]) -> [String] {
        switch self {
        case .whitespaceSplit:
            return pieces.flatMap(Self.splitAtWhitespace)
        case .bert:
            return pieces.flatMap(Self.splitAtWhitespace).flatMap(Self.splitAtPunctuation)
        case .metaspace(let marker, let prepend, let split):
            var result: [String] = []
            for (index, piece) in pieces.enumerated() {
                var scalars = String.UnicodeScalarView()
                let needsMarker = prepend == .always || (prepend == .first && index == 0)
                if needsMarker, let first = piece.unicodeScalars.first, first != marker, first != " " {
                    scalars.append(marker)
                }
                for scalar in piece.unicodeScalars {
                    scalars.append(scalar == " " ? marker : scalar)
                }
                guard split else {
                    if !scalars.isEmpty { result.append(String(scalars)) }
                    continue
                }
                // Every marker starts a new piece and stays in front of it.
                var current = String.UnicodeScalarView()
                for scalar in scalars {
                    if scalar == marker, !current.isEmpty {
                        result.append(String(current))
                        current = String.UnicodeScalarView()
                    }
                    current.append(scalar)
                }
                if !current.isEmpty { result.append(String(current)) }
            }
            return result
        case .sequence(let steps):
            return steps.reduce(pieces) { $1.apply($0) }
        }
    }

    private static func splitAtWhitespace(_ text: String) -> [String] {
        text.unicodeScalars
            .split(whereSeparator: { $0.properties.isWhitespace })
            .map { String(String.UnicodeScalarView($0)) }
    }

    private static func splitAtPunctuation(_ word: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in word.unicodeScalars {
            if isPunctuation(scalar) {
                if !current.isEmpty {
                    result.append(String(current))
                    current = String.UnicodeScalarView()
                }
                result.append(String(scalar))
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    /// BERT's notion of punctuation: every ASCII symbol, and the Unicode punctuation categories.
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 33...47, 58...64, 91...96, 123...126:
            return true
        default:
            break
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }
}
