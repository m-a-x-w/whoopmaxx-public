import Foundation
import StrapAnalytics

// WorkoutTailTrimmer.swift — post-pass that trims cooldown / EPOC drift off auto-detect candidates.
//
// THE BUG THIS EXISTS FOR (user-confirmed via the Signal Lab Detection panel): a low overnight
// resting HR puts the elevated floor (resting + 30) BELOW normal post-workout daytime HR, so the
// cooldown / EPOC drift after a real bout never drops back under the floor. The base detector's
// span-growing rule (only a > 90 s sub-floor dip closes a span) and the interval detector's chain
// rule then run the candidate from the workout's start to HOURS later — a ~50 min strength session
// surfaces as a ~4 h suggestion. Both detectors are structurally unable to see this: the frozen
// StrapAnalytics `AutoWorkoutDetector` is byte-parity with its Android twin, so the fix is a pure
// app-layer post-pass applied to BOTH detectors' candidates in `WorkoutRepository.autoDetectCandidate`
// before the merge / dismiss / newest-first steps.
//
// THE IDEA: actual WORK sits high in the candidate's own heart-rate reserve; cooldown drift sits
// well below it. Anchor the span to its last (and, symmetrically, first — walking to the gym has
// the same drift shape) sample inside the work band, pad by a short cooldown grace, and recompute
// the stats. A candidate that no longer passes its detector's gates after the trim was never a
// workout-shaped span to begin with — drop it.
//
// Pure / headless: no I/O, no clock. All ts/start/end are unix SECONDS. NOT medical advice.

enum WorkoutTailTrimmer {

    // MARK: - Constants

    /// The work band: a sample counts as WORK when its bpm reaches at least
    /// resting + `workFraction` × (peak − resting) — a fraction of the candidate's OWN reserve.
    /// WHY 0.6: cooldown / EPOC drift settles well below the work band (typically < 0.4 of the
    /// bout's reserve), while a steady easy session holds ~≥ 0.6 of its own reserve throughout —
    /// so drift is cut but an honest steady run is never trimmed at all.
    static let workFraction = 0.6

    /// Wall-clock padding kept beyond the first/last work sample (5 min). Real sessions taper —
    /// the last hard set isn't the last moment of the workout — so the trimmed span keeps a
    /// cooldown's (and warm-up's) worth of margin instead of cutting at the final peak effort.
    static let cooldownGraceS = 300

    /// Degenerate guard: when the span's peak clears resting by no more than this, the span is
    /// flat — there is no work band to separate from drift (the work mark would sit at or below
    /// the elevated floor the detectors already gated on), so trimming is meaningless. 40 bpm =
    /// the detectors' elevated gate (+30) plus a 10 bpm cushion.
    static let flatPeakMarginBPM = AutoWorkoutDetector.elevatedMarginBPM + 10

    // MARK: - Types

    /// Which detector produced the candidate — revalidation after the trim re-applies THAT
    /// detector's gates (a base candidate must still sustain ≥ 12 min; an interval candidate must
    /// still pass the SessionEval gates).
    enum Kind {
        case base
        case interval
    }

    /// The trim verdict, kept whole (raw + trimmed + the work mark) so the Signal Lab detection
    /// panel can show exactly what the post-pass did to each candidate.
    enum Outcome: Equatable {
        /// Nothing to trim (degenerate span, or every sample already inside the work band + grace).
        case unchanged(DetectedWorkout)
        /// Drift cut off one or both ends; `trimmed` is what the suggestion path carries forward.
        case trimmed(raw: DetectedWorkout, trimmed: DetectedWorkout, workMarkBpm: Int)
        /// The trimmed span no longer passes its detector's gates — not a workout-shaped span.
        case dropped(raw: DetectedWorkout, workMarkBpm: Int)

        /// The candidate the suggestion path should keep (nil = dropped).
        var survivor: DetectedWorkout? {
            switch self {
            case .unchanged(let w): return w
            case .trimmed(_, let t, _): return t
            case .dropped: return nil
            }
        }
    }

    // MARK: - Public API

    /// Trim cooldown / EPOC drift (and pre-workout warm-up drift) off `candidate`.
    ///
    /// Algorithm:
    ///  1. peak = max bpm inside the span; workMark = resting + `workFraction` × (peak − resting).
    ///  2. Trimmed end = last in-span sample with bpm ≥ workMark, + `cooldownGraceS`; trimmed
    ///     start = first such sample − `cooldownGraceS` (both clamped to the raw span).
    ///  3. Recompute durationMin / avgBpm / peakBpm over the trimmed span, matching the source
    ///     detector's avg semantics (base: all samples in the window; interval: elevated only).
    ///  4. Revalidate against the source detector's gates; failing candidates are `.dropped`.
    ///
    /// Degenerate guards (→ `.unchanged`): span shorter than the grace, flat span
    /// (peak ≤ resting + `flatPeakMarginBPM`), or no samples inside the span.
    ///
    /// PRECONDITION (P5, and load-bearing since then): `hr` must be sorted ASCENDING by ts. This
    /// used to say "any order" and re-established the order itself with a defensive `.sorted` —
    /// see the cost note in the body for why that went away. Every caller already satisfied it:
    /// production and the Signal Lab panel both read `WorkoutRepository.autoDetectHR`, whose
    /// `hrBuckets` query is `GROUP BY … ORDER BY bucket ASC` (strictly increasing, distinct
    /// timestamps — that guarantee is written down at `autoDetectHR`), and the test fixtures build
    /// the same shape with `stride`. A caller handing this an unordered series now gets a wrong
    /// window rather than a slow right one.
    ///
    /// - Parameters:
    ///   - candidate: a `DetectedWorkout` from either detector.
    ///   - kind: which detector produced it (selects avg semantics + revalidation gates).
    ///   - hr: the SAME `(ts, bpm)` series the detectors saw, ascending by ts (see PRECONDITION).
    ///   - restingBpm: the same nightly resting HR; nil → the detectors' 60 bpm fallback.
    static func trim(_ candidate: DetectedWorkout,
                     kind: Kind,
                     hr: [(ts: Int, bpm: Int)],
                     restingBpm: Int?) -> Outcome {
        // Span shorter than the grace: the grace alone would cover it — nothing to trim.
        guard candidate.endSec - candidate.startSec >= cooldownGraceS else {
            return .unchanged(candidate)
        }

        // The candidate's window as an index RANGE into `hr`, not a copy of it.
        //
        // P5, THE OTHER HALF — WHAT CHANGED AND WHY. This used to open with the identical
        // `hr.filter { … }.sorted { … }` that `WorkoutRepository.zone3PlusMinutes` opened with, and
        // it was the LARGER half of that allocation cost: the dose filter runs once per MERGED
        // candidate, while this post-pass runs once per candidate of BOTH un-merged detector sets —
        // every base span and every interval session, including the ones the merge is about to
        // discard. Each of those calls scanned the whole 7-day series (up to 120,960 points) and
        // allocated two fresh tuple arrays, and the in-trim recompute at step 3 then filtered the
        // copy a third time. All three passes are gone: `hr` arrives strictly ascending (see
        // `autoDetectHR`), so the window is a binary-searched index range (`spanRange`, left
        // `nonisolated static` and internal for exactly this adoption) walked with plain cursors.
        //
        // ARITHMETIC UNTOUCHED — the outcomes are byte-identical, which is what
        // `WorkoutTailTrimmerTests` and `AutoDetectQueueTests` pin. Same INCLUSIVE
        // `[startSec, endSec]` window (`spanRange`'s upper bound is the first ts STRICTLY greater
        // than `to`, reproducing the old `$0.ts <= endSec`); same peak; same first/last work sample,
        // found by scanning the range forward and backward exactly as `first(where:)` /
        // `last(where:)` walked the array; same per-kind average population; same gates.
        let spanIdx = WorkoutRepository.spanRange(hr, from: candidate.startSec, to: candidate.endSec)
        // Empty range = no samples in the span, the case the old `.max()` returned nil for.
        guard !spanIdx.isEmpty else { return .unchanged(candidate) }
        var peak = Int.min
        for i in spanIdx {
            let bpm = hr[i].bpm
            if bpm > peak { peak = bpm }
        }

        let resting = restingBpm ?? AutoWorkoutDetector.defaultRestingHR
        // Flat span: no work band to separate from drift.
        guard peak > resting + flatPeakMarginBPM else { return .unchanged(candidate) }

        // 1: the work mark — `workFraction` of the span's own reserve above resting.
        let workMark = Double(resting) + workFraction * Double(peak - resting)
        let markBpm = Int(workMark.rounded())

        // 2: anchor to the first/last WORK sample, pad by the grace, clamp to the raw span.
        // The peak sample itself is always ≥ workMark (workFraction < 1), so both exist.
        guard let firstWork = spanIdx.first(where: { Double(hr[$0].bpm) >= workMark }),
              let lastWork = spanIdx.last(where: { Double(hr[$0].bpm) >= workMark }) else {
            return .unchanged(candidate)
        }
        let start = max(candidate.startSec, hr[firstWork].ts - cooldownGraceS)
        let end = min(candidate.endSec, hr[lastWork].ts + cooldownGraceS)
        guard start > candidate.startSec || end < candidate.endSec else {
            return .unchanged(candidate)
        }

        // 3: recompute stats over the trimmed span, matching the source detector's semantics —
        // base averages EVERY sample in its window, interval averages the ELEVATED samples only
        // (rests would dilute a set-cadence average).
        // `start`/`end` are clamped INSIDE the raw span, so this range always nests inside `spanIdx`
        // — searching `hr` again rather than `spanIdx` costs one more O(log n) probe and yields the
        // identical indices, because everything outside `spanIdx` is outside `[start, end]` too.
        let trimIdx = WorkoutRepository.spanRange(hr, from: start, to: end)
        let floor = resting + AutoWorkoutDetector.elevatedMarginBPM
        // One cursor replaces the `filter`/`map`/`reduce`/`max` chain and its three intermediate
        // arrays. The per-kind predicate is applied to the SELECTED population verbatim rather than
        // reasoned away: `peakInTrim` is the max over the samples that were averaged, exactly as the
        // old `bpms.max()` was, so the interval case still takes its peak from elevated samples only.
        let elevatedOnly: Bool
        switch kind {
        case .base: elevatedOnly = false
        case .interval: elevatedOnly = true
        }
        var sum = 0, count = 0, peakInTrim = Int.min
        for i in trimIdx {
            let bpm = hr[i].bpm
            if elevatedOnly && bpm < floor { continue }
            sum += bpm
            count += 1
            if bpm > peakInTrim { peakInTrim = bpm }
        }
        // No sample survived the population filter — the old empty-`bpms` drop.
        guard count > 0 else { return .dropped(raw: candidate, workMarkBpm: markBpm) }
        let avg = Int((Double(sum) / Double(count)).rounded())
        let trimmed = DetectedWorkout(startSec: start, endSec: end,
                                      avgBpm: avg, peakBpm: peakInTrim,
                                      durationMin: (end - start) / 60)

        // 4: revalidate against the source detector's gates.
        switch kind {
        case .base:
            guard Double(end - start) >= AutoWorkoutDetector.minSustainedMin * 60.0 else {
                return .dropped(raw: candidate, workMarkBpm: markBpm)
            }
        case .interval:
            // Re-run the SessionEval gates over the trimmed window's samples — the trimmed span
            // must still contain a qualifying set/rest session.
            //
            // The ONE copy left in this function, and it buys something: `sessions(hr:)` takes a
            // concrete `[(ts, bpm)]`, so the slice has to be materialised. Two things make it cheap
            // where the old code was not — it is sized to the TRIMMED WINDOW instead of the 7-day
            // series, and it is only reached by an interval candidate that actually got trimmed
            // (every `.unchanged` return above short-circuits ahead of it). It stays a copy rather
            // than becoming a slice parameter because `IntervalWorkoutDetector` is not this pass's
            // file to reshape.
            let stillQualifies = IntervalWorkoutDetector
                .sessions(hr: Array(hr[trimIdx]), restingBpm: restingBpm)
                .contains { $0.qualifies }
            guard stillQualifies else {
                return .dropped(raw: candidate, workMarkBpm: markBpm)
            }
        }
        return .trimmed(raw: candidate, trimmed: trimmed, workMarkBpm: markBpm)
    }
}
