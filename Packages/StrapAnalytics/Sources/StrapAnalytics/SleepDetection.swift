import Foundation
import StrapProtocol

/// Stage 0 of sleep staging: finding the WINDOWS a person was asleep in, before any stage is
/// assigned inside them.
///
/// Stillness is the primary signal and heart rate is the confirmation. Motion alone calls a long
/// sit "sleep"; heart rate alone calls a nap on the sofa the same as a night. Requiring both, in
/// that order, is what makes a window a night.
public enum SleepDetection {

    // MARK: - Constants

    /// Stillness cut on the gravity vector, in **g per SECOND**.
    ///
    /// Per-second, not per-sample, and that distinction is load-bearing: applied to a raw
    /// consecutive-sample delta it silently means "0.01 g between whatever two samples this device
    /// happened to send", so a faster sensor moves less between samples and reads as motionless
    /// everywhere. Every comparison scales it by the measured cadence.
    public static let gravityStillThresholdGPerS = 0.01
    public static let stillWindowMin = 15
    public static let stillFraction = 0.70
    public static let maxGapMin = 20
    public static let mergeMin = 15
    public static let minSleepMin = 60
    public static let minWindowSamples = 3
    /// A window's mean HR must sit at or below this multiple of the day's baseline.
    public static let hrSleepBaselineMult = 1.05
    public static let hrSleepBandMult = hrSleepBaselineMult
    /// Below this many samples the HR confirmation abstains rather than judging.
    public static let hrRefineMinSamples = 30

    public static let epochS = 30.0
    /// Above this cadence the g/s cut stops discriminating, so nothing is asserted still.
    public static let maxStillCadenceSec = epochS
    public static let maxSupportedCadenceSec = 300.0

    /// Gravity is "sparse" when it covers far less span than HR, or has a large hole.
    public static let sparseGravitySpanFrac = 0.5
    public static let sparseBridgeGapMin = 90
    /// Above this share of a window spent off-wrist, the window is not sleep.
    public static let maxOffWristSleepFraction = 0.5

    /// A night longer than this is not one sleep. Used to REJECT, never to trim.
    public static let maxMainSleepSpanS = 16 * 60 * 60

    public static let nightContinuationGapMin = 90

    // MARK: - Cadence

    /// The stream's sample cadence, or nil when it has none worth trusting.
    ///
    /// The median gap, accepted only when at least half the gaps cluster around it. Long dropout
    /// gaps are deliberately KEPT in the sample: a dropout is a minority of gaps and cannot move a
    /// median, whereas filtering them first is exactly how a genuinely slow device becomes
    /// indistinguishable from a stream with no usable cadence at all.
    public static func sampleCadenceSeconds(_ tsSec: [Double]) -> Double? {
        guard tsSec.count >= 2 else { return nil }
        var gaps: [Double] = []
        for i in 1..<tsSec.count {
            let g = tsSec[i] - tsSec[i - 1]
            // Non-positive gaps are duplicate or unsorted timestamps, not a cadence.
            if g > 0 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return nil }
        let m = HRVAnalyzer.median(gaps)
        guard m > 0, m <= maxSupportedCadenceSec else { return nil }
        let tolerance = 2.0
        let inMode = gaps.filter { $0 <= m * tolerance && $0 * tolerance >= m }.count
        guard Double(inMode) >= Double(gaps.count) * 0.5 else { return nil }
        return m
    }

    // MARK: - Stillness

    /// Distance between consecutive gravity vectors. NaN where either sample is invalid, so an
    /// unusable pair cannot read as perfect stillness.
    static func gravityDeltas(_ g: [GravitySample]) -> [Double] {
        var out = [Double](repeating: 0, count: g.count)
        guard g.count > 1 else { return out }
        for i in 1..<g.count {
            let dx = g[i - 1].x - g[i].x, dy = g[i - 1].y - g[i].y, dz = g[i - 1].z - g[i].z
            out[i] = (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        return out
    }

    static func windowSize(_ interval: Double) -> Int {
        max(minWindowSamples, Int(Double(stillWindowMin * 60) / interval))
    }

    /// Per-sample "still" flags: a sample is still when most of its surrounding window is.
    ///
    /// With no measurable cadence — or one too coarse for the g/s cut to mean anything — NOTHING
    /// is asserted still. That yields no runs, no sessions, and an honestly absent night, rather
    /// than staging on a guessed 60-second cadence.
    static func classifyStill(_ grav: [GravitySample], _ deltas: [Double]) -> [Bool] {
        let n = grav.count
        guard n >= 2 else { return [Bool](repeating: false, count: n) }
        guard let cadence = sampleCadenceSeconds(grav.map { Double($0.ts) }),
              cadence <= maxStillCadenceSec else {
            return [Bool](repeating: false, count: n)
        }
        let half = windowSize(cadence) / 2
        let stillCut = gravityStillThresholdGPerS * cadence

        var prefix = [Int](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + (deltas[i] < stillCut ? 1 : 0) }

        return (0..<n).map { i in
            let lo = max(0, i - half), hi = min(n, i + half + 1)
            return Double(prefix[hi] - prefix[lo]) / Double(hi - lo) >= stillFraction
        }
    }

    // MARK: - Runs

    /// A run of one stillness class. `stage` is "sleep" or "active" — the coarse pass, before any
    /// sleep STAGE is assigned inside it.
    public struct Period: Equatable, Sendable {
        public var stage: String
        public var start: Int
        public var end: Int
        public init(stage: String, start: Int, end: Int) {
            self.stage = stage; self.start = start; self.end = end
        }
    }

    static func largestGapS(_ times: [Int]) -> Double {
        guard times.count >= 2 else { return 0 }
        var m = 0
        for i in 0..<(times.count - 1) { m = max(m, times[i + 1] - times[i]) }
        return Double(m)
    }

    static func isGravitySparse(_ grav: [GravitySample], _ hr: [HRSample]) -> Bool {
        guard grav.count >= 2, hr.count >= 2 else { return false }
        let hrSpan = hr.last!.ts - hr.first!.ts
        guard hrSpan > 0 else { return false }
        if Double(grav.last!.ts - grav.first!.ts) < sparseGravitySpanFrac * Double(hrSpan) { return true }
        return largestGapS(grav.map(\.ts)) > Double(maxGapMin * 60)
    }

    static func hrBaseline(_ hr: [HRSample]) -> Double? {
        guard !hr.isEmpty else { return nil }
        return HRVAnalyzer.median(hr.map { Double($0.bpm) })
    }

    static func rowsBetween(_ hr: [HRSample], _ a: Int, _ b: Int) -> [HRSample] {
        hr.filter { $0.ts >= a && $0.ts <= b }
    }

    /// Whether HR stayed in the sleep band across a gap — used to decide a gap is a dropout mid-sleep
    /// rather than the person getting up.
    static func hrSleepBandAcross(_ a: Int, _ b: Int, _ hr: [HRSample], _ baseline: Double?) -> Bool {
        guard let baseline else { return false }
        let seg = hr.filter { $0.ts > a && $0.ts <= b }.map { Double($0.bpm) }
        guard !seg.isEmpty else { return false }
        return seg.reduce(0, +) / Double(seg.count) <= baseline * hrSleepBandMult
    }

    /// Group consecutive samples of the same stillness class into runs.
    ///
    /// A gap longer than `maxGapMin` normally closes a run, EXCEPT on a sparse stream where the
    /// class did not change and HR stayed in the sleep band across the hole — that is a reporting
    /// dropout mid-sleep, and closing there fragments one night into several.
    static func buildRuns(_ grav: [GravitySample], _ flags: [Bool], sparse: Bool,
                          hr: [HRSample], baseline: Double?) -> [Period] {
        let n = grav.count
        guard n > 0 else { return [] }
        let times = grav.map(\.ts)
        let maxGapS = maxGapMin * 60
        var periods: [Period] = []
        var runStart = 0

        for i in 1...n {
            let atEnd = i == n
            var close = atEnd
            if !atEnd {
                let classChanged = flags[i] != flags[runStart]
                var gapExceeded = (times[i] - times[i - 1]) > maxGapS
                if sparse, gapExceeded, !classChanged, flags[runStart],
                   hrSleepBandAcross(times[i - 1], times[i], hr, baseline) {
                    gapExceeded = false
                }
                close = classChanged || gapExceeded
            }
            if close {
                periods.append(Period(stage: flags[runStart] ? "sleep" : "active",
                                      start: times[runStart], end: times[i - 1]))
                runStart = i
            }
        }
        return periods
    }

    /// Absorb runs shorter than the merge threshold into their neighbours.
    ///
    /// A short run BETWEEN two runs of the same class is bridged away — a two-minute stir does not
    /// end a night. Otherwise it is folded forward, or backward at the end of the stream.
    static func mergePeriods(_ periods: [Period], _ mergeMinutes: Int) -> [Period] {
        let thresholdS = mergeMinutes * 60
        var pending = periods
        var merged: [Period] = []
        var i = 0
        while i < pending.count {
            let current = pending[i]
            if (current.end - current.start) >= thresholdS {
                merged.append(current)
                i += 1
                continue
            }
            let hasPrev = i > 0 && !merged.isEmpty
            let hasNext = i + 1 < pending.count
            if hasPrev, hasNext, pending[i - 1].stage == pending[i + 1].stage {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: pending[i + 1].end))
                i += 2
            } else if hasNext {
                pending[i + 1] = Period(stage: pending[i + 1].stage, start: current.start,
                                        end: pending[i + 1].end)
                i += 1
            } else if hasPrev {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: current.end))
                i += 1
            } else {
                merged.append(current)
                i += 1
            }
        }
        return merged
    }

    /// On a sparse stream, weld adjacent sleep runs separated by a hole HR says was still sleep.
    static func bridgeSparseSleep(_ periods: [Period], sparse: Bool,
                                  hr: [HRSample], baseline: Double?) -> [Period] {
        guard sparse, !periods.isEmpty else { return periods }
        let bridgeGapS = sparseBridgeGapMin * 60
        var out: [Period] = []
        for p in periods {
            if let last = out.last, last.stage == "sleep", p.stage == "sleep" {
                let gap = p.start - last.end
                if gap >= 0, gap <= bridgeGapS, hrSleepBandAcross(last.end, p.start, hr, baseline) {
                    out[out.count - 1] = Period(stage: "sleep", start: last.start, end: p.end)
                    continue
                }
            }
            out.append(p)
        }
        return out
    }

    // MARK: - Confirmation

    /// Heart-rate confirmation for a candidate window.
    ///
    /// ABSTAINS — returns true — when there is no baseline or too few samples. A window is not
    /// rejected for lack of evidence; stillness already proposed it, and refusing on thin HR would
    /// blank nights the strap simply reported sparsely.
    static func confirmSleepWithHR(_ p: Period, _ hr: [HRSample], _ baseline: Double?) -> Bool {
        guard let baseline else { return true }
        let seg = rowsBetween(hr, p.start, p.end)
        guard seg.count >= hrRefineMinSamples else { return true }
        return Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count) <= baseline * hrSleepBaselineMult
    }

    /// Fraction of a window covered by off-wrist spans, merging overlaps so a doubly-flagged
    /// stretch is not counted twice.
    ///
    /// A FRACTION, not a yes/no. Dropping a window on any single off-wrist blip nukes a real night
    /// that over-ran into a short morning tail, while a binary rule that ignores blips keeps an
    /// all-day desk strap. Measuring coverage separates the two.
    ///
    /// Three sources are unioned: the explicit wear events, the HR-coverage gaps, and dead-flat
    /// gravity. The last two are proxies for the same fact from opposite sides of a density gate —
    /// see each for why only one of them can be right at a time.
    static func offWristFraction(_ p: Period, _ hr: [HRSample],
                                 _ wristOff: [(start: Int, end: Int)],
                                 grav: [GravitySample] = [], deltas: [Double] = []) -> Double {
        let dur = p.end - p.start
        guard dur > 0 else { return 0 }
        var spans: [(Int, Int)] = offWristHRGapSpans(p, hr).map { ($0.start, $0.end) }
        spans += offWristGravitySpans(p, grav, deltas, hr).map { ($0.start, $0.end) }
        for w in wristOff {
            let s = max(w.start, p.start), e = min(w.end, p.end)
            if e > s { spans.append((s, e)) }
        }
        guard !spans.isEmpty else { return 0 }
        spans.sort { $0.0 < $1.0 }
        var covered = 0
        var curStart = spans[0].0, curEnd = spans[0].1
        for sp in spans.dropFirst() {
            if sp.0 <= curEnd { curEnd = max(curEnd, sp.1) }
            else { covered += curEnd - curStart; curStart = sp.0; curEnd = sp.1 }
        }
        covered += curEnd - curStart
        return Double(covered) / Double(dur)
    }

    /// The window's resting HR: the lowest five-minute mean, falling back to the overall mean.
    ///
    /// A minimum over BINS, for the same reason as everywhere else — the lowest single sample of a
    /// night is a dropout beat.
    static func sessionRestingHR(_ start: Int, _ end: Int, _ hr: [HRSample]) -> Int? {
        let seg = rowsBetween(hr, start, end)
        guard !seg.isEmpty else { return nil }
        let windowS = 300
        var means: [Double] = []
        var t = start
        while t < end {
            let win = seg.filter { $0.ts >= t && $0.ts < t + windowS }.map { Double($0.bpm) }
            if !win.isEmpty { means.append(win.reduce(0, +) / Double(win.count)) }
            t += windowS
        }
        if let m = means.min() { return Int(m.rounded()) }
        return Int((Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count)).rounded())
    }

    // MARK: - Detection

    /// Find the sleep windows in a span of gravity and heart rate.
    ///
    /// The one-shot night-tail exemption is the subtle part. A pre-dawn arousal can split a short
    /// tail off the main block, and that tail is genuine sleep even below the standalone
    /// hour-minimum — so the FIRST short continuation after an overnight block is exempt. Only the
    /// first: without the one-shot, a run of short morning fragments each re-qualifies and chains
    /// the window well past the real wake.
    public static func detectSleep(gravity: [GravitySample],
                                   hr: [HRSample],
                                   wristOff: [(start: Int, end: Int)] = []) -> [Period] {
        let grav = gravity.sorted { $0.ts < $1.ts }
        guard grav.count >= 2 else { return [] }
        let hrS = hr.sorted { $0.ts < $1.ts }

        let baseline = hrBaseline(hrS)
        let sparse = isGravitySparse(grav, hrS)

        var runs = buildRuns(grav, classifyStill(grav, gravityDeltas(grav)),
                             sparse: sparse, hr: hrS, baseline: baseline)
        runs = mergePeriods(runs, mergeMin)
        runs = bridgeSparseSleep(runs, sparse: sparse, hr: hrS, baseline: baseline)

        let minSleepS = minSleepMin * 60
        let continuationGapS = nightContinuationGapMin * 60
        var chainPrevEnd: Int?
        var chainFromOvernight = false
        var nightTailAccepted = false
        var out: [Period] = []

        for p in runs where p.stage == "sleep" {
            // Chain state is computed BEFORE the minimum-length floor, so the floor can exempt a
            // night tail. Computing it after would let a pre-dawn arousal silently truncate the
            // window at the arousal.
            let continuesChain = chainPrevEnd.map { p.start - $0 <= continuationGapS } ?? false
            let isNightTail = continuesChain && chainFromOvernight && !nightTailAccepted

            if (p.end - p.start) <= minSleepS && !isNightTail { continue }
            // REJECTED, not trimmed: a span this long is not one sleep, and cutting it to the cap
            // would invent a boundary nothing measured.
            if (p.end - p.start) > maxMainSleepSpanS { continue }
            guard confirmSleepWithHR(p, hrS, baseline) else { continue }
            guard offWristFraction(p, hrS, wristOff) < maxOffWristSleepFraction else { continue }

            if isNightTail, (p.end - p.start) <= minSleepS { nightTailAccepted = true }
            if !continuesChain { nightTailAccepted = false }
            chainFromOvernight = chainFromOvernight || (p.end - p.start) > minSleepS
            chainPrevEnd = p.end
            out.append(p)
        }
        return out
    }

    // MARK: - Off-wrist proxies

    /// Longest HR-coverage gap (minutes) inside a window that still reads as worn.
    public static let offWristHRGapMin = 20
    /// One HR sample per this many seconds is the density below which the HR-gap proxy is muted.
    public static let hrDenseSpacingS = 600
    /// |Δgravity| at or under this is a strap resting on a surface, not a still wrist.
    public static let offWristGravityFlatG = 0.001

    /// HR-coverage gaps long enough to be a strap off the wrist.
    ///
    /// Worn, the strap streams heart rate continuously, so a long hole is anomalous. That is only
    /// true when the stream is DENSE: a motion-reconstructed sync carries sparse HR by design, and
    /// reading its natural spacing as off-wrist drops a real night. So the whole proxy is muted
    /// below the density bar, judged over the entire stream — an off-wrist hole inside an otherwise
    /// dense day is still caught.
    static func offWristHRGapSpans(_ p: Period, _ hr: [HRSample]) -> [(start: Int, end: Int)] {
        guard !hr.isEmpty, p.end > p.start else { return [] }
        let streamSpan = hr[hr.count - 1].ts - hr[0].ts
        if streamSpan >= hrDenseSpacingS && hr.count < streamSpan / hrDenseSpacingS { return [] }
        let gapS = offWristHRGapMin * 60
        let seg = rowsBetween(hr, p.start, p.end)
        guard !seg.isEmpty else {
            return (p.end - p.start) >= gapS ? [(p.start, p.end)] : []
        }
        var spans: [(start: Int, end: Int)] = []
        if seg[0].ts - p.start >= gapS { spans.append((p.start, seg[0].ts)) }
        for i in 1..<seg.count where seg[i].ts - seg[i - 1].ts >= gapS {
            spans.append((seg[i - 1].ts, seg[i].ts))
        }
        if p.end - seg[seg.count - 1].ts >= gapS { spans.append((seg[seg.count - 1].ts, p.end)) }
        return spans
    }

    /// Stretches where the gravity vector never moves at all.
    ///
    /// A strap set down on a surface holds one exact orientation; a worn but motionless wrist keeps
    /// micro-motion above the flat floor. This engages ONLY where the HR-gap proxy is muted — the
    /// two are complementary, and running both on a dense night would double-count the same fact.
    static func offWristGravitySpans(_ p: Period, _ grav: [GravitySample], _ deltas: [Double],
                                     _ hr: [HRSample]) -> [(start: Int, end: Int)] {
        guard grav.count >= 2, p.end > p.start else { return [] }
        if !hr.isEmpty {
            let streamSpan = hr[hr.count - 1].ts - hr[0].ts
            let sparse = streamSpan >= hrDenseSpacingS && hr.count < streamSpan / hrDenseSpacingS
            if !sparse { return [] }
        }
        let gapS = offWristHRGapMin * 60
        var spans: [(start: Int, end: Int)] = []
        var runStart: Int?
        var runEnd = 0
        for i in 0..<grav.count where grav[i].ts >= p.start && grav[i].ts <= p.end {
            let flat = i < deltas.count && deltas[i] <= offWristGravityFlatG
            if flat {
                if runStart == nil { runStart = grav[i].ts }
                runEnd = grav[i].ts
            } else {
                if let s = runStart, runEnd - s >= gapS { spans.append((s, runEnd)) }
                runStart = nil
            }
        }
        if let s = runStart, runEnd - s >= gapS { spans.append((s, runEnd)) }
        return spans
    }

    // MARK: - Time-of-day guards

    public static let secondsPerDay = 86_400
    /// The local hours a window's CENTRE has to fall in to be treated as daytime.
    public static let daytimeBandStartHour = 11
    public static let daytimeBandEndHour = 20
    /// A daytime window must run at least this long. Well under the overnight floor, so an ordinary
    /// nap can be recorded at all.
    public static let daytimeMinSleepMin = 30
    /// ...and show a real resting-HR dip against the window baseline.
    public static let daytimeRestingHRMult = 0.95
    /// ...and, when there is a night to compare against, HRV consistent with sleep.
    public static let daytimeHRVMult = 0.60
    /// A daytime block starting within this long after a real wake is suspected morning residue.
    public static let morningStillnessWindowMin = 180
    /// Inside that window the HR bar is stricter: a second sleep, not near-waking stillness.
    public static let morningReonsetRestingHRMult = 0.90
    /// The strap's own code for "asleep".
    public static let bandStateAsleep = 2
    /// How much of a block the strap must itself call asleep to confirm a re-onset.
    public static let morningReonsetBandAsleepFrac = 0.6

    static func secOfDay(_ localTs: Int) -> Int {
        ((localTs % secondsPerDay) + secondsPerDay) % secondsPerDay
    }

    /// Is the window's CENTRE in the daytime band? The centre, not the onset — a night that runs
    /// late is still a night.
    public static func isDaytimeCenter(_ p: Period, tzOffsetSeconds: Int) -> Bool {
        let centre = p.start + (p.end - p.start) / 2
        let hour = secOfDay(centre + tzOffsetSeconds) / 3600
        return hour >= daytimeBandStartHour && hour < daytimeBandEndHour
    }

    public static func isOvernightOnset(_ start: Int, tzOffsetSeconds: Int) -> Bool {
        let hour = secOfDay(start + tzOffsetSeconds) / 3600
        return !(hour >= daytimeBandStartHour && hour < daytimeBandEndHour)
    }

    /// The ordinary daytime bar: long enough, and a real cardiac dip.
    ///
    /// With no baseline or no resting HR this REJECTS, unlike the HR confirmation for a night. A
    /// daytime still stretch is much likelier to be sitting than sleeping, so absent evidence
    /// should not admit it.
    static func passesDaytimeGuard(_ p: Period, _ restingHR: Double?, _ baseline: Double?) -> Bool {
        guard (p.end - p.start) >= daytimeMinSleepMin * 60 else { return false }
        guard let baseline, let resting = restingHR else { return false }
        return resting <= baseline * daytimeRestingHRMult
    }

    /// A second, independent daytime test on HRV.
    ///
    /// The HR bar compares a MINIMUM (the lowest five-minute bucket) against a CENTRAL TENDENCY
    /// (the window median) with a 5% margin, which is structurally biased toward acceptance: the
    /// minimum of any still stretch sits well below its own mean. For someone whose waking heart
    /// rate runs well above their sleeping one, an afternoon on a sofa clears it. HRV separates
    /// those cases cleanly where HR cannot.
    ///
    /// The reference is the median of the OVERNIGHT windows this same pass already accepted — a
    /// personal, same-window comparison needing no history and no warm-up.
    ///
    /// ABSTAINS on either side missing, so it can only ever reject a candidate the HR bar admitted,
    /// never rescue one.
    static func passesDaytimeHRVGuard(_ avgHRV: Double?, _ nightHRVRef: Double?) -> Bool {
        guard let avgHRV, let ref = nightHRVRef, ref > 0 else { return true }
        return avgHRV >= ref * daytimeHRVMult
    }

    /// Does the strap itself say this block was sleep?
    ///
    /// Absent band state is false, never true: this may only ever RESCUE a block the strap scored
    /// asleep, and inventing a reading it never banked would be fabricating the anchor.
    static func bandStateConfirmsAsleep(_ p: Period,
                                        _ bandSleepState: [(ts: Int, state: Int)]) -> Bool {
        let inBlock = bandSleepState.filter { $0.ts >= p.start && $0.ts <= p.end }
        guard !inBlock.isEmpty else { return false }
        let asleep = inBlock.reduce(0) { $0 + ($1.state == bandStateAsleep ? 1 : 0) }
        return Double(asleep) / Double(inBlock.count) >= morningReonsetBandAsleepFrac
    }

    /// The stricter bar for a daytime block that begins shortly after a real wake.
    ///
    /// Residual post-wake stillness is the commonest phantom nap — a person lying in bed at 9 a.m.
    /// scoring an hour of "sleep". Inside the morning window a block must clear the ordinary bar
    /// AND either be confirmed by the strap's own state or show the deeper dip of a true second
    /// sleep. Outside it, this is the ordinary bar, so a genuine afternoon nap is untouched.
    static func passesMorningStillnessGuard(_ p: Period, _ restingHR: Double?, _ baseline: Double?,
                                            _ morningWakeEnd: Int?,
                                            _ bandSleepState: [(ts: Int, state: Int)]) -> Bool {
        guard let wakeEnd = morningWakeEnd, p.start >= wakeEnd,
              (p.start - wakeEnd) <= morningStillnessWindowMin * 60 else {
            return passesDaytimeGuard(p, restingHR, baseline)
        }
        guard passesDaytimeGuard(p, restingHR, baseline) else { return false }
        if bandStateConfirmsAsleep(p, bandSleepState) { return true }
        guard let baseline, let resting = restingHR else { return false }
        return resting <= baseline * morningReonsetRestingHRMult
    }

    /// The window's resting HR, unrounded — the comparison form the guards use.
    static func sessionRestingHRExact(_ start: Int, _ end: Int, _ hr: [HRSample]) -> Double? {
        let seg = rowsBetween(hr, start, end)
        guard !seg.isEmpty else { return nil }
        let windowS = 300
        var means: [Double] = []
        var t = start
        while t < end {
            let win = seg.filter { $0.ts >= t && $0.ts < t + windowS }.map { Double($0.bpm) }
            if !win.isEmpty { means.append(win.reduce(0, +) / Double(win.count)) }
            t += windowS
        }
        if let m = means.min() { return m }
        return Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count)
    }
}
