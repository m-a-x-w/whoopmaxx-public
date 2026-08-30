import SwiftUI
import StrapStore
import StrapAnalytics

/// Everything the Rest screen shows about one night, derived ONCE from repository rows: the day's
/// metrics + Rest score, the matching sleep session, and the decoded stage timeline.
///
/// Stage totals come from the decoded `stagesJSON` timeline when the session carries one; otherwise
/// they fall back to the day row's `deepMin`/`remMin`/`lightMin` (+ `wasoMin` for awake), so an
/// imported summary-only night still shows its breakdown.
struct RestNight {
    let dayKey: String
    /// Rest score 0–100 (the `sleep_performance` series); nil = calibrating.
    let score: Double?
    /// Minutes asleep (`DailyMetric.totalSleepMin`).
    let asleepMin: Double?
    /// Sleep efficiency, 0–100.
    let efficiency: Double?
    let bed: Date?
    let wake: Date?
    /// Stage timeline in StepHypnogram's convention (0 awake, 1 REM, 2 light, 3 deep).
    let segments: [(start: Date, end: Date, stage: Int)]
    // Stage totals in minutes (see fallback note above).
    let deepMin: Double?
    let remMin: Double?
    let lightMin: Double?
    let wakeMin: Double?
    /// The CLOCK SPAN, in seconds, of the longest flagged main-sleep fragment; nil on every night that
    /// carries no flag at all.
    ///
    /// The stager gates on `(p.end - p.start) > SleepDetection.maxMainSleepSpanS` — the run's own span —
    /// and NOT on the staged asleep total. The two are different, smaller/larger numbers: a flagged
    /// night's `asleepMin` is routinely well under the cap, so quoting it would caption "9:40 against a
    /// 16 h limit" and contradict its own reason. This field carries the span the gate measured, so the
    /// caveat can only ever quote that.
    ///
    /// SINCE 030 THE FLAG HAS A SECOND PRODUCER and this span no longer implies the stager's cause: a
    /// night flagged by `ScoreEngine.flaggedLowConfidence` for staged sleep over worn HR silence is of
    /// ordinary length, so `lowConfidenceSpanS` on such a night is UNDER the cap rather than over it.
    /// The field is still exactly the right thing to carry — it is what discriminates the two causes —
    /// but nothing may assume it exceeds `maxMainSleepSpanS`. See `lowConfidenceCaption(spanS:)`.
    let lowConfidenceSpanS: Int?

    init(dayKey: String, score: Double?, asleepMin: Double?, efficiency: Double?,
         bed: Date?, wake: Date?, segments: [(start: Date, end: Date, stage: Int)],
         deepMin: Double?, remMin: Double?, lightMin: Double?, wakeMin: Double?,
         lowConfidenceSpanS: Int? = nil) {
        self.dayKey = dayKey
        self.score = score
        self.asleepMin = asleepMin
        self.efficiency = efficiency
        self.bed = bed
        self.wake = wake
        self.segments = segments
        self.deepMin = deepMin
        self.remMin = remMin
        self.lightMin = lightMin
        self.wakeMin = wakeMin
        self.lowConfidenceSpanS = lowConfidenceSpanS
    }

    /// True when this night was kept under protest — either by the stager (an over-long run) or by
    /// ScoreEngine (staged sleep over unexplained worn silence); see `lowConfidenceSpanS`. Nothing
    /// about the night is excluded, down-weighted or re-scored because of it (016 decision 1), under
    /// either cause; it only decides whether the screen caveats what it is already showing.
    var lowConfidence: Bool { lowConfidenceSpanS != nil }

    /// The caveat sentence for a flagged night, or nil on a confident one.
    var lowConfidenceCaption: String? {
        lowConfidenceSpanS.map { Self.lowConfidenceCaption(spanS: $0) }
    }

    /// The caveat copy, hoisted to a static so a test can pin the exact sentence (the
    /// `ArousalForensicsSection.agedOutLine` idiom).
    ///
    /// It names WHAT WAS OBSERVED and stops (016 decision 2): a recorded stretch, its length, and the
    /// limit it passed. The app cannot tell a wrong clock from travel from a frozen strap, so it says
    /// none of them — and this is a fact about the RECORDING, never about the sleeper (decision 5).
    /// The limit is read from `SleepDetection.maxMainSleepSpanS`, never written as a literal, so the
    /// sentence and the gate that produced it move together.
    ///
    /// TWO CAUSES, AND THE SPAN IS AN EXACT DISCRIMINATOR BETWEEN THEM (030 Track A). `lowConfidence`
    /// now has exactly two producers, and no others: the stager's over-long-run gate
    /// (`SleepStaging.swift:1042-1044`, the ONLY place the package raises it) and
    /// `ScoreEngine.flaggedLowConfidence`, which raises it when staged asleep time sits over worn HR
    /// silence no off-wrist event explains. So `spanS > maxMainSleepSpanS` identifies the first cause
    /// and its negation identifies the second — total, with no third case to fall through.
    ///
    /// That test is not decoration; without it this sentence is FALSE. `lowConfidenceSpanS` is the span
    /// of whichever flagged fragment is longest, and a night flagged only for worn silence is an
    /// ordinary-length night. On the real 2026-08-02 corpus night — 6 h 45 m, flagged for a 166-minute
    /// hole staged as deep — the unconditional wording read "6 hours 45 minutes recorded against a
    /// 16 hour limit", quoting a span comfortably UNDER the limit it names. That is the exact
    /// self-contradiction the `lowConfidenceSpanS` doc above was written to prevent, arriving by a
    /// route that doc did not anticipate.
    ///
    /// THE SILENCE BRANCH QUOTES NO NUMBER, deliberately. The measured quantity exists — ScoreEngine
    /// banks it as `sleep_unmeasured_min` — but it is summed per DAY over every session that day owns,
    /// naps included, while this caption is about one main-night GROUP. Printing the day's total on the
    /// night's caveat would attribute nap minutes to the night, which is a different false claim in
    /// place of the one just removed. The Data wall's "Unmeasured" entry is where that number is
    /// rendered, against the day key it is actually keyed to. Vocabulary is kept in step with
    /// `SleepNeedLine.lowConfidenceWindowNote`, which names both causes as alternatives because a bare
    /// count cannot tell them apart; here the span can, so each branch names one cause outright.
    static func lowConfidenceCaption(spanS: Int) -> String {
        guard spanS > SleepDetection.maxMainSleepSpanS else {
            return "Kept, but minutes inside this night were never measured \u{2014} "
                + "the strap banked no heart rate across part of what is staged as sleep."
        }
        return "Kept, but longer than a night can be \u{2014} "
            + "\(WMFormat.duration(seconds: spanS, style: .spelled)) recorded against a "
            + "\(WMFormat.duration(seconds: SleepDetection.maxMainSleepSpanS, style: .spelled)) limit."
    }

    init(day: DailyMetric, score: Double?, session: CachedSleepSession?) {
        self.init(day: day, score: score, sessions: session.map { [$0] } ?? [])
    }

    /// The whole main-night GROUP, which the split-night bridge may span across several fragments.
    /// A single-fragment night is byte-identical to the old single-session path.
    init(day: DailyMetric, score: Double?, sessions: [CachedSleepSession]) {
        let group = sessions.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        // Union every fragment's hypnogram, in time order — a bridged night's timeline is the whole
        // group's, not the longest fragment's.
        let segments = group
            .flatMap { Self.decodeSegments($0.stagesJSON) }
            .sorted { $0.start < $1.start }
        let totals = Self.stageTotals(segments: segments)
        // The out-of-bed gap BETWEEN fragments is awake time the user really spent awake, and
        // `analyzeDay` already folds it into the day's `wasoMin`. Without it the awake row would
        // under-report a bridged night by the whole inter-fragment gap.
        let interFragmentWakeMin = Self.interFragmentAwakeMinutes(group)
        // The low-confidence flag, carried through from the session rows the group is made of. `startTs`
        // (not `effectiveStartTs`): the stager's gate ran on the DETECTED run, so this is the only span
        // that can be compared against the cap at all. On a group with more than one flagged fragment the
        // longest is taken — under the stager's cause that is the stretch the sentence is about, and
        // taking the max is also what keeps a group holding BOTH causes captioned by the over-long one,
        // which is the more specific of the two things there is to say about it (030 Track A).
        // NOTE the span is no longer guaranteed to exceed `maxMainSleepSpanS`: a night flagged only for
        // worn silence is of ordinary length. `lowConfidenceCaption` tests for that rather than assuming.
        let flaggedSpanS = group
            .filter(\.lowConfidence)
            .map { max(0, $0.endTs - $0.startTs) }
            .max()
        self.init(
            dayKey: day.day,
            score: score,
            asleepMin: day.totalSleepMin,
            // DailyMetric/CachedSleepSession efficiency is a 0–1 fraction; RestNight.efficiency is 0–100
            // (its doc + the Rest screen render it as a percent), so scale ×100 here.
            efficiency: (day.efficiency ?? group.first?.efficiency).map { $0 * 100 },
            bed: group.first.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) },
            wake: group.last.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) },
            segments: segments,
            deepMin: totals?.deep ?? day.deepMin,
            remMin: totals?.rem ?? day.remMin,
            lightMin: totals?.light ?? day.lightMin,
            wakeMin: totals.map { $0.wake + interFragmentWakeMin } ?? day.wasoMin,
            lowConfidenceSpanS: flaggedSpanS
        )
    }

    /// Minutes spent out of bed BETWEEN the group's fragments (0 for a single-fragment night).
    private static func interFragmentAwakeMinutes(_ group: [CachedSleepSession]) -> Double {
        guard group.count > 1 else { return 0 }
        var total = 0.0
        for (a, b) in zip(group, group.dropFirst()) {
            total += Double(max(0, b.effectiveStartTs - a.endTs)) / 60
        }
        return total
    }

    /// The session whose end lands on `day` (same local-day keying the repository merges by),
    /// longest first when a day holds several (the main night, not a nap).
    ///
    /// Prefer `sessions(for:in:habitualMidsleepSec:)` — this bare longest-span pick can only ever return
    /// ONE fragment of a bridged night and ignores the alignment bonus the shared selector applies.
    static func session(for day: DailyMetric, in sleeps: [CachedSleepSession]) -> CachedSleepSession? {
        sleeps
            .filter { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == day.day }
            .max { ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs) }
    }

    /// The day's main-night group, via the SAME selector `analyzeDay` and `NapCredit` use — so the Rest
    /// screen's stage rows, hypnogram, bed/wake and forensics describe exactly the blocks the hero's
    /// Asleep total was summed from, and every session is either a nap or part of the night, never both.
    static func sessions(for day: DailyMetric, in sleeps: [CachedSleepSession],
                         habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        NapCredit.mainNightSessions(for: day.day, sleeps: sleeps,
                                    habitualMidsleepSec: habitualMidsleepSec)
    }

    /// How many of `dayKeys` have a flagged main-sleep group — the debt line's count.
    ///
    /// It walks the DEBT WINDOW, not the night on screen. The ledger reaches 14 nights back and a
    /// flagged night anywhere in it moved the balance, so a caveat scoped to the displayed night would
    /// leave the swing unexplained on every other night of the window (the `windowNapMin` /
    /// `windowNapCount` precedent, which exists for exactly this reason).
    ///
    /// Resolved through the SAME `mainNightSessions` selector `RestNight(day:score:sessions:)` uses, so
    /// the count and the hero above it can never disagree about whether the displayed night is flagged.
    /// Values in, values out — the screen runs this off the SwiftUI frame path in its `.task(id:)`.
    static func lowConfidenceNightCount(dayKeys: [String], sleeps: [CachedSleepSession],
                                        habitualMidsleepSec: Int? = nil) -> Int {
        dayKeys.reduce(into: 0) { count, key in
            let group = NapCredit.mainNightSessions(for: key, sleeps: sleeps,
                                                    habitualMidsleepSec: habitualMidsleepSec)
            if group.contains(where: \.lowConfidence) { count += 1 }
        }
    }

    // MARK: - stagesJSON

    /// Decode a `stagesJSON` payload into hypnogram segments. The token table and the drop rules
    /// (unknown stages, zero/negative-length spans, nil/undecodable input → []) live in `SleepStage`;
    /// this is only the epoch→`Date` + `laneCode` projection the hypnogram renders.
    static func decodeSegments(_ stagesJSON: String?) -> [(start: Date, end: Date, stage: Int)] {
        SleepStage.decode(stagesJSON).map {
            (start: Date(timeIntervalSince1970: TimeInterval($0.start)),
             end: Date(timeIntervalSince1970: TimeInterval($0.end)),
             stage: $0.stage.laneCode)
        }
    }

    /// Per-stage minute sums off a decoded timeline; nil when there is no timeline to sum.
    private static func stageTotals(
        segments: [(start: Date, end: Date, stage: Int)]
    ) -> (deep: Double, rem: Double, light: Double, wake: Double)? {
        guard !segments.isEmpty else { return nil }
        var minutes = [0.0, 0.0, 0.0, 0.0]   // indexed by stage code
        for seg in segments where (0...3).contains(seg.stage) {
            minutes[seg.stage] += seg.end.timeIntervalSince(seg.start) / 60
        }
        return (deep: minutes[3], rem: minutes[1], light: minutes[2], wake: minutes[0])
    }
}

/// Shared value formatting for the Rest screen — a thin naming layer over `WMFormat`.
enum RestFormat {
    /// Minutes → "h:mm" (432 → "7:12").
    static func hmm(_ minutes: Double) -> String { WMFormat.hmm(minutes: minutes) }

    /// `yyyy-MM-dd` day key → local Date (midnight), for the header caption.
    static func date(fromDayKey key: String) -> Date? {
        DayKey.date(from: key)
    }
}
