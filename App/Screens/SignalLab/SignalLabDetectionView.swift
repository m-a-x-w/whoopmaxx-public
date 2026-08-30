import SwiftUI
import StrapStore
import StrapAnalytics

/// Detection mode — a read-only diagnostic of the opt-in "Looks like a workout?" pipeline over the
/// last 7 days, per local day: how much HR each detector actually saw, the elevated floor it gated on,
/// the micro-spans (sets) it found, and EVERY candidate — including interval sessions that failed a
/// gate, with per-gate verdicts — so "my workout never surfaced" is answerable from the device.
///
/// FIDELITY over re-derivation: the panel reads the SAME inputs the production path reads —
/// `WorkoutRepository.autoDetectHR` (the shared 5-s bucket read), the same resting-HR resolution, the same
/// saved-workout window and the same dismissed-span list — and the interval verdicts come from
/// `IntervalWorkoutDetector.sessions`, which `detect()` itself filters. Nothing here can disagree with
/// what the suggestion path would do. READ-ONLY: no writes, no persistence, no side effects.
struct SignalLabDetectionView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var workoutRepo: WorkoutRepository

    /// Preview / no-store seam: an injected report so the panel renders in `#Preview` with no store.
    var previewReport: DetectionLabReport? = nil

    @State private var report: DetectionLabReport?
    @State private var loading = false
    /// Bumped per load so a late read can't clobber a newer one.
    @State private var loadGen = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Both workout detectors, replayed over the last 7 days of banked HR — the same reads, floor and exclusions as the workout suggestion. Sessions that failed a gate are shown with the gate that failed. Read-only.")
                    .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let report {
                    floorLine(report)
                    if !report.suggestionsEnabled {
                        Text("Workout suggestions are OFF (More → Auto-detect workouts) — candidates below are computed but never surfaced.")
                            .font(WMType.caption).foregroundStyle(WM.Ground.inkSecondary)
                            .padding(.top, WM.Space.s)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(report.days) { day in daySection(day) }
                } else if loading {
                    Text("Reading 7 days of HR…")
                        .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                        .padding(.top, WM.Space.section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .task { await load() }
    }

    // MARK: Header lines

    private func floorLine(_ r: DetectionLabReport) -> some View {
        let resting = r.restingBpm.map(String.init) ?? "\(IntervalWorkoutDetector.defaultRestingHR) (default — no resting HR banked)"
        return Text("Elevated floor \(r.floorBpm) bpm — resting \(resting) + \(IntervalWorkoutDetector.elevatedMarginBPM). \(r.pointCount.formatted()) HR points read (\(WorkoutRepository.autoDetectBucketSeconds)-s bucket means). Saved workouts: \(r.savedSpanCount) · dismissed suggestions: \(r.dismissedSpanCount).")
            .font(WMType.caption).foregroundStyle(WM.Ground.inkSecondary)
            .padding(.top, WM.Space.m)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Per-day section

    private func daySection(_ day: DetectionLabReport.Day) -> some View {
        RuleSection(day.title, topGap: WM.Space.sectionTight) {
            VStack(alignment: .leading, spacing: WM.Space.s) {
                caption(coverageLine(day))
                caption(day.microCount == 0
                        ? "Sets (≥\(IntervalWorkoutDetector.minSetS) s elevated): none"
                        : "Sets (≥\(IntervalWorkoutDetector.minSetS) s elevated): \(day.microCount) · \(Self.oneDecimal(day.elevatedMin)) min elevated total")

                if day.base.isEmpty {
                    caption("Base detector (sustained ≥12 min): no candidates")
                } else {
                    caption("Base detector (sustained ≥12 min):")
                    ForEach(day.base) { c in baseRow(c) }
                }

                if day.sessions.isEmpty {
                    caption("Interval detector (set/rest cadence): no sessions")
                } else {
                    caption("Interval detector (set/rest cadence):")
                    ForEach(day.sessions) { s in sessionRow(s) }
                }
            }
        }
    }

    private func coverageLine(_ day: DetectionLabReport.Day) -> String {
        guard day.rawCount > 0 || day.firstTs != nil else { return "HR: none banked" }
        var line = "HR: \(day.rawCount.formatted()) raw samples"
        if let f = day.firstTs, let l = day.lastTs {
            line += " · \(Self.hm(f))–\(Self.hm(l))"
        }
        return line
    }

    // MARK: Candidate rows

    private func baseRow(_ c: DetectionLabReport.BaseCandidate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            caption("\(Self.hm(c.workout.startSec))–\(Self.hm(c.workout.endSec)) · \(c.workout.durationMin) min · avg \(c.workout.avgBpm) / peak \(c.workout.peakBpm) bpm", ink: true)
            trimLine(c.trim)
            statusLine(saved: c.overlapsSaved, dismissed: c.overlapsDismissed,
                       standing: c.standing)
        }
        .padding(.leading, WM.Space.m)
    }

    private func sessionRow(_ s: DetectionLabReport.IntervalSession) -> some View {
        let e = s.eval
        return VStack(alignment: .leading, spacing: 2) {
            caption("\(Self.hm(e.startSec))–\(Self.hm(e.endSec)) · \(e.wallS / 60) min · \(e.setCount) set\(e.setCount == 1 ? "" : "s") · \(Int((e.elevatedFraction * 100).rounded()))% elevated · avg \(e.avgBpm) bpm", ink: true)
            HStack(spacing: WM.Space.m) {
                gate(e.wallOK, "≥\(Int(IntervalWorkoutDetector.minSessionMin)) min")
                gate(e.setsOK, "≥\(IntervalWorkoutDetector.minSetCount) sets")
                gate(e.fractionOK, "≥\(Int(IntervalWorkoutDetector.minElevatedFraction * 100))% elevated")
            }
            if let trim = s.trim { trimLine(trim) }
            statusLine(saved: s.overlapsSaved, dismissed: s.overlapsDismissed,
                       standing: s.standing)
        }
        .padding(.leading, WM.Space.m)
    }

    /// What the EPOC/low-floor post-pass did to a candidate — raw span → trimmed span when they
    /// differ, "dropped after trim" when the trimmed span failed revalidation, silent when unchanged.
    @ViewBuilder
    private func trimLine(_ trim: WorkoutTailTrimmer.Outcome) -> some View {
        switch trim {
        case .unchanged:
            EmptyView()
        case .trimmed(let raw, let trimmed, let workMark):
            caption("\(Self.hm(raw.startSec))–\(Self.hm(raw.endSec)) → trimmed \(Self.hm(trimmed.startSec))–\(Self.hm(trimmed.endSec)) (peak \(raw.peakBpm), work ≥ \(workMark))")
        case .dropped(let raw, let workMark):
            caption("dropped after trim (peak \(raw.peakBpm), work ≥ \(workMark) — no qualifying span left)")
        }
    }

    /// One gate verdict — the ONLY color on this surface is the semantic pass/fail mark.
    private func gate(_ ok: Bool, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(ok ? "✓" : "✗")
                .font(WMType.overline)
                .foregroundStyle(ok ? WM.Semantic.good : WM.Semantic.bad)
            Text(label).font(WMType.caption).foregroundStyle(WM.Ground.inkSecondary)
        }
        .accessibilityLabel("\(label): \(ok ? "passed" : "failed")")
    }

    /// The exclusion / ranking outcome for a candidate that passed (or would pass) its detector's
    /// gates. Ranking-aware: only the queue HEAD is what the Today row shows right now — the rest
    /// of the queue waits its turn, and merge losers never surface at all.
    @ViewBuilder
    private func statusLine(saved: Bool, dismissed: Bool,
                            standing: DetectionLabReport.QueueStanding?) -> some View {
        if saved {
            caption("suppressed — overlaps a saved workout")
        } else if dismissed {
            caption("suppressed — inside a dismissed suggestion span")
        } else {
            switch standing {
            case .head:
                caption("next suggestion", ink: true)
            case .queued:
                caption("queued — newer suggestion shows first")
            case .mergedAway:
                caption("suppressed — overlaps a base-detector candidate (base wins the merge)")
            case nil:
                EmptyView()
            }
        }
    }

    private func caption(_ s: String, ink: Bool = false) -> some View {
        Text(s).font(WMType.caption)
            .foregroundStyle(ink ? WM.Ground.ink : WM.Ground.inkTertiary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Load

    @MainActor
    private func load() async {
        if let previewReport { report = previewReport; return }
        guard report == nil, !loading else { return }
        loadGen += 1
        let gen = loadGen
        loading = true

        let now = Int(Date().timeIntervalSince1970)
        // THE production inputs, byte-for-byte (see `WorkoutRepository.autoDetectCandidate`).
        let hr = await workoutRepo.autoDetectHR(daysBack: DetectionLabReport.daysBack, now: now)
        let restingBpm = repo.days.last(where: { $0.restingHr != nil })?.restingHr
        let saved = await workoutRepo.workoutRows(days: 30)
            .map { (start: $0.startTs, end: $0.endTs) }
        let dismissed = workoutRepo.autoDetectDismissedSpanList
        let enabled = PuffinExperiment.autoDetectWorkoutsEnabled

        // Per-day raw banked counts (indexed COUNT/MAX, no rows) for the coverage line — the loaded
        // points are bucket means, so their count would under-report what the strap actually banked.
        var rawCounts: [Int] = []
        let bounds = DetectionLabReport.dayBounds(now: now)
        for b in bounds {
            rawCounts.append(await repo.hrFingerprint(from: b.start, to: b.end - 1).count)
        }

        // Detection over 7 days of points is heavy — build the report OFF the main actor.
        let built = await Task.detached(priority: .utility) {
            DetectionLabReport.build(hr: hr, restingBpm: restingBpm,
                                     savedSpans: saved, dismissedSpans: dismissed,
                                     dayBounds: bounds, rawCounts: rawCounts,
                                     suggestionsEnabled: enabled)
        }.value

        guard gen == loadGen else { return }
        report = built
        loading = false
    }

    // MARK: Formatting

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static func hm(_ ts: Int) -> String {
        hmFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private static func oneDecimal(_ v: Double) -> String { String(format: "%.1f", v) }
}

// MARK: - Pure report model

/// Everything the Detection panel shows, built pure off the production inputs so it is testable and
/// can run off the main actor.
struct DetectionLabReport {
    /// The diagnostic window — matches `autoDetectCandidate`'s default scan window.
    static let daysBack = 7

    /// Where a surviving, unsuppressed candidate sits in the PRODUCTION suggestion queue
    /// (`WorkoutRepository.autoDetectQueue` — the panel computes the same queue from the same inputs, so
    /// these labels cannot drift from what the Today row shows).
    enum QueueStanding: Equatable {
        /// Head of the queue — the suggestion the Today row is showing right now.
        case head
        /// In the queue behind a newer candidate — surfaces once everything ahead is handled.
        case queued
        /// Survived its own trim but lost the base-vs-interval merge (base wins any overlap).
        case mergedAway
    }

    struct BaseCandidate: Identifiable {
        let workout: DetectedWorkout
        /// What the EPOC/low-floor post-pass (`WorkoutTailTrimmer`) did to this candidate — the
        /// suggestion path only ever carries `trim.survivor` forward.
        let trim: WorkoutTailTrimmer.Outcome
        /// Overlap verdicts, checked on the TRIMMED span (the survivor — production order is
        /// trim → filter, so the survivor is what the exclusion filters actually see). Falls back
        /// to the raw span only when the trim dropped the candidate outright.
        let overlapsSaved: Bool
        let overlapsDismissed: Bool
        /// nil when the candidate never reaches the queue filters (dropped by trim / suppressed).
        let standing: QueueStanding?
        var id: Int { workout.startSec }
    }

    struct IntervalSession: Identifiable {
        let eval: IntervalWorkoutDetector.SessionEval
        /// Trim outcome for QUALIFYING sessions (nil for near-misses — the post-pass only ever
        /// sees candidates that passed the gates).
        let trim: WorkoutTailTrimmer.Outcome?
        /// Overlap verdicts on the TRIMMED span when one survived (see `BaseCandidate`).
        let overlapsSaved: Bool
        let overlapsDismissed: Bool
        let standing: QueueStanding?
        var id: Int { eval.startSec }
    }

    struct Day: Identifiable {
        let key: String          // yyyy-MM-dd (local)
        let title: String        // "Wed 16 Jul"
        let rawCount: Int        // banked hrSample rows that day (fingerprint)
        let firstTs: Int?        // coverage of the LOADED points within the day
        let lastTs: Int?
        let microCount: Int      // elevated micro-spans (sets) starting that day
        let elevatedMin: Double  // their total elevated minutes
        let base: [BaseCandidate]
        let sessions: [IntervalSession]
        var id: String { key }
    }

    let floorBpm: Int
    let restingBpm: Int?
    let pointCount: Int
    let savedSpanCount: Int
    let dismissedSpanCount: Int
    let suggestionsEnabled: Bool
    /// Newest day first.
    let days: [Day]

    /// Local-midnight `[start, end)` bounds for the last `daysBack` days, NEWEST first (today's
    /// partial day included).
    static func dayBounds(now: Int) -> [(start: Int, end: Int)] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now)))
        var bounds: [(start: Int, end: Int)] = (0..<daysBack).compactMap { back in
            guard let dayStart = cal.date(byAdding: .day, value: -back, to: todayStart),
                  let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            return (start: Int(dayStart.timeIntervalSince1970), end: Int(dayEnd.timeIntervalSince1970))
        }
        // Production (`autoDetectHR`) reads a ROLLING `[now - daysBack*86400, now]` window, but the
        // local-midnight buckets above start at todayStart-(daysBack-1)d, leaving the earliest ~partial day
        // `[now - daysBack*86400, todayStart-(daysBack-1)d)` in NO bucket. HR points there — and any
        // candidate whose span STARTS there — are still fed to the detectors + queue, so a real suggestion
        // could be the queue head yet appear in no day section (and pointCount wouldn't reconcile with the
        // per-day rawCounts). Append that slice as the oldest bucket, clamped to the EXACT production read
        // start, so the bucket union covers the whole read window. Oldest-last keeps the newest-first order.
        if let oldestFullStart = bounds.last?.start {
            let readStart = now - daysBack * 86_400
            if readStart < oldestFullStart {
                bounds.append((start: readStart, end: oldestFullStart))
            }
        }
        return bounds
    }

    /// Pure assembly: run both detectors ONCE over the whole window (exactly like the production
    /// path — a session spanning midnight is never split), then group everything by the local day
    /// its span STARTS in. Overlap checks run on the TRIMMED span when a trim occurred (production
    /// order is trim → filter): `savedSpans` with touching-counts (the detectors' rule),
    /// `dismissedSpans` with strict overlap (`autoDetectCandidates`'s rule). The production queue
    /// itself comes from the SAME `WorkoutRepository.autoDetectQueue` production calls, so the
    /// head/queued labels cannot disagree with the Today row.
    static func build(hr: [(ts: Int, bpm: Int)], restingBpm: Int?,
                      savedSpans: [(start: Int, end: Int)],
                      dismissedSpans: [(start: Int, end: Int)],
                      dayBounds: [(start: Int, end: Int)],
                      rawCounts: [Int],
                      suggestionsEnabled: Bool) -> DetectionLabReport {
        // Both detectors run UNFILTERED (no savedSpans) so a suppressed candidate is still shown —
        // with its suppression labelled — instead of silently vanishing like it does in production.
        let base = AutoWorkoutDetector.detect(hr: hr, restingBpm: restingBpm, motion: nil, savedSpans: [])
        let sessions = IntervalWorkoutDetector.sessions(hr: hr, restingBpm: restingBpm)
        let micro = IntervalWorkoutDetector.microSpans(hr: hr, restingBpm: restingBpm)

        // THE production queue, from the shared pipeline core — the panel's head/queued labels are
        // derived from this list, never re-derived, so panel and Today row cannot drift.
        let queue = WorkoutRepository.autoDetectQueue(hr: hr, restingBpm: restingBpm,
                                               savedSpans: savedSpans,
                                               dismissedSpans: dismissedSpans)

        func savedHit(_ start: Int, _ end: Int) -> Bool {
            savedSpans.contains { start <= $0.end && $0.start <= end }
        }
        func dismissedHit(_ start: Int, _ end: Int) -> Bool {
            dismissedSpans.contains { start < $0.end && $0.start < end }
        }
        /// Ranking verdict for a candidate that survived its trim and neither exclusion.
        func standing(_ survivor: DetectedWorkout?, saved: Bool, dismissed: Bool) -> QueueStanding? {
            guard let s = survivor, !saved, !dismissed else { return nil }
            if queue.first == s { return .head }
            if queue.contains(s) { return .queued }
            return .mergedAway   // survived + unsuppressed but absent → lost the base-wins merge
        }

        let titleFormatter = DateFormatter()
        titleFormatter.dateFormat = "EEE d MMM"

        var days: [Day] = []
        for (i, b) in dayBounds.enumerated() {
            let inDay = { (ts: Int) in ts >= b.start && ts < b.end }
            let dayPoints = hr.filter { inDay($0.ts) }
            let dayMicro = micro.filter { inDay($0.start) }
            let dayDate = Date(timeIntervalSince1970: TimeInterval(b.start))
            days.append(Day(
                key: DayKey.local(dayDate),
                title: titleFormatter.string(from: dayDate),
                rawCount: rawCounts.indices.contains(i) ? rawCounts[i] : 0,
                firstTs: dayPoints.first?.ts,
                lastTs: dayPoints.last?.ts,
                microCount: dayMicro.count,
                elevatedMin: Double(dayMicro.reduce(0) { $0 + $1.durationS }) / 60.0,
                base: base.filter { inDay($0.startSec) }.map { w in
                    let trim = WorkoutTailTrimmer.trim(w, kind: .base,
                                                       hr: hr, restingBpm: restingBpm)
                    // Production checks the SURVIVOR (trim → filter); raw span only when dropped.
                    let span = trim.survivor ?? w
                    let saved = savedHit(span.startSec, span.endSec)
                    let dismissed = dismissedHit(span.startSec, span.endSec)
                    return BaseCandidate(workout: w,
                                         trim: trim,
                                         overlapsSaved: saved,
                                         overlapsDismissed: dismissed,
                                         standing: standing(trim.survivor,
                                                            saved: saved, dismissed: dismissed))
                },
                sessions: sessions.filter { inDay($0.startSec) }.map { s in
                    let trim: WorkoutTailTrimmer.Outcome? = s.qualifies
                        ? WorkoutTailTrimmer.trim(
                            DetectedWorkout(startSec: s.startSec, endSec: s.endSec,
                                            avgBpm: s.avgBpm, peakBpm: s.peakBpm,
                                            durationMin: s.wallS / 60),
                            kind: .interval, hr: hr, restingBpm: restingBpm)
                        : nil
                    // Production checks the SURVIVOR (trim → filter); raw span for near-misses
                    // and trim-dropped sessions (informational only — neither reaches the queue).
                    let span = trim?.survivor
                    let saved = savedHit(span?.startSec ?? s.startSec, span?.endSec ?? s.endSec)
                    let dismissed = dismissedHit(span?.startSec ?? s.startSec, span?.endSec ?? s.endSec)
                    return IntervalSession(eval: s,
                                           trim: trim,
                                           overlapsSaved: saved,
                                           overlapsDismissed: dismissed,
                                           standing: standing(span,
                                                              saved: saved, dismissed: dismissed))
                }))
        }

        return DetectionLabReport(
            floorBpm: (restingBpm ?? IntervalWorkoutDetector.defaultRestingHR)
                + IntervalWorkoutDetector.elevatedMarginBPM,
            restingBpm: restingBpm,
            pointCount: hr.count,
            savedSpanCount: savedSpans.count,
            dismissedSpanCount: dismissedSpans.count,
            suggestionsEnabled: suggestionsEnabled,
            days: days)
    }
}

// MARK: - Synthetic report (previews / no-store)

extension DetectionLabReport {
    /// A deterministic synthetic 7-day report exercising every row shape: a qualifying interval
    /// session, a near-miss on each gate, a base candidate, a suppressed candidate, and empty days.
    static func synthetic(now: Int = 1_760_000_000) -> DetectionLabReport {
        let bounds = dayBounds(now: now)
        let d0 = bounds[0].start
        // Day 0: a canonical strength session (8 × 60 s at +40 over resting, 150 s rests).
        var hr: [(ts: Int, bpm: Int)] = []
        var t = d0 + 10 * 3600
        for i in 0..<8 {
            hr += stride(from: t, through: t + 60, by: 5).map { (ts: $0, bpm: 100) }
            t += 65
            if i < 7 { hr += stride(from: t, through: t + 145, by: 5).map { (ts: $0, bpm: 70) }; t += 150 }
        }
        // Day 1: a 3-set near-miss (fails the set-count gate).
        let d1 = bounds[1].start
        t = d1 + 18 * 3600
        for i in 0..<3 {
            hr += stride(from: t, through: t + 420, by: 5).map { (ts: $0, bpm: 100) }
            t += 425
            if i < 2 { hr += stride(from: t, through: t + 195, by: 5).map { (ts: $0, bpm: 70) }; t += 200 }
        }
        // Day 2: a steady 15-min run (base-detector candidate).
        let d2 = bounds[2].start
        hr += stride(from: d2 + 7 * 3600, through: d2 + 7 * 3600 + 900, by: 5).map { (ts: $0, bpm: 100) }

        let rawCounts = bounds.map { _ in 12_345 }
        return build(hr: hr.sorted { $0.ts < $1.ts }, restingBpm: 60,
                     savedSpans: [(start: d2 + 7 * 3600, end: d2 + 7 * 3600 + 900)],
                     dismissedSpans: [],
                     dayBounds: bounds, rawCounts: rawCounts, suggestionsEnabled: true)
    }
}

// MARK: - Previews

#Preview("Signal Lab · Detection — light") {
    DetectionPreviewHost().preferredColorScheme(.light)
}

#Preview("Signal Lab · Detection — dark") {
    DetectionPreviewHost().preferredColorScheme(.dark)
}

private struct DetectionPreviewHost: View {
    private let root = AppRoot()

    var body: some View {
        SignalLabDetectionView(previewReport: .synthetic())
            .padding(WM.Space.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(WM.Ground.ground)
            .environmentObject(root.repo)
            .environmentObject(root.workoutRepo)
    }
}
