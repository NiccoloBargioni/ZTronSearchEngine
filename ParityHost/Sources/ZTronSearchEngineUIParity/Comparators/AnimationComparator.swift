import Foundation

/// What a frame-by-frame recording of one field shows about an animation.
public struct AnimationRecording: Codable, Sendable {
    /// Seconds between the first frame that differs from its predecessor and the last one that
    /// does; 0 when the whole change lands in a single frame, that is, nothing animates.
    ///
    /// A display shows whole frames, so the duration is a whole number of frame periods: the
    /// time between the two samples, as their display link reported it, rounded to frames.
    /// On a simulator that time can be off a frame period by a few milliseconds from one
    /// refresh to the next; `rawDuration` keeps it as it was reported.
    public var duration: Double
    public var rawDuration: Double
    /// Frames that differ from their predecessor.
    public var changedFrames: Int
    public var sampledFrames: Int
    /// The time between samples: the resolution of `duration`.
    public var medianFrameInterval: Double
    public var longestFrameInterval: Double
    /// What changed in each of the first changed frames, for a reader of the result.
    public var changeLog: [String] = []

    public init(duration: Double, changedFrames: Int, sampledFrames: Int, medianFrameInterval: Double, longestFrameInterval: Double) {
        self.duration = duration
        rawDuration = duration
        self.changedFrames = changedFrames
        self.sampledFrames = sampledFrames
        self.medianFrameInterval = medianFrameInterval
        self.longestFrameInterval = longestFrameInterval
    }

    /// Builds a recording from the time of every sample and whether it differed from the one
    /// before it.
    ///
    /// - Parameter framePeriod: the display's refresh period; `nil` leaves the duration as
    ///   the samples' own times give it.
    public init(timestamps: [Double], changed: [Bool], framePeriod: Double? = nil) {
        precondition(timestamps.count == changed.count, "one flag per sample")
        let changedTimes = zip(timestamps, changed).filter(\.1).map(\.0)
        var intervals: [Double] = []
        for index in timestamps.indices.dropFirst() { intervals.append(timestamps[index] - timestamps[index - 1]) }
        intervals.sort()
        let raw = (changedTimes.last ?? 0) - (changedTimes.first ?? 0)
        var duration = raw
        if let framePeriod, framePeriod > 0 { duration = (raw / framePeriod).rounded() * framePeriod }
        self.init(
            duration: duration,
            changedFrames: changedTimes.count,
            sampledFrames: timestamps.count,
            medianFrameInterval: intervals.isEmpty ? 0 : intervals[intervals.count / 2],
            longestFrameInterval: intervals.last ?? 0
        )
        rawDuration = raw
    }
}

public struct AnimationComparison: Codable, Sendable {
    public var reference: AnimationRecording
    public var clone: AnimationRecording
    /// |reference duration − clone duration|, in seconds.
    public var durationDifference: Double
    /// The comparison of the two final frames passed.
    public var sameFinalFrame: Bool
    /// Set when the recordings cannot support a verdict at one-frame precision.
    public var precisionNote: String?
    public var passes: Bool
}

/// Animation of the text-to-token conversion: same duration within one frame (16.7 ms) and
/// same final frame (specification section 15.7).
public enum AnimationComparator {
    public static let frame = 1.0 / 60.0

    public static func compare(reference: AnimationRecording, clone: AnimationRecording, sameFinalFrame: Bool) -> AnimationComparison {
        let difference = abs(reference.duration - clone.duration)
        var note: String?
        let coarsest = max(reference.medianFrameInterval, clone.medianFrameInterval)
        if coarsest > frame * 1.5 {
            note = String(format: "sampled every %.1f ms, coarser than one frame: the duration is known to that resolution only", coarsest * 1000)
        }
        if reference.changedFrames == 0 || clone.changedFrames == 0 {
            note = "no change was recorded on \(reference.changedFrames == 0 ? "the reference" : "the clone")"
        }
        return AnimationComparison(
            reference: reference, clone: clone, durationDifference: difference, sameFinalFrame: sameFinalFrame,
            precisionNote: note,
            passes: difference <= frame + 1e-9 && sameFinalFrame && reference.changedFrames > 0 && clone.changedFrames > 0
        )
    }
}
