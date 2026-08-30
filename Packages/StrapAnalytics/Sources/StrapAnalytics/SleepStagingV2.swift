import Foundation
import StrapProtocol

/// The second staging model: soft evidence per epoch, then one most-likely path over the night.
///
/// `SleepStaging` decides each epoch on its own and then repairs the result with smoothing and
/// physiology rules. This one never decides an epoch in isolation — every 30-second epoch
/// contributes a log-likelihood for each of the four stages, and a Viterbi pass picks the single
/// best sequence under a sticky transition matrix. Continuity comes out of the model instead of
/// being imposed afterwards.
///
/// Every feature is scored RELATIVE to the night that produced it: heart rate, its variability and
/// motion are z-scored within the session, and the motion thresholds are multiples of the night's
/// own quiescent jerk floor. So the model self-calibrates to the strap's decode scale and to how
/// tightly the band was worn, and never compares a wearer to a population.
///
/// Ported from OpenStrap/analytics `advanced_stager.dart` (MIT).
///
/// HONESTY: still a wrist autonomic ESTIMATE. A Viterbi path is not a PSG scoring.
public enum SleepStagingV2 {

    // MARK: - Constants

    /// Emission order. Viterbi ties resolve to the earlier entry.
    public static let stageNames = ["deep", "rem", "light", "awake"]

    /// How far outside the window the feature reads reach: the 11-minute flatness window looks back
    /// `padLo` and forward `padHi`. A caller clipping its streams tighter silently narrows the
    /// windows at both ends of the night, where onset and final waking actually live.
    public static let padLo = 330
    public static let padHi = 390

    /// Population sleep-architecture base rates, as log priors. They set the LEVEL: this is a
    /// soft-evidence model, not a labelling of scored epochs, so without them weak-evidence epochs
    /// distribute by emission noise rather than falling to light.
    ///
    /// Calibrated against a real multi-night record, and they must stay a population prior — tuning
    /// them to one wearer would make every night score against that wearer's own architecture.
    public static let baseLogPrior: [String: Double] = [
        "light": log(0.53), "deep": log(0.15), "rem": log(0.22), "awake": log(0.10)
    ]

    /// Deep is eligible only in the night's flattest heart-rate epochs, with a soft ramp above the
    /// bar rather than a hard cut.
    ///
    /// The gate moves DEEP only — REM appears in no other emission and is unaffected by it.
    public static let deepGateThresh = 0.16
    public static let deepGateSlope = 10.0

    /// Motion is measured in multiples of the night's own quiescent jerk floor, never in absolute g.
    public static let jerkFloorMoveMult = 38.0
    public static let jerkFloorGateMult = 55.0
    public static let motionGateBoost = 2.0

    /// Weight of the breathing-regularity term: regular breathing favours deep, irregular favours
    /// REM.
    public static let respWeight = 0.6

    /// Sticky by construction. Self-transitions dominate, deep↔REM is nearly forbidden, and wake
    /// mostly enters and leaves through light — which is what sleep actually does. A priori, not
    /// fitted.
    public static let transition: [String: [String: Double]] = [
        "deep":  ["deep": 0.90, "rem": 0.005, "light": 0.09, "awake": 0.005],
        "rem":   ["deep": 0.005, "rem": 0.88, "light": 0.10, "awake": 0.015],
        "light": ["deep": 0.06, "rem": 0.06, "light": 0.85, "awake": 0.03],
        "awake": ["deep": 0.01, "rem": 0.02, "light": 0.27, "awake": 0.70]
    ]

    /// Where in the night each stage belongs: deep front-loads and fades out by the middle, REM
    /// builds toward morning and is heavily suppressed in the first few minutes.
    ///
    /// A prior, not a rule — strong evidence still outvotes it.
    public static func cyclePrior(_ c: Double) -> [String: Double] {
        ["deep": 1.0 * max(0.0, 1.0 - c / 0.55),
         "rem": 1.0 * c - (c < 0.12 ? 3.0 : 0.0),
         "light": 0.0, "awake": 0.0]
    }

    // MARK: - Features

    /// One 30-second epoch.
    ///
    /// The optionals mean "not measured". They stay optional all the way to the z-score, which maps
    /// a missing value to the neutral centre, so a channel that dropped out never blocks a stage.
    public struct Epoch: Equatable, Sendable {
        public let start: Int
        /// Mean heart rate over the epoch.
        public let hr: Double?
        /// Heart-rate spread over a centred 5-minute window.
        public let hrVar: Double?
        /// Heart-rate spread over a centred 11-minute window — the deep/light separator.
        public let hrFlat11: Double?
        /// Share of in-epoch seconds moving, against this night's own floor.
        public let moveFrac: Double
        /// Peak per-second jerk in the epoch. Wake is bursty, and a mean hides a burst.
        public let jerkMax: Double
        /// How peaked the beat-interval spectrum is in the breathing band.
        public let respReg: Double?
        /// Position through the night, 0…1.
        public let clock: Double
        /// The night's quiescent jerk floor.
        public let jerkScale: Double
    }

    /// Build the per-epoch features over a wall-clock-aligned 30-second grid.
    ///
    /// An epoch with neither heart rate nor gravity is SKIPPED rather than emitted with empty
    /// features: a gap has no evidence, and an evidence-free epoch would simply take whatever the
    /// priors say and publish it as a measurement.
    public static func features(start: Int, end: Int, grav: [GravitySample],
                                hr: [HRSample], rr: [RRInterval]) -> [Epoch] {
        guard end > start else { return [] }
        let span = Double(max(1, end - start))

        var secHRSum: [Int: Double] = [:], secHRCnt: [Int: Int] = [:]
        var secGX: [Int: Double] = [:], secGY: [Int: Double] = [:], secGZ: [Int: Double] = [:]
        var secGCnt: [Int: Int] = [:]
        var rrBy: [Int: [Double]] = [:]
        for h in hr {
            secHRSum[h.ts, default: 0] += Double(h.bpm)
            secHRCnt[h.ts, default: 0] += 1
        }
        for g in grav {
            secGX[g.ts, default: 0] += g.x
            secGY[g.ts, default: 0] += g.y
            secGZ[g.ts, default: 0] += g.z
            secGCnt[g.ts, default: 0] += 1
        }
        for r in rr { rrBy[r.ts, default: []].append(Double(r.rrMs)) }

        func secHR(_ s: Int) -> Double? {
            guard let c = secHRCnt[s], c > 0 else { return nil }
            return secHRSum[s]! / Double(c)
        }
        func secG(_ s: Int) -> (x: Double, y: Double, z: Double)? {
            guard let c = secGCnt[s], c > 0 else { return nil }
            let n = Double(c)
            return (secGX[s]! / n, secGY[s]! / n, secGZ[s]! / n)
        }

        // Prefix sums over the per-second HR grid, so a 5- or 11-minute spread is O(1) instead of
        // rescanning hundreds of seconds per epoch.
        let hrKeys = secHRCnt.keys
        let gridLo = hrKeys.min() ?? 0
        let gridHi = hrKeys.max() ?? -1
        let size = gridHi >= gridLo ? (gridHi - gridLo + 2) : 1
        var pCnt = [Int](repeating: 0, count: size)
        var pSum = [Double](repeating: 0, count: size)
        var pSq = [Double](repeating: 0, count: size)
        if gridHi >= gridLo {
            for i in gridLo...gridHi {
                let idx = i - gridLo
                let v = secHR(i)
                pCnt[idx + 1] = pCnt[idx] + (v != nil ? 1 : 0)
                pSum[idx + 1] = pSum[idx] + (v ?? 0)
                pSq[idx + 1] = pSq[idx] + (v != nil ? v! * v! : 0)
            }
        }
        func stdOfSeconds(_ lo: Int, _ hi: Int) -> Double? {
            guard gridHi >= gridLo else { return nil }
            let a = max(lo, gridLo) - gridLo
            let b = min(hi, gridHi + 1) - gridLo
            guard b > a else { return nil }
            let cnt = pCnt[b] - pCnt[a]
            guard cnt >= 2 else { return nil }
            let n = Double(cnt)
            let sv = pSum[b] - pSum[a]
            let sq = pSq[b] - pSq[a]
            let m = sv / n
            let variance = (sq - 2 * m * sv + n * m * m) / n
            return max(variance, 0).squareRoot()
        }

        // Pass one: per-epoch features, plus every per-second jerk so the night's floor can be
        // measured before any of them is called movement.
        struct Raw {
            var start: Int
            var hr: Double?
            var hrVar: Double?
            var hrFlat11: Double?
            var jerks: [Double]
            var gapSec: Int
            var jerkMax: Double
            var respReg: Double?
            var clock: Double
        }
        var raws: [Raw] = []
        var allJerks: [Double] = []
        var e = ((start + 29) / 30) * 30
        while e < end {
            var hrs: [Double] = []
            var gseq: [(x: Double, y: Double, z: Double)] = []
            for s in e..<(e + 30) {
                if let v = secHR(s) { hrs.append(v) }
                if let g = secG(s) { gseq.append(g) }
            }
            if hrs.isEmpty && gseq.isEmpty { e += 30; continue }

            var jerks: [Double] = []
            if gseq.count > 1 {
                for i in 1..<gseq.count {
                    let dx = gseq[i - 1].x - gseq[i].x
                    let dy = gseq[i - 1].y - gseq[i].y
                    let dz = gseq[i - 1].z - gseq[i].z
                    jerks.append((dx * dx + dy * dy + dz * dz).squareRoot())
                }
            }
            allJerks.append(contentsOf: jerks)

            var beats: [(t: Double, v: Double)] = []
            for s in (e - 90)..<(e + 120) {
                guard let list = rrBy[s] else { continue }
                for v in list { beats.append((Double(s), min(max(v, 300), 2000))) }
            }
            beats.sort { $0.t != $1.t ? $0.t < $1.t : $0.v < $1.v }

            raws.append(Raw(start: e,
                            hr: hrs.isEmpty ? nil : hrs.reduce(0, +) / Double(hrs.count),
                            hrVar: stdOfSeconds(e - 150, e + 30 + 150),
                            hrFlat11: stdOfSeconds(e - 330, e + 30 + 360),
                            jerks: jerks,
                            gapSec: max(1, gseq.count - 1),
                            jerkMax: jerks.max() ?? 0,
                            respReg: respRegularity(beats),
                            clock: Double(e + 15 - start) / span))
            e += 30
        }

        // The floor is the MEDIAN per-second jerk over the whole night — the level the wrist sits at
        // when nothing is happening. A mean would be pulled up by the very bursts it has to measure.
        let jerkScale: Double
        if allJerks.isEmpty {
            jerkScale = 1e-6
        } else {
            let s = allJerks.sorted()
            let n = s.count
            jerkScale = n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
        }
        let moveThr = jerkScale * jerkFloorMoveMult

        return raws.map { r in
            let moves = r.jerks.filter { $0 > moveThr }.count
            return Epoch(start: r.start, hr: r.hr, hrVar: r.hrVar, hrFlat11: r.hrFlat11,
                         moveFrac: Double(moves) / Double(r.gapSec), jerkMax: r.jerkMax,
                         respReg: r.respReg, clock: r.clock, jerkScale: jerkScale)
        }
    }

    /// How much of the beat-interval spectrum sits in one peak inside the breathing band.
    ///
    /// Respiratory sinus arrhythmia modulates the beat intervals at the breathing frequency, so a
    /// single dominant peak between 0.15 and 0.40 Hz means regular breathing. The measure is the
    /// peak's SHARE of the band's power, not its size, which makes it independent of how deeply the
    /// person was breathing.
    ///
    /// nil rather than a number whenever the window is too short or too sparse to resolve a
    /// breath — an unresolvable spectrum has no peakedness.
    public static func respRegularity(_ beats: [(t: Double, v: Double)]) -> Double? {
        guard beats.count >= 12 else { return nil }
        let t0 = beats[0].t, tN = beats[beats.count - 1].t
        guard tN > t0 else { return nil }
        let n = Int(((tN - t0) / 0.25 - 1e-9).rounded(.up))
        guard n >= 16 else { return nil }

        // Beats arrive when the heart beats, not on a clock, so resample onto an even 4 Hz grid
        // before any spectrum is taken.
        var y = [Double](repeating: 0, count: n)
        var seg = 0
        for i in 0..<n {
            let t = t0 + 0.25 * Double(i)
            while seg < beats.count - 2 && beats[seg + 1].t < t { seg += 1 }
            let ta = beats[seg].t, tb = beats[seg + 1].t
            let va = beats[seg].v, vb = beats[seg + 1].v
            if tb <= ta { y[i] = va }
            else {
                let f = min(max((t - ta) / (tb - ta), 0), 1)
                y[i] = va + f * (vb - va)
            }
        }
        let mean = y.reduce(0, +) / Double(n)
        for i in 0..<n { y[i] -= mean }

        let kLo = Int((0.15 * 0.25 * Double(n)).rounded(.up))
        let kHi = Int((0.40 * 0.25 * Double(n)).rounded(.down))
        guard kHi >= kLo, kLo >= 0 else { return nil }
        var maxP = 0.0, sumP = 0.0
        for k in kLo...kHi {
            let w = -2 * Double.pi * Double(k) / Double(n)
            var re = 0.0, im = 0.0
            for j in 0..<n {
                re += y[j] * cos(w * Double(j))
                im += y[j] * sin(w * Double(j))
            }
            let p = re * re + im * im
            sumP += p
            if p > maxP { maxP = p }
        }
        guard sumP > 0 else { return nil }
        return maxP / sumP
    }

    // MARK: - Emissions and path

    /// Per-epoch log-likelihoods, then the single best path through them.
    public static func stageEpochs(_ feats: [Epoch]) -> [String] {
        guard !feats.isEmpty else { return [] }

        /// z against the night's own present values. A missing value scores 0 — the centre — so an
        /// absent channel contributes nothing rather than voting.
        func zfun(_ vals: [Double?]) -> (Double?) -> Double {
            let present = vals.compactMap { $0 }
            guard !present.isEmpty else { return { _ in 0 } }
            let m = present.reduce(0, +) / Double(present.count)
            let ss = present.reduce(0.0) { $0 + ($1 - m) * ($1 - m) }
            let sd0 = (ss / Double(present.count)).squareRoot()
            let sd = sd0 == 0 ? 1.0 : sd0
            return { v in v == nil ? 0 : (v! - m) / sd }
        }
        let zhr = zfun(feats.map(\.hr))
        let zhv = zfun(feats.map(\.hrVar))
        let zmv = zfun(feats.map { Optional($0.moveFrac) })
        let zrg = zfun(feats.map(\.respReg))

        // Flatness enters as a RANK within the night, not a value: its absolute scale varies with
        // resting heart rate and with how much of the epoch was measured.
        let fsorted = feats.compactMap(\.hrFlat11).sorted()
        func fpct(_ v: Double?) -> Double {
            guard let v, !fsorted.isEmpty else { return 0.5 }
            var lo = 0, hi = fsorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if fsorted[mid] <= v { lo = mid + 1 } else { hi = mid }
            }
            return Double(lo) / Double(fsorted.count)
        }

        var seq: [[String: Double]] = []
        seq.reserveCapacity(feats.count)
        for f in feats {
            let zhrv = zhr(f.hr), zhvv = zhv(f.hrVar), zmvv = zmv(f.moveFrac)
            let gate = deepGateSlope * max(0.0, fpct(f.hrFlat11) - deepGateThresh)
            let deep = -1.4 * zhvv - 0.2 * zhrv - 0.3 * zmvv - gate + baseLogPrior["deep"]!
            let rem = 0.6 * zhvv - 0.6 * zmvv + 0.4 * zhrv + baseLogPrior["rem"]!
            let awake = 1.0 * zmvv + 0.8 * zhvv + 0.4 * zhrv + baseLogPrior["awake"]!
            var em: [String: Double] = ["deep": deep, "rem": rem,
                                        "light": baseLogPrior["light"]!, "awake": awake]
            let pr = cyclePrior(f.clock)
            for s in stageNames { em[s]! += pr[s]! }
            // A single burst says wake even when the epoch was mostly still.
            if f.jerkMax > f.jerkScale * jerkFloorGateMult { em["awake"]! += motionGateBoost }
            if let rg = f.respReg {
                let z = zrg(rg)
                em["deep"]! += respWeight * z
                em["rem"]! -= respWeight * z
            }
            seq.append(em)
        }
        return viterbi(seq)
    }

    /// Most likely stage sequence, not the most likely stage per epoch.
    ///
    /// The distinction is the whole point: taking each epoch's best label independently produces
    /// paths the transition matrix says are nearly impossible, like a lone deep epoch inside REM.
    public static func viterbi(_ emSeq: [[String: Double]]) -> [String] {
        guard !emSeq.isEmpty else { return [] }
        let logT = transition.mapValues { $0.mapValues { log($0) } }
        var V = emSeq[0]                      // uniform start: the first epoch is its emission
        var back: [[String: String]] = []
        for t in 1..<emSeq.count {
            var newV: [String: Double] = [:]
            var bp: [String: String] = [:]
            for s in stageNames {
                var bestPrev = stageNames[0]
                var bestVal = V[bestPrev]! + logT[bestPrev]![s]!
                for p in stageNames.dropFirst() {
                    let val = V[p]! + logT[p]![s]!
                    if val > bestVal { bestVal = val; bestPrev = p }
                }
                newV[s] = bestVal + emSeq[t][s]!
                bp[s] = bestPrev
            }
            V = newV
            back.append(bp)
        }
        var last = stageNames[0]
        var lastV = V[last]!
        for s in stageNames.dropFirst() where V[s]! > lastV { lastV = V[s]!; last = s }
        var path = [last]
        for bp in back.reversed() {
            last = bp[last]!
            path.append(last)
        }
        return path.reversed()
    }

    // MARK: - Entry point

    /// Stage one window into a hypnogram.
    ///
    /// The streams are clipped to the padded window here rather than by the caller, so the feature
    /// windows always reach as far as they were designed to.
    public static func stageSession(start: Int, end: Int,
                                    grav: [GravitySample], hr: [HRSample],
                                    rr: [RRInterval] = []) -> [StageSegment] {
        let lo = start - padLo, hi = end + padHi
        let gravW = grav.filter { $0.ts >= lo && $0.ts < hi }
        let hrW = hr.filter { $0.ts >= lo && $0.ts < hi }
        let rrW = rr.filter { $0.ts >= lo && $0.ts < hi }
        let feats = features(start: start, end: end, grav: gravW, hr: hrW, rr: rrW)
        // Detection already called this window sleep; light claims the least.
        guard !feats.isEmpty else { return [StageSegment(start: start, end: end, stage: "light")] }

        let labels = stageEpochs(feats)
        var segments: [StageSegment] = []
        for i in 0..<feats.count {
            let stage = labels[i] == "awake" ? "wake" : labels[i]
            // The first and last segments are stretched to the window bounds: a skipped leading or
            // trailing epoch is a gap in the evidence, not a gap in the night.
            let segStart = i == 0 ? start : feats[i].start
            let segEnd = i == feats.count - 1 ? end : feats[i + 1].start
            if let last = segments.last, last.stage == stage {
                segments[segments.count - 1] = StageSegment(start: last.start, end: segEnd,
                                                            stage: stage)
            } else {
                segments.append(StageSegment(start: segStart, end: segEnd, stage: stage))
            }
        }
        return segments
    }
}
