import Foundation

/// The reference device of the specification and the budgets measured against it (section 15).
///
/// Every target is a p95 on an iPhone 6s (A9, 2 GB RAM, no Neural Engine), iOS 15.8, 100,000
/// indexed items, Release build. Tests that run elsewhere cannot prove a budget is met there;
/// what they can do is refuse to pass unless the code is faster than the budget by at least the
/// factor the reference device is slower than the machine running them. That is a necessary
/// condition, not a sufficient one: only a run on the device settles a gate.
public enum ReferenceDevice {
    /// How many times slower one core of the reference device is than one core of the machine
    /// running the tests. On the reference device itself the factor is 1.
    ///
    /// The estimate for Apple-silicon Macs and the simulators they host is 6: single-core
    /// benchmark scores put an A9 at roughly a fifth to a sixth of an M-series performance core,
    /// before the difference in memory bandwidth.
    public static var slowdown: Double {
        if let override = ProcessInfo.processInfo.environment["ZTRON_REFERENCE_SLOWDOWN"].flatMap(Double.init), override >= 1 {
            return override
        }
        #if targetEnvironment(simulator) || os(macOS)
        return 6
        #else
        return isReferenceHardware ? 1 : 3
        #endif
    }

    /// `true` when the process runs on the reference device itself.
    public static var isReferenceHardware: Bool {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let model = String(decoding: machine.prefix { $0 != 0 }, as: UTF8.self)
        // iPhone8,1 is the iPhone 6s; iPhone8,2 the 6s Plus.
        return model == "iPhone8,1" || model == "iPhone8,2"
    }

    /// The time the machine running the tests must stay under for `budget` seconds on the
    /// reference device to be plausible.
    public static func scaled(_ budget: TimeInterval) -> TimeInterval {
        budget / slowdown
    }
}

/// The p95 budgets of specification section 15, in seconds and bytes.
public enum PerformanceBudget {
    // 15.1 Latency
    /// Tokenization and normalization of a query of 64 characters or fewer.
    public static let tokenization: TimeInterval = 0.0003
    public static let prefixLookup: TimeInterval = 0.003
    /// BM25F scoring of 2,000 candidates or fewer.
    public static let scoring: TimeInterval = 0.003
    /// Fuzzy expansion at 8 candidates per token.
    public static let fuzzyExpansion: TimeInterval = 0.006
    /// RRF fusion of 3 channels x 200 entries.
    public static let fusion: TimeInterval = 0.0005
    /// First lexical snapshot, from the debounce firing to published.
    public static let lexicalSnapshot: TimeInterval = 0.012
    public static let queryEmbedding: TimeInterval = 0.180
    public static let queryEmbeddingHardCap: TimeInterval = 0.300
    public static let nearestNeighbours: TimeInterval = 0.005
    /// Semantic snapshot after the typing pause, including the 300 ms debounce.
    public static let semanticSnapshot: TimeInterval = 0.500
    public static let rerank: TimeInterval = 0.250
    public static let rerankHardCap: TimeInterval = 0.400
    public static let rerankedSnapshot: TimeInterval = 0.750
    public static let nextPage: TimeInterval = 0.008
    /// Cold start to search-ready from a memory-mapped index.
    public static let coldStart: TimeInterval = 0.250
    /// Full lexical rebuild on locale change, 100,000 items.
    public static let localeRebuild: TimeInterval = 2.0
    /// Incremental upsert, amortized per document.
    public static let upsertPerDocument: TimeInterval = 0.0001
    /// Main-thread cost of publishing a 20-hit snapshot.
    public static let publish: TimeInterval = 0.001

    // 15.2 Memory, resident
    public static let lexicalIndexBytes = 40 * 1024 * 1024
    public static let secondaryLanguageBytes = 10 * 1024 * 1024
    public static let itemVectorBytes = 40 * 1024 * 1024
    public static let graphBytes = 20 * 1024 * 1024
    public static let embeddingModelBytes = 80 * 1024 * 1024
    public static let rerankerModelBytes = 60 * 1024 * 1024

    // 15.8 Small contexts, scan strategy
    public static let scanCreation40: TimeInterval = 0.005
    public static let scanCreation500: TimeInterval = 0.050
    public static let scanQuery40: TimeInterval = 0.0005
    public static let scanQuery500: TimeInterval = 0.003
    public static let scanContextBytes40 = 100 * 1024
    public static let scanContextBytes500 = 1024 * 1024

    // 15.9 Database sources
    /// Context creation from 10k rows, 3 string fields, 2 languages.
    public static let databaseContext10k: TimeInterval = 1.5
    /// One page: read, resolve and project 500 rows.
    public static let databasePage: TimeInterval = 0.040
    /// Incremental upsert of 100 changed rows, after the commit.
    public static let databaseUpsert100: TimeInterval = 0.050
    public static let databaseContextBytes10k = 6 * 1024 * 1024
    public static let databaseIndexWrite10k: TimeInterval = 0.400
    public static let databaseIndexLoad10k: TimeInterval = 0.250
}

/// Timing helpers for the performance tests.
public enum Measure {
    /// Runs `body` `iterations` times and returns each duration in seconds.
    public static func durations(iterations: Int, warmup: Int = 3, _ body: () throws -> Void) rethrows -> [TimeInterval] {
        for _ in 0..<warmup { try body() }
        var durations: [TimeInterval] = []
        durations.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
        }
        return durations
    }

    /// Runs an asynchronous `body` `iterations` times and returns each duration in seconds.
    public static func durations(iterations: Int, warmup: Int = 3, _ body: () async throws -> Void) async rethrows -> [TimeInterval] {
        for _ in 0..<warmup { try await body() }
        var durations: [TimeInterval] = []
        durations.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try await body()
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
        }
        return durations
    }

    /// The value below which the given share of samples fall.
    public static func percentile(_ share: Double, of samples: [TimeInterval]) -> TimeInterval {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * share).rounded(.down)))]
    }

    public static func p95(_ samples: [TimeInterval]) -> TimeInterval { percentile(0.95, of: samples) }
    public static func p50(_ samples: [TimeInterval]) -> TimeInterval { percentile(0.50, of: samples) }

    /// Bytes of live heap allocations of the process. Unlike the footprint, it drops the moment
    /// memory is freed, so the difference between two readings is what an object really holds.
    public static func heapInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }

    /// Bytes of a memory-mapped region this process has actually touched: the pages of an index
    /// file that are resident on account of the search subsystem. `data` must be a mapping (or
    /// any page-aligned buffer); `range` narrows the count to part of it. Whole pages are
    /// counted, so two neighbouring ranges may both count the page they share.
    public static func referencedBytes(of data: Data, in range: Range<Int>? = nil) -> Int {
        data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress, raw.count > 0 else { return 0 }
            let pageSize = Int(getpagesize())
            guard UInt(bitPattern: base) % UInt(pageSize) == 0 else { return range?.count ?? raw.count }
            let pages = (raw.count + pageSize - 1) / pageSize
            var states = [CChar](repeating: 0, count: pages)
            guard mincore(UnsafeMutableRawPointer(mutating: base), raw.count, &states) == 0 else { return range?.count ?? raw.count }
            // In core and referenced through this mapping.
            let wanted = CChar(MINCORE_INCORE | MINCORE_REFERENCED)
            let bounds = range ?? 0..<raw.count
            guard !bounds.isEmpty else { return 0 }
            let first = bounds.lowerBound / pageSize
            let last = min(pages - 1, (bounds.upperBound - 1) / pageSize)
            guard first <= last else { return 0 }
            var total = 0
            for page in first...last where (states[page] & wanted) == wanted { total += pageSize }
            return total
        }
    }

    /// Resident memory footprint of the process, in bytes.
    public static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
