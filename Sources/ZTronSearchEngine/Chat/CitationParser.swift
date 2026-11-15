import Foundation

/// Finds `[kind:id]` citations in a stream of generated text (specification section 14.3).
///
/// Text arrives in arbitrary pieces, so a marker can straddle any number of deltas. The parser
/// holds back only what could still become a marker, and releases everything else at once.
/// Markers never reach the transcript text: one that names a source becomes a citation, one
/// that does not is dropped (and reported by the caller).
struct CitationParser {
    enum Output: Equatable {
        case text(String)
        /// A `[kind:id]` whose id is among the sources.
        case citation(SearchableID)
        /// A `[kind:id]` whose id is not among the sources. Dropped from the text.
        case unknown(String)
    }

    /// Longest marker body the parser waits for before deciding the bracket is ordinary text.
    static let maximumMarkerLength = 160

    private let sources: Set<SearchableID>
    private let isKind: (String) -> Bool
    /// Text after an unclosed `[`, bracket included.
    private var pending = ""

    /// - Parameters:
    ///   - sources: ids that may be cited.
    ///   - isKind: whether a string is the raw value of one of the schema's kinds. A bracket is
    ///     a citation attempt only when it opens with one, so `[1]` or a Markdown link passes
    ///     through untouched.
    init(sources: Set<SearchableID>, isKind: @escaping (String) -> Bool) {
        self.sources = sources
        self.isKind = isKind
    }

    mutating func consume(_ delta: String) -> [Output] {
        var outputs: [Output] = []
        var text = ""
        func flushText() {
            if !text.isEmpty {
                outputs.append(.text(text))
                text = ""
            }
        }
        for character in delta {
            if pending.isEmpty {
                if character == "[" {
                    pending = "["
                } else {
                    text.append(character)
                }
                continue
            }
            if character == "]" {
                let body = String(pending.dropFirst())
                pending = ""
                if let marker = marker(in: body) {
                    flushText()
                    outputs.append(sources.contains(marker) ? .citation(marker) : .unknown(marker.rawValue))
                } else {
                    text.append("[" + body + "]")
                }
                continue
            }
            if character == "[" || character.isNewline || pending.count > Self.maximumMarkerLength {
                // Not a marker after all: release what was held, and start over on a new bracket.
                text.append(pending)
                pending = ""
                if character == "[" {
                    pending = "["
                } else {
                    text.append(character)
                }
                continue
            }
            pending.append(character)
            // Once the part before the colon is not a kind, the bracket is ordinary text.
            if character == ":", !isKind(String(pending.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)) {
                text.append(pending)
                pending = ""
            }
        }
        flushText()
        return outputs
    }

    /// The end of the stream: whatever was held back is ordinary text.
    mutating func finish() -> [Output] {
        guard !pending.isEmpty else { return [] }
        defer { pending = "" }
        return [.text(pending)]
    }

    /// The id of a `kind:id` body, when its kind is one of the schema's.
    private func marker(in body: String) -> SearchableID? {
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let kind = body[..<colon].trimmingCharacters(in: .whitespaces)
        let id = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard isKind(kind), !id.isEmpty else { return nil }
        return SearchableID(id)
    }
}

/// Assembles a grounded prompt inside the token budget (specification section 14.3, step 2).
///
/// Order: host system prompt, grounding instructions, the sources block, history trimmed
/// oldest-first, then the message. The message and the sources are never trimmed; history is.
struct PromptAssembler {
    static let groundingInstructions = """
        Answer only from the sources below. Cite every source you use as [kind:id], exactly as it is \
        written in the sources. If the sources do not cover the question, say that they do not and do not guess.
        """

    static let ungroundedInstructions = "Answer from the conversation alone."

    struct Assembly: Equatable {
        var messages: [ChatMessage]
        var promptTokens: Int
        /// History messages left out, oldest first.
        var droppedHistory: Int
    }

    enum Failure: Error, Equatable {
        /// The system prompt, the sources and the message alone exceed the budget.
        case exceedsBudget(required: Int, budget: Int)
    }

    /// Tokens available to the prompt: `contextWindow - maxNewTokens - margin`.
    let budget: Int
    let countTokens: (String) async -> Int

    func assemble(system: String?, sources: [String], grounded: Bool, history: [ChatMessage], message: String) async throws -> Assembly {
        var systemParts: [String] = []
        if let system = SearchProjector.nonEmpty(system) { systemParts.append(system) }
        if grounded {
            systemParts.append(Self.groundingInstructions)
            systemParts.append("Sources:\n" + (sources.isEmpty ? "(none)" : sources.joined(separator: "\n")))
        } else {
            systemParts.append(Self.ungroundedInstructions)
        }
        let systemMessage = ChatMessage(role: .system, content: systemParts.joined(separator: "\n\n"))
        let userMessage = ChatMessage(role: .user, content: message)

        let fixed = await countTokens(systemMessage.content) + countTokens(userMessage.content)
        guard fixed <= budget else { throw Failure.exceedsBudget(required: fixed, budget: budget) }

        // Keep the most recent history that fits; drop from the oldest end.
        var kept: [ChatMessage] = []
        var used = fixed
        for entry in history.reversed() {
            let cost = await countTokens(entry.content)
            if used + cost > budget { break }
            used += cost
            kept.append(entry)
        }
        kept.reverse()
        return Assembly(
            messages: [systemMessage] + kept + [userMessage],
            promptTokens: used,
            droppedHistory: history.count - kept.count
        )
    }

    /// Cuts a rendered source down to `limit` tokens, on a word boundary.
    static func truncate(_ text: String, toTokens limit: Int, countTokens: (String) async -> Int) async -> String {
        if await countTokens(text) <= limit { return text }
        let words = text.split(whereSeparator: \.isWhitespace)
        var low = 0
        var high = words.count
        // The longest prefix of words that fits.
        while low < high {
            let middle = (low + high + 1) / 2
            if await countTokens(words[..<middle].joined(separator: " ")) <= limit {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return words[..<low].joined(separator: " ")
    }
}
