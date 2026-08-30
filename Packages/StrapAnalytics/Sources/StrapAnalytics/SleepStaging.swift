import Foundation
import StrapProtocol

/// Stage 1-3: turning one detected sleep WINDOW into a hypnogram.
///
/// `SleepDetection` says which spans of the day were sleep. This says what happened inside one.
/// The two are kept apart because they fail differently — detection can be wrong about a nap and
/// still stage a real night correctly, and a staging change must never be able to move a window
/// boundary.
///
/// Ported from OpenStrap/analytics `advanced_stager.dart` (MIT).
///
/// HONESTY: a wrist-worn four-class ESTIMATE from heart rate, motion and beat intervals. Not PSG.
/// No wrist device measures EEG, so "deep" here means an autonomic signature consistent with deep
/// sleep, never a scored N3 epoch.
public enum SleepStaging {

    // MARK: - Constants

    public static let epochS = SleepDetection.epochS
    public static let featureWindowS = 5 * 60.0

    /// Movement cut on the gravity vector, in g PER SECOND — the same rate model, and the same
    /// trap, as `SleepDetection.gravityStillThresholdGPerS`.
    public static let moveDeltaThresholdGPerS = 0.01

    public static let hrDogSigma1S = 120.0
    public static let hrDogSigma2S = 600.0

    /// Percentile bands. Every threshold is RELATIVE to this night's own distribution: an absolute
    /// bpm or ms cut would classify a fit 45-bpm sleeper and a 70-bpm one by their resting rate
    /// rather than by what changed overnight.
    public static let stageHRLowPct = 25.0
    public static let stageHRHighPct = 70.0
    public static let stageHRVHighPct = 70.0
    public static let stageHRVarHighPct = 65.0
    public static let stageRRVHighPct = 65.0
    public static let stageRRVLowPct = 50.0
    public static let stageWakeMoveFrac = 0.15
    public static let stageStillMoveFrac = 0.10

    /// Above this share of sleep epochs missing RMSSD, the parasympathetic channel is not usable
    /// and wake falls back to heart rate alone.
    public static let cardiacSparseEpochFrac = 0.5

    public static let smoothEpochs = 5
    public static let noREMAfterOnsetMin = 15.0
    /// Deep sleep concentrates in the first third of a night. Past that, a deep call competes with
    /// an earlier one rather than standing on its own.
    public static let deepFirstFraction = 1.0 / 3.0
    public static let fragmentMergeEpochs = 6

    // MARK: - Cole–Kripke spine
    //
    // KNOWN DEVIATION, deliberate. The published Cole–Kripke weights were fitted to Actigraph
    // zero-crossing counts, and a 1 Hz gravity-delta sum is not that count. It is used anyway,
    // under three limits that keep the mismatch from reaching a stage label:
    //
    //   1. SPINE ONLY. Its output locates sleep ONSET and FINAL WAKE and picks which epochs feed
    //      the percentile bands. It never assigns a stage.
    //   2. OVERRIDDEN. The hypnogram comes from the per-epoch features below, then smoothing, then
    //      `reimposePhysiology` — all of which outrank the raw CK call.
    //   3. RELATIVE. `rescaleCounts` normalises before the weights are applied, so the spine reads
    //      within-night relative motion, not an absolute count the surrogate cannot honour.
    //
    // Do not read a CK flag as a validated sleep/wake score.
    public static let ckWeights: [Double] = [106, 54, 58, 76, 230, 74, 67]
    public static let ckScale = 0.001
    public static let ckBack = 4
    public static let ckFwd = 2
    public static let ckCountDivisor = 100.0
    public static let ckCountClip = 300.0
    public static let onsetPersistEpochs = 3

    // MARK: - Epoch grid

    struct EpochGrid {
        var edges: [Double]
        var nEpochs: Int
        var counts: [Double]
        var hr: [Double]
        var moveFrac: [Double]
        var rrBuckets: [[Double]]
        var rrTsBuckets: [[Int]]
        var respBuckets: [[Double]]
        var ckFlags: [Bool]
    }

    /// Bin every stream onto a fixed 30 s grid over `[start, end)`.
    ///
    /// `moveFrac` defaults to 1.0 — "moving" — for an epoch with no gravity samples, and the whole
    /// motion channel is abandoned when the stream has no trustworthy cadence. Both are the
    /// conservative direction: absent motion evidence must not read as stillness, because stillness
    /// is what this pipeline calls sleep.
    static func buildEpochGrid(_ start: Int, _ end: Int,
                               _ gSeg: [GravitySample], _ hSeg: [HRSample],
                               _ rSeg: [RRInterval], _ respSeg: [RespSample]) -> EpochGrid {
        guard end > start else {
            return EpochGrid(edges: [Double(start)], nEpochs: 0, counts: [], hr: [],
                             moveFrac: [], rrBuckets: [], rrTsBuckets: [], respBuckets: [],
                             ckFlags: [])
        }
        let span = Double(end - start)
        let nEpochs = max(1, Int((span / epochS).rounded(.up)))
        var edges = (0...nEpochs).map { Double(start) + Double($0) * epochS }
        edges[nEpochs] = max(edges[nEpochs], Double(end))

        func idx(_ ts: Int) -> Int? {
            if ts < start || ts >= end { return ts == end ? nEpochs - 1 : nil }
            return min((ts - start) / Int(epochS), nEpochs - 1)
        }

        var counts = [Double](repeating: 0, count: nEpochs)
        var gravN = [Int](repeating: 0, count: nEpochs)
        var moveN = [Int](repeating: 0, count: nEpochs)
        var hrSum = [Double](repeating: 0, count: nEpochs)
        var hrCnt = [Int](repeating: 0, count: nEpochs)
        var rrBuckets = [[Double]](repeating: [], count: nEpochs)
        var rrTsBuckets = [[Int]](repeating: [], count: nEpochs)
        var respBuckets = [[Double]](repeating: [], count: nEpochs)

        // A gravity delta spans one sampling interval, and `counts` sums them per epoch — so its
        // size is cadence before it is movement (30 terms per epoch at 1 Hz, 6 at 5 s). With no
        // measurable cadence there is no motion evidence at all: counts stay 0, gravN stays 0
        // (moveFrac 1.0, "moving"), and Cole–Kripke is handed nothing.
        let cadence = SleepDetection.sampleCadenceSeconds(gSeg.map { Double($0.ts) })
        let cadenceOK = cadence != nil && cadence! <= SleepDetection.maxStillCadenceSec
        if let cadence, cadenceOK {
            let moveCut = moveDeltaThresholdGPerS * cadence
            let deltas = SleepDetection.gravityDeltas(gSeg)
            for k in 0..<gSeg.count {
                guard let i = idx(gSeg[k].ts) else { continue }
                counts[i] += deltas[k]
                gravN[i] += 1
                if deltas[k] >= moveCut { moveN[i] += 1 }
            }
        }
        for h in hSeg {
            guard let i = idx(h.ts) else { continue }
            hrSum[i] += Double(h.bpm)
            hrCnt[i] += 1
        }
        for r in rSeg {
            guard let i = idx(r.ts) else { continue }
            rrBuckets[i].append(Double(r.rrMs))
            rrTsBuckets[i].append(r.ts)
        }
        for r in respSeg {
            guard let i = idx(r.ts) else { continue }
            respBuckets[i].append(Double(r.raw))
        }

        var hr = [Double](repeating: .nan, count: nEpochs)
        var moveFrac = [Double](repeating: 1.0, count: nEpochs)
        for i in 0..<nEpochs {
            if hrCnt[i] > 0 { hr[i] = hrSum[i] / Double(hrCnt[i]) }
            moveFrac[i] = gravN[i] > 0 ? Double(moveN[i]) / Double(gravN[i]) : 1.0
        }
        // Spelled out rather than left to the arithmetic: an all-zero count series scores `si < 1`
        // on every epoch, i.e. SLEEP everywhere — exactly the fabrication the abstain exists for.
        let ckFlags = cadenceOK ? coleKripke(rescaleCounts(counts))
                                : [Bool](repeating: false, count: nEpochs)

        return EpochGrid(edges: edges, nEpochs: nEpochs, counts: counts, hr: hr,
                         moveFrac: moveFrac, rrBuckets: rrBuckets, rrTsBuckets: rrTsBuckets,
                         respBuckets: respBuckets, ckFlags: ckFlags)
    }

    /// Per-epoch gravity-delta sum → the Cole–Kripke count surrogate.
    ///
    /// NO cadence factor, deliberately. Under this file's rate model a per-sample delta grows
    /// linearly with the sampling interval, so a 30 s epoch holds 30 terms of size d at 1 Hz and 6
    /// terms of size 5d at 5 s — the sum is already the same. Scaling by cadence here would inflate
    /// a slower band's count and move the onset/final-wake decision on exactly the devices the rate
    /// model exists to support, while leaving 1 Hz untouched and the defect invisible.
    static func rescaleCounts(_ counts: [Double]) -> [Double] {
        counts.map { min($0 / ckCountDivisor, ckCountClip) }
    }

    static func coleKripke(_ rescaled: [Double]) -> [Bool] {
        let n = rescaled.count
        var flags = [Bool](repeating: false, count: n)
        for i in 0..<n {
            var si = 0.0
            for k in 0..<ckWeights.count {
                let j = i - ckBack + k
                let a = (j >= 0 && j < n) ? rescaled[j] : 0.0
                si += ckWeights[k] * a
            }
            flags[i] = si * ckScale < 1.0
        }
        return flags
    }

    /// First persistent sleep run, and the last sleep epoch of the night.
    ///
    /// Onset needs `onsetPersistEpochs` in a row: a single quiet epoch while still awake in bed is
    /// not falling asleep. Final wake takes the LAST sleep epoch rather than the first sustained
    /// wake run, because a morning lie-in is still inside the recorded window.
    static func onsetAndFinalWake(_ ckFlags: [Bool]) -> (onset: Int, finalWake: Int) {
        let n = ckFlags.count
        guard n > 0 else { return (0, 0) }
        var run = 0
        var onset: Int?
        for i in 0..<n {
            run = ckFlags[i] ? run + 1 : 0
            if run >= onsetPersistEpochs { onset = i - onsetPersistEpochs + 1; break }
        }
        var finalWake: Int?
        for i in stride(from: n - 1, through: 0, by: -1) where ckFlags[i] { finalWake = i; break }
        let o = onset ?? 0
        var f = finalWake ?? (n - 1)
        if f < o { f = n - 1 }
        return (o, f)
    }

    // MARK: - Difference-of-Gaussians HR variability

    static func gaussianKernel(sigmaS: Double, dtS: Double = epochS) -> [Double] {
        let sigma = max(sigmaS / dtS, 1e-6)
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        var k: [Double] = []
        k.reserveCapacity(2 * radius + 1)
        for x in (-radius)...radius {
            let z = Double(x) / sigma
            k.append(exp(-0.5 * z * z))
        }
        let sum = k.reduce(0, +)
        return k.map { $0 / sum }
    }

    /// Convolve with the edges REFLECTED rather than zero-padded.
    ///
    /// Zero padding would drag the first and last epochs of a night toward zero, which the
    /// difference below then reads as a variability event at exactly the two moments — sleep onset
    /// and final wake — the pipeline cares most about.
    static func convolveReflect(_ x: [Double], _ kernel: [Double]) -> [Double] {
        let r = kernel.count / 2
        guard r > 0, x.count > r else { return x }
        var padded: [Double] = []
        padded.reserveCapacity(x.count + 2 * r)
        for i in 0..<r { padded.append(x[r - i]) }
        padded.append(contentsOf: x)
        for i in 0..<r { padded.append(x[x.count - 2 - i]) }
        let m = kernel.count
        var out: [Double] = []
        out.reserveCapacity(x.count)
        var i = 0
        while i <= padded.count - m {
            var acc = 0.0
            for j in 0..<m { acc += padded[i + j] * kernel[m - 1 - j] }
            out.append(acc)
            if out.count == x.count { break }
            i += 1
        }
        return out
    }

    /// A 2-minute smooth minus a 10-minute smooth: the HR movement fast enough to be a stage
    /// transition, with the slow overnight drift removed.
    ///
    /// Missing epochs are linearly interpolated first, then held flat at the ends. Leaving them as
    /// NaN would poison both kernels; filling them with zero would create the same artificial edge
    /// the reflected convolution above exists to avoid.
    static func dogHRVariability(_ hrPerEpoch: [Double]) -> [Double] {
        let n = hrPerEpoch.count
        guard n > 0 else { return [] }
        let maskIdx = (0..<n).filter { !hrPerEpoch[$0].isNaN }
        guard let first = maskIdx.first, let last = maskIdx.last else {
            return [Double](repeating: 0, count: n)
        }
        var filled = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if !hrPerEpoch[i].isNaN { filled[i] = hrPerEpoch[i] }
            else if i <= first { filled[i] = hrPerEpoch[first] }
            else if i >= last { filled[i] = hrPerEpoch[last] }
            else {
                var lo = first, hi = last
                for m in maskIdx {
                    if m <= i { lo = m }
                    if m >= i { hi = m; break }
                }
                if hi == lo { filled[i] = hrPerEpoch[lo] }
                else {
                    let t = Double(i - lo) / Double(hi - lo)
                    filled[i] = hrPerEpoch[lo] + t * (hrPerEpoch[hi] - hrPerEpoch[lo])
                }
            }
        }
        let g1 = convolveReflect(filled, gaussianKernel(sigmaS: hrDogSigma1S))
        let g2 = convolveReflect(filled, gaussianKernel(sigmaS: hrDogSigma2S))
        return (0..<n).map { g1[$0] - g2[$0] }
    }

    // MARK: - Features

    struct EpochFeatures {
        var index: Int
        var midTs: Double
        var moveFrac: Double
        var ckSleep: Bool
        var hr: Double
        var hrVar: Double
        var rmssd: Double
        var sdnn: Double
        var respRate: Double
        var rrv: Double
        /// Position through the night, 0 at onset and 1 at final wake. The only feature that knows
        /// what time it is; everything else is local.
        var clock: Double
    }

    static func extractFeatures(_ grid: EpochGrid, onsetIdx: Int, finalWakeIdx: Int)
        -> [EpochFeatures] {
        let n = grid.nEpochs
        let dogHR = dogHRVariability(grid.hr)
        let halfW = Int((featureWindowS / epochS / 2).rounded())
        let span = max(1, finalWakeIdx - onsetIdx)
        var out: [EpochFeatures] = []
        out.reserveCapacity(n)

        for i in 0..<n {
            let lo = max(0, i - halfW)
            let hi = min(n, i + halfW + 1)
            let winDog = dogHR.isEmpty ? [0.0] : Array(dogHR[lo..<hi])
            let hrVar = winDog.count >= 2 ? populationStd(winDog) : Double.nan

            var winRR: [Double] = []
            var winResp: [Double] = []
            for j in lo..<hi {
                winRR.append(contentsOf: grid.rrBuckets[j])
                winResp.append(contentsOf: grid.respBuckets[j])
            }
            let filteredRR = HRVAnalyzer.rangeFilter(winRR)
            let enough = filteredRR.count >= 5
            let rmssd = enough ? (HRVAnalyzer.rmssdRaw(filteredRR) ?? Double.nan) : Double.nan
            let sdnn = enough ? (HRVAnalyzer.sdnnRaw(filteredRR) ?? Double.nan) : Double.nan

            // The raw respiration channel is the better source and is used when present. It never
            // is: no WHOOP record carries one, so in practice every night takes the RR-derived
            // path. That fallback is not a degradation — respiratory sinus arrhythmia modulates
            // the beat intervals themselves at the breathing frequency, which is the same signal a
            // dedicated sensor would read (the classic ECG-derived-respiration argument).
            //
            // It matters because `rrv` gates the primary REM rule. With no fallback that feature is
            // permanently NaN, the rule can never fire, and REM collapses into the "light"
            // catch-all on every real night.
            let rr = winResp.count >= 8 ? respRateAndRRV(winResp) : rrvFromRRSeries(filteredRR)

            let clock = clampD(Double(i - onsetIdx) / Double(span), 0, 1)
            let ckSleep = i < grid.ckFlags.count ? grid.ckFlags[i] : true
            out.append(EpochFeatures(index: i,
                                     midTs: (grid.edges[i] + grid.edges[i + 1]) / 2,
                                     moveFrac: grid.moveFrac[i],
                                     ckSleep: ckSleep,
                                     hr: grid.hr[i],
                                     hrVar: hrVar,
                                     rmssd: rmssd,
                                     sdnn: sdnn,
                                     respRate: rr.rate,
                                     rrv: rr.rrv,
                                     clock: clock))
        }
        return out
    }

    /// Breathing rate and its variability from a raw 1 Hz respiration trace.
    static func respRateAndRRV(_ respRaw: [Double], dtS: Double = 1.0)
        -> (rate: Double, rrv: Double) {
        let nan = (rate: Double.nan, rrv: Double.nan)
        guard respRaw.count >= 8 else { return nan }
        let mean = respRaw.reduce(0, +) / Double(respRaw.count)
        let x = respRaw.map { $0 - mean }
        if x.allSatisfy({ abs($0) < 1e-12 }) { return nan }
        guard populationStd(x) > 0 else { return nan }
        let minDistance = max(2, Int((2.0 / dtS).rounded()))
        let peaks = findPeaks(x, distance: minDistance, height: 0.0)
        guard peaks.count >= 3 else { return nan }
        var intervals: [Double] = []
        for i in 1..<peaks.count {
            let iv = Double(peaks[i] - peaks[i - 1]) * dtS
            if iv >= 1.5 && iv <= 12.0 { intervals.append(iv) }
        }
        guard intervals.count >= 2 else { return nan }
        return (60 / HRVAnalyzer.median(intervals), populationStd(intervals))
    }

    /// The same peak count applied to the beat intervals themselves, for when no respiration
    /// channel exists. Beat times are reconstructed by cumulatively summing the intervals, so a
    /// breath's length is measured in seconds of clock rather than in beats.
    static func rrvFromRRSeries(_ rrMs: [Double]) -> (rate: Double, rrv: Double) {
        let nan = (rate: Double.nan, rrv: Double.nan)
        guard rrMs.count >= 8 else { return nan }
        var times = [Double](repeating: 0, count: rrMs.count + 1)
        for i in 0..<rrMs.count { times[i + 1] = times[i] + rrMs[i] }
        let mean = rrMs.reduce(0, +) / Double(rrMs.count)
        let x = rrMs.map { $0 - mean }
        if x.allSatisfy({ abs($0) < 1e-9 }) { return nan }
        guard populationStd(x) > 0 else { return nan }
        // Peaks at least two beats apart — an RR series carries about one sample per beat, so a
        // distance-1 peak is beat-to-beat noise, not a breath.
        let peaks = findPeaks(x, distance: 2, height: 0.0)
        guard peaks.count >= 3 else { return nan }
        var intervalsS: [Double] = []
        for i in 1..<peaks.count {
            let iv = (times[peaks[i]] - times[peaks[i - 1]]) / 1000.0
            if iv >= 1.5 && iv <= 12.0 { intervalsS.append(iv) }
        }
        guard intervalsS.count >= 2 else { return nan }
        return (60 / HRVAnalyzer.median(intervalsS), populationStd(intervalsS))
    }

    /// Local maxima at least `distance` apart, tallest first.
    ///
    /// A plateau reports its centre, so a flat-topped peak is one peak and not none.
    static func findPeaks(_ x: [Double], distance: Int, height: Double) -> [Int] {
        let n = x.count
        guard n >= 3 else { return [] }
        var candidates: [Int] = []
        var i = 1
        while i < n - 1 {
            if x[i] > x[i - 1] && x[i] >= height {
                var j = i
                while j + 1 < n && x[j + 1] == x[i] { j += 1 }
                if j + 1 < n && x[j + 1] < x[i] { candidates.append((i + j) / 2) }
                i = j + 1
            } else {
                i += 1
            }
        }
        guard distance > 1, !candidates.isEmpty else { return candidates }
        let byHeight = candidates.sorted { a, b in
            x[a] != x[b] ? x[a] > x[b] : a < b
        }
        var keep = [Int: Bool](uniqueKeysWithValues: candidates.map { ($0, true) })
        for p in byHeight where keep[p] == true {
            for q in candidates where q != p && keep[q] == true {
                if abs(q - p) < distance { keep[q] = false }
            }
        }
        return candidates.filter { keep[$0] == true }
    }

    // MARK: - Classifier

    /// Bands are drawn over the CK-sleep epochs only, when there are any.
    ///
    /// Including the awake tails would put the night's highest heart rates in the distribution, and
    /// every percentile inside sleep would shift with how long the person lay awake first.
    static func classifyEpochs(_ features: [EpochFeatures]) -> [String] {
        let anyCk = features.contains { $0.ckSleep }
        let sleepFeats = anyCk ? features.filter { $0.ckSleep } : features
        let hrLo = pct(sleepFeats.map(\.hr), stageHRLowPct)
        let hrHi = pct(sleepFeats.map(\.hr), stageHRHighPct)
        let rmssdHi = pct(sleepFeats.map(\.rmssd), stageHRVHighPct)
        let hrvarHi = pct(sleepFeats.map(\.hrVar), stageHRVarHighPct)
        let rrvHi = pct(sleepFeats.map(\.rrv), stageRRVHighPct)
        let rrvLo = pct(sleepFeats.map(\.rrv), stageRRVLowPct)
        let sparse = isCardiacSparse(sleepFeats)
        return features.map {
            classifyOne($0, hrLo: hrLo, hrHi: hrHi, rmssdHi: rmssdHi,
                        hrvarHi: hrvarHi, rrvHi: rrvHi, rrvLo: rrvLo, cardiacSparse: sparse)
        }
    }

    /// Percentile over the FINITE values only, nil when there are none — so a channel that was
    /// never available yields no band rather than a band built from nothing.
    static func pct(_ values: [Double], _ p: Double) -> Double? {
        let finite = values.filter { $0.isFinite }.sorted()
        guard !finite.isEmpty else { return nil }
        return StrainScorer.percentile(finite, p)
    }

    static func isCardiacSparse(_ sleepFeats: [EpochFeatures]) -> Bool {
        guard !sleepFeats.isEmpty else { return false }
        let missing = sleepFeats.filter { !$0.rmssd.isFinite }.count
        return Double(missing) >= cardiacSparseEpochFrac * Double(sleepFeats.count)
    }

    /// One epoch's stage.
    ///
    /// The order is the rule. Wake is tested first because movement outranks any cardiac
    /// signature; deep and REM are mutually exclusive claims on a still epoch; everything left is
    /// light, which is both the commonest stage and the honest place to put an epoch nothing
    /// distinguishes.
    ///
    /// A missing channel ABSTAINS rather than votes: `parasympOK` and `rrvRegular` are true when
    /// their input is absent, so a night with no beat intervals still separates deep from light on
    /// heart rate and motion instead of losing deep entirely.
    static func classifyOne(_ f: EpochFeatures, hrLo: Double?, hrHi: Double?,
                            rmssdHi: Double?, hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?,
                            cardiacSparse: Bool) -> String {
        let hasHR = f.hr.isFinite
        let hrLow = hasHR && hrLo != nil && f.hr <= hrLo!
        let hrHigh = hasHR && hrHi != nil && f.hr >= hrHi!
        let parasympOK = !f.rmssd.isFinite || (rmssdHi != nil && f.rmssd >= rmssdHi!)
        let hrvarHigh = f.hrVar.isFinite && hrvarHi != nil && f.hrVar >= hrvarHi!
        let cardiacActivated = hrHigh || hrvarHigh
        // With RMSSD mostly missing, `hrvarHigh` is doing the work alone and over-calls wake, so
        // the wake test falls back to heart rate only.
        let activatedForWake = cardiacSparse ? hrHigh : cardiacActivated
        let rrvIrregular = f.rrv.isFinite && rrvHi != nil && f.rrv >= rrvHi!
        let rrvRegular = !f.rrv.isFinite || (rrvLo != nil && f.rrv <= rrvLo!)
        let still = f.moveFrac <= stageStillMoveFrac
        let moving = f.moveFrac >= stageWakeMoveFrac

        if moving && (activatedForWake || !hasHR) { return "wake" }
        if still && parasympOK && hrLow && rrvRegular { return "deep" }
        if still && cardiacActivated && rrvIrregular { return "rem" }
        // Rare-gap fallback: this specific window had too few beats to compute rrv even though the
        // session generally has it. Uses the same cardiac-activation signal as the rule above
        // rather than a stricter one — the data is already thin here, and demanding more of it is
        // how REM disappeared from nights that had it.
        if still && cardiacActivated && !f.rrv.isFinite { return "rem" }
        return "light"
    }

    // MARK: - Post-processing

    /// Median filter over a 5-epoch window, with the epoch's own label winning any tie.
    ///
    /// Sleep does not alternate stage every 30 seconds. A lone dissenting epoch is far more likely
    /// to be a noisy feature than a real 30-second REM bout.
    static func smoothLabels(_ labels: [String], window: Int = smoothEpochs) -> [String] {
        let n = labels.count
        guard n > 0, window > 1 else { return labels }
        var w = window
        if w % 2 == 0 { w += 1 }
        let half = w / 2
        var out = labels
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            var counts: [String: Int] = [:]
            var order: [String] = []
            for k in lo..<hi {
                let s = labels[k]
                if counts[s] == nil { order.append(s) }
                counts[s, default: 0] += 1
            }
            let best = counts.values.max() ?? 0
            let winners = order.filter { counts[$0] == best }
            out[i] = winners.contains(labels[i]) ? labels[i] : (winners.first ?? labels[i])
        }
        return out
    }

    /// Two rules sleep architecture actually obeys, imposed after classification.
    ///
    /// REM does not occur in the first ~15 minutes after falling asleep, and deep sleep front-loads
    /// the night. The second rule only fires when early deep was actually found — if the night has
    /// no early deep, a late deep call is the only deep evidence there is and demoting it would
    /// erase the stage rather than relocate it.
    static func reimposePhysiology(_ labels: [String], _ features: [EpochFeatures],
                                   onsetIdx: Int, finalWakeIdx: Int) -> [String] {
        let noREMEpochs = Int((noREMAfterOnsetMin * 60 / epochS).rounded())
        var hasEarlyDeep = false
        for i in 0..<labels.count
        where labels[i] == "deep" && features[i].clock <= deepFirstFraction {
            hasEarlyDeep = true
            break
        }
        var out = labels
        for i in 0..<labels.count {
            guard i >= onsetIdx, i <= finalWakeIdx else { continue }
            if out[i] == "rem" && (i - onsetIdx) < noREMEpochs { out[i] = "light" }
            if out[i] == "deep" && features[i].clock > deepFirstFraction && hasEarlyDeep {
                out[i] = "light"
            }
        }
        return out
    }

    static func stageDepthRank(_ stage: String) -> Int {
        switch stage {
        case "deep": return 3
        case "rem": return 2
        case "light": return 1
        default: return 0
        }
    }

    /// Absorb runs shorter than three minutes into their neighbours.
    ///
    /// A run below that is not a scoreable bout. When both neighbours are the same stage the
    /// fragment simply disappears into them; otherwise the LONGER neighbour takes it, and a tie
    /// goes to the SHALLOWER stage — inventing deep or REM from a tie is the expensive error.
    static func mergeFragments(_ labels: [String],
                               thresholdEpochs: Int = fragmentMergeEpochs) -> [String] {
        let n = labels.count
        guard n > 0, thresholdEpochs > 1 else { return labels }
        var runs: [(stage: String, len: Int)] = []
        var i = 0
        while i < n {
            var j = i
            while j < n && labels[j] == labels[i] { j += 1 }
            runs.append((labels[i], j - i))
            i = j
        }
        guard runs.count >= 2 else { return labels }

        var merged: [(stage: String, len: Int)] = []
        i = 0
        while i < runs.count {
            let cur = runs[i]
            if cur.len >= thresholdEpochs {
                merged.append(cur)
                i += 1
                continue
            }
            let hasPrev = !merged.isEmpty
            let hasNext = i + 1 < runs.count
            if hasPrev && hasNext && merged[merged.count - 1].stage == runs[i + 1].stage {
                merged[merged.count - 1].len += cur.len + runs[i + 1].len
                i += 2
            } else if hasPrev && hasNext {
                let prev = merged[merged.count - 1]
                let next = runs[i + 1]
                let winner: String
                if prev.len > next.len { winner = prev.stage }
                else if next.len > prev.len { winner = next.stage }
                else {
                    winner = stageDepthRank(prev.stage) <= stageDepthRank(next.stage)
                        ? prev.stage : next.stage
                }
                if winner == prev.stage {
                    merged[merged.count - 1].len = prev.len + cur.len
                } else {
                    runs[i + 1].len = next.len + cur.len
                }
                i += 1
            } else if hasNext {
                runs[i + 1].len += cur.len
                i += 1
            } else if hasPrev {
                merged[merged.count - 1].len += cur.len
                i += 1
            } else {
                merged.append(cur)
                i += 1
            }
        }
        var out: [String] = []
        out.reserveCapacity(n)
        for r in merged { out.append(contentsOf: [String](repeating: r.stage, count: r.len)) }
        return out
    }

    /// Epoch labels → contiguous segments tiling `[start, end)`.
    ///
    /// The last segment is stretched to `end` so the hypnogram covers the whole window: a
    /// sub-epoch remainder must not read as a hole in the night.
    static func buildSegments(_ labels: [String], _ grid: EpochGrid, end: Int) -> [StageSegment] {
        var segments: [StageSegment] = []
        for i in 0..<labels.count {
            let stage = labels[i]
            let segStart = Int(grid.edges[i].rounded())
            let segEnd = Int(grid.edges[i + 1].rounded())
            if let last = segments.last, last.stage == stage {
                segments[segments.count - 1] = StageSegment(start: last.start, end: segEnd,
                                                            stage: stage)
            } else {
                segments.append(StageSegment(start: segStart, end: segEnd, stage: stage))
            }
        }
        if let last = segments.last {
            segments[segments.count - 1] = StageSegment(start: last.start, end: end,
                                                        stage: last.stage)
        }
        return segments
    }

    // MARK: - Entry points

    /// Stage one window into a hypnogram.
    ///
    /// Fewer than two gravity samples means there is no motion channel at all. The window is
    /// reported as a single "light" span rather than dropped: detection already decided this was
    /// sleep, and light is the stage that claims the least.
    public static func stageSession(start: Int, end: Int,
                                    grav: [GravitySample], hr: [HRSample],
                                    rr: [RRInterval] = [], resp: [RespSample] = [])
        -> [StageSegment] {
        let gSeg = grav.filter { $0.ts >= start && $0.ts <= end }
        guard gSeg.count >= 2 else { return [StageSegment(start: start, end: end, stage: "light")] }
        let hSeg = SleepDetection.rowsBetween(hr, start, end)
        let rSeg = rr.filter { $0.ts >= start && $0.ts <= end }
        let respSeg = resp.filter { $0.ts >= start && $0.ts <= end }

        let grid = buildEpochGrid(start, end, gSeg, hSeg, rSeg, respSeg)
        guard grid.nEpochs > 0 else {
            return [StageSegment(start: start, end: end, stage: "light")]
        }
        let (onsetIdx, finalWakeIdx) = onsetAndFinalWake(grid.ckFlags)
        let feats = extractFeatures(grid, onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)
        var labels = classifyEpochs(feats)
        labels = smoothLabels(labels)
        labels = reimposePhysiology(labels, feats, onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)
        labels = mergeFragments(labels)
        // Outside onset..finalWake the person was in bed, not asleep.
        for i in 0..<labels.count where i < onsetIdx || i > finalWakeIdx { labels[i] = "wake" }
        return buildSegments(labels, grid, end: end)
    }

    /// Stage a window and wrap it with the session-level numbers.
    public static func stageWindow(start: Int, end: Int,
                                   grav: [GravitySample], hr: [HRSample],
                                   rr: [RRInterval] = [], resp: [RespSample] = [],
                                   lowConfidence: Bool = false) -> SleepSession {
        let stages = stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
        return SleepSession(start: start, end: end,
                            efficiency: efficiency(start: start, end: end, stages: stages),
                            stages: stages,
                            restingHR: SleepDetection.sessionRestingHR(start, end, hr),
                            avgHRV: sessionAvgHRV(start: start, end: end, rr: rr),
                            lowConfidence: lowConfidence)
    }

    /// Asleep time as a share of time in bed.
    public static func efficiency(start: Int, end: Int, stages: [StageSegment]) -> Double {
        let inBed = end - start
        guard inBed > 0 else { return 0 }
        let wake = stages.filter { $0.stage == "wake" }.reduce(0) { $0 + ($1.end - $1.start) }
        return min(1.0, Double(max(0, inBed - wake)) / Double(inBed))
    }

    // MARK: - Session HRV

    /// Mean RMSSD over 5-minute tumbling windows across the session, or nil.
    ///
    /// Two guards, both of which change the answer materially on real nights:
    ///
    /// A QUALITY GATE. A window is admitted only if it kept at least `HRVAnalyzer.minBeats` clean
    /// intervals and threw away no more than `defaultSpotMaxRejectedFraction` of its own. Averaging
    /// every window equally lets one that discarded four-fifths of its beats contribute at full
    /// weight — and those windows produce the LARGEST numbers, so they dominate what they should
    /// barely influence. These windows are not motion artefacts and a movement gate will not catch
    /// them; they are sustained beat-lock loss during motionless sleep.
    ///
    /// SPLICE SAFETY. RMSSD is built from successive differences, so it must never difference
    /// across a beat the cleaner just removed, nor across a stream dropout.
    public static func sessionAvgHRV(start: Int, end: Int, rr: [RRInterval]) -> Double? {
        guard end > start, !rr.isEmpty else { return nil }
        let seg = rr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return nil }
        let windowS = 5 * 60
        let windowCount = (end - start + windowS - 1) / windowS
        guard windowCount > 0 else { return nil }
        var buckets = [[Double]](repeating: [], count: windowCount)
        var bucketTs = [[Int]](repeating: [], count: windowCount)
        for r in seg {
            let b = (r.ts - start) / windowS
            guard b >= 0, b < windowCount else { continue }
            buckets[b].append(Double(r.rrMs))
            bucketTs[b].append(r.ts)
        }
        var vals: [Double] = []
        for (b, bucket) in buckets.enumerated() where !bucket.isEmpty {
            let kept = HRVAnalyzer.cleanRRIndexed(bucket)
            guard kept.count >= HRVAnalyzer.minBeats else { continue }
            let rejected = 1.0 - Double(kept.count) / Double(bucket.count)
            guard rejected <= HRVAnalyzer.defaultSpotMaxRejectedFraction else { continue }
            if let r = HRVAnalyzer.rmssdExcludingSplices(kept, ts: bucketTs[b]) { vals.append(r) }
        }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Small math

    /// Population deviation (÷n), not the sample one. These epochs are the whole window being
    /// described, not a draw from a larger one.
    static func populationStd(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let m = xs.reduce(0, +) / Double(xs.count)
        let ss = xs.reduce(0.0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count)).squareRoot()
    }

    static func clampD(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, x))
    }

    // MARK: - Hypnogram metrics

    /// AASM-shaped summary of one staged night.
    public struct HypnogramMetrics: Equatable, Sendable {
        /// Time in bed — the detected window.
        public let tibS: Double
        /// Total sleep time.
        public let tstS: Double
        /// Sleep period time: first sleep epoch to last, wake inside included.
        public let sptS: Double
        /// Non-sleep seconds before the first sleep epoch, or nil when nothing staged as sleep.
        ///
        /// NOT sleep-onset latency, and named so it cannot be read as one. Latency needs a
        /// lights-out reference and the strap has none: the window START is itself a stillness
        /// marker, so it already begins after the wrist has been essentially motionless for
        /// minutes. Subtracting a second threshold on the same motion stream from it yields
        /// roughly zero by construction.
        ///
        /// nil rather than the whole window when no epoch staged as sleep — reporting time in bed
        /// as "time to fall asleep" beside a TST of zero is a fabricated number, not an abstention.
        public let leadingNonSleepS: Double?
        /// Seconds from sleep onset to the first REM epoch. NaN when the night has no REM.
        public let remLatencyS: Double
        /// Wake after sleep onset — wake INSIDE the sleep period only.
        public let wasoS: Double
        public let efficiency: Double
        public let disturbances: Int
        public let deepMin: Double
        public let remMin: Double
        public let lightMin: Double
        public let deepPct: Double
        public let remPct: Double
        public let lightPct: Double

        public init(tibS: Double, tstS: Double, sptS: Double, leadingNonSleepS: Double?,
                    remLatencyS: Double, wasoS: Double, efficiency: Double, disturbances: Int,
                    deepMin: Double, remMin: Double, lightMin: Double,
                    deepPct: Double, remPct: Double, lightPct: Double) {
            self.tibS = tibS; self.tstS = tstS; self.sptS = sptS
            self.leadingNonSleepS = leadingNonSleepS; self.remLatencyS = remLatencyS
            self.wasoS = wasoS; self.efficiency = efficiency; self.disturbances = disturbances
            self.deepMin = deepMin; self.remMin = remMin; self.lightMin = lightMin
            self.deepPct = deepPct; self.remPct = remPct; self.lightPct = lightPct
        }
    }

    /// Summarise a staged night.
    ///
    /// Wake is only counted as WASO between the first and last sleep epoch. Wake before sleep and
    /// wake after final waking are time in bed, not disturbed sleep, and counting them would make
    /// a night that started late look fragmented.
    public static func hypnogramMetrics(_ session: SleepSession) -> HypnogramMetrics {
        let segs = session.stages.sorted { $0.start < $1.start }
        let tib = max(0.0, Double(session.end - session.start))
        func dur(_ s: StageSegment) -> Double { Double(s.end - s.start) }

        let sleepSegs = segs.filter { $0.stage != "wake" }
        let tst = sleepSegs.reduce(0.0) { $0 + dur($1) }
        let deepS = segs.filter { $0.stage == "deep" }.reduce(0.0) { $0 + dur($1) }
        let remS = segs.filter { $0.stage == "rem" }.reduce(0.0) { $0 + dur($1) }
        let lightS = segs.filter { $0.stage == "light" }.reduce(0.0) { $0 + dur($1) }

        let onset: Double, sptEnd: Double
        let leadingNonSleep: Double?
        if let first = sleepSegs.first, let last = sleepSegs.last {
            onset = Double(first.start)
            sptEnd = Double(last.end)
            leadingNonSleep = max(0.0, onset - Double(session.start))
        } else {
            onset = Double(session.end)
            sptEnd = Double(session.end)
            leadingNonSleep = nil
        }

        let remLatency = sleepSegs.first { $0.stage == "rem" }
            .map { Double($0.start) - onset } ?? Double.nan

        var waso = 0.0
        var disturbances = 0
        for s in segs where s.stage == "wake" {
            let w0 = max(Double(s.start), onset)
            let w1 = min(Double(s.end), sptEnd)
            if w1 > w0 { waso += w1 - w0; disturbances += 1 }
        }

        let se = tib > 0 ? tst / tib : 0.0
        func share(_ x: Double) -> Double { tst > 0 ? x / tst * 100.0 : 0.0 }

        return HypnogramMetrics(tibS: tib, tstS: tst, sptS: max(0.0, sptEnd - onset),
                                leadingNonSleepS: leadingNonSleep, remLatencyS: remLatency,
                                wasoS: waso, efficiency: min(1.0, se), disturbances: disturbances,
                                deepMin: deepS / 60, remMin: remS / 60, lightMin: lightS / 60,
                                deepPct: share(deepS), remPct: share(remS), lightPct: share(lightS))
    }

    // MARK: - Exposed epoch series

    /// Per-epoch motion over a window — the same gravity-delta sums the spine scores.
    ///
    /// Empty when there is no motion channel, rather than a row of zeros: zeros read as perfect
    /// stillness, which is the one thing an absent accelerometer must never say.
    public static func sessionEpochMotion(start: Int, end: Int,
                                          grav: [GravitySample]) -> [Double] {
        let gSeg = grav.filter { $0.ts >= start && $0.ts <= end }
        guard gSeg.count >= 2 else { return [] }
        return buildEpochGrid(start, end, gSeg, [], [], []).counts
    }

    /// The strap's OWN sleep state, gridded onto the same 30-second epochs as the stages.
    ///
    /// EMPTY when the window carries no band samples — an absent signal stays absent, and a
    /// fabricated array of zeros would read as "the strap said awake all night".
    ///
    /// Band state is a step function, so an epoch with no sample of its own carries the previous
    /// epoch's forward, and leading epochs take the first sample's. The code is carried VERBATIM:
    /// this never converts the strap's own claim into a derived stage.
    public static func sessionEpochSleepState(start: Int, end: Int,
                                              sleepState: [(ts: Int, state: Int)]) -> [Int] {
        let seg = sleepState.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        guard !seg.isEmpty, end > start else { return [] }
        let nEpochs = max(1, Int((Double(end - start) / epochS).rounded(.up)))
        var out = [Int](repeating: seg[0].state, count: nEpochs)
        var last = seg[0].state
        var si = 0
        for i in 0..<nEpochs {
            let epochEnd = start + Int(Double(i + 1) * epochS)
            while si < seg.count && seg[si].ts < epochEnd {
                last = seg[si].state
                si += 1
            }
            out[i] = last
        }
        return out
    }

    // MARK: - Respiration channel

    /// Distinct raw values a respiration window needs before a rate can possibly be read from it.
    ///
    /// Peak-picking needs one interior sample strictly above both neighbours. With two levels the
    /// detrended window is a square wave whose every "peak" is a plateau between equals; with one
    /// it is flat. Three is the first count that can produce a real maximum.
    public static let respMinDistinctRawLevels = 3

    /// Is this respiration window worth running the estimator over?
    ///
    /// Cheap, and deliberately so — it short-circuits on the third distinct level, so a night of
    /// constant ADC readings costs a few comparisons instead of a full scan.
    public static func respChannelUsable(_ resp: [RespSample]) -> Bool {
        guard resp.count >= 8 else { return false }
        var levels: Set<Int> = []
        for s in resp {
            levels.insert(s.raw)
            if levels.count >= respMinDistinctRawLevels { return true }
        }
        return false
    }
}
