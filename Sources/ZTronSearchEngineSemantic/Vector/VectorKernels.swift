import Accelerate
import Foundation
import simd

/// Distance kernels over `Float` and INT8 vectors.
///
/// Specification section 7.3 forbids per-element Swift loops in the hot path, so every kernel
/// is a vDSP call or a 16-lane simd loop. The pointer forms are the ones the index uses; the
/// array forms exist for callers and tests and check their arguments.
///
/// Three families:
/// - `Float` with `Float`: vDSP.
/// - INT8 with INT8: exact integer arithmetic in 16-lane simd vectors.
/// - `Float` with INT8, the asymmetric form the index searches with: the stored codes are
///   widened with `vDSP_vflt8` and reduced with `vDSP_dotpr`, so the query keeps its full
///   precision and only the stored side is quantized.
public enum VectorKernels: Sendable {
    // MARK: Float with Float

    /// Dot product of two `Float` vectors of `count` elements.
    @inline(__always)
    public static func dot(_ lhs: UnsafePointer<Float>, _ rhs: UnsafePointer<Float>, count: Int) -> Float {
        var result: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(count))
        return result
    }

    /// Dot product of two `Float` vectors of equal length.
    public static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        precondition(lhs.count == rhs.count, "vectors must have the same length")
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                guard let l = left.baseAddress, let r = right.baseAddress else { return 0 }
                return dot(l, r, count: lhs.count)
            }
        }
    }

    /// Squared Euclidean distance between two `Float` vectors of `count` elements.
    @inline(__always)
    public static func squaredDistance(_ lhs: UnsafePointer<Float>, _ rhs: UnsafePointer<Float>, count: Int) -> Float {
        var result: Float = 0
        vDSP_distancesq(lhs, 1, rhs, 1, &result, vDSP_Length(count))
        return result
    }

    /// Squared Euclidean distance between two `Float` vectors of equal length.
    public static func squaredDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        precondition(lhs.count == rhs.count, "vectors must have the same length")
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                guard let l = left.baseAddress, let r = right.baseAddress else { return 0 }
                return squaredDistance(l, r, count: lhs.count)
            }
        }
    }

    /// Sum of squares of a `Float` vector of `count` elements.
    @inline(__always)
    public static func squaredNorm(_ vector: UnsafePointer<Float>, count: Int) -> Float {
        var result: Float = 0
        vDSP_svesq(vector, 1, &result, vDSP_Length(count))
        return result
    }

    /// Euclidean length of a `Float` vector.
    public static func norm(_ vector: [Float]) -> Float {
        vector.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return squaredNorm(base, count: vector.count).squareRoot()
        }
    }

    /// Scales `vector` to unit length in place.
    ///
    /// - Returns: `false`, leaving the vector untouched, when it has no direction (zero length)
    ///   or holds a value that is not finite.
    @discardableResult
    public static func normalize(_ vector: inout [Float]) -> Bool {
        let count = vector.count
        return vector.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            let squared = squaredNorm(base, count: count)
            // A sum of squares is finite exactly when every element is, short of overflow, and
            // a vector that overflows the sum has no usable direction either.
            guard squared.isFinite, squared > 0 else { return false }
            var length = squared.squareRoot()
            vDSP_vsdiv(base, 1, &length, base, 1, vDSP_Length(count))
            return true
        }
    }

    /// `vector` scaled to unit length, or `nil` when it has no direction or is not finite.
    public static func normalized(_ vector: [Float]) -> [Float]? {
        var copy = vector
        return normalize(&copy) ? copy : nil
    }

    /// Products of every row of a row-major matrix with one vector: `output[r] = rows[r] . vector`.
    @inline(__always)
    public static func products(
        rows: UnsafePointer<Float>,
        rowCount: Int,
        vector: UnsafePointer<Float>,
        count: Int,
        into output: UnsafeMutablePointer<Float>
    ) {
        vDSP_mmul(rows, 1, vector, 1, output, 1, vDSP_Length(rowCount), 1, vDSP_Length(count))
    }

    // MARK: INT8 with INT8

    /// Exact dot product of two INT8 vectors of `count` elements.
    ///
    /// Sixteen lanes at a time: the codes are widened to 16 bits, multiplied (a product of two
    /// INT8 values always fits), widened again and accumulated in 32 bits. Exact for any
    /// `count` up to 65,536.
    public static func dot(_ lhs: UnsafePointer<Int8>, _ rhs: UnsafePointer<Int8>, count: Int) -> Int32 {
        let left = UnsafeRawPointer(lhs)
        let right = UnsafeRawPointer(rhs)
        var accumulator = SIMD16<Int32>()
        var index = 0
        while index &+ 16 <= count {
            let a = SIMD16<Int16>(truncatingIfNeeded: left.loadUnaligned(fromByteOffset: index, as: SIMD16<Int8>.self))
            let b = SIMD16<Int16>(truncatingIfNeeded: right.loadUnaligned(fromByteOffset: index, as: SIMD16<Int8>.self))
            accumulator &+= SIMD16<Int32>(truncatingIfNeeded: a &* b)
            index &+= 16
        }
        var sum = simd_reduce_add(accumulator)
        // At most 15 trailing elements when `count` is not a multiple of the lane count.
        while index < count {
            sum &+= Int32(lhs[index]) &* Int32(rhs[index])
            index &+= 1
        }
        return sum
    }

    /// Exact dot product of two INT8 vectors of equal length.
    public static func dot(_ lhs: [Int8], _ rhs: [Int8]) -> Int32 {
        precondition(lhs.count == rhs.count, "vectors must have the same length")
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                guard let l = left.baseAddress, let r = right.baseAddress else { return 0 }
                return dot(l, r, count: lhs.count)
            }
        }
    }

    /// Exact squared Euclidean distance between two INT8 vectors of `count` elements.
    public static func squaredDistance(_ lhs: UnsafePointer<Int8>, _ rhs: UnsafePointer<Int8>, count: Int) -> Int32 {
        let left = UnsafeRawPointer(lhs)
        let right = UnsafeRawPointer(rhs)
        var accumulator = SIMD16<Int32>()
        var index = 0
        while index &+ 16 <= count {
            let a = SIMD16<Int16>(truncatingIfNeeded: left.loadUnaligned(fromByteOffset: index, as: SIMD16<Int8>.self))
            let b = SIMD16<Int16>(truncatingIfNeeded: right.loadUnaligned(fromByteOffset: index, as: SIMD16<Int8>.self))
            // A difference of two INT8 values fits 16 bits; its square needs 32.
            let difference = SIMD16<Int32>(truncatingIfNeeded: a &- b)
            accumulator &+= difference &* difference
            index &+= 16
        }
        var sum = simd_reduce_add(accumulator)
        while index < count {
            let difference = Int32(lhs[index]) &- Int32(rhs[index])
            sum &+= difference &* difference
            index &+= 1
        }
        return sum
    }

    /// Exact squared Euclidean distance between two INT8 vectors of equal length.
    public static func squaredDistance(_ lhs: [Int8], _ rhs: [Int8]) -> Int32 {
        precondition(lhs.count == rhs.count, "vectors must have the same length")
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                guard let l = left.baseAddress, let r = right.baseAddress else { return 0 }
                return squaredDistance(l, r, count: lhs.count)
            }
        }
    }

    // MARK: Float with INT8

    /// Widens `count` INT8 codes to `Float`.
    @inline(__always)
    public static func widen(_ codes: UnsafePointer<Int8>, into output: UnsafeMutablePointer<Float>, count: Int) {
        vDSP_vflt8(codes, 1, output, 1, vDSP_Length(count))
    }

    /// Dot product of a `Float` vector with an INT8 vector.
    ///
    /// - Parameter scratch: Room for `count` floats; holds the widened codes on return.
    @inline(__always)
    public static func dot(
        _ lhs: UnsafePointer<Float>,
        _ codes: UnsafePointer<Int8>,
        count: Int,
        scratch: UnsafeMutablePointer<Float>
    ) -> Float {
        vDSP_vflt8(codes, 1, scratch, 1, vDSP_Length(count))
        var result: Float = 0
        vDSP_dotpr(lhs, 1, scratch, 1, &result, vDSP_Length(count))
        return result
    }

    /// Dot product of a `Float` vector with an INT8 vector of equal length.
    public static func dot(_ lhs: [Float], _ codes: [Int8]) -> Float {
        precondition(lhs.count == codes.count, "vectors must have the same length")
        var scratch = [Float](repeating: 0, count: lhs.count)
        return lhs.withUnsafeBufferPointer { left in
            codes.withUnsafeBufferPointer { right in
                scratch.withUnsafeMutableBufferPointer { buffer in
                    guard let l = left.baseAddress, let r = right.baseAddress, let s = buffer.baseAddress else { return 0 }
                    return dot(l, r, count: lhs.count, scratch: s)
                }
            }
        }
    }
}
