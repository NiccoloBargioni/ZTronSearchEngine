import Foundation

/// Merges segments at the posting level, dropping deleted documents.
///
/// Nothing is re-tokenized: vocabularies are merged by byte order, postings are re-based onto
/// the new ordinals, and document frequencies are recounted from the surviving postings, so the
/// result has exactly the statistics of an index built from the live documents alone.
enum SegmentMerger {
    struct Input {
        let segment: IndexSegment
        let tombstones: Bitset
    }

    static func merge(_ inputs: [Input], metadata: IndexMetadata? = nil) -> Data {
        withViews(inputs.map(\.segment)) { views in
            merge(inputs, views: views, metadata: metadata)
        }
    }

    /// Opens every segment at once.
    static func withViews<Result>(
        _ segments: [IndexSegment],
        from index: Int = 0,
        collected: [SegmentView] = [],
        _ body: ([SegmentView]) throws -> Result
    ) rethrows -> Result {
        if index == segments.count { return try body(collected) }
        return try segments[index].withView { view in
            try withViews(segments, from: index + 1, collected: collected + [view], body)
        }
    }

    private static func merge(_ inputs: [Input], views: [SegmentView], metadata: IndexMetadata?) -> Data {
        let fields = SearchField.count
        let dead = UInt32.max

        // New ordinals: inputs in order, live documents in order.
        var remap: [[UInt32]] = []
        var liveTotal = 0
        for input in inputs {
            var mapping = [UInt32](repeating: dead, count: input.segment.documentCount)
            for ordinal in 0..<input.segment.documentCount where !input.tombstones.contains(ordinal) {
                mapping[ordinal] = UInt32(liveTotal)
                liveTotal += 1
            }
            remap.append(mapping)
        }

        // Kind and filter tables.
        var kinds: [String] = []
        var kindOrdinals: [String: Int] = [:]
        var filters: [FilterRecord] = []
        var filterOrdinals: [FilterRecord: UInt32] = [:]
        var kindMaps: [[Int]] = []
        var filterMaps: [[UInt32]] = []
        for input in inputs {
            kindMaps.append(input.segment.kinds.map { kind in
                if let existing = kindOrdinals[kind] { return existing }
                kindOrdinals[kind] = kinds.count
                kinds.append(kind)
                return kinds.count - 1
            })
            filterMaps.append(input.segment.filters.map { record in
                if let existing = filterOrdinals[record] { return existing }
                let ordinal = UInt32(filters.count)
                filterOrdinals[record] = ordinal
                filters.append(record)
                return ordinal
            })
        }

        // The merged segment is never larger than its inputs together.
        var reservation = SegmentWriter.Reservation(documents: liveTotal)
        for input in inputs {
            reservation.terms = max(reservation.terms, input.segment.termCount)
            reservation.termBytes += input.segment.sectionRange(.termBytes).count
            reservation.postingBytes += input.segment.sectionRange(.postings).count
            reservation.idBytes += input.segment.sectionRange(.idBytes).count
            reservation.storeBytes += input.segment.sectionRange(.storeBytes).count
            reservation.forwardBytes += input.segment.sectionRange(.forwardBytes).count
        }
        if inputs.count > 1 {
            reservation.terms = min(inputs.reduce(0) { $0 + $1.segment.termCount }, reservation.terms * 2)
        }
        var writer = SegmentWriter(reserving: reservation, collectsTrigrams: false)

        // Vocabulary: k-way merge in byte order. `termMaps` records where every term of every
        // input went, which is what re-bases the trigram index and the per-document term lists.
        var termMaps = inputs.map { [UInt32](repeating: dead, count: $0.segment.termCount) }
        var cursors = [Int](repeating: 0, count: inputs.count)
        var stamps = [UInt32](repeating: 0, count: liveTotal)
        var stamp: UInt32 = 0
        var previous = [Int](repeating: -1, count: fields)
        var holders: [Int] = []
        while true {
            holders.removeAll(keepingCapacity: true)
            var smallest: UnsafeRawBufferPointer?
            for index in inputs.indices where cursors[index] < inputs[index].segment.termCount {
                let candidate = views[index].termBuffer(cursors[index])
                guard let current = smallest else {
                    smallest = candidate
                    holders.append(index)
                    continue
                }
                let order = compare(candidate, current)
                if order < 0 {
                    smallest = candidate
                    holders.removeAll(keepingCapacity: true)
                    holders.append(index)
                } else if order == 0 {
                    holders.append(index)
                }
            }
            guard let termBuffer = smallest else { break }

            stamp += 1
            var documentFrequency: UInt32 = 0
            for field in 0..<fields { previous[field] = -1 }
            for index in holders {
                let view = views[index]
                let mapping = remap[index]
                let isOnlyHolder = holders.count == 1
                for field in 0..<fields {
                    guard let range = view.postingRange(term: cursors[index], field: field) else { continue }
                    var offset = range.start
                    let end = range.start + range.length
                    var document = -1
                    while offset < end {
                        document += Int(readVarint(view.postings, &offset))
                        let frequency = readVarint(view.postings, &offset)
                        let mapped = mapping[document]
                        guard mapped != dead else { continue }
                        writer.appendPosting(field: field, document: Int(mapped), previous: previous[field], frequency: frequency)
                        previous[field] = Int(mapped)
                        if isOnlyHolder && field == 0 {
                            // A document counts once per term; with a single holder and the
                            // first field there is nothing to have counted it before.
                            stamps[Int(mapped)] = stamp
                            documentFrequency += 1
                        } else if stamps[Int(mapped)] != stamp {
                            stamps[Int(mapped)] = stamp
                            documentFrequency += 1
                        }
                    }
                }
            }
            if documentFrequency > 0 {
                let ordinal = UInt32(writer.termCount)
                for index in holders { termMaps[index][cursors[index]] = ordinal }
                writer.commitTerm(utf8: termBuffer, documentFrequency: documentFrequency)
            } else {
                // Every document that held the term is gone: the staged postings are empty.
                writer.discardStagedPostings()
            }
            for index in holders { cursors[index] += 1 }
        }

        // Documents, each with its term list re-based onto the merged vocabulary. The map is
        // monotonic, so the list stays ascending.
        var forward: [UInt32] = []
        for (index, input) in inputs.enumerated() {
            let view = views[index]
            let termMap = termMaps[index]
            for ordinal in 0..<input.segment.documentCount where remap[index][ordinal] != dead {
                var ordinals: [UInt32] = []
                for position in 0..<view.filterCount(ordinal) {
                    ordinals.append(filterMaps[index][view.filterOrdinal(ordinal, position)])
                }
                writer.addDocument(
                    id: view.idBuffer(ordinal),
                    store: view.storeBuffer(ordinal),
                    kind: kindMaps[index][view.kindOrdinal(ordinal)],
                    filters: ordinals,
                    updatedAt: view.updatedAtRaw(ordinal)
                ) { field in
                    view.fieldLength(field: field, document: ordinal)
                }
                forward.removeAll(keepingCapacity: true)
                view.forEachTerm(of: ordinal) { term in
                    let mapped = termMap[term]
                    if mapped != dead { forward.append(mapped) }
                }
                writer.addForward(forward)
            }
        }
        let trigrams = mergeTrigrams(views: views, termMaps: termMaps)
        return writer.finish(kinds: kinds, filters: filters, metadata: metadata, trigrams: trigrams)
    }

    /// Merges the trigram indexes of the inputs: trigrams in ascending order, each with the
    /// surviving terms that contain it, re-based and ascending. Nothing is derived from the
    /// terms again.
    private static func mergeTrigrams(views: [SegmentView], termMaps: [[UInt32]]) -> SegmentWriter.TrigramIndex {
        let dead = UInt32.max
        var index = SegmentWriter.TrigramIndex()
        var capacity = 0
        var keyCount = 0
        for view in views {
            capacity += view.segment.sectionRange(.trigramPostings).count
            keyCount = max(keyCount, view.segment.trigramCount)
        }
        var postings = ByteWriter(capacity: capacity + capacity / 4)
        index.keys.reserveCapacity(keyCount)
        index.offsets.reserveCapacity(keyCount + 1)

        var cursors = [Int](repeating: 0, count: views.count)
        var terms: [UInt32] = []
        while true {
            var smallest: UInt64?
            for input in views.indices where cursors[input] < views[input].segment.trigramCount {
                let key = views[input].trigramKey(cursors[input])
                if smallest == nil || key < smallest! { smallest = key }
            }
            guard let key = smallest else { break }

            terms.removeAll(keepingCapacity: true)
            var sources = 0
            for input in views.indices where cursors[input] < views[input].segment.trigramCount {
                let view = views[input]
                guard view.trigramKey(cursors[input]) == key else { continue }
                let run = view.trigramRun(cursors[input])
                let termMap = termMaps[input]
                var offset = run.start
                let end = run.start + run.length
                var ordinal = 0
                while offset < end {
                    ordinal += Int(readVarint(view.trigramPostings, &offset))
                    let mapped = termMap[ordinal]
                    if mapped != dead { terms.append(mapped) }
                }
                cursors[input] += 1
                sources += 1
            }
            guard !terms.isEmpty else { continue }
            // One source is already ascending and distinct; several may share terms.
            if sources > 1 { RadixSort.sortUnique(&terms) }
            index.keys.append(key)
            var previous: UInt32 = 0
            for term in terms {
                postings.append(varint: UInt64(term &- previous))
                previous = term
            }
            index.offsets.append(UInt32(postings.count))
        }
        index.postings = postings.bytes
        return index
    }

    @inline(__always)
    private static func compare(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Int {
        let common = min(lhs.count, rhs.count)
        if common > 0 {
            let order = memcmp(lhs.baseAddress!, rhs.baseAddress!, common)
            if order != 0 { return Int(order) }
        }
        return lhs.count - rhs.count
    }
}

extension SegmentView {
    /// The stored `updatedAt` as written: seconds since the reference date, NaN for none.
    func updatedAtRaw(_ document: Int) -> Double {
        updatedAt(document)?.timeIntervalSinceReferenceDate ?? .nan
    }
}
