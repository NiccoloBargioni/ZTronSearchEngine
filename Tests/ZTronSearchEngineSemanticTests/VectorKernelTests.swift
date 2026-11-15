import XCTest
@testable import ZTronSearchEngineSemantic

/// The kernels against naive per-element loops (specification section 7.3).
final class VectorKernelTests: XCTestCase {
    /// Lengths around the lane count of the simd kernels, and the two production sizes.
    private let lengths = [1, 2, 7, 15, 16, 17, 31, 32, 33, 100, 127, 128, 255, 256, 383, 384]

    private func randomCodes(_ count: Int, _ generator: inout SeededGenerator) -> [Int8] {
        (0..<count).map { _ in Int8(truncatingIfNeeded: Int(generator.next() % 256) - 128) }
    }

    func testFloatDotMatchesNaiveLoop() {
        var generator = SeededGenerator(seed: 1)
        for count in lengths {
            let a = generator.gaussianVector(count)
            let b = generator.gaussianVector(count)
            var expected: Double = 0
            for index in 0..<count { expected += Double(a[index]) * Double(b[index]) }
            XCTAssertEqual(Double(VectorKernels.dot(a, b)), expected, accuracy: 1e-3 * max(1, abs(expected)), "count \(count)")
        }
    }

    func testFloatSquaredDistanceMatchesNaiveLoop() {
        var generator = SeededGenerator(seed: 2)
        for count in lengths {
            let a = generator.gaussianVector(count)
            let b = generator.gaussianVector(count)
            var expected: Double = 0
            for index in 0..<count {
                let difference = Double(a[index]) - Double(b[index])
                expected += difference * difference
            }
            XCTAssertEqual(Double(VectorKernels.squaredDistance(a, b)), expected, accuracy: 1e-3 * max(1, expected), "count \(count)")
        }
    }

    func testNormAndNormalization() throws {
        var generator = SeededGenerator(seed: 3)
        for count in lengths {
            let vector = generator.gaussianVector(count)
            var expected: Double = 0
            for value in vector { expected += Double(value) * Double(value) }
            XCTAssertEqual(Double(VectorKernels.norm(vector)), expected.squareRoot(), accuracy: 1e-4 * max(1, expected.squareRoot()))

            let unit = try XCTUnwrap(VectorKernels.normalized(vector))
            XCTAssertEqual(VectorKernels.norm(unit), 1, accuracy: 1e-5)
            for index in 0..<count {
                XCTAssertEqual(Double(unit[index]), Double(vector[index]) / expected.squareRoot(), accuracy: 1e-5)
            }
        }
    }

    func testNormalizationRefusesVectorsWithoutDirection() {
        XCTAssertNil(VectorKernels.normalized([0, 0, 0]))
        XCTAssertNil(VectorKernels.normalized([1, .nan, 0]))
        XCTAssertNil(VectorKernels.normalized([1, .infinity, 0]))
        XCTAssertNil(VectorKernels.normalized([]))
        var untouched: [Float] = [0, 0]
        XCTAssertFalse(VectorKernels.normalize(&untouched))
        XCTAssertEqual(untouched, [0, 0])
    }

    func testInt8DotIsExact() {
        var generator = SeededGenerator(seed: 4)
        for count in lengths {
            for _ in 0..<8 {
                let a = randomCodes(count, &generator)
                let b = randomCodes(count, &generator)
                var expected: Int32 = 0
                for index in 0..<count { expected += Int32(a[index]) * Int32(b[index]) }
                XCTAssertEqual(VectorKernels.dot(a, b), expected, "count \(count)")
            }
        }
    }

    func testInt8DotAtTheExtremes() {
        for count in [16, 33, 384] {
            let low = [Int8](repeating: -128, count: count)
            let high = [Int8](repeating: 127, count: count)
            XCTAssertEqual(VectorKernels.dot(low, low), Int32(count) * 16_384)
            XCTAssertEqual(VectorKernels.dot(high, high), Int32(count) * 16_129)
            XCTAssertEqual(VectorKernels.dot(low, high), Int32(count) * -16_256)
        }
    }

    func testInt8SquaredDistanceIsExact() {
        var generator = SeededGenerator(seed: 5)
        for count in lengths {
            let a = randomCodes(count, &generator)
            let b = randomCodes(count, &generator)
            var expected: Int32 = 0
            for index in 0..<count {
                let difference = Int32(a[index]) - Int32(b[index])
                expected += difference * difference
            }
            XCTAssertEqual(VectorKernels.squaredDistance(a, b), expected, "count \(count)")
        }
        let low = [Int8](repeating: -128, count: 384)
        let high = [Int8](repeating: 127, count: 384)
        XCTAssertEqual(VectorKernels.squaredDistance(low, high), 384 * 255 * 255)
    }

    func testAsymmetricDotMatchesNaiveLoop() {
        var generator = SeededGenerator(seed: 6)
        for count in lengths {
            let query = generator.gaussianVector(count)
            let codes = randomCodes(count, &generator)
            var expected: Double = 0
            for index in 0..<count { expected += Double(query[index]) * Double(codes[index]) }
            XCTAssertEqual(Double(VectorKernels.dot(query, codes)), expected, accuracy: 1e-3 * max(1, abs(expected)), "count \(count)")
        }
    }

    func testWidenReproducesEveryCode() {
        let codes = (0..<256).map { Int8(truncatingIfNeeded: $0 - 128) }
        var widened = [Float](repeating: 0, count: codes.count)
        codes.withUnsafeBufferPointer { source in
            widened.withUnsafeMutableBufferPointer { target in
                VectorKernels.widen(source.baseAddress!, into: target.baseAddress!, count: codes.count)
            }
        }
        XCTAssertEqual(widened, codes.map(Float.init))
    }

    func testRowProductsMatchNaiveLoop() {
        var generator = SeededGenerator(seed: 7)
        let rowCount = 9
        let count = 37
        let rows = generator.gaussianVector(rowCount * count)
        let vector = generator.gaussianVector(count)
        var output = [Float](repeating: 0, count: rowCount)
        rows.withUnsafeBufferPointer { matrix in
            vector.withUnsafeBufferPointer { values in
                output.withUnsafeMutableBufferPointer { target in
                    VectorKernels.products(rows: matrix.baseAddress!, rowCount: rowCount, vector: values.baseAddress!, count: count, into: target.baseAddress!)
                }
            }
        }
        for row in 0..<rowCount {
            var expected: Double = 0
            for index in 0..<count { expected += Double(rows[row * count + index]) * Double(vector[index]) }
            XCTAssertEqual(Double(output[row]), expected, accuracy: 1e-3)
        }
    }
}
