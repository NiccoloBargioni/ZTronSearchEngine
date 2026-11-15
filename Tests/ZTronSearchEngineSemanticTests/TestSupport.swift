import Accelerate
import Foundation
import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSemantic

/// SplitMix64: a small, fast generator whose stream depends only on the seed, so every test
/// that uses it is reproducible on any machine.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    /// Standard normal, by Box-Muller.
    mutating func gaussian() -> Float {
        let u = max(unit(), 1e-7)
        let v = unit()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    mutating func gaussianVector(_ count: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: count)
        vector.withUnsafeMutableBufferPointer { buffer in
            for index in 0..<count { buffer[index] = gaussian() }
        }
        return vector
    }

    mutating func unitVector(_ count: Int) -> [Float] {
        var vector = gaussianVector(count)
        VectorKernels.normalize(&vector)
        return vector
    }
}

/// A synthetic corpus shaped like sentence embeddings: unit vectors grouped in topics.
///
/// Topics belong to a handful of super-topics, so clusters have near and far neighbours. Inside
/// a topic the points spread along a low-rank basis with a decaying spectrum, plus isotropic
/// noise over all dimensions. What makes nearest-neighbour search hard is not the ambient
/// dimension but the local intrinsic dimension (LID) of the data, so every shape below states
/// the LID it produces, measured with the Levina-Bickel estimator on the 20 exact neighbours of
/// 1,000 queries.
struct ClusteredCorpus {
    /// The statistics of a corpus.
    struct Shape {
        var name: String
        /// Points per topic. Far more than `efSearch`, so a search cannot just enumerate a topic.
        var clusterSize: Int
        var superCount: Int
        /// Directions a topic spreads along.
        var rank: Int
        /// The spread along direction `j` falls off as `(1 + j)^-exponent`.
        var spectrumExponent: Float
        var spread: Float
        /// Length of the isotropic noise added to every point.
        var noise: Float

        /// Tight topics: LID about 16, nearest neighbours at a cosine similarity of about 0.92.
        static let tight = Shape(name: "tight", clusterSize: 2_000, superCount: 12, rank: 24, spectrumExponent: 0.5, spread: 0.35, noise: 0.10)
        /// Diffuse topics: LID about 27, the range measured on real sentence-embedding sets;
        /// nearest neighbours at a cosine similarity of about 0.75.
        static let diffuse = Shape(name: "diffuse", clusterSize: 2_000, superCount: 12, rank: 48, spectrumExponent: 0.25, spread: 0.30, noise: 0.15)
        /// Isotropic Gaussian topics: LID about 94. No embedding model produces this; it is the
        /// stress case that shows how recall degrades with intrinsic dimension.
        static let isotropic = Shape(name: "isotropic", clusterSize: 2_000, superCount: 12, rank: 1, spectrumExponent: 0, spread: 0, noise: 0.8)
    }

    let dimensions: Int
    let shape: Shape
    let clusterCount: Int
    private let centers: [[Float]]
    /// Per cluster, `rank` rows of `dimensions` floats.
    private let bases: [[Float]]
    private let spectrum: [Float]

    /// - Parameter count: The number of points the corpus will be asked for; it fixes the
    ///   number of topics.
    init(dimensions: Int, count: Int, shape: Shape, seed: UInt64) {
        self.dimensions = dimensions
        self.shape = shape
        self.clusterCount = max(4, count / shape.clusterSize)
        var generator = SeededGenerator(seed: seed)
        let supers = (0..<shape.superCount).map { _ in generator.unitVector(dimensions) }
        var centers: [[Float]] = []
        var bases: [[Float]] = []
        for cluster in 0..<clusterCount {
            let parent = supers[cluster % shape.superCount]
            let own = generator.unitVector(dimensions)
            var center = [Float](repeating: 0, count: dimensions)
            var weight: Float = 0.7
            vDSP_vsma(own, 1, &weight, parent, 1, &center, 1, vDSP_Length(dimensions))
            VectorKernels.normalize(&center)
            centers.append(center)
            // Random directions in high dimension are close to orthonormal once scaled.
            var basis = generator.gaussianVector(shape.rank * dimensions)
            var scale = 1 / Float(dimensions).squareRoot()
            vDSP_vsmul(basis, 1, &scale, &basis, 1, vDSP_Length(basis.count))
            bases.append(basis)
        }
        self.centers = centers
        self.bases = bases
        self.spectrum = (0..<shape.rank).map { pow(Float(1 + $0), -shape.spectrumExponent) }
    }

    /// Draws `count` points; the topic of point `i` is `i % clusterCount`.
    func points(count: Int, seed: UInt64) -> [[Float]] {
        var generator = SeededGenerator(seed: seed)
        var result: [[Float]] = []
        result.reserveCapacity(count)
        let rank = shape.rank
        var latent = [Float](repeating: 0, count: rank)
        var along = [Float](repeating: 0, count: dimensions)
        let length = vDSP_Length(dimensions)
        for index in 0..<count {
            let cluster = index % clusterCount
            for component in 0..<rank {
                latent[component] = generator.gaussian() * spectrum[component] * shape.spread
            }
            // along = latent (1 x rank) * basis (rank x dimensions)
            vDSP_mmul(latent, 1, bases[cluster], 1, &along, 1, 1, length, vDSP_Length(rank))
            var point = generator.gaussianVector(dimensions)
            var noiseScale = shape.noise / Float(dimensions).squareRoot()
            vDSP_vsmul(point, 1, &noiseScale, &point, 1, length)
            vDSP_vadd(point, 1, along, 1, &point, 1, length)
            vDSP_vadd(point, 1, centers[cluster], 1, &point, 1, length)
            VectorKernels.normalize(&point)
            result.append(point)
        }
        return result
    }
}

/// A directory under the system temporary directory, removed when the test ends.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztron-semantic-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

extension XCTestCase {
    /// Asserts that `expression` throws exactly `expected`.
    func assertThrows<T>(
        _ expected: SemanticError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ expression: () throws -> T
    ) {
        do {
            _ = try expression()
            XCTFail("expected \(expected), but nothing was thrown", file: file, line: line)
        } catch let error as SemanticError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    /// The asynchronous form of ``assertThrows(_:file:line:_:)``.
    func assertThrowsAsync<T>(
        _ expected: SemanticError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ expression: () async throws -> T
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected), but nothing was thrown", file: file, line: line)
        } catch let error as SemanticError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

/// Monotonic time in seconds, for the latency reports.
func monotonicSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

/// The `fraction` quantile of `samples` by the nearest-rank method.
func quantile(_ samples: [Double], _ fraction: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[min(sorted.count - 1, max(0, rank - 1))]
}
