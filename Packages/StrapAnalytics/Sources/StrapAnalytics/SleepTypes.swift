import Foundation

/// One contiguous run of a single sleep stage.
public struct StageSegment: Equatable, Sendable, Codable {
    public var start: Int
    public var end: Int
    /// "wake" | "light" | "deep" | "rem"
    public var stage: String
    public init(start: Int, end: Int, stage: String) {
        self.start = start; self.end = end; self.stage = stage
    }
    public var durationS: Int { max(0, end - start) }
}

/// A staged night.
///
/// A pure data carrier, kept separate from whatever produced it. Several engines — arousal
/// forensics, sleep readouts, debt — consume a staged night without caring which stager built it,
/// and separating the two lets an imported night and a locally staged one flow through the same
/// code.
public struct SleepSession: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let efficiency: Double
    public let stages: [StageSegment]
    public let restingHR: Int?
    public let avgHRV: Double?
    /// The stager kept this night but flagged it — the recorded span is longer than any single
    /// sleep it will vouch for. Shown with a caveat rather than hidden.
    public let lowConfidence: Bool

    public init(start: Int, end: Int, efficiency: Double, stages: [StageSegment],
                restingHR: Int?, avgHRV: Double?, lowConfidence: Bool = false) {
        self.start = start; self.end = end; self.efficiency = efficiency
        self.stages = stages; self.restingHR = restingHR; self.avgHRV = avgHRV
        self.lowConfidence = lowConfidence
    }
}
