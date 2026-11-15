import Combine
import Foundation
import SwiftUI
import ZTronSearchEngine

/// The throttled query, its snapshots and paging (specification section 13).
///
/// The host owns the model with `@StateObject`; the package attaches it to the host's own views
/// through modifiers. State is split into narrowly scoped models because on iOS 15 any
/// `@Published` mutation invalidates every view observing that object.
@MainActor
public final class ZTronSearchResultsModel<Schema: SearchSchema>: ObservableObject {
    @Published public private(set) var hits: [SearchHit<Schema.Kind>] = []
    /// `.lexical`, `.semantic`, `.reranked`; `nil` before the first snapshot.
    @Published public private(set) var phase: SearchPhase?
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasMore = false
    @Published public private(set) var degraded: Set<SearchChannel> = []
    @Published public private(set) var error: SearchError?

    /// Derived, for sectioned layouts: one section per class, fused order kept inside each.
    public var hitsByKind: [Schema.Kind: [SearchHit<Schema.Kind>]] {
        Dictionary(grouping: hits, by: \.kind)
    }

    /// The query the published hits answer.
    public private(set) var query = SearchQuery<Schema>(text: "")

    private enum Backend {
        case service(SearchService<Schema>)
        case scan(ScanIndex<Schema>)
    }

    private let backend: Backend
    /// Bumped by every change of query: the model's own generation.
    private var revision: UInt64 = 0
    private var searchTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    /// Generation of the service snapshot the cursor belongs to.
    private var snapshotGeneration: UInt64 = 0
    private var nextCursor: SearchCursor?
    private var cursorInFlight: SearchCursor?
    /// Page requests actually issued; a repeated trigger for the same cursor issues none.
    public private(set) var pageRequestCount = 0

    public init(service: SearchService<Schema>) {
        backend = .service(service)
    }

    /// A model over a scan index: no debounce and no actor hop at all. Every update publishes
    /// the single final snapshot before it returns.
    public init(scan: ScanIndex<Schema>) {
        backend = .scan(scan)
    }

    deinit {
        searchTask?.cancel()
        pageTask?.cancel()
    }

    // MARK: Querying

    /// Searches for the field's text and tokens: cancels the prior stream and bumps the
    /// generation. Returns early when the query did not change, so re-renders cost nothing.
    public func update(text: String, tokens: [ZTronSearchToken<Schema>]) {
        var next = SearchQuery<Schema>(text: text, tokens: tokens)
        next.limit = query.limit
        guard next != query else { return }
        start(next, trigger: .typing)
    }

    /// Runs the semantic and rerank phases immediately.
    public func submit() {
        start(query, trigger: .submit)
    }

    /// Hits per page. Changing it takes effect with the next query.
    public var pageSize: Int {
        get { query.limit }
        set { query.limit = max(1, newValue) }
    }

    /// Cancels everything in flight and clears the results.
    public func reset() {
        revision &+= 1
        searchTask?.cancel()
        searchTask = nil
        cancelPaging()
        query = SearchQuery<Schema>(text: "")
        hits = []
        phase = nil
        degraded = []
        error = nil
        hasMore = false
        isLoading = false
        if case .service(let service) = backend {
            Task { await service.cancel() }
        }
    }

    private func start(_ next: SearchQuery<Schema>, trigger: SearchTrigger) {
        revision &+= 1
        let revision = revision
        query = next
        searchTask?.cancel()
        // A query change cancels any page in flight and clears the cursor.
        cancelPaging()
        if error != nil { error = nil }

        switch backend {
        case .scan(let index):
            searchTask = nil
            apply(index.snapshot(for: next, generation: revision), revision: revision)
        case .service(let service):
            // Loading from the first keystroke until the final snapshot or a cancellation.
            if !isLoading { isLoading = true }
            searchTask = Task { [weak self] in
                let stream = await service.results(for: next, trigger: trigger)
                for await snapshot in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(snapshot, revision: revision)
                }
                self?.streamEnded(revision: revision)
            }
        }
    }

    /// The UI boundary: a snapshot is published only when it belongs to the current generation
    /// and its query equals the current query.
    private func apply(_ snapshot: SearchSnapshot<Schema>, revision: UInt64) {
        guard revision == self.revision, snapshot.query == query else { return }
        // Publish only what changed: on iOS 15 every `@Published` write invalidates every observer.
        if hits != snapshot.hits { hits = snapshot.hits }
        if phase != snapshot.phase { phase = snapshot.phase }
        if degraded != snapshot.degraded { degraded = snapshot.degraded }
        if snapshot.isFinal {
            snapshotGeneration = snapshot.generation
            nextCursor = snapshot.nextCursor
            if hasMore != (snapshot.nextCursor != nil) { hasMore = snapshot.nextCursor != nil }
            if isLoading { isLoading = false }
        }
    }

    /// Applies a snapshot as if the current stream had delivered it. For tests of the UI boundary.
    func applyForTesting(_ snapshot: SearchSnapshot<Schema>) {
        apply(snapshot, revision: revision)
    }

    private func streamEnded(revision: UInt64) {
        guard revision == self.revision, isLoading else { return }
        isLoading = false
    }

    // MARK: Paging

    /// Loads the next page in its own cancellable task. Guarded by generation and cursor, so a
    /// request for the same page is never duplicated, however early or often the trigger fires.
    public func loadNextPage() {
        guard let cursor = nextCursor, cursorInFlight != cursor else { return }
        let revision = revision
        cursorInFlight = cursor
        pageRequestCount += 1

        switch backend {
        case .scan(let index):
            var paged = query
            paged.cursor = cursor
            append(index.snapshot(for: paged, generation: revision), after: cursor, revision: revision)
        case .service(let service):
            let generation = snapshotGeneration
            pageTask = Task { [weak self] in
                do {
                    let page = try await service.page(after: cursor, generation: generation)
                    guard !Task.isCancelled else { return }
                    self?.append(page, after: cursor, revision: revision)
                } catch let failure as SearchError {
                    self?.pageFailed(failure, cursor: cursor, revision: revision)
                } catch {
                    self?.pageFailed(.unsupported(String(describing: error)), cursor: cursor, revision: revision)
                }
            }
        }
    }

    private func append(_ page: SearchSnapshot<Schema>, after cursor: SearchCursor, revision: UInt64) {
        guard revision == self.revision, nextCursor == cursor else { return }
        hits.append(contentsOf: page.hits)
        nextCursor = page.nextCursor
        hasMore = page.nextCursor != nil
        cursorInFlight = nil
        pageTask = nil
    }

    private func pageFailed(_ failure: SearchError, cursor: SearchCursor, revision: UInt64) {
        guard revision == self.revision, nextCursor == cursor else { return }
        cursorInFlight = nil
        pageTask = nil
        // A stale generation means the query moved on; that is not an error to show.
        if failure == .staleGeneration {
            nextCursor = nil
            hasMore = false
        } else {
            error = failure
        }
    }

    private func cancelPaging() {
        pageTask?.cancel()
        pageTask = nil
        nextCursor = nil
        cursorInFlight = nil
        if hasMore { hasMore = false }
    }
}

/// Autocomplete suggestions, paged (specification section 13).
@MainActor
public final class ZTronSuggestionsModel<Schema: SearchSchema>: ObservableObject {
    @Published public private(set) var suggestions: [SearchSuggestion] = []
    /// `true` while another page may exist.
    @Published public private(set) var hasMore = false

    private let service: SearchService<Schema>
    private let minimumQueryLength: Int
    private let pageSize: Int
    private let debounce: TimeInterval
    private var prefix = ""
    private var revision: UInt64 = 0
    private var pages = 0
    private var task: Task<Void, Never>?
    /// Calls made to the service; none are made below the minimum query length.
    public private(set) var requestCount = 0

    /// - Parameter debounce: suggestions share the lexical timer, 120 ms.
    public init(service: SearchService<Schema>, minimumQueryLength: Int = 2, pageSize: Int = 10, debounce: TimeInterval = 0.120) {
        self.service = service
        self.minimumQueryLength = max(1, minimumQueryLength)
        self.pageSize = max(1, pageSize)
        self.debounce = max(0, debounce)
    }

    deinit {
        task?.cancel()
    }

    /// Suggests for a typed prefix. Disabled below `minimumQueryLength`.
    public func update(prefix: String) {
        guard prefix != self.prefix else { return }
        self.prefix = prefix
        revision &+= 1
        task?.cancel()
        pages = 0
        guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumQueryLength else {
            suggestions = []
            hasMore = false
            return
        }
        load(pages: 1, delay: debounce)
    }

    /// Loads one more page of at most `pageSize` suggestions.
    public func loadNextPage() {
        guard hasMore, task == nil else { return }
        load(pages: pages + 1, delay: 0)
    }

    private func load(pages target: Int, delay: TimeInterval) {
        let revision = revision
        let prefix = prefix
        let limit = pageSize * target
        let service = service
        task = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            self?.requestCount += 1
            let result = await service.suggestions(for: prefix, limit: limit)
            guard let self, !Task.isCancelled, revision == self.revision else { return }
            self.suggestions = result
            self.pages = target
            self.hasMore = result.count == limit
            self.task = nil
        }
    }
}
