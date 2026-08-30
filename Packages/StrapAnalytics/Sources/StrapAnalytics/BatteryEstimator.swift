import Foundation

/// How long the strap has left, from its own state-of-charge history.
///
/// The estimate prefers a MEASURED discharge rate over the rated figure, because rated life assumes
/// a usage pattern nobody has. Someone streaming live heart rate all day drains far faster than the
/// datasheet, and telling them twelve days when they have two is worse than not answering.
public enum BatteryEstimator {

    public static let ratedLifeHoursWhoop4: Double = 108   // 4.5 days
    public static let ratedLifeHoursWhoop5: Double = 288   // 12 days

    /// A fit needs this much elapsed time and this much drop before its slope means anything.
    /// Below either, the rate is dominated by the resolution of the reported percentage.
    public static let minSpanHours: Double = 2.0
    public static let minDropPct: Double = 2.0

    /// A rise larger than this between readings is a charge, not sampling noise.
    public static let chargeStepPct: Double = 1.0
    /// A charge reaching this counts as a full one and anchors a new discharge run.
    public static let nearFullPct: Double = 90.0

    public enum Source: String, Equatable, Sendable { case measured, rated }

    public struct Estimate: Equatable, Sendable {
        public let remainingHours: Double
        /// Which rate produced this. Surfaced so a UI can distinguish an estimate from a
        /// manufacturer's claim.
        public let source: Source
        public let currentSoc: Double
        public init(remainingHours: Double, source: Source, currentSoc: Double) {
            self.remainingHours = remainingHours; self.source = source; self.currentSoc = currentSoc
        }
    }

    /// Estimate remaining runtime.
    public static func estimate(samples: [(ts: Int, soc: Double)], ratedHours: Double) -> Estimate? {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard let last = sorted.last else { return nil }
        let current = last.soc
        let run = dischargeFitWindow(sorted)

        // Endpoints rather than least squares: the window is short and monotone within a segment,
        // so a fitted line adds nothing a slope between its ends does not already say.
        let measuredRate: Double? = {
            guard run.count >= 2, let first = run.first, let lastRun = run.last else { return nil }
            let spanHours = Double(lastRun.ts - first.ts) / 3600.0
            let drop = first.soc - lastRun.soc
            guard spanHours >= minSpanHours, drop >= minDropPct else { return nil }
            let rate = drop / spanHours
            return rate > 0 ? rate : nil
        }()

        let rate = measuredRate ?? (100.0 / max(ratedHours, 1))
        // Anchored on the LATEST state of charge even when the fit window ended earlier: the
        // question is how long from now, not from the end of the last clean discharge segment.
        let remaining = max(0, current) / rate
        // A near-flat run that squeaked past the drop gate can produce an absurd rate. Nothing
        // beats about 1.5x the rated life on a fresh charge.
        return Estimate(remainingHours: min(remaining, ratedHours * 1.5),
                        source: measuredRate != nil ? .measured : .rated,
                        currentSoc: current)
    }

    /// The segment of the history to fit.
    ///
    /// Two problems it exists to solve, both of which otherwise wreck the slope:
    ///
    /// - A CHARGE inside the buffer makes the net change positive, so the fit sees no discharge at
    ///   all and silently falls back to rated. The window therefore starts at the most recent
    ///   near-full charge.
    /// - A PARTIAL top-up — a few minutes on the charger at a desk — is a rise mid-discharge that
    ///   flattens the apparent rate. The window ends before the most recent one, preferring the
    ///   longer clean segment before it.
    static func dischargeFitWindow(_ sorted: [(ts: Int, soc: Double)]) -> [(ts: Int, soc: Double)] {
        guard sorted.count >= 2 else { return sorted }

        var startIdx = 0
        for i in stride(from: sorted.count - 1, through: 1, by: -1)
        where sorted[i].soc > sorted[i - 1].soc + chargeStepPct && sorted[i].soc >= nearFullPct {
            startIdx = i
            break
        }

        // With no near-full charge to anchor on — routine on a 12-day strap that rarely tops past
        // 90% between charges — anchor at the buffer's HIGHEST reading instead of the oldest. The
        // oldest can sit below a later charge, which makes the window net to a RISE and leaves the
        // estimate permanently stuck on rated. The maximum is at least every later reading, so the
        // window can only discharge, and the drop gate still rejects a flat one.
        if startIdx == 0 {
            var maxIdx = 0
            for i in sorted.indices where sorted[i].soc >= sorted[maxIdx].soc { maxIdx = i }
            startIdx = maxIdx
        }

        var endIdx = sorted.count - 1
        if endIdx - startIdx >= 1 {
            for i in stride(from: sorted.count - 1, through: startIdx + 1, by: -1)
            where sorted[i].soc > sorted[i - 1].soc + chargeStepPct && sorted[i].soc < nearFullPct {
                endIdx = i - 1
                break
            }
        }
        guard endIdx > startIdx else { return Array(sorted[startIdx...]) }
        return Array(sorted[startIdx...endIdx])
    }

    /// Hours as something a person reads at a glance — hours up to two days, then days.
    public static func label(hours: Double) -> String {
        if hours < 48 { return "~\(Int(hours.rounded()))h" }
        return "~\(String(format: "%.1f", hours / 24)) days"
    }

    // MARK: - Diagnostics

    /// The same estimate, plus an account of how it was reached.
    ///
    /// Returns the IDENTICAL estimate as `estimate` — it calls it — so the trace can never explain
    /// a number the app is not showing. Pure, with no clock and no I/O, so a fixture stays exact.
    public static func estimateTrace(samples: [(ts: Int, soc: Double)], ratedHours: Double)
        -> (estimate: Estimate?, trace: [String]) {
        let sorted = samples.sorted { $0.ts < $1.ts }
        guard let first = sorted.first, let last = sorted.last else {
            return (nil, ["battery series=0 readings, nothing to anchor to"])
        }
        var lines = ["battery series=\(sorted.count) readings span \(first.ts)..\(last.ts)s"]
        for s in sorted { lines.append("battery read t=\(s.ts)s soc=\(pct(s.soc))") }

        for i in stride(from: sorted.count - 1, through: 1, by: -1)
        where sorted[i].soc > sorted[i - 1].soc + chargeStepPct && sorted[i].soc >= nearFullPct {
            let rise = sorted[i].soc - sorted[i - 1].soc
            lines.append("battery chargeStep at t=\(sorted[i].ts)s +\(pct(rise))pp — anchors the run")
            break
        }
        let run = dischargeFitWindow(sorted)
        if let runFirst = run.first, let runLast = run.last, run.count >= 2 {
            let spanHours = Double(runLast.ts - runFirst.ts) / 3600.0
            let drop = runFirst.soc - runLast.soc
            lines.append("battery dischargeRun start=\(runFirst.ts)s "
                + "span=\(hours(spanHours))h drop=\(pct(drop))pp")
            if spanHours < minSpanHours {
                lines.append("battery gate=minSpanHours \(hours(spanHours)) < \(hours(minSpanHours))")
            }
            if drop < minDropPct {
                lines.append("battery gate=minDropPct \(pct(drop)) < \(pct(minDropPct))")
            }
            if spanHours >= minSpanHours, drop >= minDropPct {
                lines.append("battery rate=\(pct(drop / spanHours))pp/h measured")
            }
        } else {
            lines.append("battery dischargeRun too short to fit")
        }

        let est = estimate(samples: samples, ratedHours: ratedHours)
        if let est {
            lines.append("battery source=\(est.source) soc=\(pct(est.currentSoc)) "
                + "remaining=\(hours(est.remainingHours))h")
        } else {
            lines.append("battery estimate=absent")
        }
        return (est, lines)
    }

    private static func pct(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func hours(_ v: Double) -> String { String(format: "%.2f", v) }
}
