import Foundation
import StrapAnalytics

/// The ONE owner of the `stagesJSON` stage vocabulary.
///
/// The store's stage-timeline shape (`DayEngine.encodeStages` / `SleepWindowReclip` / `DemoSeed`)
/// is `[{"start":epoch,"end":epoch,"stage":"light|deep|rem|wake"}]` — STRING stages, wall-clock unix
/// seconds. Writers in the frozen `StrapAnalytics` package only ever emit `wake | light | deep | rem`
/// (`StageSegment.stage`; `SleepStagingV2` renames its internal "awake" label to "wake" before it builds
/// a `StageSegment`). `awake` is accepted here as a READ-ONLY alias because imported imported nights carry
/// it (same alias `SleepStageTotals` honours: "the stager calls awake 'wake'; the importer 'awake'").
///
/// Every decode of `stagesJSON` in the app goes through `decode(_:)` so the accepted token set lives in
/// exactly one place. An unrecognised token is a SILENT DROP of just that segment (never a throw and
/// never a fabricated stage) — a future writer emitting a new label degrades to a gap in the hypnogram
/// rather than a wrong stage. `ArousalForensicsLoader` deliberately does NOT use this: it hands the raw
/// `[StageSegment]` straight back to a frozen-package API.
enum SleepStage: String, CaseIterable {
    case wake, awake, rem, light, deep

    /// Parse one `stagesJSON` stage token, case-insensitively. nil = unrecognised (caller drops it).
    init?(token: String) {
        self.init(rawValue: token.lowercased())
    }

    /// The hypnogram lane code `StepHypnogram` renders top→bottom: 0 = awake, 1 = REM, 2 = light,
    /// 3 = deep. Both wake spellings collapse onto lane 0.
    var laneCode: Int {
        switch self {
        case .wake, .awake: return 0
        case .rem:          return 1
        case .light:        return 2
        case .deep:         return 3
        }
    }

    /// Decode a `stagesJSON` payload into typed segments, in stored order.
    ///
    /// Decodes the VENDORED `StrapAnalytics.StageSegment` — the exact type `DayEngine.encodeStages`
    /// writes — so the read shape can never drift from the write shape. Unknown stage tokens and
    /// zero/negative-length spans (`end` must be strictly after `start`) are dropped segment-by-segment;
    /// nil or structurally-malformed JSON yields [] (one bad element fails the WHOLE array decode, since
    /// `start`/`end`/`stage` are all required).
    static func decode(_ stagesJSON: String?) -> [(start: Int, end: Int, stage: SleepStage)] {
        guard let stagesJSON,
              let data = stagesJSON.data(using: .utf8),
              let segs = try? JSONDecoder().decode([StageSegment].self, from: data) else { return [] }
        return segs.compactMap { seg -> (start: Int, end: Int, stage: SleepStage)? in
            guard seg.end > seg.start, let stage = SleepStage(token: seg.stage) else { return nil }
            return (seg.start, seg.end, stage)
        }
    }
}
