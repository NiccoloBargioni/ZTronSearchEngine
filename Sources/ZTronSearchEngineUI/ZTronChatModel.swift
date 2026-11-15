import Combine
import Foundation
import SwiftUI
import ZTronSearchEngine

/// One entry of a chat transcript: role, text, sources, citations.
public struct ChatTranscriptEntry<Kind: SearchItemKind>: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let role: ChatMessage.Role
    public var text: String
    /// What the answer was grounded in. Kind-aware, so a cited map opens as a map and a cited
    /// tip as a tip through the same kind switch as the results rows.
    public var sources: [SearchHit<Kind>]
    /// The sources the answer actually cited, in order of first mention.
    public var citations: [SearchableID]

    public init(id: UUID = UUID(), role: ChatMessage.Role, text: String, sources: [SearchHit<Kind>] = [], citations: [SearchableID] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.sources = sources
        self.citations = citations
    }
}

/// Chat readiness, transcript and generation (specification section 14.5).
///
/// No chat view ships. The host owns this model with `@StateObject`, attaches it to its own
/// screen with `.zTronChat`, and builds the transcript, the composer, the readiness card and the
/// source chips from the published state.
@MainActor
public final class ZTronChatModel<Schema: SearchSchema>: ObservableObject {
    @Published public private(set) var readiness: ChatReadiness
    /// Role, text, sources, citations.
    @Published public private(set) var transcript: [ChatTranscriptEntry<Schema.Kind>] = []
    @Published public private(set) var isGenerating = false
    /// Why the last message did not complete, when it did not. Cleared by the next send.
    @Published public private(set) var lastError: ChatError?

    private let chat: ChatService<Schema>?
    private let system: String?
    private let grounding: ChatGrounding<Schema.Kind>
    private var session: ChatSessionID?
    private var gateCheck: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var generation: Task<Void, Never>?
    private var turn: UInt64 = 0
    private var didPrepare = false

    /// - Parameter chat: the facade's chat service. `nil` when either boundary is absent, for
    ///   example below iOS 17 where no runtime is linked: readiness is then
    ///   `.unavailable(.device)` and the host shows no entry point.
    public init(
        chat: ChatService<Schema>?,
        system: String? = nil,
        grounding: ChatGrounding<Schema.Kind> = .corpus(topK: 6, kinds: nil)
    ) {
        self.chat = chat
        self.system = system
        self.grounding = grounding
        readiness = chat == nil ? .unavailable(.device) : .checking
        if let chat {
            // The device gate is known without touching the asset provider.
            gateCheck = Task { [weak self] in
                let gate = await chat.gate()
                // Once a preparation was asked for, its stream is the only source of readiness.
                guard let self, !Task.isCancelled, !self.didPrepare else { return }
                self.readiness = gate
            }
        }
    }

    deinit {
        gateCheck?.cancel()
        preparation?.cancel()
        generation?.cancel()
    }

    /// Makes the model ready under a download policy, publishing every step.
    public func prepare(policy: DownloadPolicy) {
        guard let chat else { return }
        didPrepare = true
        gateCheck?.cancel()
        preparation?.cancel()
        preparation = Task { [weak self] in
            for await state in await chat.prepare(policy: policy) {
                guard let self, !Task.isCancelled else { return }
                self.readiness = state
            }
            self?.preparation = nil
        }
    }

    /// Sends a message and streams the answer into the transcript.
    public func send(_ text: String) {
        guard let chat, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        generation?.cancel()
        turn &+= 1
        let turn = turn
        lastError = nil
        transcript.append(ChatTranscriptEntry(role: .user, text: text))
        let answer = ChatTranscriptEntry<Schema.Kind>(role: .assistant, text: "")
        transcript.append(answer)
        isGenerating = true

        generation = Task { [weak self] in
            guard let session = await self?.sessionID(in: chat) else { return }
            do {
                for try await event in await chat.send(text, in: session) {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(event, to: answer.id)
                }
            } catch is CancellationError {
                // The transcript keeps what was said before the cancel.
            } catch let failure as ChatError {
                self?.fail(failure, turn: turn)
            } catch {
                self?.fail(.generationFailed(String(describing: error)), turn: turn)
            }
            self?.finish(turn: turn)
        }
    }

    /// Cancels the generation in flight.
    public func cancel() {
        guard isGenerating else { return }
        generation?.cancel()
        generation = nil
        isGenerating = false
        if let chat, let session {
            Task { await chat.cancel(session) }
        }
    }

    private func sessionID(in chat: ChatService<Schema>) async -> ChatSessionID {
        if let session { return session }
        let created = await chat.newSession(system: system, grounding: grounding)
        if let existing = session { return existing }
        session = created
        return created
    }

    private func apply(_ event: ChatEvent<Schema.Kind>, to id: UUID) {
        guard let index = transcript.lastIndex(where: { $0.id == id }) else { return }
        switch event {
        case .sources(let hits):
            transcript[index].sources = hits
        case .delta(let delta):
            transcript[index].text += delta
        case .citation(let source):
            if !transcript[index].citations.contains(source) { transcript[index].citations.append(source) }
        case .finished:
            break
        }
    }

    private func fail(_ failure: ChatError, turn: UInt64) {
        guard turn == self.turn else { return }
        lastError = failure
        if case .notReady(let state) = failure { readiness = state }
    }

    private func finish(turn: UInt64) {
        guard turn == self.turn else { return }
        isGenerating = false
        generation = nil
    }
}
