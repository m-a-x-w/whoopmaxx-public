import Foundation
import StrapProtocol
@preconcurrency import StrapStore

/// One day's streams in, one day's numbers out.
///
/// Every analyzer in this package is a pure function over its own inputs. This is where they are
/// wired together into the row the app stores and reads: sleep, the three scores, workouts, steps,
/// calories, and the confidence tier beside each score.
///
/// It touches no database and no clock. Everything it needs is a parameter, which is what makes a
/// day's numbers reproducible from the same streams months later.
public enum DayEngine {

    // MARK: - Day keys

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The UTC calendar day of an instant.
    public static func dayString(_ ts: Int) -> String {
        isoDay.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// The wearer's LOCAL calendar day of an instant, `offsetSec` east of UTC.
    ///
    /// The day key is what every daily figure aggregates by, and the app reads "today" from the
    /// local calendar — so the bucket has to be local too. West of UTC, an evening crosses midnight
    /// UTC, lands in tomorrow's bucket, and the local "today" read never finds it: the dashboard
    /// simply stops updating.
    ///
    /// Shifting the instant turns the fixed-UTC formatter into a local one, so an offset of zero is
    /// exactly the UTC form above.
    public static func dayString(_ ts: Int, offsetSec: Int) -> String {
        dayString(ts + offsetSec)
    }

    /// UTC-midnight seconds of an ISO day key.
    ///
    /// This is what lets a day-membership test be an integer comparison rather than a date format
    /// per sample — the difference between one comparison and a hundred thousand formatter calls
    /// per scored day. A malformed key yields an empty 1970 window that matches nothing, rather
    /// than trapping: one bad key must not take down a whole scoring pass.
    public static func dayStartUTCSeconds(_ day: String) -> Int {
        Int(isoDay.date(from: day)?.timeIntervalSince1970 ?? 0)
    }

    // MARK: - Wear events

    /// Pair WRIST_OFF/WRIST_ON events into off-wrist intervals.
    ///
    /// An unclosed OFF runs to the end of the read window — the strap is still off. Repeated OFFs
    /// or ONs coalesce rather than opening a second interval, because a duplicate event is a
    /// transport artefact and not the wearer taking the band off twice.
    public static func offWristIntervals(events: [WhoopEvent],
                                         windowEnd: Int) -> [(start: Int, end: Int)] {
        let wear = events
            .filter { $0.kind.hasPrefix("WRIST_OFF") || $0.kind.hasPrefix("WRIST_ON") }
            .sorted { $0.ts < $1.ts }
        var intervals: [(start: Int, end: Int)] = []
        var offStart: Int?
        for e in wear {
            if e.kind.hasPrefix("WRIST_OFF") {
                if offStart == nil { offStart = e.ts }
            } else {
                if let s = offStart, e.ts > s { intervals.append((s, e.ts)) }
                offStart = nil
            }
        }
        if let s = offStart, windowEnd > s { intervals.append((s, windowEnd)) }
        return intervals
    }

    /// Take a calendar day's samples out of a night window already in memory, or decline.
    ///
    /// Declines — returns nil, so the caller reads the store — when the day is not strictly inside
    /// the window, or when the window came back at the row limit and may be truncated exactly where
    /// the day sits. Both guards can only ever fall back to a real read, never return the wrong
    /// rows.
    public static func daySliceFromNight<T>(_ night: [T],
                                            nightLo: Int, nightHi: Int,
                                            dayLo: Int, dayHi: Int,
                                            limit: Int = 200_000,
                                            ts: (T) -> Int) -> [T]? {
        guard dayLo >= nightLo, dayHi <= nightHi, night.count < limit else { return nil }
        return night.filter { ts($0) >= dayLo && ts($0) <= dayHi }
    }

    /// Stage segments as the JSON the store keeps.
    ///
    /// Keys are sorted so the same night always encodes to the same string. Without that, the
    /// self-heal that skips a write when the re-derived JSON is unchanged would rewrite every night
    /// on every pass.
    public static func encodeStages(_ stages: [StageSegment]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(stages) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Inputs and outputs

    /// Personal baselines the caller built from prior nights.
    public struct ProfileBaselines: Sendable {
        public let hrv: Baselines.BaselineState?
        public let restingHR: Baselines.BaselineState?
        public let resp: Baselines.BaselineState?
        public let skinTemp: Baselines.BaselineState?
        public init(hrv: Baselines.BaselineState? = nil,
                    restingHR: Baselines.BaselineState? = nil,
                    resp: Baselines.BaselineState? = nil,
                    skinTemp: Baselines.BaselineState? = nil) {
            self.hrv = hrv; self.restingHR = restingHR; self.resp = resp; self.skinTemp = skinTemp
        }
    }

    /// Everything one day's analysis produced.
    public struct DayResult {
        public let daily: DailyMetric
        public let sleepSessions: [SleepSession]
        public let cachedSleep: [CachedSleepSession]
        public let workouts: [ExerciseSession]
        public let recovery: Double?
        public let strain: Double?
        public let restScore: Double?
        public let chargeDrivers: [ChargeDriver]
        public let skinTempRelative: SkinTempRelative?
        public let nightlySkinTempC: Double?
        public let chargeConfidence: ScoreConfidence
        public let effortConfidence: ScoreConfidence
        public let restConfidence: ScoreConfidence
        /// Per-epoch motion beside each night's stages, keyed by session start. A night that could
        /// not be gridded is ABSENT from the map, so the caller stores nothing rather than a
        /// fabricated flat series.
        public let sessionMotionByStart: [Int: [Double]]
        /// The strap's own per-epoch sleep state beside each night, keyed by session start. Absent
        /// for a strap that reports none, so the caller stores nothing rather than a fabrication.
        public let sessionSleepStateByStart: [Int: [Int]]
        public let dayCoverage: Double?
    }

    // MARK: - The day

    /// Analyse one day.
    ///
    /// - Parameters:
    ///   - day: the LOCAL calendar day. A night is attributed to the day it ENDS on.
    ///   - hr/rr/resp/gravity: the night window — wider than the day, because staging needs the
    ///     pre-midnight hours the calendar day omits.
    ///   - dayHr/daySteps/dayGravity: the whole local calendar day, when the caller has it. The
    ///     additive totals and workout detection use these so an evening workout lands on its own
    ///     day; the night window only reaches about noon, so without them a 5 p.m. run is invisible
    ///     until the next pass. Sleep and recovery deliberately keep the night window.
    ///   - restingHRFallbackBpm: the wearer's own resting HR for Effort's zone weights on a day
    ///     that banked no sleep — which is exactly a day with a capture hole. Without it such a day
    ///     is scored against a generic stranger, suppressing Effort further on precisely the days
    ///     already missing hours. The caller must pass only a USABLE baseline: an unusable fold
    ///     returns its midpoint seed, which is worse than the generic value.
    public static func analyzeDay(day: String,
                                  hr: [HRSample] = [],
                                  rr: [RRInterval] = [],
                                  resp: [RespSample] = [],
                                  gravity: [GravitySample] = [],
                                  steps: [StepSample] = [],
                                  dayHr: [HRSample]? = nil,
                                  daySteps: [StepSample]? = nil,
                                  dayGravity: [GravitySample]? = nil,
                                  skinTemp: [SkinTempSample] = [],
                                  skinTempFamily: DeviceFamily = .whoop5,
                                  profile: UserProfile,
                                  baselines: ProfileBaselines = ProfileBaselines(),
                                  maxHROverride: Double? = nil,
                                  tzOffsetSeconds: Int = 0,
                                  wristOff: [(start: Int, end: Int)] = [],
                                  sleepNeedHours: Double = Rest.defaultNeedHours,
                                  sleepConsistency: Double? = nil,
                                  habitualMidsleepSec: Int? = nil,
                                  bandSleepState: [(ts: Int, state: Int)] = [],
                                  method: SleepSessions.Method = .path,
                                  dayCoverage: Double? = nil,
                                  restingHRFallbackBpm: Double? = nil) -> DayResult {

        let dayStartUTC = dayStartUTCSeconds(day)
        let dayEndUTC = dayStartUTC + 86_400
        func inDay(_ ts: Int) -> Bool {
            (ts + tzOffsetSeconds) >= dayStartUTC && (ts + tzOffsetSeconds) < dayEndUTC
        }

        // ── Sleep ──────────────────────────────────────────────────────────────────────────────
        let allSessions = SleepSessions.detectSleep(hr: hr, rr: rr, resp: resp, gravity: gravity,
                                                    tzOffsetSeconds: tzOffsetSeconds,
                                                    wristOff: wristOff,
                                                    bandSleepState: bandSleepState,
                                                    method: method)
        let matched = allSessions.filter { inDay($0.end) }

        // The day's MAIN night. A day can hold a night AND a nap, both ending on it, and the
        // headline sleep figures describe the night alone — summing the nap in makes "your night"
        // disagree with itself across screens. Naps keep their own rows.
        let blocks = matched.map { SleepGrouping.NightBlock(start: $0.start, end: $0.end) }
        let mainIdx = SleepGrouping.mainNightGroupIndices(blocks, offsetSec: tzOffsetSeconds,
                                                          habitualMidsleepSec: habitualMidsleepSec)
            ?? []
        let mainGroup = mainIdx.map { matched[$0] }

        var deepS = 0.0, remS = 0.0, lightS = 0.0, tstS = 0.0
        var inBedS = 0.0, effWeighted = 0.0, wasoS = 0.0
        var disturbances = 0
        for s in mainGroup {
            let m = SleepStaging.hypnogramMetrics(s)
            let inBed = Double(s.end - s.start)
            inBedS += inBed
            effWeighted += s.efficiency * inBed     // in-bed-weighted, so a long fragment counts more
            deepS += m.deepMin * 60
            remS += m.remMin * 60
            lightS += m.lightMin * 60
            tstS += m.tstS
            disturbances += m.disturbances
            wasoS += m.wasoS
        }
        // REM latency is a property of the night's ONSET, so it cannot be summed across bridged
        // fragments — it comes from the first one only.
        let remLatencyS = mainGroup.first.map { SleepStaging.hypnogramMetrics($0).remLatencyS }

        // The out-of-bed time BETWEEN bridged fragments belongs to no fragment's span, so without
        // this it is counted nowhere and a real 20-minute waking disappears. It extends in-bed (and
        // so lowers efficiency) and counts as one disturbance; total sleep is untouched.
        let gapAwakeS = SleepGrouping.interFragmentAwakeSeconds(
            mainGroup.map { (start: $0.start, end: $0.end) })
        if gapAwakeS > 0 {
            inBedS += gapAwakeS
            wasoS += gapAwakeS
            disturbances += 1
        }
        let efficiency = inBedS > 0 ? effWeighted / inBedS : 0.0
        let hasStagedSleep = (deepS + remS) > 0

        let restScore: Double? = matched.isEmpty ? nil : Rest.composite(
            tstSeconds: tstS, inBedSeconds: inBedS, efficiency: efficiency,
            restorativeSeconds: deepS + remS, needHours: sleepNeedHours,
            consistency: sleepConsistency, deepSeconds: deepS,
            ageYears: profile.age > 0 ? profile.age : nil)

        // ── Resting physiology ─────────────────────────────────────────────────────────────────
        // Deliberately over ALL of the day's sessions, not just the main night: this is the body's
        // best resting reading for the day, and the night dominates it anyway. The sleep-quality
        // figures above are main-night; these are day-best. Two different questions.
        //
        // Except on a nap-only day. These two numbers feed the personal baselines directly, and
        // nothing downstream gates them on duration — so a day whose only sleep was a short
        // afternoon block would seed the baselines from a nap. A nap's resting HR sits well above a
        // night's, which biases the baseline upward and drags every later Charge with it. The test
        // is "too short to be a night", not "happened during the day": a shift worker's daytime
        // sleep runs a full night's length and passes through untouched.
        let napOnly: Bool = {
            guard !mainGroup.isEmpty else { return false }
            let allDaytime = mainGroup.allSatisfy {
                SleepDetection.isDaytimeCenter(
                    SleepDetection.Period(stage: "sleep", start: $0.start, end: $0.end),
                    tzOffsetSeconds: tzOffsetSeconds)
            }
            guard allDaytime else { return false }
            return mainGroup.reduce(0) { $0 + ($1.end - $1.start) } < SleepDetection.minSleepMin * 60
        }()

        let restingHRDaily = napOnly ? nil : matched.compactMap(\.restingHR).min()
        let avgHRVDaily: Double? = {
            guard !napOnly else { return nil }
            let pairs = matched.compactMap { s -> (Double, Double)? in
                s.avgHRV.map { ($0, Double(s.end - s.start)) }
            }
            guard !pairs.isEmpty else { return nil }
            let total = pairs.reduce(0.0) { $0 + $1.0 * $1.1 }
            let weight = pairs.reduce(0.0) { $0 + $1.1 }
            return weight > 0 ? total / weight : nil
        }()

        // Median of the per-session estimates, so one disturbed window cannot set the night's
        // breathing rate.
        let respRateDaily: Double? = {
            let per = matched
                .map { SleepSessions.respRateFromRR(rr, start: $0.start, end: $0.end) }
                .filter { $0.isFinite }
            return per.isEmpty ? nil : HRVAnalyzer.median(per)
        }()

        // ── Skin temperature ───────────────────────────────────────────────────────────────────
        // The nightly mean is harvested every pass and is baseline-independent; the DEVIATION needs
        // a personal baseline, so on a first pass it is nil and the caller seeds the baseline from
        // the means before asking again.
        let nightlySkinTempC = SkinTemp.wornNightlyMeanC(sessions: matched, hr: hr,
                                                         skinTemp: skinTemp, family: skinTempFamily)
        let skinTempDevC: Double? = nightlySkinTempC.flatMap { v in
            guard let b = baselines.skinTemp, b.usable else { return nil }
            return round2(Baselines.deviation(v, state: b).delta)
        }

        // ── Charge ─────────────────────────────────────────────────────────────────────────────
        var recovery: Double?
        var chargeDrivers: [ChargeDriver] = []
        if let hrvVal = avgHRVDaily, let rhrVal = restingHRDaily, let hrvBase = baselines.hrv {
            let sleepPerf = restScore.map { $0 / 100.0 }
            recovery = RecoveryScorer.recovery(
                hrv: hrvVal, rhr: Double(rhrVal), resp: respRateDaily,
                hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                respBaseline: baselines.resp, sleepPerf: sleepPerf, skinTempDev: skinTempDevC)
            // Built from the IDENTICAL inputs as the score, so the explanation can never describe a
            // different number than the one shown.
            chargeDrivers = RecoveryScorer.chargeDrivers(
                hrv: hrvVal, rhr: Double(rhrVal), resp: respRateDaily,
                hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                respBaseline: baselines.resp, sleepPerf: sleepPerf, skinTempDev: skinTempDevC)
        }
        let skinTempRelative = RecoveryScorer.skinTempRelative(deviationC: skinTempDevC)

        // ── Effort ─────────────────────────────────────────────────────────────────────────────
        let effMaxHR: Double? = maxHROverride
            ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
        let restForStrain = restingHRDaily.map(Double.init)
            ?? restingHRFallbackBpm
            ?? StrainScorer.defaultRestingHR
        let strain = StrainScorer.strain(dayHr ?? hr, maxHR: effMaxHR,
                                         restingHR: restForStrain, sex: profile.sex)

        // ── Workouts ───────────────────────────────────────────────────────────────────────────
        let workouts = WorkoutDetector.detect(
            hr: dayHr ?? hr, gravity: dayGravity ?? gravity,
            restingHR: restingHRDaily.map(Double.init), maxHR: maxHROverride,
            age: profile.age > 0 ? profile.age : nil, profile: profile)

        // ── Steps ──────────────────────────────────────────────────────────────────────────────
        let stepsTotal = stepTotal(daySteps ?? steps, inDay: inDay, profile: profile)

        // ── Calories ───────────────────────────────────────────────────────────────────────────
        let dayHrFiltered = (dayHr ?? hr).filter { inDay($0.ts) }
        let activeKcalEst: Double? = dayHrFiltered.isEmpty ? nil : Calories.estimateDayCalories(
            dayHrFiltered, profile: profile, hrmax: effMaxHR,
            restingHR: restingHRDaily.map(Double.init))

        // ── The row ────────────────────────────────────────────────────────────────────────────
        let daily = DailyMetric(
            day: day,
            totalSleepMin: matched.isEmpty ? nil : tstS / 60,
            efficiency: matched.isEmpty ? nil : efficiency,
            deepMin: matched.isEmpty ? nil : deepS / 60,
            remMin: matched.isEmpty ? nil : remS / 60,
            lightMin: matched.isEmpty ? nil : lightS / 60,
            disturbances: matched.isEmpty ? nil : disturbances,
            restingHr: restingHRDaily,
            avgHrv: avgHRVDaily,
            recovery: recovery,
            strain: strain,
            exerciseCount: workouts.count,
            spo2Pct: nil,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateDaily,
            steps: stepsTotal,
            activeKcalEst: activeKcalEst,
            // Always nil. The strap gives no lights-out reference to measure a latency from, so the
            // honest value is absence rather than a number that is zero by construction.
            solMin: nil,
            // NaN means the night had no REM at all; it must not reach a stored column or a later
            // mean.
            remLatencyMin: matched.isEmpty ? nil
                : remLatencyS.flatMap { $0.isNaN ? nil : $0 / 60 },
            wasoMin: matched.isEmpty ? nil : wasoS / 60)

        let cachedSleep = matched.map {
            CachedSleepSession(startTs: $0.start, endTs: $0.end, efficiency: $0.efficiency,
                               restingHr: $0.restingHR, avgHrv: $0.avgHRV,
                               stagesJSON: encodeStages($0.stages),
                               lowConfidence: $0.lowConfidence)
        }

        var sessionMotionByStart: [Int: [Double]] = [:]
        for s in matched {
            let motion = SleepStaging.sessionEpochMotion(start: s.start, end: s.end, grav: gravity)
            if !motion.isEmpty { sessionMotionByStart[s.start] = motion }
        }

        var sessionSleepStateByStart: [Int: [Int]] = [:]
        if !bandSleepState.isEmpty {
            for s in matched {
                let states = SleepStaging.sessionEpochSleepState(start: s.start, end: s.end,
                                                                 sleepState: bandSleepState)
                if !states.isEmpty { sessionSleepStateByStart[s.start] = states }
            }
        }

        return DayResult(
            daily: daily, sleepSessions: matched, cachedSleep: cachedSleep, workouts: workouts,
            recovery: recovery, strain: strain, restScore: restScore,
            chargeDrivers: chargeDrivers, skinTempRelative: skinTempRelative,
            nightlySkinTempC: nightlySkinTempC,
            chargeConfidence: ScoreConfidence.charge(recovery: recovery,
                                                     hrvBaseline: baselines.hrv),
            effortConfidence: ScoreConfidence.effort(strain: strain, hrSampleCount: hr.count,
                                                     coverage: dayCoverage),
            restConfidence: ScoreConfidence.rest(hasSession: !matched.isEmpty,
                                                 hasStagedSleep: hasStagedSleep,
                                                 asleepSeconds: tstS,
                                                 restorativeSeconds: deepS + remS,
                                                 efficiency: efficiency),
            sessionMotionByStart: sessionMotionByStart,
            sessionSleepStateByStart: sessionSleepStateByStart,
            dayCoverage: dayCoverage)
    }

    /// A delta this large between adjacent records is a sync boundary or a reset, not steps.
    public static let maxStepDelta = 512

    /// The day's steps, from wrap-aware increments of the strap's running counter.
    ///
    /// The counter is CUMULATIVE and wraps at 16 bits, so the day's total is the sum of its
    /// increments — summing the counter itself adds a running total to itself and produces millions
    /// of steps a day.
    ///
    /// The counter counts motion ticks rather than validated steps, hence the calibration divisor.
    /// Its floor means a bad setting can at most double the total, never explode it.
    static func stepTotal(_ steps: [StepSample], inDay: (Int) -> Bool,
                          profile: UserProfile) -> Int? {
        let sorted = steps.filter { inDay($0.ts) }.sorted { $0.ts < $1.ts }
        guard sorted.count >= 2 else { return nil }
        var total = 0
        for i in 1..<sorted.count {
            let delta = (sorted[i].counter - sorted[i - 1].counter) & 0xFFFF
            if delta >= 1 && delta < maxStepDelta { total += delta }
        }
        guard total > 0 else { return nil }
        let scaled = Int((Double(total) / max(profile.stepTicksPerStep, 0.5)).rounded())
        return scaled > 0 ? scaled : nil
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}
