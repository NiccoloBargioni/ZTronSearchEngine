import XCTest
@testable import ZTronSearchEngineSemantic

final class VectorQuantizationTests: XCTestCase {
    private func sample(count: Int, dimensions: Int, seed: UInt64) -> [[Float]] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { _ in generator.unitVector(dimensions) }
    }

    func testRoundTripErrorIsBoundedByHalfAStep() throws {
        let dimensions = 384
        let vectors = sample(count: 400, dimensions: dimensions, seed: 11)
        let quantization = try VectorQuantization.fitted(to: vectors, dimensions: dimensions)
        for vector in vectors {
            let decoded = try quantization.decode(quantization.encode(vector))
            for dimension in 0..<dimensions {
                // Every sample lies inside the fitted range, so nothing is clamped.
                XCTAssertTrue(quantization.range(dimension: dimension).contains(vector[dimension]))
                let bound = quantization.maximumRoundTripError(dimension: dimension) * 1.001 + 1e-7
                XCTAssertLessThanOrEqual(abs(decoded[dimension] - vector[dimension]), bound)
            }
        }
    }

    func testFittedStepIsFarFinerThanTheUniformOne() throws {
        let dimensions = 384
        let vectors = sample(count: 400, dimensions: dimensions, seed: 12)
        let fitted = try VectorQuantization.fitted(to: vectors, dimensions: dimensions)
        let uniform = try VectorQuantization.uniform(dimensions: dimensions)
        let fittedStep = fitted.scales.reduce(0, +) / Float(dimensions)
        let uniformStep = uniform.scales.reduce(0, +) / Float(dimensions)
        XCTAssertEqual(uniformStep, 1 / 127, accuracy: 1e-7)
        XCTAssertLessThan(fittedStep, uniformStep / 2)

        // And the reconstruction is correspondingly closer.
        var fittedError: Float = 0
        var uniformError: Float = 0
        for vector in vectors {
            fittedError += VectorKernels.squaredDistance(try fitted.decode(fitted.encode(vector)), vector)
            uniformError += VectorKernels.squaredDistance(try uniform.decode(uniform.encode(vector)), vector)
        }
        XCTAssertLessThan(fittedError, uniformError / 4)
    }

    func testUniformRoundTripNeverClampsUnitVectors() throws {
        let dimensions = 96
        let quantization = try VectorQuantization.uniform(dimensions: dimensions)
        var axis = [Float](repeating: 0, count: dimensions)
        axis[5] = 1
        axis[6] = -1
        let decoded = try quantization.decode(quantization.encode(axis))
        XCTAssertEqual(decoded[5], 1, accuracy: 1e-6)
        XCTAssertEqual(decoded[6], -1, accuracy: 1e-6)
        for vector in sample(count: 50, dimensions: dimensions, seed: 13) {
            let restored = try quantization.decode(quantization.encode(vector))
            for dimension in 0..<dimensions {
                XCTAssertLessThanOrEqual(abs(restored[dimension] - vector[dimension]), 0.5 / 127 + 1e-6)
            }
        }
    }

    func testEncodeMatchesNaiveRounding() throws {
        let dimensions = 64
        let vectors = sample(count: 300, dimensions: dimensions, seed: 14)
        let quantization = try VectorQuantization.fitted(to: vectors, dimensions: dimensions)
        for vector in vectors.prefix(40) {
            let codes = try quantization.encode(vector)
            for dimension in 0..<dimensions {
                let exact = (vector[dimension] - quantization.offsets[dimension]) / quantization.scales[dimension]
                let clamped = min(127, max(-127, exact))
                XCTAssertLessThanOrEqual(abs(Float(codes[dimension]) - clamped), 0.5 + 1e-3)
                XCTAssertGreaterThanOrEqual(codes[dimension], -127)
            }
        }
    }

    func testValuesOutsideTheRangeAreClamped() throws {
        let quantization = try VectorQuantization(offsets: [0.5, 0], scales: [0.01, 0.002])
        let codes = try quantization.encode([100, -100])
        XCTAssertEqual(codes, [127, -127])
        let decoded = try quantization.decode(codes)
        XCTAssertEqual(decoded[0], 0.5 + 1.27, accuracy: 1e-5)
        XCTAssertEqual(decoded[1], -0.254, accuracy: 1e-5)
        XCTAssertEqual(quantization.range(dimension: 0).upperBound, 1.77, accuracy: 1e-5)
    }

    func testHeadroomShrinksAsTheSampleGrows() throws {
        XCTAssertEqual(VectorQuantization.automaticHeadroom(sampleCount: 300), 0.28, accuracy: 0.01)
        XCTAssertEqual(VectorQuantization.automaticHeadroom(sampleCount: 20_000), 0.09, accuracy: 0.01)
        XCTAssertEqual(VectorQuantization.automaticHeadroom(sampleCount: 100_000), 0.057, accuracy: 0.005)
        XCTAssertGreaterThan(VectorQuantization.automaticHeadroom(sampleCount: 10_000_000), 0)

        // The fitted range is the observed one, widened on both sides by the headroom.
        let vectors = sample(count: 300, dimensions: 8, seed: 19)
        let tight = try VectorQuantization.fitted(to: vectors, dimensions: 8, headroom: 0)
        let wide = try VectorQuantization.fitted(to: vectors, dimensions: 8, headroom: 0.5)
        let automatic = try VectorQuantization.fitted(to: vectors, dimensions: 8)
        for dimension in 0..<8 {
            let observed = vectors.map { $0[dimension] }
            XCTAssertEqual(tight.range(dimension: dimension).lowerBound, observed.min()!, accuracy: 1e-5)
            XCTAssertEqual(tight.range(dimension: dimension).upperBound, observed.max()!, accuracy: 1e-5)
            XCTAssertEqual(wide.scales[dimension], tight.scales[dimension] * 2, accuracy: 1e-6)
            XCTAssertEqual(wide.offsets[dimension], tight.offsets[dimension], accuracy: 1e-6)
            let expected = 1 + 2 * VectorQuantization.automaticHeadroom(sampleCount: 300)
            XCTAssertEqual(automatic.scales[dimension], tight.scales[dimension] * expected, accuracy: 1e-6)
        }
    }

    func testSmallSamplesFallBackToTheUniformRange() throws {
        let few = sample(count: 10, dimensions: 32, seed: 15)
        XCTAssertEqual(try VectorQuantization.fitted(to: few, dimensions: 32), try VectorQuantization.uniform(dimensions: 32))
        let enough = sample(count: 10, dimensions: 32, seed: 15)
        XCTAssertNotEqual(
            try VectorQuantization.fitted(to: enough, dimensions: 32, minimumSampleCount: 10),
            try VectorQuantization.uniform(dimensions: 32)
        )
    }

    func testADimensionThatNeverMovesStillGetsAUsableStep() throws {
        var vectors = sample(count: 300, dimensions: 16, seed: 16)
        for index in vectors.indices { vectors[index][3] = 0.25 }
        let quantization = try VectorQuantization.fitted(to: vectors, dimensions: 16)
        XCTAssertGreaterThan(quantization.scales[3], 0)
        let widest = quantization.scales.max() ?? 0
        XCTAssertGreaterThanOrEqual(quantization.scales[3], widest * 0.019)
        XCTAssertEqual(try quantization.decode(quantization.encode(vectors[0]))[3], 0.25, accuracy: 1e-4)
    }

    func testPreparedQueryReproducesTheDotWithTheDecodedRow() throws {
        let dimensions = 384
        let vectors = sample(count: 300, dimensions: dimensions, seed: 17)
        let quantization = try VectorQuantization.fitted(to: vectors, dimensions: dimensions)
        var generator = SeededGenerator(seed: 18)
        for vector in vectors.prefix(20) {
            let query = generator.unitVector(dimensions)
            let codes = try quantization.encode(vector)
            var weights = [Float](repeating: 0, count: dimensions)
            let bias = query.withUnsafeBufferPointer { values in
                weights.withUnsafeMutableBufferPointer { quantization.prepare(values.baseAddress!, into: $0.baseAddress!) }
            }
            let fast = bias + VectorKernels.dot(weights, codes)
            let reference = VectorKernels.dot(query, try quantization.decode(codes))
            XCTAssertEqual(fast, reference, accuracy: 1e-4)
            // And the quantized similarity stays close to the exact one.
            XCTAssertEqual(fast, VectorKernels.dot(query, vector), accuracy: 2e-3)
        }
    }

    func testInvalidParametersAndVectorsAreRefused() throws {
        assertThrows(.unsupportedDimensions(0)) { try VectorQuantization(offsets: [], scales: []) }
        assertThrows(.unsupportedDimensions(385)) { try VectorQuantization.uniform(dimensions: 385) }
        assertThrows(.dimensionMismatch(expected: 2, found: 1)) { try VectorQuantization(offsets: [0, 0], scales: [1]) }
        XCTAssertThrowsError(try VectorQuantization(offsets: [0], scales: [0]))
        XCTAssertThrowsError(try VectorQuantization(offsets: [.nan], scales: [1]))
        XCTAssertThrowsError(try VectorQuantization.uniform(dimensions: 4, bound: 0))

        let quantization = try VectorQuantization.uniform(dimensions: 4)
        assertThrows(.dimensionMismatch(expected: 4, found: 3)) { try quantization.encode([1, 0, 0]) }
        assertThrows(.dimensionMismatch(expected: 4, found: 5)) { try quantization.decode([1, 0, 0, 0, 0]) }
        XCTAssertThrowsError(try quantization.encode([1, .nan, 0, 0])) { error in
            guard case SemanticError.invalidVector = error else { return XCTFail("unexpected \(error)") }
        }
        assertThrows(.dimensionMismatch(expected: 4, found: 3)) {
            try VectorQuantization.fitted(to: [[1, 0, 0, 0], [0, 1, 0]], dimensions: 4, minimumSampleCount: 2)
        }
    }
}
