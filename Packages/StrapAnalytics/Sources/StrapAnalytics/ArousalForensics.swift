import Foundation
import StrapProtocol

/// Why a mid-sleep awakening happened, as far as the signals can say.
public enum ArousalCause: String, Equatable, Sendable, Codable {
    /// Movement or a roll-over — the easiest to read, and the one to rule out first.
    case positional
    /// Breathing or autonomic irregularity just before the wake.
    case respiratory
    /// A skin-temperature rise across the wake against the preceding sleep.
    case thermal
    /// A heart-rate surge with LOW motion — a sympathetic stir rather than a movement.
    case cardiac
    /// Nothing cleared a bar. The awakening is real; its cause is honestly unknown.
    case unexplained
}

public struct Arousal: Equatable, Sendable, Codable {
    public let start: Int
    public let end: Int
    public let cause: ArousalCause
    /// A short phrase naming what fired, so the classification can be checked rather than trusted.
    public let evidence: String
    public let durationMin: Double
    public init(start: Int, end: Int, cause: ArousalCause, evidence: String, durationMin: Double) {
        self.start = start; self.end = end; self.cause = cause
        self.evidence = evidence; self.durationMin = durationMin
    }
}

/// Attributes mid-sleep awakenings to a likely cause.
public enum ArousalForensics {

    /// Shorter wakes are not classified. A brief stir is normal architecture, not an event.
    public static let minArousalDurationS: Double = 120
    /// How much preceding sleep forms the comparison baseline.
    public static let baselineLookbackS: Double = 600
    public static let epochS: Double = 30

    public static let positionalMotionRatioBar: Double = 3.0
    /// An absolute floor beside the ratio. Without it, a perfectly still baseline makes any
    /// movement at all a threefold increase.
    public static let positionalMotionFloor: Double = 0.5
    public static let positionalRollDegBar: Double = 30
    public static let respMinSamples: Int = 12
    public static let respCVDeltaBar: Double = 0.06
    public static let thermalRiseCBar: Double = 0.3
    public static let cardiacHRDeltaBar: Double = 12

    /// Classify every qualifying wake segment in a night.
    ///
    /// Only MID-SLEEP wakes are classified. The settling-in before the first sleep and the final
    /// wake are not awakenings — treating them as such would tag every night with two events that
    /// mean nothing.
    public static func classify(session: SleepSession,
                                motionEpochs: [Double],
                                hr: [HRSample],
                                rr: [RRInterval],
                                resp: [RespSample],
                                skinTemp: [SkinTempSample],
                                gravity: [GravitySample],
                                family: DeviceFamily) -> [Arousal] {
        let stages = session.stages
        guard !stages.isEmpty else { return [] }
        let sleep = stages.filter { $0.stage != "wake" }
        guard let firstSleepStart = sleep.map(\.start).min(),
              let lastSleepEnd = sleep.map(\.end).max() else { return [] }

        return stages.filter {
            $0.stage == "wake"
                && Double($0.end - $0.start) >= minArousalDurationS
                && $0.start >= firstSleepStart && $0.end <= lastSleepEnd
        }.map {
            tag(wakeStart: $0.start, wakeEnd: $0.end, gridStart: session.start,
                restingHR: session.restingHR, motionEpochs: motionEpochs,
                hr: hr, rr: rr, resp: resp, skinTemp: skinTemp, gravity: gravity, family: family)
        }
    }

    /// Attribute one wake.
    ///
    /// Causes are resolved in PRIORITY order, not by strength. Movement is checked first and, when
    /// it fires, suppresses the cardiac test entirely — because moving raises heart rate, and
    /// without that suppression every roll-over would also read as a cardiac event and the two
    /// categories would be indistinguishable.
    static func tag(wakeStart: Int, wakeEnd: Int, gridStart: Int, restingHR: Int?,
                    motionEpochs: [Double], hr: [HRSample], rr: [RRInterval], resp: [RespSample],
                    skinTemp: [SkinTempSample], gravity: [GravitySample],
                    family: DeviceFamily) -> Arousal {
        let ws = Double(wakeStart), we = Double(wakeEnd)
        let bs = Swift.max(Double(gridStart), ws - baselineLookbackS)

        // Positional: a motion peak well above the preceding baseline, or a real change in
        // orientation. Either alone is enough — a roll-over can be smooth, and a thrash need not
        // change which way the wrist faces.
        let baseMotion = motionValues(motionEpochs, gridStart: gridStart, lo: bs, hi: ws)
        let wakeMotion = motionValues(motionEpochs, gridStart: gridStart, lo: ws, hi: we)
        var motionFired = false
        if let wakePeak = wakeMotion.max() {
            let base = HRVAnalyzer.median(baseMotion)
            motionFired = wakePeak >= Swift.max(positionalMotionFloor, base * positionalMotionRatioBar)
        }
        var rollFired = false
        if let a = meanVector(gravity, lo: bs, hi: ws), let b = meanVector(gravity, lo: ws, hi: we),
           let angle = angleDeg(a, b) {
            rollFired = angle >= positionalRollDegBar
        }
        let positionalCleared = motionFired || rollFired

        let respCleared = respiratoryIrregular(rr: rr, resp: resp, bs: bs, ws: ws, we: we)

        let baseSkin = skinTemp.filter { inRange($0.ts, bs, ws) }
            .map { skinTempCelsius(raw: $0.raw, family: family) }
        let wakeSkin = skinTemp.filter { inRange($0.ts, ws, we) }
            .map { skinTempCelsius(raw: $0.raw, family: family) }
        var thermalCleared = false
        var thermalDelta = 0.0
        if let b = mean(baseSkin), let w = mean(wakeSkin) {
            thermalDelta = w - b
            thermalCleared = thermalDelta >= thermalRiseCBar
        }

        // Cardiac is tested ONLY when movement did not fire.
        let wakeHR = hr.filter { inRange($0.ts, ws, we) }.map(\.bpm)
        let restHR = restingHR ?? hr.filter { inRange($0.ts, bs, ws) }.map(\.bpm).min()
        var cardiacCleared = false
        var hrDelta = 0
        if !positionalCleared, let peak = wakeHR.max(), let rest = restHR {
            hrDelta = peak - rest
            cardiacCleared = Double(hrDelta) >= cardiacHRDeltaBar
        }

        let cause: ArousalCause
        let evidence: String
        if positionalCleared {
            cause = .positional; evidence = rollFired ? "roll-over" : "movement"
        } else if respCleared {
            cause = .respiratory; evidence = "breathing irregular"
        } else if thermalCleared {
            cause = .thermal; evidence = String(format: "+%.1f\u{00B0}C skin", thermalDelta)
        } else if cardiacCleared {
            cause = .cardiac; evidence = "HR +\(hrDelta)"
        } else {
            // Named honestly rather than assigned to the nearest-miss category. A wrong
            // explanation is worse than none, because it invites a change of behaviour.
            cause = .unexplained; evidence = "no clear signal"
        }

        return Arousal(start: wakeStart, end: wakeEnd, cause: cause,
                       evidence: evidence, durationMin: Double(wakeEnd - wakeStart) / 60.0)
    }

    /// Beat-to-beat variability rising across the wake.
    ///
    /// Prefers R-R and falls back to the raw respiration channel — not every strap reports both,
    /// and a night with only one should still be classifiable.
    static func respiratoryIrregular(rr: [RRInterval], resp: [RespSample],
                                     bs: Double, ws: Double, we: Double) -> Bool {
        let baseRR = rr.filter { inRange($0.ts, bs, ws) }.map { Double($0.rrMs) }
        let wakeRR = rr.filter { inRange($0.ts, ws, we) }.map { Double($0.rrMs) }
        if baseRR.count >= respMinSamples, wakeRR.count >= respMinSamples,
           let bCV = cv(baseRR), let wCV = cv(wakeRR) {
            return (wCV - bCV) >= respCVDeltaBar
        }
        let baseResp = resp.filter { inRange($0.ts, bs, ws) }.map { Double($0.raw) }
        let wakeResp = resp.filter { inRange($0.ts, ws, we) }.map { Double($0.raw) }
        if baseResp.count >= respMinSamples, wakeResp.count >= respMinSamples,
           let bCV = cv(baseResp), let wCV = cv(wakeResp) {
            return (wCV - bCV) >= respCVDeltaBar
        }
        return false
    }

    /// Epoch values overlapping a window. Epochs are positional — index times epoch length from
    /// the session start — because the motion lane carries no timestamps of its own.
    static func motionValues(_ epochs: [Double], gridStart: Int, lo: Double, hi: Double) -> [Double] {
        guard !epochs.isEmpty else { return [] }
        var out: [Double] = []
        for i in epochs.indices {
            let e0 = Double(gridStart) + Double(i) * epochS
            if e0 + epochS > lo && e0 < hi { out.append(epochs[i]) }
        }
        return out
    }

    static func meanVector(_ g: [GravitySample], lo: Double, hi: Double)
        -> (x: Double, y: Double, z: Double)? {
        let w = g.filter { inRange($0.ts, lo, hi) }
        guard !w.isEmpty else { return nil }
        let n = Double(w.count)
        return (w.reduce(0) { $0 + $1.x } / n,
                w.reduce(0) { $0 + $1.y } / n,
                w.reduce(0) { $0 + $1.z } / n)
    }

    /// Angle between two orientation vectors, in degrees.
    static func angleDeg(_ a: (x: Double, y: Double, z: Double),
                         _ b: (x: Double, y: Double, z: Double)) -> Double? {
        let magA = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        let magB = (b.x * b.x + b.y * b.y + b.z * b.z).squareRoot()
        guard magA > 1e-9, magB > 1e-9 else { return nil }
        // Clamped before acos: floating-point error on parallel vectors pushes the cosine a hair
        // past 1 and acos returns NaN, which would silently disable roll detection.
        let cosT = (a.x * b.x + a.y * b.y + a.z * b.z) / (magA * magB)
        return acos(Swift.min(1, Swift.max(-1, cosT))) * 180.0 / Double.pi
    }

    static func inRange(_ ts: Int, _ lo: Double, _ hi: Double) -> Bool {
        Double(ts) >= lo && Double(ts) < hi
    }

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Coefficient of variation — dispersion relative to the mean, so it compares across signals
    /// on different scales.
    static func cv(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs), m != 0 else { return nil }
        let sd = (xs.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)).squareRoot()
        return sd / abs(m)
    }
}
