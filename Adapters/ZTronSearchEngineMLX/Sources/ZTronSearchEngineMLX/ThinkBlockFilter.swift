import Foundation

/// Removes `<think>…</think>` blocks from text that arrives in pieces.
///
/// The model decodes one token at a time, so a tag can be split anywhere: `"<th"` in one piece and
/// `"ink>"` in the next. The filter therefore holds back any tail that could still become a tag and
/// releases it only once the following pieces decide the matter.
///
/// Rules:
/// - Everything between an opening tag and its matching closing tag is dropped, tags included.
/// - Blocks nest: an opening tag inside a block needs its own closing tag.
/// - A block that is never closed swallows the rest of the text.
/// - A closing tag with no block open is dropped on its own.
/// - Whitespace that directly follows a block is dropped when nothing but whitespace came before
///   the block, so a reply that starts with a block does not start with blank lines.
///
/// Tags are matched exactly, Unicode scalar by Unicode scalar. The filter is a plain value with no
/// dependency on the model: feed it with ``consume(_:)`` and call ``finish()`` once at the end of
/// the stream.
public struct ThinkBlockFilter: Sendable, Equatable {
    /// The tag that opens a block.
    public let openTag: String
    /// The tag that closes a block.
    public let closeTag: String

    private let openScalars: [Unicode.Scalar]
    private let closeScalars: [Unicode.Scalar]

    /// Text received but not yet classified: a possible start of a tag.
    private var pending: [Unicode.Scalar] = []
    /// How many blocks are open.
    private var depth = 0
    /// `true` once text other than whitespace has been returned.
    private var hasEmittedText = false
    /// `true` while whitespace after a leading block is being dropped.
    private var isDroppingWhitespace = false

    /// Creates a filter for the given tags. Both must be non-empty and different.
    public init(openTag: String = "<think>", closeTag: String = "</think>") {
        precondition(
            !openTag.isEmpty && !closeTag.isEmpty && openTag != closeTag,
            "ThinkBlockFilter needs two distinct, non-empty tags"
        )
        self.openTag = openTag
        self.closeTag = closeTag
        self.openScalars = Array(openTag.unicodeScalars)
        self.closeScalars = Array(closeTag.unicodeScalars)
    }

    /// `true` while the text consumed so far ends inside a block.
    public var isInsideBlock: Bool { depth > 0 }

    /// Feeds the next piece of text and returns what may be shown now.
    ///
    /// The result can be empty: the piece was inside a block, or it ends with characters that
    /// might be the start of a tag.
    public mutating func consume(_ piece: String) -> String {
        pending.append(contentsOf: piece.unicodeScalars)
        var visible = String.UnicodeScalarView()

        while true {
            guard let tag = firstTag() else {
                // No complete tag: release everything except a tail that may still become one.
                let cut = pending.count - heldSuffixLength()
                if depth == 0 {
                    emit(pending[..<cut], into: &visible)
                }
                pending.removeFirst(cut)
                break
            }

            if depth == 0 {
                emit(pending[..<tag.start], into: &visible)
            }
            pending.removeFirst(tag.start + tag.length)

            if tag.isOpening {
                depth += 1
            } else if depth > 0 {
                depth -= 1
                if depth == 0 && !hasEmittedText {
                    isDroppingWhitespace = true
                }
            }
            // A closing tag outside a block is dropped and changes nothing else.
        }

        return String(visible)
    }

    /// Ends the stream and returns the text that was still held back.
    ///
    /// Outside a block, a held tail is ordinary text (a `<` that never became a tag). Inside a
    /// block it belongs to the unterminated block and is dropped. The filter is reset afterwards
    /// and can be reused.
    public mutating func finish() -> String {
        var visible = String.UnicodeScalarView()
        if depth == 0 {
            emit(pending[...], into: &visible)
        }
        pending.removeAll(keepingCapacity: true)
        depth = 0
        hasEmittedText = false
        isDroppingWhitespace = false
        return String(visible)
    }

    // MARK: - Private

    private struct Tag {
        let start: Int
        let length: Int
        let isOpening: Bool
    }

    /// The earliest complete tag in `pending`.
    private func firstTag() -> Tag? {
        guard !pending.isEmpty else { return nil }
        for start in pending.indices {
            let rest = pending[start...]
            if rest.starts(with: openScalars) {
                return Tag(start: start, length: openScalars.count, isOpening: true)
            }
            if rest.starts(with: closeScalars) {
                return Tag(start: start, length: closeScalars.count, isOpening: false)
            }
        }
        return nil
    }

    /// Length of the longest tail of `pending` that is a proper prefix of a tag.
    private func heldSuffixLength() -> Int {
        let longest = min(pending.count, max(openScalars.count, closeScalars.count) - 1)
        guard longest > 0 else { return 0 }
        for length in stride(from: longest, through: 1, by: -1) {
            let tail = pending.suffix(length)
            if (length < openScalars.count && openScalars.starts(with: tail))
                || (length < closeScalars.count && closeScalars.starts(with: tail))
            {
                return length
            }
        }
        return 0
    }

    /// Appends `scalars` to `visible`, dropping whitespace that follows a leading block.
    private mutating func emit(_ scalars: ArraySlice<Unicode.Scalar>, into visible: inout String.UnicodeScalarView) {
        var scalars = scalars
        if isDroppingWhitespace {
            scalars = scalars.drop(while: { $0.properties.isWhitespace })
            guard !scalars.isEmpty else { return }
            isDroppingWhitespace = false
        }
        guard !scalars.isEmpty else { return }
        if !hasEmittedText && scalars.contains(where: { !$0.properties.isWhitespace }) {
            hasEmittedText = true
        }
        visible.append(contentsOf: scalars)
    }
}
