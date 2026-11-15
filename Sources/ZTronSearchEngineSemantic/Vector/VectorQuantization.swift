import Accelerate
import Foundation

/// INT8 scalar quantization of one embedding space.
///
/// Each dimension has its own affine map: a stored code `c` in -127...127 stands for the value
/// `offsets[i] + scales[i] * c`. Per-dimension parameters matter for real sentence embeddings,
/// where a few dimensions carry a large constant component: a single global scale would spend
/// most of its 8 bits on that constant.
///
/// The index searches asymmetrically. A query stays in `Float`; ``prepare(_:into:)`` folds the
/// parameters into it once, after which the similarity with any stored row is one widening and
/// one dot product over the raw codes:
///
///     query . decode(codes) = bias + weights . codes
///     weights[i] = query[i] * scales[i]        bias = query . offsets
public struct VectorQuantization: Sendable, Hashable {
    /// Value a code of zero stands for, per dimension.
    public let offsets: [Float]
    /// Width of one code step, per dimension; always positive.
    public let scales: [Float]

    /// The largest magnitude a code takes. -128 is never written, so the range is symmetric.
    public static let codeLimit: Float = 127

    /// Stores fitted from fewer vectors than this use ``uniform(dimensions:bound:)``: a
    /// per-dimension range estimated from a handful of samples would clip later vectors.
    public static let defaultMinimumSampleCount = 256

    /// Components per vector.
    public var dimensions: Int { offsets.count }

    /// - Throws: ``SemanticError/unsupportedDimensions(_:)`` or ``SemanticError/invalidVector(_:)``
    ///   when the parameters are not usable.
    public init(offsets: [Float], scales: [Float]) throws {
        guard offsets.count == scales.count else {
            throw SemanticError.dimensionMismatch(expected: offsets.count, found: scales.count)
        }
        guard (1...SemanticLimits.maximumDimensions).contains(offsets.count) else {
            throw SemanticError.unsupportedDimensions(offsets.count)
        }
        guard offsets.allSatisfy(\.isFinite), scales.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw SemanticError.invalidVector("quantization parameters must be finite, and scales positive")
        }
        self.offsets = offsets
        self.scales = scales
    }

    /// The same symmetric range `-bound...bound` for every dimension.
    ///
    /// With the default bound of 1 no component of a unit-length vector can ever clip, at the
    /// price of a coarse step (1/127). It is what a store uses until it has seen enough
    /// vectors to fit real ranges.
    public static func uniform(dimensions: Int, bound: Float = 1) throws -> VectorQuantization {
        guard bound.isFinite, bound > 0 else {
            throw SemanticError.invalidVector("the quantization bound must be positive")
        }
        return try VectorQuantization(
            offsets: [Float](repeating: 0, count: max(0, dimensions)),
            scales: [Float](repeating: bound / codeLimit, count: max(0, dimensions))
        )
    }

    /// Fits per-dimension ranges to a sample of the vectors that will be stored.
    ///
    /// Each dimension maps its observed minimum and maximum, widened by `headroom` of the range
    /// on both sides, onto the code range. Vectors stored later that fall outside are clamped,
    /// which costs far more accuracy than a slightly coarser step, so the default headroom
    /// (``automaticHeadroom(sampleCount:)``) is generous for small samples and tight for large
    /// ones.
    ///
    /// - Parameters:
    ///   - vectors: The sample; every vector must have `dimensions` finite components.
    ///   - headroom: Fraction of each dimension's range added on both sides; `nil` picks it
    ///     from the sample size.
    ///   - minimumSampleCount: Below this many vectors the result is
    ///     ``uniform(dimensions:bound:)`` with a bound of 1.
    public static func fitted(
        to vectors: [[Float]],
        dimensions: Int,
        headroom: Float? = nil,
        minimumSampleCount: Int = defaultMinimumSampleCount
    ) throws -> VectorQuantization {
        guard (1...SemanticLimits.maximumDimensions).contains(dimensions) else {
            throw SemanticError.unsupportedDimensions(dimensions)
        }
        guard vectors.count >= max(2, minimumSampleCount) else {
            return try uniform(dimensions: dimensions)
        }
        var minima = [Float](repeating: .greatestFiniteMagnitude, count: dimensions)
        var maxima = [Float](repeating: -.greatestFiniteMagnitude, count: dimensions)
        let length = vDSP_Length(dimensions)
        try minima.withUnsafeMutableBufferPointer { low in
            try maxima.withUnsafeMutableBufferPointer { high in
                guard let lowBase = low.baseAddress, let highBase = high.baseAddress else { return }
                for vector in vectors {
                    guard vector.count == dimensions else {
                        throw SemanticError.dimensionMismatch(expected: dimensions, found: vector.count)
                    }
                    try vector.withUnsafeBufferPointer { values in
                        guard let base = values.baseAddress else { return }
                        guard VectorKernels.squaredNorm(base, count: dimensions).isFinite else {
                            throw SemanticError.invalidVector("a sample vector holds a value that is not finite")
                        }
                        vDSP_vmin(lowBase, 1, base, 1, lowBase, 1, length)
                        vDSP_vmax(highBase, 1, base, 1, highBase, 1, length)
                    }
                }
            }
        }

        // range = max - min, widened; a dimension that barely moves in the sample still gets a
        // usable step, so a later vector that does move there is not crushed to a constant.
        var offsets = [Float](repeating: 0, count: dimensions)
        var scales = [Float](repeating: 0, count: dimensions)
        minima.withUnsafeBufferPointer { low in
            maxima.withUnsafeBufferPointer { high in
                offsets.withUnsafeMutableBufferPointer { offsetBuffer in
                    scales.withUnsafeMutableBufferPointer { scaleBuffer in
                        guard let lowBase = low.baseAddress, let highBase = high.baseAddress,
                              let offsetBase = offsetBuffer.baseAddress, let scaleBase = scaleBuffer.baseAddress else { return }
                        var half: Float = 0.5
                        vDSP_vasm(lowBase, 1, highBase, 1, &half, offsetBase, 1, length)        // (min + max) / 2

                        vDSP_vsub(lowBase, 1, highBase, 1, scaleBase, 1, length)                // max - min
                        var widening = 1 + 2 * max(0, headroom ?? automaticHeadroom(sampleCount: vectors.count))
                        vDSP_vsmul(scaleBase, 1, &widening, scaleBase, 1, length)
                        var widest: Float = 0
                        vDSP_maxv(scaleBase, 1, &widest, length)
                        var floor = max(widest * 0.02, 1e-6)
                        var ceiling = Float.greatestFiniteMagnitude
                        vDSP_vclip(scaleBase, 1, &floor, &ceiling, scaleBase, 1, length)
                        var steps = 2 * codeLimit
                        vDSP_vsdiv(scaleBase, 1, &steps, scaleBase, 1, length)                  // range / 254
                    }
                }
            }
        }
        return try VectorQuantization(offsets: offsets, scales: scales)
    }

    /// The headroom ``fitted(to:dimensions:headroom:minimumSampleCount:)`` uses by default.
    ///
    /// The extremes of a sample grow with its size: for Gaussian components, like the square
    /// root of the logarithm of the count. The range fitted to `sampleCount` vectors is widened
    /// by the factor those extremes are expected to grow by once sixteen times as many vectors,
    /// and at least 2^20, have been stored: 28% per side for 300 vectors, 6% for 100,000.
    public static func automaticHeadroom(sampleCount: Int) -> Float {
        let count = Double(max(2, sampleCount))
        let future = max(16 * count, 1_048_576)
        let growth = (log(future) / log(count)).squareRoot()
        return Float((growth - 1) / 2)
    }

    // MARK: Encoding and decoding

    /// Quantizes a vector. Components outside a dimension's range are clamped.
    ///
    /// - Throws: ``SemanticError/dimensionMismatch(expected:found:)`` or
    ///   ``SemanticError/invalidVector(_:)``.
    public func encode(_ vector: [Float]) throws -> [Int8] {
        guard vector.count == dimensions else {
            throw SemanticError.dimensionMismatch(expected: dimensions, found: vector.count)
        }
        var scratch = [Float](repeating: 0, count: dimensions)
        return try [Int8](unsafeUninitializedCapacity: dimensions) { codes, initialized in
            try vector.withUnsafeBufferPointer { values in
                try scratch.withUnsafeMutableBufferPointer { work in
                    guard let source = values.baseAddress, let workBase = work.baseAddress, let target = codes.baseAddress else { return }
                    guard VectorKernels.squaredNorm(source, count: dimensions).isFinite else {
                        throw SemanticError.invalidVector("the vector holds a value that is not finite")
                    }
                    encode(source, into: target, scratch: workBase)
                }
            }
            initialized = dimensions
        }
    }

    /// Quantizes `dimensions` finite values into `codes`, using `scratch` (room for
    /// `dimensions` floats) as working storage.
    func encode(_ vector: UnsafePointer<Float>, into codes: UnsafeMutablePointer<Int8>, scratch: UnsafeMutablePointer<Float>) {
        let length = vDSP_Length(dimensions)
        var low = -Self.codeLimit
        var high = Self.codeLimit
        offsets.withUnsafeBufferPointer { offsetBuffer in
            scales.withUnsafeBufferPointer { scaleBuffer in
                guard let offsetBase = offsetBuffer.baseAddress, let scaleBase = scaleBuffer.baseAddress else { return }
                vDSP_vsub(offsetBase, 1, vector, 1, scratch, 1, length)       // vector - offsets
                vDSP_vdiv(scaleBase, 1, scratch, 1, scratch, 1, length)       // ... / scales
                vDSP_vclip(scratch, 1, &low, &high, scratch, 1, length)
                vDSP_vfixr8(scratch, 1, codes, 1, length)                      // round to nearest
            }
        }
    }

    /// The values a row of codes stands for.
    public func decode(_ codes: [Int8]) throws -> [Float] {
        guard codes.count == dimensions else {
            throw SemanticError.dimensionMismatch(expected: dimensions, found: codes.count)
        }
        return [Float](unsafeUninitializedCapacity: dimensions) { values, initialized in
            codes.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress, let target = values.baseAddress else { return }
                decode(sourceBase, into: target)
            }
            initialized = dimensions
        }
    }

    /// Decodes `dimensions` codes into `values`.
    func decode(_ codes: UnsafePointer<Int8>, into values: UnsafeMutablePointer<Float>) {
        let length = vDSP_Length(dimensions)
        offsets.withUnsafeBufferPointer { offsetBuffer in
            scales.withUnsafeBufferPointer { scaleBuffer in
                guard let offsetBase = offsetBuffer.baseAddress, let scaleBase = scaleBuffer.baseAddress else { return }
                vDSP_vflt8(codes, 1, values, 1, length)
                vDSP_vma(values, 1, scaleBase, 1, offsetBase, 1, values, 1, length)   // codes * scales + offsets
            }
        }
    }

    /// Folds the parameters into a query so that `bias + weights . codes` is its dot product
    /// with the decoded row.
    ///
    /// - Parameter weights: Room for `dimensions` floats; receives `query * scales`.
    /// - Returns: The bias, `query . offsets`.
    func prepare(_ query: UnsafePointer<Float>, into weights: UnsafeMutablePointer<Float>) -> Float {
        let length = vDSP_Length(dimensions)
        var bias: Float = 0
        offsets.withUnsafeBufferPointer { offsetBuffer in
            scales.withUnsafeBufferPointer { scaleBuffer in
                guard let offsetBase = offsetBuffer.baseAddress, let scaleBase = scaleBuffer.baseAddress else { return }
                vDSP_dotpr(query, 1, offsetBase, 1, &bias, length)
                vDSP_vmul(query, 1, scaleBase, 1, weights, 1, length)
            }
        }
        return bias
    }

    /// The largest error ``decode(_:)`` of ``encode(_:)`` makes on a component of dimension
    /// `dimension` that lies inside the dimension's range: half a code step.
    public func maximumRoundTripError(dimension: Int) -> Float {
        scales[dimension] / 2
    }

    /// The values dimension `dimension` can represent without clamping.
    public func range(dimension: Int) -> ClosedRange<Float> {
        let reach = scales[dimension] * Self.codeLimit
        return (offsets[dimension] - reach)...(offsets[dimension] + reach)
    }

    /// Mixed into store fingerprints.
    var digest: UInt64 {
        Fingerprint.hash(offsets, seed: 0x6F66_6673) ^ Fingerprint.hash(scales, seed: 0x7363_616C)
    }
}
