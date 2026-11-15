import Foundation

// Search contexts and database sources (specification sections 9.1 and 9.2).

extension SearchService {
    /// One service per context; ready on return, and the scan strategy touches no disk.
    ///
    /// Memory sources are projected and tokenized before the initializer returns. Database
    /// sources are read through an asynchronous boundary, so they load in the background, in
    /// pages, never blocking a query on what is already there; ``waitUntilReady()`` returns once
    /// they are in.
    public init(
        context: SearchContext<Schema>,
        semantic: (any SemanticSearching)? = nil,
        profile: RankingProfile = .default,
        signals: SignalProviders = .none,
        configuration: SearchEngineConfiguration = .default
    ) {
        let prepared = Self.prepare(context, semantic: semantic, profile: profile, signals: signals, configuration: configuration)
        self.init(setup: prepared.setup)
        let embeddings = prepared.embeddings
        let persist = prepared.needsPersistence
        guard !embeddings.isEmpty || persist || !prepared.setup.databaseSources.isEmpty else { return }
        // Index loading is the one place a detached task is used.
        Task.detached(priority: .utility) { [weak self] in
            await self?.finishSetup(embeddings: embeddings, persist: persist)
        }
    }

    /// Wholesale replacement of the context's memory items; cheap at scan size.
    public func replace<Item: Searchable>(items: [Item]) async where Item.Kind == Schema.Kind {
        await replaceMemory(items.map(AnySearchable.init))
    }

    /// The specification's spelling, where the runtime supports constrained existentials.
    @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
    @_disfavoredOverload
    public func replace(items: [any Searchable<Schema.Kind>]) async {
        await replaceMemory(items.map { AnySearchable($0) })
    }

    /// Re-reads every source on demand.
    public func refresh() async {
        await rebuild(languages: languages)
    }

    /// Returns once every source of the context has been read.
    public func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    /// Writes the index to the context's storage now. Called at sync time by hosts that want
    /// the index to commit with their data; the service also persists on its own after changes.
    public func persist() async {
        persistTask?.cancel()
        await persistIndex()
    }

    /// `true` when the context is served by the scan strategy.
    public var usesScanStrategy: Bool { storage.isScan }

    // MARK: Setup

    struct Prepared {
        var setup: Setup
        var embeddings: [SearchableID: [Float]]
        var needsPersistence: Bool
    }

    /// Everything the initializer can do synchronously: project the memory items, pick the
    /// strategy and build or memory-map the index.
    static func prepare(
        _ context: SearchContext<Schema>,
        semantic: (any SemanticSearching)?,
        profile: RankingProfile,
        signals: SignalProviders,
        configuration: SearchEngineConfiguration
    ) -> Prepared {
        var configuration = configuration
        if let locale = context.locale {
            configuration.locale = locale
            configuration.followsSystemLocale = false
        }
        let languages = ResolvedLanguages(locale: configuration.locale, configuration: configuration)
        let reporter = DiagnosticReporter(configuration)

        var databaseSources: [DatabaseSource] = []
        for source in context.sources {
            if case .database(let connection, let tables) = source {
                databaseSources.append(DatabaseSource(connection: connection, tables: tables))
            }
        }
        let hasDatabase = !databaseSources.isEmpty
        let items = lastOccurrences(context.memoryItems)
        let wantsIndex: Bool
        switch context.strategy {
        case .scan: wantsIndex = false
        case .indexed: wantsIndex = true
        // The size of a context with database sources is only known once its rows are read.
        case .automatic: wantsIndex = !hasDatabase && items.count > configuration.scanThreshold
        }

        var setup = Setup(
            contextID: context.id,
            semantic: semantic,
            reranker: nil,
            signals: signals,
            profile: profile,
            configuration: configuration,
            languages: languages,
            storage: .scan(ScanEngine(documents: [])),
            strategy: context.strategy,
            indexStorage: context.indexStorage,
            localizedStrings: context.localizedStrings,
            databaseSources: databaseSources,
            memoryItems: items,
            isReady: !hasDatabase
        )
        // Only an index kept in a file of its own is checked against the items at the next launch.
        var persistsToFile = false
        if case .files = context.indexStorage { persistsToFile = wantsIndex && !hasDatabase && context.id != .default }
        let metadata = indexMetadata(languages: languages, semantic: semantic, fingerprint: persistsToFile ? fingerprint(of: items) : "")

        // An indexed context persists under its own file: when the file was written from the
        // same content, memory-map it and skip projection and tokenization altogether.
        if wantsIndex, !hasDatabase, case .files(let directory) = context.indexStorage,
           let data = try? FileIO.map(indexFileURL(in: directory, contextID: context.id)),
           let segment = try? IndexSegment(data: data),
           (try? LexicalIndex.validate(segment, expecting: metadata)) != nil {
            setup.storage = .indexed(LexicalIndex(segment: segment, metadata: metadata))
            var embeddings: [SearchableID: [Float]] = [:]
            if semantic != nil {
                for item in items {
                    if let embedding = (item.base as? any EmbeddableSearchable)?.embedding { embeddings[item.searchID] = embedding }
                }
            }
            return Prepared(setup: setup, embeddings: embeddings, needsPersistence: false)
        }

        let projection = project(items, languages: languages, reporter: reporter)
        if wantsIndex {
            let data = SegmentBuilder.build([DocumentTokenizer.tokenize(projection.documents)], metadata: metadata)
            setup.storage = .indexed(LexicalIndex(segment: try? IndexSegment(data: data), metadata: metadata))
            let persists: Bool
            if case .inMemory = context.indexStorage { persists = false } else { persists = !hasDatabase }
            return Prepared(setup: setup, embeddings: projection.embeddings, needsPersistence: persists)
        }
        setup.scanEmbeddings = projection.embeddings
        setup.storage = .scan(ScanEngine(documents: projection.documents, embeddings: projection.embeddings))
        return Prepared(setup: setup, embeddings: projection.embeddings, needsPersistence: false)
    }

    func finishSetup(embeddings: [SearchableID: [Float]], persist: Bool) async {
        await upsertVectors(embeddings)
        if !databaseSources.isEmpty {
            // Subscribe before the first read: a commit that lands while the rows are being read
            // must not be lost. Its change is applied once the load is in.
            startChangeObservers()
            await rebuild(languages: languages, adoptingPersistedIndex: true)
        } else if persist {
            await persistIndex()
        }
    }

    static func indexMetadata(languages: ResolvedLanguages, semantic: (any SemanticSearching)?, fingerprint: String) -> IndexMetadata {
        IndexMetadata(
            localeTag: languages.active,
            secondaryLanguages: languages.secondary,
            includesAllLanguages: languages.includesAllLanguages,
            embeddingModelID: semantic?.modelID ?? "",
            contentFingerprint: fingerprint
        )
    }

    /// A cheap identity of the memory items: ids, kinds, the size of their text and title, and
    /// their modification dates. Edits that keep all of them need an explicit ``refresh()``.
    /// The order of the items does not matter: a host may hand the same items in another order.
    static func fingerprint(of items: [AnySearchable<Schema.Kind>]) -> String {
        var sum: UInt64 = 0
        var mixed: UInt64 = 0
        for item in items {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            func mix(_ value: UInt64) {
                hash ^= value
                hash = hash &* 0x0000_0100_0000_01B3
            }
            mix(fnv1a(item.searchID.rawValue))
            mix(fnv1a(item.searchKind.rawValue))
            mix(UInt64(item.searchText.utf8.count))
            if let title = (item.base as? any TitledSearchable)?.searchTitle { mix(UInt64(title.utf8.count)) }
            if let date = (item.base as? any TemporalSearchable)?.updatedAt { mix(date.timeIntervalSinceReferenceDate.bitPattern) }
            sum = sum &+ hash
            mixed ^= hash &* 0x9E37_79B9_7F4A_7C15
        }
        return String(items.count, radix: 16) + "-" + String(sum, radix: 16) + "-" + String(mixed, radix: 16)
    }

    /// The file of an indexed context: keyed by its id and `projectionVersion`.
    static func indexFileURL(in directory: URL, contextID: SearchContextID) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let name = contextID.rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? "context"
        return directory.appendingPathComponent("\(name).v\(SearchDocument.projectionVersion).ztsi")
    }

    // MARK: Documents

    /// Upserts and removes in one step, under whichever strategy serves the context.
    func mutateDocuments(upserting documents: [SearchDocument], removing ids: [SearchableID]) async {
        guard !documents.isEmpty || !ids.isEmpty else { return }
        switch storage {
        case .indexed(let index):
            await index.mutate(upserting: documents, removing: ids)
        case .scan(let engine):
            var kept = engine.documents
            if !ids.isEmpty {
                let doomed = Set(ids)
                kept.removeAll { doomed.contains($0.id) }
            }
            storage = .scan(ScanEngine(documents: kept + documents, embeddings: scanEmbeddings, session: tokenizer))
        }
    }

    /// An `.automatic` context that outgrew the scan threshold moves to the indexed strategy.
    func rebalanceStrategy() async {
        guard strategy == .automatic, case .scan(let engine) = storage, engine.count > configuration.scanThreshold else { return }
        let index = LexicalIndex()
        await index.replaceAll(
            with: engine.documents,
            metadata: Self.indexMetadata(languages: languages, semantic: semantic, fingerprint: "")
        )
        guard case .scan(let current) = storage, current.count == engine.count else { return }
        storage = .indexed(index)
        await upsertVectors(scanEmbeddings)
    }

    private func replaceMemory(_ items: [AnySearchable<Schema.Kind>]) async {
        startObservers()
        let previous = Set(memoryPositions.keys)
        memoryItems = Self.lastOccurrences(items)
        memoryPositions = Self.positions(of: memoryItems)
        let projection = await project(memoryItems, languages: languages)
        let current = Set(projection.documents.map(\.id))
        let removed = Array(previous.subtracting(current))
        if databaseSources.isEmpty {
            scanEmbeddings = projection.embeddings
            await install(projection.documents, languages: languages)
        } else {
            for id in removed { scanEmbeddings[id] = nil }
            scanEmbeddings.merge(projection.embeddings) { _, new in new }
            await mutateDocuments(upserting: projection.documents, removing: removed)
            await rebalanceStrategy()
        }
        if !removed.isEmpty { await semantic?.remove(removed) }
        await upsertVectors(projection.embeddings)
        schedulePersist()
    }

    /// Puts a complete document set in place under the strategy its size calls for.
    private func install(_ documents: [SearchDocument], languages: ResolvedLanguages) async {
        let wantsIndex: Bool
        switch strategy {
        case .scan: wantsIndex = false
        case .indexed: wantsIndex = true
        case .automatic: wantsIndex = documents.count > configuration.scanThreshold
        }
        if wantsIndex {
            let metadata = Self.indexMetadata(languages: languages, semantic: semantic, fingerprint: await contentFingerprint())
            if case .indexed(let index) = storage {
                // The same actor keeps serving: the new segment is built aside and swapped in.
                await index.replaceAll(with: documents, metadata: metadata)
            } else {
                let index = LexicalIndex()
                await index.replaceAll(with: documents, metadata: metadata)
                storage = .indexed(index)
            }
        } else {
            storage = .scan(ScanEngine(documents: documents, embeddings: scanEmbeddings, session: tokenizer))
        }
    }

    /// The identity of the memory items a persisted index file is checked against at the next
    /// launch. Only a context that keeps its index in a file of its own needs one. Thousands of
    /// items are fingerprinted off the actor.
    private func contentFingerprint() async -> String {
        guard databaseSources.isEmpty, contextID != .default, case .files = indexStorage else { return "" }
        let items = memoryItems
        guard items.count >= 2_000 else { return Self.fingerprint(of: items) }
        return await withTaskGroup(of: String.self, returning: String.self) { group in
            group.addTask(priority: .utility) { Self.fingerprint(of: items) }
            return await group.next() ?? ""
        }
    }

    /// The memory items whose projection can depend on the locale, picked off the actor when
    /// there are thousands to look at.
    private func localizedMemoryItems() async -> [AnySearchable<Schema.Kind>] {
        let items = memoryItems
        guard items.count >= 2_000 else { return items.filter(Self.isLocalized) }
        return await withTaskGroup(of: [AnySearchable<Schema.Kind>].self, returning: [AnySearchable<Schema.Kind>].self) { group in
            group.addTask(priority: .utility) { items.filter(Self.isLocalized) }
            return await group.next() ?? []
        }
    }

    // MARK: Rebuild

    private func acquireRebuildLock() async {
        if rebuildLock.tryAcquire() { return }
        await withCheckedContinuation { continuation in
            rebuildLock.enqueue(continuation)
        }
    }

    /// What a rebuild has to look at again.
    enum RebuildScope: Sendable {
        /// Every item and every row.
        case everything
        /// Only what can differ under another locale: items that carry localizations, and the
        /// rows of every table (their localized keys resolve per language). The projection of
        /// any other item is the same in every locale, so it is neither projected nor tokenized
        /// again, and the result is the index a full rebuild would produce.
        case localeChange
    }

    /// Re-reads the sources under `languages` and swaps the result in. Queries keep using the
    /// previous generation until the swap.
    func rebuild(languages target: ResolvedLanguages, adoptingPersistedIndex: Bool = false, scope: RebuildScope = .everything) async {
        await acquireRebuildLock()
        defer { rebuildLock.release() }
        await rebuildLocked(languages: target, adoptingPersistedIndex: adoptingPersistedIndex, scope: scope)
    }

    private func rebuildLocked(languages target: ResolvedLanguages, adoptingPersistedIndex: Bool = false, scope: RebuildScope = .everything) async {
        defer { markReady() }

        if memoryItems.isEmpty && databaseSources.isEmpty {
            // A service over a host-loaded index holds nothing to project again.
            if await count > 0 {
                reporter.report(.rebuildSkipped(reason: "the service holds no items; index them again under the new locale"))
            }
            languages = target
            return
        }

        sourceRevision &+= 1
        let revision = sourceRevision

        if adoptingPersistedIndex, await adoptPersistedIndex(languages: target) {
            return
        }

        // The narrow scope needs an index to patch and the previous rows of every table.
        var narrow = false
        if scope == .localeChange, case .indexed = storage {
            let tableCount = databaseSources.reduce(0) { $0 + $1.tables.count }
            narrow = tables.count == tableCount && tables.allSatisfy(\.isKnown)
        }

        let memory = await project(narrow ? await localizedMemoryItems() : memoryItems, languages: target)
        guard revision == sourceRevision else { return }
        var documents = memory.documents
        var states: [TableState] = []
        var removals: [SearchableID] = []
        for (sourceIndex, source) in databaseSources.enumerated() {
            for (tableIndex, table) in source.tables.enumerated() {
                var state = TableState(source: sourceIndex, table: tableIndex)
                do {
                    let rows = try await readWholeTable(table, key: TableKey(source: sourceIndex, table: tableIndex), on: source.connection, languages: target)
                    guard revision == sourceRevision else { return }
                    for row in rows {
                        state.ids.insert(row.document.id)
                        if let rowID = row.rowID { state.rows[rowID] = row.document.id }
                        documents.append(row.document)
                    }
                    state.isKnown = true
                    if narrow, let previous = tables.first(where: { $0.source == sourceIndex && $0.table == tableIndex }) {
                        removals.append(contentsOf: previous.ids.subtracting(state.ids))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    reporter.report(.databaseFailure(table: table.name, message: String(describing: error)))
                    if narrow, let previous = tables.first(where: { $0.source == sourceIndex && $0.table == tableIndex }) {
                        // The rows could not be read: what was indexed for the table stays.
                        state = previous
                    }
                }
                states.append(state)
            }
        }

        // Uniqueness of ids across sources is the host's responsibility; a clash is reported.
        // Within the memory items the projection has already seen to it.
        if !databaseSources.isEmpty {
            var seen = Set<SearchableID>()
            seen.reserveCapacity(documents.count)
            for document in documents where !seen.insert(document.id).inserted {
                reporter.report(.duplicateID(id: document.id))
            }
        }

        if narrow, case .indexed(let index) = storage {
            let metadata = Self.indexMetadata(languages: target, semantic: semantic, fingerprint: await contentFingerprint())
            guard revision == sourceRevision else { return }
            await index.mutate(upserting: documents, removing: removals, metadata: metadata)
        } else {
            scanEmbeddings = memory.embeddings
            await install(documents, languages: target)
        }
        guard revision == sourceRevision else { return }
        tables = states
        languages = target
        await upsertVectors(memory.embeddings)
        await persistIndex()
    }

    private func markReady() {
        isReady = true
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Database rows

    struct ReadRow: Sendable {
        let document: SearchDocument
        let rowID: Int64?
    }

    /// Reads a table source in pages and projects every row through the item projector.
    func read(
        _ table: SearchTableSource<Schema>,
        on connection: any SearchDatabaseConnection,
        languages: ResolvedLanguages,
        rowIDs: [Int64]?
    ) async throws -> [ReadRow] {
        let rowProjector = SearchRowProjector<Schema>(source: table, languages: languages, resolver: localizedStrings, reporter: reporter)
        let reporter = reporter
        var result: [ReadRow] = []
        try await SearchRowReader.forEachPage(of: table, on: connection, pageSize: configuration.databasePageSize, rowIDs: rowIDs) { rows, layout in
            var session = SearchRowProjector<Schema>.Session()
            var items: [AnySearchable<Schema.Kind>] = []
            var identities: [SearchableID: Int64] = [:]
            items.reserveCapacity(rows.count)
            for row in rows {
                guard let projected = rowProjector.project(row, layout: layout, session: &session) else { continue }
                items.append(projected.item)
                if let rowID = projected.rowID { identities[projected.item.searchID] = rowID }
            }
            for document in Self.project(items, languages: languages, reporter: reporter).documents {
                result.append(ReadRow(document: document, rowID: identities[document.id]))
            }
        }
        return result
    }

    /// Reads a whole table. Pages are separate read transactions (section 9.2, rule 2), so a
    /// commit between two of them can move a row across a page boundary. When the change stream
    /// reports a commit on the table while it is being read, the table is read again; after a
    /// few attempts on a table that never rests, the last read stands, the changes that arrived
    /// during it are applied afterwards, and the condition is reported.
    func readWholeTable(
        _ table: SearchTableSource<Schema>,
        key: TableKey,
        on connection: any SearchDatabaseConnection,
        languages: ResolvedLanguages
    ) async throws -> [ReadRow] {
        readsInFlight[key, default: 0] += 1
        defer {
            readsInFlight[key, default: 1] -= 1
            if readsInFlight[key] == 0 {
                readsInFlight[key] = nil
                deferredChanges[key] = nil
            }
        }
        var attempt = 0
        while true {
            attempt += 1
            let serial = changeSerials[key, default: 0]
            deferredChanges[key] = []
            let rows = try await read(table, on: connection, languages: languages, rowIDs: nil)
            if changeSerials[key, default: 0] == serial { return rows }
            if attempt >= 3 {
                reporter.report(.sourceChangedWhileReading(table: table.name))
                for change in deferredChanges[key] ?? [] {
                    pendingChanges.append(PendingChange(source: key.source, change: change))
                }
                startChangeProcessor()
                return rows
            }
        }
    }

    // MARK: Change stream

    /// Subscribes to the boundary's change stream of every database source. The host wires
    /// update and commit hooks; the stream may stay silent.
    func startChangeObservers() {
        for (sourceIndex, source) in databaseSources.enumerated() {
            let stream = source.connection.changes(in: Set(source.tables.map(\.name)))
            maintenanceTasks.append(Task { [weak self] in
                for await change in stream {
                    guard let self else { return }
                    await self.receive(change, source: sourceIndex)
                }
            })
        }
    }

    /// Notes a change the moment it arrives, so a read in flight learns about it, and queues it.
    /// Changes are applied one at a time, in order, never while the sources are being re-read.
    func receive(_ change: SearchDatabaseChange, source sourceIndex: Int) {
        var isCoveredByAReadInFlight = true
        var matched = false
        for (tableIndex, table) in databaseSources[sourceIndex].tables.enumerated() where table.name == change.table {
            matched = true
            let key = TableKey(source: sourceIndex, table: tableIndex)
            changeSerials[key, default: 0] &+= 1
            if readsInFlight[key, default: 0] > 0 {
                // The reader sees the new serial and reads the table again, which covers it.
                deferredChanges[key, default: []].append(change)
            } else {
                isCoveredByAReadInFlight = false
            }
        }
        guard matched, !isCoveredByAReadInFlight else { return }
        // Commits that queue up behind one another on the same table are applied as one.
        if let last = pendingChanges.indices.last, pendingChanges[last].source == sourceIndex,
           pendingChanges[last].change.table == change.table {
            let merged: Set<Int64>?
            if let earlier = pendingChanges[last].change.rowIDs, let later = change.rowIDs {
                merged = earlier.union(later)
            } else {
                merged = nil
            }
            pendingChanges[last].change = SearchDatabaseChange(table: change.table, rowIDs: merged)
        } else {
            pendingChanges.append(PendingChange(source: sourceIndex, change: change))
        }
        startChangeProcessor()
    }

    private func startChangeProcessor() {
        guard changeProcessor == nil, !pendingChanges.isEmpty else { return }
        changeProcessor = Task { [weak self] in
            await self?.drainChanges()
        }
    }

    private func drainChanges() async {
        while !pendingChanges.isEmpty, !Task.isCancelled {
            let next = pendingChanges.removeFirst()
            await apply(next.change, source: next.source)
        }
        changeProcessor = nil
    }

    /// Applies one commit's changes to one table: changed rowids are re-read and upserted or
    /// removed; a change without rowids refreshes its table.
    func apply(_ change: SearchDatabaseChange, source sourceIndex: Int) async {
        // A rebuild re-reads every row; a change applied in the middle of one would be
        // overwritten by what the rebuild read before the commit.
        await acquireRebuildLock()
        defer { rebuildLock.release() }
        let revision = sourceRevision
        let source = databaseSources[sourceIndex]
        for (tableIndex, table) in source.tables.enumerated() where table.name == change.table {
            guard let known = tables.first(where: { $0.source == sourceIndex && $0.table == tableIndex }), known.isKnown else {
                // The index was adopted from storage and this table's rows were never read here.
                await rebuildLocked(languages: languages)
                return
            }
            do {
                let incremental = change.rowIDs != nil && table.rowID != nil
                let rows: [ReadRow]
                if incremental {
                    rows = try await read(table, on: source.connection, languages: languages, rowIDs: change.rowIDs?.sorted())
                } else {
                    rows = try await readWholeTable(table, key: TableKey(source: sourceIndex, table: tableIndex), on: source.connection, languages: languages)
                }
                // Generation guard: a wholesale rebuild since the batch was read supersedes it.
                guard revision == sourceRevision,
                      let position = tables.firstIndex(where: { $0.source == sourceIndex && $0.table == tableIndex }) else { return }

                var state = incremental ? tables[position] : TableState(source: sourceIndex, table: tableIndex, isKnown: true)
                var removals: [SearchableID] = []
                var returned = Set<Int64>()
                for row in rows {
                    if let rowID = row.rowID {
                        returned.insert(rowID)
                        if incremental, let previous = state.rows[rowID], previous != row.document.id {
                            removals.append(previous)
                            state.ids.remove(previous)
                        }
                        state.rows[rowID] = row.document.id
                    }
                    state.ids.insert(row.document.id)
                }
                if incremental, let changed = change.rowIDs {
                    // A changed rowid that no longer comes back was deleted or left the predicate.
                    for rowID in changed where !returned.contains(rowID) {
                        if let previous = state.rows.removeValue(forKey: rowID) {
                            removals.append(previous)
                            state.ids.remove(previous)
                        }
                    }
                } else {
                    removals.append(contentsOf: tables[position].ids.subtracting(state.ids))
                }
                tables[position] = state
                // An id that moved to another row is upserted, not removed.
                let upserted = Set(rows.map(\.document.id))
                removals.removeAll { upserted.contains($0) }
                await mutateDocuments(upserting: rows.map(\.document), removing: removals)
                if !removals.isEmpty { await semantic?.remove(removals) }
            } catch is CancellationError {
                return
            } catch {
                reporter.report(.databaseFailure(table: table.name, message: String(describing: error)))
            }
        }
        await rebalanceStrategy()
        schedulePersist()
    }

    // MARK: Persistence

    /// Persists shortly after the last change, so a burst of changes writes once. An index that
    /// is not persisted is folded back into one segment instead, once the burst is over.
    func schedulePersist() {
        guard case .indexed(let index) = storage else { return }
        let persists: Bool
        if case .inMemory = indexStorage { persists = false } else { persists = contextID != .default }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: persists ? 1_000_000_000 : 2_000_000_000)
            } catch {
                return
            }
            if persists {
                await self?.persistIndex()
            } else if await index.segmentCount > LexicalIndex.comfortableSegments, !Task.isCancelled {
                await index.compact()
            }
        }
    }

    func persistIndex() async {
        guard case .indexed(let index) = storage else { return }
        do {
            switch indexStorage {
            case .inMemory:
                return
            case .files(let directory):
                guard contextID != .default else { return }
                try await index.save(to: Self.indexFileURL(in: directory, contextID: contextID))
            case .database(let prefix):
                guard let connection = databaseSources.first?.connection, let segment = await index.compactedSegment() else { return }
                try await DatabaseIndexStore(prefix: prefix).save(segment, on: connection)
            }
        } catch {
            reporter.report(.persistenceFailed(message: String(describing: error)))
        }
    }

    /// Starts from the index a previous run persisted, when it was written for the same
    /// languages and model. The rows are then not read at all until something changes.
    private func adoptPersistedIndex(languages target: ResolvedLanguages) async -> Bool {
        guard strategy != .scan else { return false }
        let expected = Self.indexMetadata(languages: target, semantic: semantic, fingerprint: "")
        let index = LexicalIndex()
        do {
            switch indexStorage {
            case .inMemory:
                return false
            case .files(let directory):
                let url = Self.indexFileURL(in: directory, contextID: contextID)
                guard await FileIO.exists(url) else { return false }
                try await index.load(from: url, expecting: expected)
            case .database(let prefix):
                guard let connection = databaseSources.first?.connection,
                      let data = try await DatabaseIndexStore(prefix: prefix).load(on: connection) else { return false }
                try await index.adopt(data, expecting: expected)
            }
        } catch {
            reporter.report(.indexDiscarded(reason: String(describing: error)))
            return false
        }
        // A persisted index only stands in for an indexed context.
        let adoptedCount = await index.count
        guard strategy == .indexed || adoptedCount > configuration.scanThreshold else { return false }
        storage = .indexed(index)
        languages = target
        tables = databaseSources.enumerated().flatMap { sourceIndex, source in
            source.tables.indices.map { TableState(source: sourceIndex, table: $0) }
        }
        return true
    }
}
