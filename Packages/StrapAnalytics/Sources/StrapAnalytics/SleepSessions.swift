import Foundation
import StrapProtocol

/// Detection and staging joined up: raw streams in, staged nights out.
///
/// `SleepDetection` proposes windows from stillness alone. This is where every other signal gets a
/// vote — the clock, heart rate, HRV, wear events, the strap's own state — and where a surviving
/// window is handed to a stager.
///
/// The gates are ordered cheapest-and-most-decisive first, and each one only ever REJECTS. Nothing
/// here can turn a window that stillness never proposed into sleep.
public enum SleepSessions {

    /// Which stager runs on the windows detection keeps.
    public enum Method: Sendable {
        /// Per-epoch percentile bands, then smoothing and physiology.
        case bands
        /// Soft evidence and one Viterbi path over the night.
        case path
    }

    /// Find and stage every sleep window in a span of streams.
    ///
    /// - Parameters:
    ///   - tzOffsetSeconds: seconds east of UTC. The daytime and morning guards read the wearer's
    ///     clock, not UTC — a night in Auckland is a nap in London otherwise.
    ///   - wristOff: explicit wear intervals. The HR-gap and flat-gravity proxies are always on;
    ///     these sharpen them.
    ///   - bandSleepState: the strap's own per-timestamp sleep code, used only to confirm a
    ///     borderline morning re-onset. It never overrides a derived stage.
    public static func detectSleep(hr: [HRSample] = [],
                                   rr: [RRInterval] = [],
                                   resp: [RespSample] = [],
                                   gravity: [GravitySample] = [],
                                   tzOffsetSeconds: Int = 0,
                                   wristOff: [(start: Int, end: Int)] = [],
                                   bandSleepState: [(ts: Int, state: Int)] = [],
                                   method: Method = .path) -> [SleepSession] {
        let grav = gravity.sorted { $0.ts < $1.ts }
        guard grav.count >= 2 else { return [] }
        let hrS = hr.sorted { $0.ts < $1.ts }
        let rrS = rr.sorted { $0.ts < $1.ts }
        let respS = resp.sorted { $0.ts < $1.ts }

        let baseline = SleepDetection.hrBaseline(hrS)
        let sparse = SleepDetection.isGravitySparse(grav, hrS)
        let deltas = SleepDetection.gravityDeltas(grav)

        var runs = SleepDetection.buildRuns(grav, SleepDetection.classifyStill(grav, deltas),
                                            sparse: sparse, hr: hrS, baseline: baseline)
        runs = SleepDetection.mergePeriods(runs, SleepDetection.mergeMin)
        runs = SleepDetection.bridgeSparseSleep(runs, sparse: sparse, hr: hrS, baseline: baseline)

        let continuationGapS = SleepDetection.nightContinuationGapMin * 60
        var chainPrevEnd: Int?
        var chainFromOvernight = false
        // Overnight HRV accumulated within this pass, as the daytime guard's reference. Runs are
        // visited in time order over a window spanning days, so a daytime candidate is in practice
        // always preceded by a night.
        var overnightHRVs: [Double] = []
        var nightHRVRef: Double?

        var sessions: [SleepSession] = []
        for p in runs where p.stage == "sleep" {
            let spanS = p.end - p.start
            let isDaytime = SleepDetection.isDaytimeCenter(p, tzOffsetSeconds: tzOffsetSeconds)

            // The floor is band-aware. Holding a daytime window to the overnight hour would make
            // the daytime guard's own length bar unreachable — the effective minimum becomes the
            // larger of the two, and no ordinary nap can ever be recorded.
            let floorS = (isDaytime ? SleepDetection.daytimeMinSleepMin
                                    : SleepDetection.minSleepMin) * 60
            if spanS <= floorS { continue }

            // FLAGGED, not dropped. A window this long is a bad-clock artefact rather than a night,
            // but erasing it leaves a hole where a night should be — with no way for anything
            // downstream to say why. Kept and marked, so it can be down-weighted instead.
            let lowConfidence = spanS > SleepDetection.maxMainSleepSpanS

            guard SleepDetection.confirmSleepWithHR(p, hrS, baseline) else { continue }

            // Off-wrist is off-wrist whatever time it is, so this is checked BEFORE the night-tail
            // exemption below — it must never ride a continuation chain.
            let offFrac = SleepDetection.offWristFraction(p, hrS, wristOff,
                                                          grav: grav, deltas: deltas)
            guard offFrac < SleepDetection.maxOffWristSleepFraction else { continue }

            let restingExact = SleepDetection.sessionRestingHRExact(p.start, p.end, hrS)
            let resting = restingExact.map { Int($0.rounded()) }
            // Computed before the gate ladder because the daytime guard READS it. Left below the
            // ladder it exists only to fill the result, and the one channel that separates a real
            // nap from sedentary stillness never gets to decide anything.
            let avgHRV = SleepStaging.sessionAvgHRV(start: p.start, end: p.end, rr: rrS)

            let continuesChain = chainPrevEnd.map { p.start - $0 <= continuationGapS } ?? false
            // A night that runs into the daytime band — a late wake, or a stir that splits the tail
            // into its own daytime-centred run — is the night, not an isolated nap.
            let isNightTail = continuesChain && chainFromOvernight

            if isDaytime && !isNightTail {
                let morningWakeEnd = chainFromOvernight ? chainPrevEnd : nil
                let passesMorning = SleepDetection.passesMorningStillnessGuard(
                    p, restingExact, baseline, morningWakeEnd, bandSleepState)
                let passesHRV = SleepDetection.passesDaytimeHRVGuard(avgHRV, nightHRVRef)
                guard passesMorning && passesHRV else { continue }
            }

            let stages: [StageSegment]
            switch method {
            case .bands:
                stages = SleepStaging.stageSession(start: p.start, end: p.end, grav: grav,
                                                   hr: hrS, rr: rrS, resp: respS)
            case .path:
                stages = SleepStagingV2.stageSession(start: p.start, end: p.end, grav: grav,
                                                     hr: hrS, rr: rrS)
            }
            sessions.append(SleepSession(
                start: p.start, end: p.end,
                efficiency: SleepStaging.efficiency(start: p.start, end: p.end, stages: stages),
                stages: stages, restingHR: resting, avgHRV: avgHRV,
                lowConfidence: lowConfidence))

            // A run that does not continue the chain starts a new one, anchored on whether ITS
            // onset was overnight.
            if !continuesChain {
                chainFromOvernight = SleepDetection.isOvernightOnset(
                    p.start, tzOffsetSeconds: tzOffsetSeconds)
            }
            if !isDaytime, let h = avgHRV {
                overnightHRVs.append(h)
                nightHRVRef = HRVAnalyzer.median(overnightHRVs)
            }
            chainPrevEnd = p.end
        }
        return sessions.sorted { $0.start < $1.start }
    }

    /// Stage a window the user asserted, without re-litigating whether it was sleep.
    ///
    /// Every detection gate is deliberately bypassed: a human said this was their night, and the
    /// job here is only to label what happened inside it. The staging math is the same code the
    /// automatic path runs, so only the BOUNDARY is forced, never the result.
    public static func stageWindow(start: Int, end: Int,
                                   hr: [HRSample] = [], rr: [RRInterval] = [],
                                   resp: [RespSample] = [], gravity: [GravitySample] = [],
                                   method: Method = .path) -> SleepSession {
        let grav = gravity.sorted { $0.ts < $1.ts }
        let hrS = hr.sorted { $0.ts < $1.ts }
        let rrS = rr.sorted { $0.ts < $1.ts }
        let respS = resp.sorted { $0.ts < $1.ts }
        let stages: [StageSegment]
        switch method {
        case .bands:
            stages = SleepStaging.stageSession(start: start, end: end, grav: grav,
                                               hr: hrS, rr: rrS, resp: respS)
        case .path:
            stages = SleepStagingV2.stageSession(start: start, end: end, grav: grav,
                                                 hr: hrS, rr: rrS)
        }
        return SleepSession(start: start, end: end,
                            efficiency: SleepStaging.efficiency(start: start, end: end,
                                                                stages: stages),
                            stages: stages,
                            restingHR: SleepDetection.sessionRestingHR(start, end, hrS),
                            avgHRV: SleepStaging.sessionAvgHRV(start: start, end: end, rr: rrS))
    }

    /// Nightly respiratory rate from the beat intervals, as the median of the per-window estimates.
    ///
    /// A median across windows, not one estimate over the night: a single disturbed stretch would
    /// otherwise set the night's breathing rate.
    public static func respRateFromRR(_ rr: [RRInterval], start: Int, end: Int) -> Double {
        let seg = rr.filter { $0.ts >= start && $0.ts <= end }
        guard seg.count >= 8 else { return .nan }
        let filtered = HRVAnalyzer.rangeFilter(seg.map { Double($0.rrMs) })
        return SleepStaging.rrvFromRRSeries(filtered).rate
    }
}
