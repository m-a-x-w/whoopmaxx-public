import Foundation
import StrapAnalytics
import StrapProtocol

// HRVByStage.swift — rMSSD (and, where the record can hold one, a Lomb-Scargle spectrum) bucketed by
// SLEEP STAGE, so the app can say whether HRV recovered THROUGH the night instead of only on average.
//
// WHAT THIS ANSWERS THAT THE APP CANNOT TODAY. `dailyMetric.avgHrv` is one number per night: the mean of
// 5-minute-window rMSSDs across the whole session (`SleepStaging.sessionAvgHRV`). It cannot distinguish a
// night where deep sleep carried the parasympathetic rebound from a night of the same average where deep
// was flat and a couple of REM blocks did all the lifting. This engine splits the same estimator by the
// stored hypnogram's stage labels.
//
// PURE AND STORELESS BY CONSTRUCTION. Stage spans + R-R intervals in, per-stage readings out. No store,
// no SwiftUI, no actor isolation, no clock — every input is a parameter and the output is a function of
// them alone, so the whole thing is testable without a fixture database.
//
// ── THE PROVENANCE TRAP THIS ENGINE EXISTS TO SURVIVE ───────────────────────────────────────────────
//
// The stored `stagesJSON` in this project is `SleepStagingV2` output, and V2 ASSERTS A STAGE ACROSS SPANS
// WHERE NO CHANNEL HAD ANY DATA. Its epoch loop skips an epoch with neither HR nor gravity coverage
// (`SleepStagingV2.swift:286`, `if hrs.isEmpty && gseq.isEmpty { e += 30; continue }`), and the tiling that
// follows (`:118-131`) stretches the PRECEDING label across the resulting hole — the segment's `end` is
// the next STAGED epoch's start, not the end of the evidence. The hypnogram therefore claims stage over
// clock the strap never watched, and it does so silently: nothing in the JSON marks the stretch.
//
// Bucketing HRV by such a span is the single worst thing this engine could do. Measured on the real
// 2026-08-09 corpus (22 staged sessions), the session ending 08-02 carries a 176-MINUTE "deep" segment in
// which only 20 of its 352 thirty-second epochs hold any in-range R-R at all — 5.7 % coverage — while
// still containing 570 in-range beats clustered at the edges. A naive implementation has far more than
// the 20 beats `HRVAnalyzer` asks for and would return a confident, beautiful deep-sleep rMSSD computed
// from ten minutes of data and attributed to nearly three hours the strap was not reading. That is the
// app asserting a number it did not measure.
//
// So: EVERY span must prove real R-R coverage before it contributes, and a stage that cannot prove it
// returns ABSENCE (`rmssd == nil` plus a verdict saying which way it failed) — never zero, never a
// quietly-smaller number computed from whatever beats happened to be lying around.
//
// ── THE COVERAGE BAR, AND WHY IT IS THE ONE IT IS ───────────────────────────────────────────────────
//
// Coverage is measured as THE FRACTION OF A SPAN'S WHOLE 30-SECOND EPOCHS THAT HOLD AT LEAST ONE IN-RANGE
// R-R INTERVAL, on the same absolute wall-clock 30 s grid V2 itself stages on (`SleepStagingV2.swift:277`,
// `firstE = ((start + 29) / 30) * 30`). Two rejected alternatives, and why:
//
//   • BEAT COUNT alone is no defence — the phantom span above has 570 of them.
//   • Σ(R-R durations) ÷ span, the ratio `HRVFreqReadout.coverage` uses, is the right measure for ITS
//     question (does the tachogram's cumulative-sum clock match wall time) but the wrong one here: the
//     store timestamps R-R rows to whole seconds and averages 1.28 rows per distinct second, so at any
//     ordinary heart rate several ~800 ms beats land on one second of clock and the ratio runs over 1.
//     Measured on the corpus it reaches 1.93 for light and 1.96 for deep, which makes it useless as a
//     floor. Epoch occupancy is immune: a second either has a beat in it or it does not.
//
// The floor is 0.60, chosen against the measured distribution rather than picked round. Night-pooled
// epoch coverage over the 22 real sessions:
//
//     deep   min 0.237  p10 0.667  median 1.000      (the 0.237 IS the phantom night)
//     rem    min 0.889  p10 0.966  median 0.990
//     light  min 0.884  p10 0.937  median 0.997
//     wake   min 0.292  p10 0.564  median 0.681
//
// 0.60 sits in a genuine trough: it rejects the phantom (0.237) with a wide margin, rejects nothing else
// in deep / REM / light (whose next-lowest real values are 0.667, 0.889 and 0.884), and keeps wake — which
// legitimately reads worse, being short, fragmented and full of movement — on 18 of 22 nights while
// blanking the four where wake's own coverage really is under three-fifths. A 0.80 floor would have blanked
// wake on 17 of 22 nights; a 0.50 floor would still have admitted spans a third of which were never watched.
//
// ── WHY THE ESTIMATOR IS 5-MINUTE WINDOWS AND NOT ONE POOLED rMSSD ──────────────────────────────────
//
// A single rMSSD pooled over all of a stage's beats would NOT be comparable to the nightly HRV the app
// already shows, because that nightly number is the MEAN OF PER-5-MINUTE-WINDOW rMSSDs, not a pooled one
// (`SleepStaging.sessionAvgHRV`, SleepStaging.swift:2474). Putting two different estimators side by side
// ("night 48 ms, deep 61 ms") would invite a comparison neither number supports. So this engine mirrors
// that recipe exactly — tumbling 5-minute windows, the same two admission constants, the same splice-safe
// Δ-statistic — but anchors the windows inside each stage span instead of across the session. The mirror
// is deliberate duplication of an INTERNAL frozen-package function we cannot call; if `sessionAvgHRV`'s
// recipe ever changes, `stageWindowRmssds` below is the place that has to change with it.
//
// Windows never cross a span boundary, which also makes cross-span splicing structurally impossible: two
// deep blocks hours apart are never differenced against each other, because no window ever contains beats
// from both.
//
// ── COPY / HONESTY CONTRACT ─────────────────────────────────────────────────────────────────────────
//
// Descriptive and within-user. rMSSD is a time-domain dispersion of successive R-R differences and nothing
// more; a per-stage split of it is not a "recovery quality", not a sleep verdict, and not a diagnosis.
// Banned from any string a surface builds on this type, exactly as in `HRVFreqReadout`: impaired, poor,
// abnormal, apnea, insomnia, arrhythmia, "consider", "you should", "talk to". Every withheld value is an
// absence with a stated reason, and the reason is about THE RECORD, never about the person.

enum HRVByStage {

    // MARK: - Vocabulary

    /// The four canonical stage buckets, declared in reporting order (deep first: it is the stage the
    /// question is usually about).
    ///
    /// This is NOT a second stage vocabulary. `SleepStage` remains the one owner of the `stagesJSON` token
    /// table (`Core/Data/SleepStage.swift`); this enum is the BUCKET set, which differs from it in exactly
    /// one way — `SleepStage` carries both `wake` and `awake` because the stager and the importer spell the
    /// same state differently, and a bucket must collapse them or the same night would report two wakes.
    enum Stage: String, CaseIterable, Sendable {
        case deep, rem, light, wake

        /// Collapse a decoded `stagesJSON` token onto its bucket. Total on purpose — every token
        /// `SleepStage` accepts has a bucket, so a span can never be silently lost between the two types.
        init(_ stage: SleepStage) {
            switch stage {
            case .deep:         self = .deep
            case .rem:          self = .rem
            case .light:        self = .light
            case .wake, .awake: self = .wake
            }
        }
    }

    /// One stage span: half-open `[start, end)` in wall-clock unix seconds, matching the contiguous tiling
    /// `DayEngine.encodeStages` writes (each segment's `end` is the next segment's `start`). Half-open
    /// is what keeps a beat landing exactly on a boundary from being counted into both neighbours.
    struct Span: Equatable, Sendable {
        let start: Int
        let end: Int
        let stage: Stage

        init(start: Int, end: Int, stage: Stage) {
            self.start = start
            self.end = end
            self.stage = stage
        }

        /// Clock the span claims, in seconds. Clamped at 0 so a malformed (end <= start) span contributes
        /// nothing rather than a negative that would corrupt a total.
        var durationSec: Int { max(0, end - start) }
    }

    // MARK: - Result

    /// Why a stage has no number. Each case means exactly one thing, so a surface can caption it without
    /// having to re-derive anything, and `.measured` is the ONLY case in which `Reading.rmssd` is non-nil.
    enum Verdict: Equatable, Sendable {
        /// The stage has a value.
        case measured
        /// The hypnogram never labelled this stage at all — there is nothing to have measured.
        case notLabelled
        /// Labelled with enough clock to speak for, but under `minEpochCoverage` of that clock holds any
        /// R-R. This is the verdict the V2 phantom span earns.
        case notObserved
        /// The stage's admitted clock is under `minStageSec` — a real but too-brief span (or the observed
        /// part of one) that cannot carry a stage-level claim.
        case tooLittleTime
        /// Enough admitted clock, but no 5-minute window inside it cleared the beat-count / noise gate —
        /// the strap was timestamping rows the cleaning pipeline then threw away.
        case tooFewBeats
    }

    /// One stage's reading. The quantities that qualify the number travel WITH it, so a surface never has
    /// to decide on its own how much of the night a value speaks for.
    struct Reading: Equatable, Sendable {
        let stage: Stage

        /// Mean of the 5-minute-window rMSSDs (ms) across this stage's admitted spans, or nil.
        ///
        /// nil is ABSENCE — the stage was not measured. It is never 0, and it is never a smaller number
        /// substituted for a larger one; see `verdict` for which way it failed.
        let rmssd: Double?

        /// Which of the five outcomes produced (or withheld) `rmssd`.
        let verdict: Verdict

        /// Fraction of this stage's whole 30-second epochs — across ALL its spans, admitted or not — that
        /// hold at least one in-range R-R interval. 0 when the stage claims no whole epoch.
        ///
        /// Reported over all spans rather than only the admitted ones because the thing being qualified is
        /// the hypnogram's claim about this stage, not the subset of it that survived.
        let coverage: Double

        /// Seconds of this stage the hypnogram claims, over every span.
        let claimedSec: Int

        /// Seconds in the spans that cleared the coverage bar — the clock the reading actually speaks for.
        /// Always <= `claimedSec`; the gap is span the strap did not watch closely enough to bucket.
        ///
        /// A SURFACE MUST NOT PRINT `rmssd` WITHOUT THIS PAIR WHEN THEY DIFFER, and they really do differ on
        /// real data. On the 2026-08-09 corpus the night ending 08-02 claims 217 minutes of deep, 176 of
        /// which are the phantom span; this engine excludes that span, measures 70.3 ms over the 41 real
        /// minutes, and reports `admittedSec` ≈ 2 460 against `claimedSec` ≈ 13 020 with `coverage` 0.24.
        /// The number is honest — it is the deep the strap actually watched — but rendering it bare as
        /// "deep 70 ms" would let the reader assume it speaks for all 217 minutes, which is the same false
        /// claim by a different route. Blanking it instead would be the opposite error: throwing away 41
        /// minutes of real measurement. So the qualification travels with the value and the surface renders
        /// both.
        let admittedSec: Int

        /// Number of 5-minute windows that produced a value and were averaged into `rmssd`.
        let windows: Int

        /// Clean intervals behind those windows, after range + Malik ectopic rejection.
        let cleanBeats: Int

        /// Lomb-Scargle LF / HF / LF-HF / total power over the stage's LONGEST admitted span, or nil.
        ///
        /// PER-SPAN AND NEVER POOLED, deliberately. `HRVFreqDomain` builds its time base from the CUMULATIVE
        /// SUM of the cleaned intervals (`HRVFreqDomain.swift:106-114`), so concatenating a stage's several
        /// blocks — which in a real night are scattered across seven hours — would sew them into one
        /// continuous record and inject broadband power at every seam. A spectrum is a property of one
        /// continuous record; the longest admitted span is the only place a stage reliably has one, it is
        /// chosen deterministically (ties broken by the earlier start), and it is reported alone rather than
        /// averaged so nothing is cherry-picked by aggregation.
        ///
        /// Withheld (nil) unless that span's OWN epoch coverage clears `minBandCoverage`, which is stricter
        /// than the time-domain floor for the reason `HRVFreqReadout` documents: the cumulative-sum clock
        /// stitches gaps shut invisibly and scales every reported frequency by 1/coverage, with no nil to
        /// warn anyone. Also nil whenever the engine's own span gates decline (under 20 clean beats, or
        /// under `HRVFreqDomain.minSpanForHFSec` of tachogram).
        let bands: HRVFreqDomain.Bands?

        /// Seconds of the span `bands` was read over, or nil when `bands` is nil. A spectrum without the
        /// length of the record it came from is not interpretable.
        let bandSpanSec: Int?

        /// How much of the stage's claimed clock the reading speaks for, in [0, 1]. 1 means every span of
        /// this stage cleared the coverage bar; anything less means part of the hypnogram's claim is not
        /// behind the number. 0 when the stage claims no clock at all.
        var admittedFraction: Double {
            claimedSec > 0 ? Double(admittedSec) / Double(claimedSec) : 0
        }
    }

    /// A night's readings: exactly one per `Stage`, always all four, in `Stage.allCases` order. A stage that
    /// the hypnogram never labelled is present with `.notLabelled` rather than missing, so a surface can lay
    /// out a fixed four-row table without having to invent a placeholder.
    struct Night: Equatable, Sendable {
        let readings: [Reading]

        /// Unreachable for any `Night` `analyze` produces — it builds one reading per case of
        /// `Stage.allCases` — but total rather than force-unwrapped on purpose. A missing reading means
        /// "nothing is known about this stage", and `.notLabelled` with zeroed quantities IS that
        /// statement, so the fallback cannot become a fabricated measurement.
        subscript(stage: Stage) -> Reading {
            readings.first { $0.stage == stage } ?? Reading(stage: stage, rmssd: nil,
                                                            verdict: .notLabelled, coverage: 0,
                                                            claimedSec: 0, admittedSec: 0, windows: 0,
                                                            cleanBeats: 0, bands: nil, bandSpanSec: nil)
        }
    }

    // MARK: - Floors (public so tests can pin them and a surface can caption them)

    /// The staging grid, seconds. Absolute and wall-clock aligned, matching the grid `SleepStagingV2` stages
    /// on (`SleepStagingV2.swift:277`), so an epoch this engine measures is an epoch V2 either staged or
    /// stretched a label across.
    static let epochSec: Int = 30

    /// Minimum fraction of a span's whole epochs that must hold in-range R-R before the span may contribute.
    /// 0.60 — see the file header for the measured distribution this was chosen against.
    ///
    /// DO NOT SET THIS TO 0 TO "SEE ALL THE SPANS" WHILE DEBUGGING. A zero floor does not merely loosen the
    /// gate, it deletes it: every guard downstream is `ratio >= minEpochCoverage`, so at 0 the V2 phantom
    /// span is admitted like any other and the engine reports a confident deep-sleep rMSSD over clock the
    /// strap never watched — the single failure this whole file exists to prevent. `HRVByStageTests`
    /// pins the value for exactly that reason.
    static let minEpochCoverage: Double = 0.60

    /// Stricter floor before a span may carry a frequency-domain spectrum. 0.80 matches
    /// `HRVFreqReadout.minCoverage`; it is higher than the time-domain floor because the Lomb-Scargle time
    /// base is the cumulative sum of the intervals, so missing clock does not blank the result, it SHIFTS it.
    static let minBandCoverage: Double = 0.80

    /// A span shorter than this many whole epochs cannot be judged on its coverage ratio at all — with one
    /// or two epochs the ratio only takes the values 0, ½ and 1, which says nothing about whether the strap
    /// was watching. Such a span is excluded rather than admitted on a coin-flip.
    static let minSpanEpochs: Int = 2

    /// Minimum admitted clock (seconds) before a stage-level number is reported. 300 s is the Task Force
    /// (1996) short-term recording length — the same frame `HRVFreqDomain.minSpanForLFSec` relaxes — and it
    /// is the width of one window of the estimator, so below it the "mean over windows" is a mean of one.
    static let minStageSec: Int = 300

    /// Width of the tumbling windows the stage rMSSD is a mean over. 300 s, matching
    /// `SleepStaging.sessionAvgHRV`, so a per-stage value and the nightly value are the same estimator.
    static let windowSec: Int = 300

    // MARK: - Entry points

    /// Per-stage HRV for one night.
    ///
    /// - Parameters:
    ///   - spans: the hypnogram's stage spans. Need not be sorted, need not tile anything, and may overlap
    ///     (a malformed payload cannot break this — spans are resolved independently).
    ///   - rr: R-R intervals covering at least the session. Need not be sorted. Rows outside every span are
    ///     ignored, so passing a wider window than the night costs correctness nothing.
    /// - Returns: one `Reading` per `Stage`, always all four.
    static func analyze(spans: [Span], rr: [RRInterval]) -> Night {
        // Sort by (ts, rrMs) — the store's own read order (`Reads.swift:100`, `ORDER BY ts ASC, rrMs ASC`).
        // Several beats legitimately share one second (the corpus averages 1.28 rows per distinct second),
        // and Swift's sort is not stable, so without the secondary key the same input could produce two
        // different orderings and therefore two different Δ-statistics.
        let ordered = rr.sorted { $0.ts == $1.ts ? $0.rrMs < $1.rrMs : $0.ts < $1.ts }

        // Which 30 s epochs of the whole night hold at least one interval the analyzer would keep at range.
        // Built once for the night rather than per span: a night is ~1 000 epochs and ~30 000 rows, so this
        // turns the coverage measure from a per-span scan into a set lookup.
        //
        // The membership test is the RANGE filter only (`HRVAnalyzer.rrMinMs...rrMaxMs`), not Malik ectopic
        // rejection. Range is a per-beat physiological plausibility test and is exactly the right question
        // here — "was there a beat in this second?" — whereas Malik is CONTEXTUAL: it rejects a beat by
        // comparison with its neighbours, so applying it would let a noisy neighbourhood erase evidence that
        // the strap was reading at all. The beats that finally enter the statistic are Malik-filtered
        // downstream by `cleanRRIndexed` regardless.
        var occupied = Set<Int>()
        occupied.reserveCapacity(ordered.count)
        for row in ordered {
            let ms = Double(row.rrMs)
            if ms >= HRVAnalyzer.rrMinMs && ms <= HRVAnalyzer.rrMaxMs {
                occupied.insert(epochIndex(row.ts))
            }
        }

        var readings: [Reading] = []
        readings.reserveCapacity(Stage.allCases.count)
        for stage in Stage.allCases {
            readings.append(reading(for: stage,
                                    spans: spans.filter { $0.stage == stage && $0.durationSec > 0 },
                                    ordered: ordered,
                                    occupied: occupied))
        }
        return Night(readings: readings)
    }

    /// Stage spans from a stored `stagesJSON` payload — the read side of `DayEngine.encodeStages`.
    ///
    /// The inverse this needed ALREADY EXISTED: `SleepStage.decode` (`Core/Data/SleepStage.swift:44`)
    /// decodes the vendored `StageSegment` shape, drops unknown tokens and non-positive spans segment by
    /// segment, and is documented as the one place the accepted token set lives. Writing a second decoder
    /// here would have created exactly the drift that file exists to prevent, so this only maps its typed
    /// output onto the bucket enum.
    static func spans(fromStagesJSON json: String?) -> [Span] {
        SleepStage.decode(json).map { Span(start: $0.start, end: $0.end, stage: Stage($0.stage)) }
    }

    // MARK: - Per-stage resolution

    /// Resolve one stage: measure its coverage, admit the spans that clear the bar, and either average their
    /// windows or return the absence that says which way it failed.
    private static func reading(for stage: Stage,
                                spans: [Span],
                                ordered: [RRInterval],
                                occupied: Set<Int>) -> Reading {
        guard !spans.isEmpty else {
            return Reading(stage: stage, rmssd: nil, verdict: .notLabelled, coverage: 0,
                           claimedSec: 0, admittedSec: 0, windows: 0, cleanBeats: 0,
                           bands: nil, bandSpanSec: nil)
        }

        var claimedSec = 0
        var claimedEpochs = 0
        var coveredEpochs = 0
        var admitted: [(span: Span, beats: ArraySlice<RRInterval>, coverage: Double)] = []

        // Resolve the stage's spans in TIME order, not in the order the caller happened to list them.
        //
        // This is not cosmetic. `rmssd` below is a mean over `values`, and `values` is built by appending
        // each admitted span's windows in the order the spans are walked — so a floating-point sum whose
        // ADDEND ORDER depends on the caller's array order is a result that can differ in its last ULP
        // between two calls carrying the same night. `analyze` already canonicalises the R-R side by sorting
        // (ts, rrMs) for exactly this reason; leaving the span side un-canonicalised would have made the
        // engine order-independent in one input and not the other, which is the harder bug to ever notice.
        // Sorting here makes the whole result a function of the INPUT SET, which is what the tests assert
        // and what a surface caching a reading against a night is entitled to assume.
        //
        // (start, end) rather than start alone so that two spans sharing a start — only reachable from a
        // malformed payload, since a real hypnogram tiles — still order deterministically.
        for span in spans.sorted(by: { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }) {
            claimedSec += span.durationSec
            let (epochs, covered) = epochCoverage(span: span, occupied: occupied)
            claimedEpochs += epochs
            coveredEpochs += covered
            // Too few whole epochs for the ratio to mean anything, or too little of them watched.
            guard epochs >= minSpanEpochs else { continue }
            let ratio = Double(covered) / Double(epochs)
            guard ratio >= minEpochCoverage else { continue }
            admitted.append((span, beats(in: span, of: ordered), ratio))
        }

        let coverage = claimedEpochs > 0 ? Double(coveredEpochs) / Double(claimedEpochs) : 0
        let admittedSec = admitted.reduce(0) { $0 + $1.span.durationSec }

        // Verdict order matters, and each branch means one thing. A stage the hypnogram itself never gave
        // enough clock to is `.tooLittleTime` whatever its coverage; only a stage that HAD the clock and
        // failed to have it watched is `.notObserved`.
        if claimedSec < minStageSec {
            return Reading(stage: stage, rmssd: nil, verdict: .tooLittleTime, coverage: coverage,
                           claimedSec: claimedSec, admittedSec: admittedSec, windows: 0, cleanBeats: 0,
                           bands: nil, bandSpanSec: nil)
        }
        if admittedSec < minStageSec {
            return Reading(stage: stage, rmssd: nil, verdict: .notObserved, coverage: coverage,
                           claimedSec: claimedSec, admittedSec: admittedSec, windows: 0, cleanBeats: 0,
                           bands: nil, bandSpanSec: nil)
        }

        var values: [Double] = []
        var cleanBeats = 0
        for entry in admitted {
            let (windowValues, kept) = stageWindowRmssds(span: entry.span, beats: entry.beats)
            values.append(contentsOf: windowValues)
            cleanBeats += kept
        }
        guard !values.isEmpty else {
            return Reading(stage: stage, rmssd: nil, verdict: .tooFewBeats, coverage: coverage,
                           claimedSec: claimedSec, admittedSec: admittedSec, windows: 0,
                           cleanBeats: cleanBeats, bands: nil, bandSpanSec: nil)
        }

        // Spectrum over the single longest admitted span (ties to the earlier start, so the choice is a
        // function of the input and not of `admitted`'s incidental order) — see `Reading.bands`.
        var bands: HRVFreqDomain.Bands? = nil
        var bandSpanSec: Int? = nil
        if let best = admitted.max(by: { a, b in
            a.span.durationSec == b.span.durationSec ? a.span.start > b.span.start
                                                     : a.span.durationSec < b.span.durationSec
        }), best.coverage >= minBandCoverage,
           let spectrum = HRVFreqDomain.freqDomain(rr: Array(best.beats)) {
            bands = spectrum
            bandSpanSec = best.span.durationSec
        }

        return Reading(stage: stage,
                       rmssd: values.reduce(0, +) / Double(values.count),
                       verdict: .measured,
                       coverage: coverage,
                       claimedSec: claimedSec,
                       admittedSec: admittedSec,
                       windows: values.count,
                       cleanBeats: cleanBeats,
                       bands: bands,
                       bandSpanSec: bandSpanSec)
    }

    // MARK: - Coverage

    /// The absolute, wall-clock-aligned 30 s epoch a timestamp falls in.
    private static func epochIndex(_ ts: Int) -> Int {
        // Integer division floors toward zero, which is the same as flooring for the non-negative unix
        // seconds every stored row carries; the `< 0` arm keeps the grid monotonic anyway so a nonsense
        // pre-epoch timestamp cannot make two different seconds share a bucket.
        ts >= 0 ? ts / epochSec : ((ts + 1) / epochSec) - 1
    }

    /// `(whole epochs inside the span, how many of them hold in-range R-R)`.
    ///
    /// Only epochs lying ENTIRELY inside `[start, end)` are counted. A partial epoch at either edge is
    /// shared with the neighbouring stage, so crediting it would let a well-covered neighbour vouch for a
    /// span that has no data of its own — the exact direction of error this engine exists to prevent.
    private static func epochCoverage(span: Span, occupied: Set<Int>) -> (epochs: Int, covered: Int) {
        let first = (span.start + epochSec - 1) / epochSec   // first epoch starting at or after span.start
        let past = span.end / epochSec                        // first epoch ending after span.end
        guard past > first else { return (0, 0) }
        var covered = 0
        for e in first..<past where occupied.contains(e) { covered += 1 }
        return (past - first, covered)
    }

    // MARK: - Beat lookup

    /// The rows of a ts-ordered series that fall in `[span.start, span.end)`.
    ///
    /// Returned as a slice, not a copy: a night's spans collectively touch every row once, and the only
    /// consumer that needs an `Array` (the spectrum) makes one for the single span it runs on.
    private static func beats(in span: Span, of ordered: [RRInterval]) -> ArraySlice<RRInterval> {
        let lo = lowerBound(ordered, span.start)
        let hi = lowerBound(ordered, span.end)
        return lo < hi ? ordered[lo..<hi] : ordered[lo..<lo]
    }

    /// First index of a ts-ordered series whose `ts` is >= `ts`, or `count`. Binary search rather than a
    /// merge walk over sorted spans, so an overlapping or out-of-order span list still resolves correctly.
    private static func lowerBound(_ ordered: [RRInterval], _ ts: Int) -> Int {
        var lo = 0, hi = ordered.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if ordered[mid].ts < ts { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: - The estimator

    /// rMSSD per tumbling 5-minute window inside ONE span, plus the clean-beat count behind the admitted
    /// windows.
    ///
    /// DELIBERATE MIRROR of `SleepStaging.sessionAvgHRV` (SleepStaging.swift:2474), which is `internal` to the
    /// frozen package and so cannot be called from here. Everything about the recipe is kept identical —
    /// tumbling `windowSec` buckets anchored at the window's own start, `HRVAnalyzer.cleanRRIndexed`, the
    /// two admission constants (`minBeats` = 20 clean intervals; no more than
    /// `defaultSpotMaxRejectedFraction` = 0.35 of the bucket's own beats thrown away), and the splice-safe
    /// Δ-statistic `rmssdExcludingSplices` with per-beat timestamps supplied so pairs straddling either a
    /// rejected beat or a stream dropout are excluded. The ONE difference is the anchor: windows start at
    /// the SPAN's start, not the session's, and stop at its end.
    ///
    /// That anchoring is also what makes cross-span splicing impossible: no window ever holds beats from two
    /// spans, so two blocks of the same stage hours apart are never differenced against one another. If
    /// `sessionAvgHRV`'s recipe changes, this is the function that has to change with it, or a per-stage
    /// value stops being comparable to the nightly one it will be shown beside.
    private static func stageWindowRmssds(span: Span,
                                          beats: ArraySlice<RRInterval>) -> (values: [Double], cleanBeats: Int) {
        let duration = span.durationSec
        guard duration > 0, !beats.isEmpty else { return ([], 0) }
        let windowCount = (duration + windowSec - 1) / windowSec

        var buckets = [[Double]](repeating: [], count: windowCount)
        var bucketTs = [[Int]](repeating: [], count: windowCount)
        for row in beats {
            let b = (row.ts - span.start) / windowSec
            // `beats` is already clipped to [span.start, span.end), so `b` is in range; the guard is a
            // belt-and-braces against a caller handing in a hand-built slice.
            guard b >= 0, b < windowCount else { continue }
            buckets[b].append(Double(row.rrMs))
            bucketTs[b].append(row.ts)
        }

        var values: [Double] = []
        var cleanBeats = 0
        for (b, bucket) in buckets.enumerated() where !bucket.isEmpty {
            let kept = HRVAnalyzer.cleanRRIndexed(bucket)
            guard kept.count >= HRVAnalyzer.minBeats else { continue }
            let rejectedFraction = 1.0 - Double(kept.count) / Double(bucket.count)
            guard rejectedFraction <= HRVAnalyzer.defaultSpotMaxRejectedFraction else { continue }
            guard let r = HRVAnalyzer.rmssdExcludingSplices(kept, ts: bucketTs[b]) else { continue }
            values.append(r)
            cleanBeats += kept.count
        }
        return (values, cleanBeats)
    }
}
