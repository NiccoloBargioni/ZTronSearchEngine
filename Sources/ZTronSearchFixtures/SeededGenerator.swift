import Foundation

/// A deterministic random number generator: SplitMix64.
///
/// The same seed yields the same sequence on every run and on every platform, which is what
/// makes the fixtures reproducible. It is not a cryptographic generator.
///
/// The standard library's `Int.random(in:using:)` and friends are free to change how they turn
/// random bits into values between Swift releases, so the fixtures never go through them: they
/// call ``next()``, ``index(below:)`` and ``int(in:)``, whose arithmetic is fixed here.
public struct SeededGenerator: RandomNumberGenerator, Sendable, Hashable {
    /// The internal state. Two generators with the same state produce the same sequence.
    public private(set) var state: UInt64

    /// Creates a generator. Every seed is valid, zero included.
    public init(seed: UInt64) {
        state = seed
    }

    /// The next 64 random bits.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return SeededGenerator.mix(state)
    }

    /// A uniform index in `0..<bound`. `bound` must be positive.
    ///
    /// The value is the high half of the 128-bit product of the next 64 bits and `bound`. The
    /// bias is at most `bound / 2^64`, far below anything a fixture can observe.
    public mutating func index(below bound: Int) -> Int {
        precondition(bound > 0, "bound must be positive")
        return Int(truncatingIfNeeded: next().multipliedFullWidth(by: UInt64(bound)).high)
    }

    /// A uniform integer in a closed range.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + index(below: range.upperBound - range.lowerBound + 1)
    }

    /// `true` with probability `numerator / denominator`.
    public mutating func chance(_ numerator: Int, in denominator: Int) -> Bool {
        index(below: denominator) < numerator
    }

    /// A generator for an independent stream, derived from this seed and a stream number.
    ///
    /// Used to give every item of a corpus its own sequence, so item `n` is the same whatever
    /// the size of the corpus it is generated in.
    public static func stream(seed: UInt64, _ stream: UInt64) -> SeededGenerator {
        SeededGenerator(seed: mix(seed ^ mix(stream &+ 0xD6E8_FEB8_6659_FD93)))
    }

    /// The SplitMix64 output function: a bijective mix of 64 bits. Also used as a hash.
    @inline(__always)
    public static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
