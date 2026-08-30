import Foundation
import StrapAnalytics

// IntervalWorkoutDetector.swift — app-layer sibling of StrapAnalytics `AutoWorkoutDetector` for
// INTERVAL / STRENGTH sessions.
//
// The base detector requires HR to stay ≥ resting + 30 bpm for a contiguous ≥ 12 min, tolerating
// dips of at most 90 s. Strength training never survives that shape: sets run 30–90 s elevated and
// the 2–3 min rests between them are all "dips" longer than 90 s, so every rest splits the span and
// no fragment reaches 12 min. StrapAnalytics is FROZEN (byte-parity with the Android twin), so the
// fix lives here in the app layer: detect the SET / REST cadence directly — short elevated
// micro-spans chained across rest-sized gaps — and feed the result into the SAME opt-in
// "Looks like a workout?" suggestion path (`WorkoutRepository.autoDetectCandidate`), where the base
// detector's candidates win any overlap (steadier signal).
//
// Reuses the base detector's public pieces so the two stay consistent: the same elevated gate
// (`AutoWorkoutDetector.elevatedMarginBPM` over resting, `defaultRestingHR` fallback), the same
// `SavedWorkoutSpan` overlap-exclusion, and the same `DetectedWorkout` output shape.
//
// Deliberately CONSERVATIVE, like the base detector: a session needs ≥ 4 sets (rejects isolated
// stress spikes), ≥ 20 min wall-clock, and a meaningful elevated-time fraction. It only ever
// SUGGESTS — nothing is persisted until the user taps Save.
//
// Pure / headless: no I/O, no clock. All ts/start/end are unix SECONDS. NOT medical advice.

enum IntervalWorkoutDetector {

    // MARK: - Constants

    /// Elevated gate margin over resting HR — SAME +30 bpm floor as the base detector
    /// (consistency beats cleverness; a "working" sample means the same thing in both).
    static let elevatedMarginBPM = AutoWorkoutDetector.elevatedMarginBPM
    /// Resting-HR fallback when the caller has no nightly RHR — same 60 bpm as the base detector.
    static let defaultRestingHR = AutoWorkoutDetector.defaultRestingHR
    /// A contiguous run of elevated samples must span at least this long to count as a SET
    /// (micro-span). Shorter blips (one hard flight of stairs) are noise.
    static let minSetS = 30
    /// A silence (no samples at all) longer than this inside a run of elevated samples closes the
    /// micro-span — two elevated readings a capture-gap apart are not one continuous set.
    static let maxIntraSetGapS = 60
    /// Two micro-spans whose gap is at most this belong to the SAME session (a between-sets rest;
    /// 2–3 min rests are the strength norm, 4 min is the ceiling before we call the workout over).
    static let maxRestGapS = 240
    /// A session must span at least this much wall clock (sets + rests) to qualify (20 min).
    static let minSessionMin: Double = 20.0
    /// A session must contain at least this many micro-spans — the set-count signal that rejects
    /// a couple of isolated stress / caffeine spikes that happen to land near each other.
    static let minSetCount = 4
    /// Elevated time (sum of micro-span durations) must be at least this fraction of the session's
    /// wall span. Rejects sparse spikes stretched over a long window. Tuned to 0.25 (not higher):
    /// the canonical strength cadence — ~60 s sets against 2–3 min rests — yields a work fraction
    /// of only ~0.25–0.33, so a stricter gate would reject the exact pattern this detector exists
    /// to catch, while 0.25 still rejects sparse-spike windows by ~5×.
    static let minElevatedFraction = 0.25

    // MARK: - Diagnostic types

    /// One elevated MICRO-SPAN (a SET): a maximal run of consecutive elevated samples whose wall span
    /// is ≥ `minSetS`. Exposed for the Signal Lab detection panel; `detect` consumes these internally.
    struct MicroSpan: Equatable {
        let start: Int
        let end: Int
        var durationS: Int { end - start }
    }

    /// The diagnostic evaluation of ONE chained session — every gate verdicted individually so a
    /// near-miss (a real workout that failed exactly one gate) is observable, not silently dropped.
    /// `detect()` is exactly `sessions(...).filter(\.qualifies)` + the saved-span exclusion, so this
    /// can never disagree with what the suggestion path surfaces.
    struct SessionEval: Equatable {
        let startSec: Int
        let endSec: Int
        /// Number of micro-spans (sets) chained into this session.
        let setCount: Int
        /// Sum of micro-span durations (seconds) — the session's elevated time.
        let elevatedS: Int
        /// Mean bpm over the ELEVATED samples in the window (rests would dilute a set-cadence average).
        let avgBpm: Int
        let peakBpm: Int

        /// Wall-clock span, first set start → last set end (seconds).
        var wallS: Int { endSec - startSec }
        /// Elevated time as a fraction of the wall span (0 when the span is degenerate).
        var elevatedFraction: Double { wallS > 0 ? Double(elevatedS) / Double(wallS) : 0 }
        /// Gate 1: wall span ≥ `minSessionMin` (20 min).
        var wallOK: Bool { Double(wallS) >= minSessionMin * 60.0 }
        /// Gate 2: set count ≥ `minSetCount` (4).
        var setsOK: Bool { setCount >= minSetCount }
        /// Gate 3: elevated fraction ≥ `minElevatedFraction` (0.25).
        var fractionOK: Bool { wallS > 0 && elevatedFraction >= minElevatedFraction }
        /// All three gates — the exact qualification `detect` filters on.
        var qualifies: Bool { wallOK && setsOK && fractionOK }
    }

    // MARK: - Public API

    /// Detect candidate interval / strength sessions.
    ///
    /// Algorithm:
    ///  1. Sort HR ascending. Floor = restingHR + `elevatedMarginBPM`. A sample is "elevated" when
    ///     bpm >= floor (identical gate to the base detector).
    ///  2. Build MICRO-SPANS: maximal runs of consecutive elevated samples. Any sub-threshold
    ///     sample ends the run, as does a sample silence > `maxIntraSetGapS`. Keep a micro-span
    ///     only when its wall span (first→last elevated ts) is >= `minSetS` — that's a SET.
    ///  3. Chain micro-spans into SESSIONS: consecutive micro-spans stay in one session while the
    ///     gap between them (next.start - prev.end) is <= `maxRestGapS` (a rest period).
    ///  4. A session QUALIFIES when its wall span (first set start → last set end) is
    ///     >= `minSessionMin`, it contains >= `minSetCount` micro-spans, and its elevated time
    ///     (sum of micro-span durations) is >= `minElevatedFraction` of the wall span.
    ///  5. Drop a session that OVERLAPS any saved span (touching endpoints count) — never
    ///     re-suggest one. Identical rule to the base detector.
    ///  6. Emit a `DetectedWorkout` per surviving session: avg/peak bpm over the ELEVATED samples
    ///     in the window (rests would drag a set-cadence average down) + whole-minute duration.
    ///
    /// - Parameters:
    ///   - hr: the day's (or last day or two's) HR samples `[(ts, bpm)]`; any order; empty → [].
    ///   - restingBpm: the nightly resting HR for the day; nil → `defaultRestingHR` (60).
    ///   - savedSpans: already-saved workout windows to exclude by overlap.
    static func detect(hr: [(ts: Int, bpm: Int)],
                       restingBpm: Int?,
                       savedSpans: [SavedWorkoutSpan] = []) -> [DetectedWorkout] {
        // Steps 1–4 + 6 live in `sessions` (which evaluates EVERY chained session, near-misses
        // included, for the diagnostic panel); this filter is steps 4 (the gate verdicts) + 5.
        sessions(hr: hr, restingBpm: restingBpm)
            .filter { $0.qualifies }
            // 5: never re-suggest a window overlapping an already-saved workout (touching endpoints count).
            .filter { s in !savedSpans.contains(where: { s.startSec <= $0.endSec && $0.startSec <= s.endSec }) }
            .map { DetectedWorkout(startSec: $0.startSec, endSec: $0.endSec,
                                   avgBpm: $0.avgBpm, peakBpm: $0.peakBpm,
                                   durationMin: $0.wallS / 60) }
    }

    /// Steps 1–2 of `detect`: the elevated MICRO-SPANS (sets) over the HR stream. Diagnostic +
    /// building block for `sessions` — pure, no gates beyond the per-set `minSetS` floor.
    static func microSpans(hr: [(ts: Int, bpm: Int)], restingBpm: Int?) -> [MicroSpan] {
        let seg = hr.sorted { $0.ts < $1.ts }
        if seg.isEmpty { return [] }

        let floor = (restingBpm ?? defaultRestingHR) + elevatedMarginBPM

        // --- 2: build micro-spans (sets) ---
        var sets: [MicroSpan] = []
        var setStart: Int? = nil
        var setEnd = 0
        var prevTs: Int? = nil

        func closeSet() {
            if let s = setStart, setEnd - s >= minSetS { sets.append(MicroSpan(start: s, end: setEnd)) }
            setStart = nil
        }

        for sample in seg {
            // A capture silence longer than maxIntraSetGapS ends the current set regardless of
            // what the next sample reads — we can't claim continuity across missing data.
            if let p = prevTs, sample.ts - p > maxIntraSetGapS { closeSet() }
            prevTs = sample.ts
            if sample.bpm >= floor {
                if setStart == nil { setStart = sample.ts }
                setEnd = sample.ts
            } else {
                closeSet()   // unlike the base detector, ANY sub-threshold sample ends the set
            }
        }
        closeSet()
        return sets
    }

    /// Steps 1–4 + 6 of `detect` as a DIAGNOSTIC evaluation: every chained session with per-gate
    /// verdicts (`SessionEval`), near-misses included — `detect` is exactly this filtered to
    /// `qualifies` plus the saved-span exclusion, so the two can never drift. Chronological order.
    static func sessions(hr: [(ts: Int, bpm: Int)], restingBpm: Int?) -> [SessionEval] {
        let seg = hr.sorted { $0.ts < $1.ts }
        let floor = (restingBpm ?? defaultRestingHR) + elevatedMarginBPM

        let sets = microSpans(hr: hr, restingBpm: restingBpm)
        if sets.isEmpty { return [] }

        // --- 3: chain sets into sessions across rest-sized gaps (sets are start-ascending) ---
        var sessions: [[MicroSpan]] = []
        var current: [MicroSpan] = [sets[0]]
        for k in 1..<sets.count {
            if sets[k].start - current[current.count - 1].end <= maxRestGapS {
                current.append(sets[k])
            } else {
                sessions.append(current)
                current = [sets[k]]
            }
        }
        sessions.append(current)

        // --- 4 (as verdicts, not filters) + 6 ---
        var results: [SessionEval] = []
        for session in sessions {
            guard let first = session.first, let last = session.last else { continue }
            let start = first.start, end = last.end

            // 6: stats over the ELEVATED samples in the window (rests would dilute the average).
            // A session is made of micro-spans — runs of elevated samples — so `bpms` is never
            // empty; the guard keeps the original `detect` behavior byte-identical regardless.
            let bpms = seg.filter { $0.ts >= start && $0.ts <= end && $0.bpm >= floor }.map { $0.bpm }
            if bpms.isEmpty { continue }
            let avg = Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
            let peak = bpms.max() ?? avg
            results.append(SessionEval(startSec: start, endSec: end,
                                       setCount: session.count,
                                       elevatedS: session.reduce(0) { $0 + $1.durationS },
                                       avgBpm: avg, peakBpm: peak))
        }
        return results
    }

    /// Merge the two detectors' candidate lists for the suggestion path: the BASE detector wins any
    /// overlap (a sustained elevation is the steadier signal — an interval reading of the same
    /// window adds nothing), so an interval candidate that overlaps (touching endpoints count) any
    /// base candidate is dropped. Pure, so tests can exercise the rule directly.
    static func merged(base: [DetectedWorkout],
                       interval: [DetectedWorkout]) -> [DetectedWorkout] {
        base + interval.filter { cand in
            !base.contains { cand.startSec <= $0.endSec && $0.startSec <= cand.endSec }
        }
    }
}
