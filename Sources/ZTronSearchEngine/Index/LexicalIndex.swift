import Foundation

/// The BM25F index (specification sections 7.1 and 9).
///
/// The index is a short list of immutable segments. Every segment has the same layout whether
/// it was just built in memory or memory-mapped from disk: a sorted vocabulary,
/// varint-compressed postings per field, per-field document lengths, a document store, a
/// trigram index and the term list of every document.
///
/// Indexing is incremental. An upsert builds a small segment for the documents that actually
/// changed and marks the versions it replaces as deleted in the older segments; a removal only
/// marks. A deletion adjusts the statistics of exactly the terms the document held, read from
/// its stored term list, and segments are merged at the posting level in tiers, so after any
/// sequence of upserts and removals the index scores exactly like one built from the live
/// documents alone. Nothing is rebuilt and nothing is tokenized twice for a mutation to take
/// effect.
///
/// Queries are never held up by a mutation: tokenization, segment building and merging of more
/// than a handful of documents run off the actor, and the result is swapped in between two
/// queries. Nor is a mutation held up by merging: an upsert returns once its documents are
/// searchable, and the segments are brought back into their tiers behind it.
public actor LexicalIndex {
    /// Batches up to this size are tokenized and built on the actor: less than a millisecond.
    static let inlineLimit = 64
    /// Larger batches are cut into chunks this big, tokenized and built in parallel.
    static let chunkSize = 4_096
    /// Merges of at most this many live documents run on the actor.
    static let inlineMergeLimit = 256
    /// Segments are merged when this many share a size tier; tier `t` holds 4^t to 4^(t+1) - 1
    /// documents, so every document is rewritten once per tier it passes through.
    static let tierFanout = 4
    /// A backstop only: the tiers of an index of a million documents hold fewer segments.
    static let maximumSegments = 32
    /// More segments than this and an idle index is worth folding into one (``compact()``).
    static let comfortableSegments = 6

    private var entries: [IndexEntry] = []
    private var storedMetadata = IndexMetadata()
    private var searcher = IndexSearcher()
    private let tokenizer = TokenizerSession()
    private var mutationLock = AsyncLock()
    /// Bumped on every mutation.
    private(set) var revision: UInt64 = 0
    /// Where the state of `persistedRevision` was last written or loaded.
    private var persistedURL: URL?
    private var persistedRevision: UInt64 = 0
    private var lastEntryID: UInt64 = 0
    /// Brings the segments back into their tiers after a mutation.
    private var mergeTask: Task<Void, Never>?

    public init() {}

    /// An index that starts from an already built or memory-mapped segment.
    init(segment: IndexSegment?, metadata: IndexMetadata) {
        if let segment, segment.documentCount > 0 {
            var entry = IndexEntry(segment: segment)
            entry.id = 1
            lastEntryID = 1
            entries = [entry]
        }
        storedMetadata = metadata
    }

    deinit {
        mergeTask?.cancel()
    }

    // MARK: Public API

    /// Adds documents, replacing any with the same id. Takes effect for the next query.
    ///
    /// A document identical to the stored one costs a comparison and nothing else, so indexing
    /// the same content again is cheap.
    public func upsert(_ documents: [SearchDocument]) async {
        guard !documents.isEmpty else { return }
        await lock()
        defer { mutationLock.release() }
        await apply(upserting: await deduplicated(documents), removing: [], metadata: nil)
    }

    /// Removes documents. Takes effect for the next query.
    public func remove(_ ids: [SearchableID]) async {
        guard !ids.isEmpty else { return }
        await lock()
        defer { mutationLock.release() }
        await apply(upserting: [], removing: ids, metadata: nil)
    }

    /// Replaces the index with a memory-mapped, versioned file.
    ///
    /// A file written by another projection or normalizer version is discarded and the call throws
    /// ``SearchError/versionMismatch(_:)``: the caller rebuilds.
    public func load(from url: URL) async throws {
        try await load(from: url, expecting: nil)
    }

    /// Writes the live documents as one compact segment and continues from the mapped file.
    /// Nothing is written when the file already holds the current state.
    public func save(to url: URL) async throws {
        await lock()
        defer { mutationLock.release() }
        if persistedURL == url, persistedRevision == revision, await FileIO.exists(url) { return }
        let data = await compactedData()
        try await FileIO.write(data, to: url)
        let mapped = try FileIO.map(url)
        let segment = try IndexSegment(data: mapped)
        entries = segment.documentCount > 0 ? [entry(segment)] : []
        persistedURL = url
        persistedRevision = revision
    }

    /// Live documents.
    public var count: Int {
        entries.reduce(0) { $0 + $1.liveCount }
    }

    // MARK: Engine API

    var metadata: IndexMetadata { storedMetadata }

    func setMetadata(_ metadata: IndexMetadata) {
        storedMetadata = metadata
    }

    var statistics: CorpusStatistics {
        var totals = [UInt64](repeating: 0, count: SearchField.count)
        for entry in entries {
            for field in 0..<SearchField.count {
                totals[field] += entry.segment.totalFieldLengths[field] - entry.removedFieldLengths[field]
            }
        }
        return CorpusStatistics(documentCount: count, totalFieldLengths: totals)
    }

    var segmentCount: Int { entries.count }

    /// Documents and deleted documents of every segment, largest first.
    var segmentShape: [(documents: Int, deleted: Int)] {
        entries.map { ($0.segment.documentCount, $0.tombstones.count) }
    }

    /// The same once the merges that are due have run.
    var settledShape: [(documents: Int, deleted: Int)] {
        get async {
            await settle()
            return segmentShape
        }
    }

    /// Loads a file and checks it was built for the same languages and embedding model.
    func load(from url: URL, expecting expected: IndexMetadata?) async throws {
        await lock()
        defer { mutationLock.release() }
        let data = try FileIO.map(url)
        do {
            let segment = try IndexSegment(data: data)
            try Self.validate(segment, expecting: expected)
            entries = segment.documentCount > 0 ? [entry(segment)] : []
            storedMetadata = segment.metadata ?? IndexMetadata()
            revision &+= 1
            persistedURL = url
            persistedRevision = revision
        } catch {
            await FileIO.remove(url)
            throw error
        }
    }

    /// Adopts an already serialized segment, for example one read back from the host database.
    func adopt(_ data: Data, expecting expected: IndexMetadata?) async throws {
        await lock()
        defer { mutationLock.release() }
        let segment = try IndexSegment(data: data)
        try Self.validate(segment, expecting: expected)
        entries = segment.documentCount > 0 ? [entry(segment)] : []
        storedMetadata = segment.metadata ?? IndexMetadata()
        revision &+= 1
    }

    /// The current index as one compact segment, for persistence outside a file.
    func compactedSegment() async -> IndexSegment? {
        await lock()
        defer { mutationLock.release() }
        return try? IndexSegment(data: await compactedData())
    }

    static func validate(_ segment: IndexSegment, expecting expected: IndexMetadata?) throws {
        guard segment.projectionVersion == SearchDocument.projectionVersion else {
            throw SearchError.versionMismatch("projection \(segment.projectionVersion), expected \(SearchDocument.projectionVersion)")
        }
        guard segment.normalizerVersion == SearchNormalizer.version else {
            throw SearchError.versionMismatch("normalizer \(segment.normalizerVersion), expected \(SearchNormalizer.version)")
        }
        guard let expected else { return }
        let found = segment.metadata ?? IndexMetadata()
        guard found.embeddingModelID == expected.embeddingModelID else {
            throw SearchError.versionMismatch("embedding model '\(found.embeddingModelID)', expected '\(expected.embeddingModelID)'")
        }
        guard found.localeTag == expected.localeTag,
              found.secondaryLanguages == expected.secondaryLanguages,
              found.includesAllLanguages == expected.includesAllLanguages else {
            throw SearchError.versionMismatch("languages \(found.localeTag) \(found.secondaryLanguages), expected \(expected.localeTag) \(expected.secondaryLanguages)")
        }
        if !expected.contentFingerprint.isEmpty && found.contentFingerprint != expected.contentFingerprint {
            throw SearchError.versionMismatch("content changed since the index was written")
        }
    }

    /// Makes the index hold exactly `documents`. Only the documents that differ from what is
    /// stored are tokenized; ids that are no longer present are removed. Queries keep using the
    /// previous state until the swap.
    func replaceAll(with documents: [SearchDocument], metadata: IndexMetadata) async {
        await lock()
        defer { mutationLock.release() }
        let unique = await deduplicated(documents)
        guard !entries.isEmpty else {
            await apply(upserting: unique, removing: [], metadata: metadata, skippingUnchanged: false)
            return
        }
        let snapshot = entries
        let change = await Self.offActor { Self.difference(of: unique, from: snapshot, removingAbsent: true) }
        await apply(upserting: change.upserts, removing: change.removals, metadata: metadata, skippingUnchanged: false)
    }

    /// Upserts and removes in one step: no query sees one without the other.
    func mutate(upserting documents: [SearchDocument], removing ids: [SearchableID], metadata: IndexMetadata? = nil) async {
        guard !documents.isEmpty || !ids.isEmpty || metadata != nil else { return }
        await lock()
        defer { mutationLock.release() }
        await apply(upserting: await deduplicated(documents), removing: ids, metadata: metadata)
    }

    /// Folds the segments into one, in memory. Queries after a long run of small updates read
    /// several vocabularies; the service calls this once the updates have stopped.
    func compact() async {
        await lock()
        defer { mutationLock.release() }
        guard entries.count > 1 || entries.contains(where: { !$0.tombstones.isEmpty }) else { return }
        let before = revision
        let data = await compactedData()
        guard revision == before, let segment = try? IndexSegment(data: data) else { return }
        entries = segment.documentCount > 0 ? [entry(segment)] : []
    }

    /// The serialized, compacted index with its metadata.
    func serialized() async -> Data {
        await lock()
        defer { mutationLock.release() }
        return await compactedData()
    }

    /// Runs the lexical and fuzzy channels.
    func search(_ request: LexicalRequest) throws -> LexicalResponse {
        let current = entries
        let statistics = statistics
        let session = tokenizer
        return try SegmentMerger.withViews(current.map(\.segment)) { views in
            try searcher.search(request, entries: current, views: views, statistics: statistics, session: session)
        }
    }

    /// The stored projection of a live document.
    func document(for id: SearchableID) -> SearchDocument? {
        guard let location = locate(id) else { return nil }
        return try? entries[location.entry].segment.document(at: location.ordinal)
    }

    func contains(_ id: SearchableID) -> Bool {
        locate(id) != nil
    }

    /// The stored kind of each id, `nil` for an id the index does not hold.
    func rawKinds(of ids: [SearchableID]) -> [String?] {
        ids.map { id in
            guard let location = locate(id) else { return nil }
            let segment = entries[location.entry].segment
            return segment.withView { segment.kinds[$0.kindOrdinal(location.ordinal)] }
        }
    }

    /// Where each hit matched: field, language and highlight ranges.
    func describe(_ ids: [SearchableID], matchTerms: [String: Double], fieldWeights: [Double]) -> [MatchDescription] {
        var terms = MatchTerms(matchTerms)
        return ids.map { id in
            guard !matchTerms.isEmpty, let document = document(for: id) else { return .none }
            return Highlighter.describe(document, terms: &terms, fieldWeights: fieldWeights, session: tokenizer)
        }
    }

    /// Turns semantic neighbours into ranked documents, best first and at most `limit`,
    /// dropping ids the index does not hold and documents that violate a hard constraint:
    /// a kind, a filter, or a phrase the query requires.
    func resolve(_ matches: [SemanticMatch], constraints: HardConstraints, phrases: [[String]] = [], limit: Int = .max) -> [RankedDocument] {
        let segmentConstraints = SegmentConstraints(constraints, entries: entries)
        var resolved: [RankedDocument] = []
        resolved.reserveCapacity(min(matches.count, limit))
        for match in matches {
            if resolved.count >= limit { break }
            guard let location = locate(match.id) else { continue }
            let entry = entries[location.entry]
            let document: RankedDocument? = entry.segment.withView { view in
                guard segmentConstraints.allows(segment: location.entry, ordinal: location.ordinal, view: view) else { return nil }
                if !phrases.isEmpty {
                    guard let stored = try? view.document(at: location.ordinal),
                          Highlighter.containsPhrases(phrases, in: stored, session: tokenizer) else { return nil }
                }
                return RankedDocument(
                    id: match.id,
                    rawKind: entry.segment.kinds[view.kindOrdinal(location.ordinal)],
                    updatedAt: view.updatedAt(location.ordinal),
                    score: Double(match.similarity)
                )
            }
            if let document { resolved.append(document) }
        }
        return resolved
    }

    /// Vocabulary terms that complete `prefix`, the prefix itself first when it is a term.
    func completions(of prefix: String, limit: Int) -> [(term: String, documentFrequency: Int)] {
        let current = entries
        return SegmentMerger.withViews(current.map(\.segment)) { views in
            let source = IndexTermSource(entries: current, views: views)
            var result: [(String, Int)] = []
            if let exact = source.exact(prefix), !ScriptClass.isExactOnly(prefix) {
                result.append((exact.term, exact.documentFrequency))
            }
            for expansion in source.prefixExpansions(of: prefix, limit: limit) {
                result.append((expansion.term, expansion.documentFrequency))
            }
            return Array(result.prefix(limit))
        }
    }

    /// Every live document, oldest segment first. Used to rebuild and to persist.
    func allDocuments() -> [SearchDocument] {
        var documents: [SearchDocument] = []
        documents.reserveCapacity(count)
        for entry in entries {
            entry.segment.withView { view in
                for ordinal in 0..<entry.segment.documentCount where !entry.tombstones.contains(ordinal) {
                    if let document = try? view.document(at: ordinal) { documents.append(document) }
                }
            }
        }
        return documents
    }

    /// Every live id.
    func allIDs() -> [SearchableID] {
        var ids: [SearchableID] = []
        ids.reserveCapacity(count)
        for entry in entries {
            entry.segment.withView { view in
                for ordinal in 0..<entry.segment.documentCount where !entry.tombstones.contains(ordinal) {
                    ids.append(SearchableID(view.idString(ordinal)))
                }
            }
        }
        return ids
    }

    // MARK: Mutation

    private func lock() async {
        if mutationLock.tryAcquire() { return }
        await withCheckedContinuation { continuation in
            mutationLock.enqueue(continuation)
        }
    }

    /// The last document of each id, in first-seen order.
    private func deduplicated(_ documents: [SearchDocument]) async -> [SearchDocument] {
        if documents.count <= Self.inlineLimit { return Self.deduplicated(documents) }
        return await Self.offActor { Self.deduplicated(documents) }
    }

    private static func deduplicated(_ documents: [SearchDocument]) -> [SearchDocument] {
        var positions: [SearchableID: Int] = [:]
        positions.reserveCapacity(documents.count)
        var unique: [SearchDocument] = []
        unique.reserveCapacity(documents.count)
        for document in documents {
            if let position = positions[document.id] {
                unique[position] = document
            } else {
                positions[document.id] = unique.count
                unique.append(document)
            }
        }
        return unique
    }

    /// What has to change for the index to hold `documents`.
    struct Change: Sendable {
        /// Documents that are new or differ from the stored version.
        var upserts: [SearchDocument] = []
        /// Stored ids that are not among the documents.
        var removals: [SearchableID] = []
    }

    /// Compares documents with what `snapshot` stores, byte for byte.
    private static func difference(of documents: [SearchDocument], from snapshot: [IndexEntry], removingAbsent: Bool) -> Change {
        SegmentMerger.withViews(snapshot.map(\.segment)) { views in
            var change = Change()
            var present = removingAbsent ? snapshot.map { Bitset(capacity: $0.segment.documentCount) } : []
            var record = ByteWriter(capacity: 512)
            for document in documents {
                if let location = locate(document.id, in: snapshot, views: views) {
                    if removingAbsent { present[location.entry].insert(location.ordinal) }
                    record.bytes.removeAll(keepingCapacity: true)
                    DocumentCodec.encode(document, into: &record)
                    let stored = views[location.entry].storeBuffer(location.ordinal)
                    let identical = record.bytes.withUnsafeBytes { fresh in
                        fresh.count == stored.count && (fresh.count == 0 || memcmp(fresh.baseAddress!, stored.baseAddress!, fresh.count) == 0)
                    }
                    if identical { continue }
                }
                change.upserts.append(document)
            }
            if removingAbsent {
                for (index, entry) in snapshot.enumerated() {
                    for ordinal in 0..<entry.segment.documentCount
                    where !entry.tombstones.contains(ordinal) && !present[index].contains(ordinal) {
                        change.removals.append(SearchableID(views[index].idString(ordinal)))
                    }
                }
            }
            return change
        }
    }

    /// The entries with the live versions of `ids` marked as deleted and taken out of the
    /// statistics.
    private static func deleting(_ ids: [SearchableID], from snapshot: [IndexEntry]) -> (entries: [IndexEntry], deleted: Bool) {
        var entries = snapshot
        var deleted = false
        for id in ids {
            for index in entries.indices.reversed() {
                guard let ordinal = entries[index].segment.ordinal(of: id), !entries[index].tombstones.contains(ordinal) else { continue }
                entries[index].delete(ordinal)
                deleted = true
                break
            }
        }
        return (entries, deleted)
    }

    private static func locate(_ id: SearchableID, in entries: [IndexEntry], views: [SegmentView]) -> (entry: Int, ordinal: Int)? {
        for index in entries.indices.reversed() {
            if let ordinal = views[index].ordinal(ofID: id.rawValue), !entries[index].tombstones.contains(ordinal) {
                return (index, ordinal)
            }
        }
        return nil
    }

    /// The one mutation: builds a segment for the documents aside, then swaps it in together
    /// with the deletions. The caller holds the mutation lock.
    private func apply(
        upserting documents: [SearchDocument],
        removing ids: [SearchableID],
        metadata: IndexMetadata?,
        skippingUnchanged: Bool = true
    ) async {
        var documents = documents
        if skippingUnchanged && !entries.isEmpty && !documents.isEmpty {
            let snapshot = entries
            if documents.count <= Self.inlineLimit {
                documents = Self.difference(of: documents, from: snapshot, removingAbsent: false).upserts
            } else {
                let candidates = documents
                documents = await Self.offActor { Self.difference(of: candidates, from: snapshot, removingAbsent: false).upserts }
            }
        }
        let segment = await build(documents)

        // Marking thousands of documents as deleted reads each one's term list: more than a
        // query should wait for, so a large batch is worked out aside, on a copy.
        let doomed = documents.map(\.id) + ids
        var marked: (entries: [IndexEntry], deleted: Bool)?
        if doomed.count > Self.inlineMergeLimit, !entries.isEmpty {
            let snapshot = entries
            marked = await Self.offActor { Self.deleting(doomed, from: snapshot) }
        }

        // The swap. Nothing suspends between the deletions and the new segment, so no query
        // sees a document missing while its new version is on the way.
        if let metadata { storedMetadata = metadata }
        var deleted = false
        if let marked {
            // The mutation lock is held: the entries are the ones the copy was taken from.
            entries = marked.entries
            deleted = marked.deleted
        } else {
            for id in doomed {
                guard let location = locate(id) else { continue }
                entries[location.entry].delete(location.ordinal)
                deleted = true
            }
        }
        if let segment { entries.append(entry(segment)) }
        entries.removeAll { $0.liveCount == 0 }
        guard segment != nil || deleted || metadata != nil else { return }
        revision &+= 1
        scheduleMerges()
    }

    private func entry(_ segment: IndexSegment) -> IndexEntry {
        lastEntryID &+= 1
        var entry = IndexEntry(segment: segment)
        entry.id = lastEntryID
        return entry
    }

    /// Tokenizes documents and builds their segment: on the actor for a handful, on the
    /// cooperative pool otherwise, in parallel chunks when there are many.
    private func build(_ documents: [SearchDocument]) async -> IndexSegment? {
        guard !documents.isEmpty else { return nil }
        let data: Data
        if documents.count <= Self.inlineLimit {
            data = SegmentBuilder.build([DocumentTokenizer.tokenize(documents, session: tokenizer)])
        } else if documents.count <= Self.chunkSize {
            data = await Self.offActor { SegmentBuilder.build([DocumentTokenizer.tokenize(documents)]) }
        } else {
            data = await Self.buildInChunks(documents)
        }
        do {
            return try IndexSegment(data: data)
        } catch {
            assertionFailure("a freshly built segment failed validation: \(error)")
            return nil
        }
    }

    /// Each chunk becomes a small segment on its own task; the segments are then merged at the
    /// posting level. Memory in flight stays near the size of the finished segment instead of
    /// several times the size of the tokenized corpus.
    private static func buildInChunks(_ documents: [SearchDocument]) async -> Data {
        let chunkCount = (documents.count + chunkSize - 1) / chunkSize
        let chunks = await withTaskGroup(of: (Int, Data).self, returning: [Data].self) { group in
            for chunk in 0..<chunkCount {
                let slice = Array(documents[(chunk * chunkSize)..<min(documents.count, (chunk + 1) * chunkSize)])
                group.addTask(priority: .utility) {
                    (chunk, SegmentBuilder.build([DocumentTokenizer.tokenize(slice)]))
                }
            }
            var built = [Data?](repeating: nil, count: chunkCount)
            for await (chunk, data) in group {
                built[chunk] = data
            }
            return built.compactMap { $0 }
        }
        return await offActor {
            let inputs = chunks.compactMap { try? IndexSegment(data: $0) }.map {
                SegmentMerger.Input(segment: $0, tombstones: Bitset())
            }
            return SegmentMerger.merge(inputs)
        }
    }

    /// Runs CPU-bound work on the cooperative pool, off this actor, as a structured child task.
    private static func offActor<Result: Sendable>(_ work: @escaping @Sendable () -> Result) async -> Result {
        await withTaskGroup(of: Result.self, returning: Result.self) { group in
            group.addTask(priority: .utility) { work() }
            // The group has exactly one child.
            return await group.next()!
        }
    }

    private func locate(_ id: SearchableID) -> (entry: Int, ordinal: Int)? {
        for index in entries.indices.reversed() {
            if let ordinal = entries[index].segment.ordinal(of: id), !entries[index].tombstones.contains(ordinal) {
                return (index, ordinal)
            }
        }
        return nil
    }

    // MARK: Merging

    /// The size tier of a segment: tier `t` holds 4^t to 4^(t+1) - 1 live documents.
    static func tier(ofLiveCount count: Int) -> Int {
        var tier = 0
        var bound = tierFanout
        while count >= bound {
            tier += 1
            bound *= tierFanout
        }
        return tier
    }

    /// The segments to merge next, if any.
    private func nextMerge() -> [Int]? {
        // A segment that is mostly deleted documents is rewritten without them.
        if let index = entries.firstIndex(where: { $0.tombstones.count * 2 > $0.segment.documentCount }) {
            return [index]
        }
        var tiers: [Int: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            tiers[Self.tier(ofLiveCount: entry.liveCount), default: []].append(index)
        }
        if let tier = tiers.keys.sorted().first(where: { tiers[$0]!.count >= Self.tierFanout }) {
            return tiers[tier]
        }
        if entries.count > Self.maximumSegments {
            // Fold the two lowest tiers together: small segments, several slots freed.
            let lowest = tiers.keys.sorted().prefix(2).flatMap { tiers[$0] ?? [] }
            if lowest.count > 1 { return lowest }
            let order = entries.indices.sorted { entries[$0].liveCount < entries[$1].liveCount }
            return [order[0], order[1]]
        }
        return nil
    }

    /// Starts the merges a mutation made due, unless they are already running.
    private func scheduleMerges() {
        guard mergeTask == nil, nextMerge() != nil else { return }
        mergeTask = Task { [weak self] in
            await self?.runMerges()
        }
    }

    /// Merges until every tier holds fewer than `tierFanout` segments.
    ///
    /// A small merge runs in place under the mutation lock. A large one reads its segments,
    /// lets go of the lock while it works off the actor, and takes the lock again to swap the
    /// result in: mutations and queries go on meanwhile. If one of its segments lost a document
    /// in that time, the result is dropped and the merge is tried again.
    private func runMerges() async {
        while !Task.isCancelled {
            await lock()
            entries.removeAll { $0.liveCount == 0 }
            guard let group = nextMerge() else {
                mergeTask = nil
                mutationLock.release()
                return
            }
            let inputs = group.map { SegmentMerger.Input(segment: entries[$0].segment, tombstones: entries[$0].tombstones) }
            let live = group.reduce(0) { $0 + entries[$1].liveCount }
            if live <= Self.inlineMergeLimit {
                install(SegmentMerger.merge(inputs), replacing: group)
                mutationLock.release()
                continue
            }
            let ids = group.map { entries[$0].id }
            let deletions = group.map { entries[$0].tombstones.count }
            mutationLock.release()
            let data = await Self.offActor { SegmentMerger.merge(inputs) }
            await lock()
            let positions = ids.compactMap { id in entries.firstIndex { $0.id == id } }
            if positions.count == ids.count, zip(positions, deletions).allSatisfy({ entries[$0].tombstones.count == $1 }) {
                install(data, replacing: positions)
            }
            mutationLock.release()
        }
        mergeTask = nil
    }

    /// Puts a merged segment in the place of the entries it was made from.
    private func install(_ data: Data, replacing group: [Int]) {
        guard let merged = try? IndexSegment(data: data) else {
            assertionFailure("a merged segment failed validation")
            return
        }
        for index in group.sorted(by: >) { entries.remove(at: index) }
        if merged.documentCount > 0 { entries.append(entry(merged)) }
        // Largest first: recent documents sit at the end, where a lookup starts.
        entries.sort { $0.liveCount > $1.liveCount }
    }

    /// Returns once no merge is running or due. Mutations never wait for this; tests that look
    /// at the shape of the index do.
    func settle() async {
        while let task = mergeTask {
            await task.value
        }
    }

    /// One segment holding the live documents, with the current metadata.
    private func compactedData() async -> Data {
        let metadata = storedMetadata
        if entries.isEmpty {
            return SegmentBuilder.build([], metadata: metadata)
        }
        if entries.count == 1, entries[0].tombstones.isEmpty, entries[0].segment.metadata == metadata {
            return entries[0].segment.data
        }
        let inputs = entries.map { SegmentMerger.Input(segment: $0.segment, tombstones: $0.tombstones) }
        if count <= Self.inlineMergeLimit {
            return SegmentMerger.merge(inputs, metadata: metadata)
        }
        return await Self.offActor { SegmentMerger.merge(inputs, metadata: metadata) }
    }
}
