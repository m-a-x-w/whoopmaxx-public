import Foundation
import StrapProtocol
import StrapAnalytics

/// ThermalSleepSignature — the start of the night read out of the skin-temperature trace, ROBUSTLY
/// (011 W2.2). Pure, no store, no schema, nothing persisted.
///
/// Two jobs off one binned pass:
///
///   • THE NADIR, FIXED. `BodyClockEngine.nightlyTempMinClockHour` was a plain single-sample argmin over
///     ~30,000 samples behind nothing but the 28–42 °C worn band. Measured on the real backup, each night
///     carries 16–110 isolated dropout samples that clear 28.00 °C by a hair, and the surviving nightly
///     minimum occurs exactly ONCE in 6 of 7 long nights — the argmin was latching onto one of those
///     transients, landing +0.5…+3.3 h (median +1.1 h) away from a 5-min-median + rolling-median nadir,
///     biased early in 6 of 7. That number is not advisory: `CircadianEngine.estimatePhase` OVERRIDES its
///     own cosinor fit with `observedTempMinHour` when one is present, scores `offsetVsScheduleMinutes`
///     against ±20-minute copy thresholds, and rides into `TwoProcessModel.recommendBedtime`. A dropout
///     spike was steering bedtime advice by up to three hours. A bin median over hundreds of samples,
///     then a rolling median over seven bins, cannot see a singleton at all.
///
///   • THE ONSET DUMP. How far the trace falls at the start of the night, and how long it takes to settle
///     there. Emitted ONLY behind a readability gate — coverage, session length, and amplitude measured
///     against the post-settle plateau's OWN jitter. On the corpus that gate passes the five warm-start
///     nights (amplitude 3.18–5.50 °C vs plateau SD 0.19–0.77 °C) and correctly rejects the three
///     cold-start nights (amplitude 0.40–1.25 °C), where the strap was already cool at onset and the
///     unguarded maths reports a bogus 0.4 °C "dump".
///
/// UNITS HONESTY, which is why the shape of this API is what it is. On the WHOOP 4.0 the raw→°C slope is
/// PROVISIONAL and says so (`Streams.swift:82-85`, "All 4.0 values APPROXIMATE"). So `settleMinutes` is
/// what a surface leads with — time is not scaled by the slope, so it is calibration-free — and the
/// amplitude is only ever expressed as a within-user RANKING (`heatDump`), which is slope-invariant
/// because the same slope applies to every night. No absolute °C is printed anywhere. The nadir DEPTH is
/// deliberately not emitted at all: plateau jitter (SD 0.19–0.77 °C) swamps it, so there is no honest
/// number to hand back.
///
/// READ-ONLY (011 decision 2): nothing here feeds `AnalyticsEngine` or moves a Charge / Effort / Rest
/// score. The only shipped number it changes is the body-clock nadir, which it makes more correct.
///
/// Framing register (011 decision 5): descriptive, within-user, no condition name, no probability, no
/// call-to-action. Banned from every string this type or its surfaces produce — thermoregulation,
/// vasodilation, impaired, poor, abnormal, apnea, insomnia, hypoxemia, arrhythmia, "consider",
/// "you should", "talk to".
enum ThermalSleepSignature {

    // MARK: - Constants (named in one place; every one of them is a refusal threshold)

    /// Plausible worn skin-temperature range (°C). Same band `BodyClockEngine` gates on — off-wrist and
    /// charging drift never reaches the bins.
    static let wornMinC = 28.0
    static let wornMaxC = 42.0

    /// Bin width for the first median. Five minutes at the stream's 1 Hz is ~300 samples per bin.
    static let binSeconds = 300
    /// Samples a bin needs before its median is trusted. A tenth of a full 1 Hz bin: permissive about
    /// sampling rate, but far more than the handful of dropout samples any single bin can carry, so the
    /// median can never BE one of them.
    static let minSamplesPerBin = 30
    /// Bins in the rolling median (7 × 5 min ≈ half an hour), and how many of them must carry a value
    /// before the window has a median at all.
    static let smoothBins = 7
    static let minSmoothBins = 4

    /// Shortest session worth reading. Below this there is no settled plateau to measure a drop against.
    static let minSessionSeconds = 3 * 3_600
    /// Fraction of the session's bins that must carry a trusted median before the night is read.
    static let minCoverage = 0.5
    /// The window the onset limb is looked for in — the drop, if there is one, is a first-two-hours event.
    static let onsetWindowSeconds = 2 * 3_600
    /// How close to the window's floor counts as settled (°C). Provisional-slope scaled like every other
    /// °C here, which is why it never reaches a surface.
    static let settleToleranceC = 0.30
    /// Bins the post-settle plateau needs before its jitter is a measurement rather than a guess.
    static let minPlateauBins = 6
    /// The readability gate proper: the drop must be this many times the plateau's own SD. Measured SNR
    /// on the readable corpus nights is 5–8×; the cold-start nights sit far below 3×.
    static let snrK = 3.0

    /// Nightly-amplitude baseline config for the within-user ranking. Bounds are wide enough to admit
    /// every readable night in the corpus (3.18–5.50 °C) without admitting a decode failure; the σ floor
    /// matches the `skin_temp` config's 0.3 °C so a run of near-identical nights cannot manufacture a
    /// verdict out of a spread of nothing. Half-lives are the house 14/21 (unused by `rollingMeanSD`,
    /// which is a plain trailing mean/SD, but `MetricCfg` carries them).
    static let amplitudeCfg = Baselines.MetricCfg(minVal: 0.2, maxVal: 15.0, floorSpread: 0.3,
                                        halfLifeB: 14.0, halfLifeS: 21.0)

    // MARK: - Values

    /// The onset limb of one night. Present ONLY when the drop cleared the readability gate.
    struct Onset: Equatable {
        /// °C from the onset level down to the floor of the onset window. Provisional-slope scaled on the
        /// 4.0 — only ever ranked against the same user's other nights, never printed.
        let amplitudeC: Double
        /// Minutes from the first readable bin to the settle bin. Calibration-free: the only number here
        /// a surface may lead with.
        let settleMinutes: Int
        /// `amplitudeC` per hour across those minutes. Same provisional slope, same within-user-only rule.
        let rateCPerHour: Double
    }

    /// One night's reading. The nadir survives even when the onset limb does not — a night whose start
    /// was unreadable still has a robust minimum, and that minimum is the value the body clock rides on.
    struct Night: Equatable {
        /// Unix seconds at the centre of the lowest smoothed bin of the whole session.
        let nadirTs: Int
        /// Share of the session's bins that carried a trusted median.
        let coverage: Double
        /// SD (°C) of the smoothed bins after the settle bin — the jitter `amplitudeC` has to beat. nil
        /// when there was no settle bin, or too few bins behind it to measure jitter honestly.
        let plateauSdC: Double?
        /// nil ⇔ the start of the night could not be read clearly.
        let onset: Onset?
    }

    /// Where last night's drop sits against the user's OWN recent nights. Mirrors `RhythmRegularity`'s
    /// benign vocabulary; the copy for each case lives with the surface, not here.
    ///   .steeper    → a steeper drop than the recent nights
    ///   .typical    → in line with the recent nights
    ///   .shallower  → a shallower drop than the recent nights
    ///   .unreadable → couldn't read the start of the night clearly
    enum Steepness: String, Equatable, Sendable {
        case steeper
        case typical
        case shallower
        case unreadable
    }

    /// What the body-clock readout has to say about last night's heat dump. The two ways of having no
    /// verdict are DIFFERENT facts and never collapse: `steepness == .unreadable` means the night itself
    /// wouldn't read, `steepness == nil` means it read fine and there is not yet enough of the user's own
    /// history to rank it against.
    struct HeatDump: Equatable {
        /// Last night's settle duration, or nil when the onset limb was unreadable.
        let settleMinutes: Int?
        /// nil until `Baselines.minNightsSeed` readable nights sit behind it — there is no within-user
        /// ranking to print yet, and a population one does not exist.
        let steepness: Steepness?
        /// Readable earlier nights the ranking was built on (0 when there is no ranking).
        let comparedNights: Int
    }

    // MARK: - Per-night analysis

    /// Read one sleep session's skin-temperature stream. `start` / `end` are the session's own bounds
    /// (unix seconds) — coverage is measured against the session, not against whatever the stream
    /// happened to contain, so a strap that banked one hour of a nine-hour night reports 0.11 rather than
    /// a confident 1.0.
    ///
    /// Returns nil when the session is too short or too thinly covered to read at all. A returned `Night`
    /// always carries a measured nadir; its `onset` is the part that may honestly be missing.
    static func analyze(_ samples: [SkinTempSample], family: DeviceFamily,
                        start: Int, end: Int) -> Night? {
        let span = end - start
        guard span >= minSessionSeconds else { return nil }

        let binCount = (span + binSeconds - 1) / binSeconds
        guard binCount > 0 else { return nil }

        // ── Bin medians ──────────────────────────────────────────────────────────────────────────────
        var buckets = [[Double]](repeating: [], count: binCount)
        for s in samples {
            guard s.ts >= start, s.ts <= end else { continue }
            let c = skinTempCelsius(raw: s.raw, family: family)
            guard c >= wornMinC, c <= wornMaxC else { continue }
            let idx = Swift.min(binCount - 1, (s.ts - start) / binSeconds)
            buckets[idx].append(c)
        }
        var binC = [Double?](repeating: nil, count: binCount)
        var filled = 0
        for i in 0..<binCount where buckets[i].count >= minSamplesPerBin {
            binC[i] = median(buckets[i])
            filled += 1
        }
        let coverage = Double(filled) / Double(binCount)
        guard coverage >= minCoverage else { return nil }

        // ── Rolling median ───────────────────────────────────────────────────────────────────────────
        let smooth = rollingMedian(binC)
        guard let nadirIdx = argmin(smooth) else { return nil }
        // Bin CENTRE, clamped to the session: a span that isn't a whole number of bins would otherwise
        // put the last bin's centre a couple of minutes past the night the reading belongs to.
        let nadirTs = Swift.min(end, start + nadirIdx * binSeconds + binSeconds / 2)

        // ── Onset limb ───────────────────────────────────────────────────────────────────────────────
        let windowBins = Swift.min(binCount, onsetWindowSeconds / binSeconds)
        let windowVals = (0..<windowBins).compactMap { smooth[$0] }
        // The onset level is the median of the first two readable bins (the median of two IS their mean).
        guard let onsetIdx = (0..<windowBins).first(where: { smooth[$0] != nil }),
              windowVals.count >= 2, let floorC = windowVals.min()
        else { return Night(nadirTs: nadirTs, coverage: coverage, plateauSdC: nil, onset: nil) }
        let onsetC = (windowVals[0] + windowVals[1]) / 2.0

        // The floor is by construction attained inside the window, so a settle bin always exists; what it
        // may fail to be is LATER than the onset — a night that starts already settled has no drop to read.
        guard let settleIdx = (onsetIdx..<windowBins).first(where: { i in
            guard let v = smooth[i] else { return false }
            return v <= floorC + settleToleranceC
        }), settleIdx > onsetIdx else {
            return Night(nadirTs: nadirTs, coverage: coverage, plateauSdC: nil, onset: nil)
        }

        // ── The gate: the drop against the plateau's own jitter ───────────────────────────────────────
        let plateau = ((settleIdx + 1)..<binCount).compactMap { smooth[$0] }
        let plateauSd = plateau.count >= minPlateauBins ? sampleSD(plateau) : nil
        let amplitudeC = onsetC - floorC
        let settleMinutes = (settleIdx - onsetIdx) * binSeconds / 60
        guard let plateauSd, amplitudeC > 0, amplitudeC >= snrK * plateauSd else {
            return Night(nadirTs: nadirTs, coverage: coverage, plateauSdC: plateauSd, onset: nil)
        }

        let onset = Onset(amplitudeC: amplitudeC,
                          settleMinutes: settleMinutes,
                          rateCPerHour: amplitudeC / (Double(settleMinutes) / 60.0))
        return Night(nadirTs: nadirTs, coverage: coverage, plateauSdC: plateauSd, onset: onset)
    }

    // MARK: - Within-user ranking

    /// Rank last night's drop against the readable nights BEFORE it. `history` is one entry per earlier
    /// scanned night, oldest → newest, nil where that night's onset didn't read — the nils are passed
    /// through rather than dropped so `rollingMeanSD` counts only the nights it actually has.
    ///
    /// Last night is deliberately NOT in its own baseline: the copy says "your recent nights", and folding
    /// tonight in drags the mean toward it, which flattens the very comparison being made.
    static func heatDump(latest: Onset?, history: [Double?]) -> HeatDump {
        guard let latest else {
            return HeatDump(settleMinutes: nil, steepness: .unreadable, comparedNights: 0)
        }
        let state = Baselines.rollingMeanSD(history, cfg: amplitudeCfg)
        guard state.usable else {
            return HeatDump(settleMinutes: latest.settleMinutes, steepness: nil,
                            comparedNights: state.nValid)
        }
        let dev = Baselines.deviation(latest.amplitudeC, state: state)
        let steepness: Steepness
        if dev.inNormalRange { steepness = .typical }
        else if dev.z > 0 { steepness = .steeper }
        else { steepness = .shallower }
        return HeatDump(settleMinutes: latest.settleMinutes, steepness: steepness,
                        comparedNights: state.nValid)
    }

    // MARK: - Pure helpers

    /// Centred `smoothBins`-wide median over the bin series; nil where fewer than `minSmoothBins` of the
    /// window carried a value, so a lone surviving bin in a gap never becomes a smoothed reading.
    static func rollingMedian(_ bins: [Double?]) -> [Double?] {
        let half = smoothBins / 2
        var out = [Double?](repeating: nil, count: bins.count)
        for i in 0..<bins.count {
            let lo = Swift.max(0, i - half)
            let hi = Swift.min(bins.count - 1, i + half)
            let window = (lo...hi).compactMap { bins[$0] }
            if window.count >= minSmoothBins { out[i] = median(window) }
        }
        return out
    }

    /// Index of the smallest present value, or nil when nothing is present.
    static func argmin(_ values: [Double?]) -> Int? {
        var bestIdx: Int? = nil
        var bestV = Double.greatestFiniteMagnitude
        for (i, v) in values.enumerated() {
            guard let v, v < bestV else { continue }
            bestV = v
            bestIdx = i
        }
        return bestIdx
    }

    /// Median of a non-empty sample (even counts average the two middles).
    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2.0
    }

    /// Sample SD (ddof = 1) of two or more values; 0 for anything shorter.
    static func sampleSD(_ xs: [Double]) -> Double {
        guard xs.count >= 2 else { return 0 }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let ss = xs.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }
}
