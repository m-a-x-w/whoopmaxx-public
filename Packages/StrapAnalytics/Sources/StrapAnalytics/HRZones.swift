import Foundation
import StrapProtocol

/// One training zone as a bpm span and the percent-of-max it came from.
public struct HRZone: Equatable, Sendable {
    public let number: Int
    public let lower: Double
    public let upper: Double
    public let lowerPct: Double
    public let upperPct: Double
    public init(number: Int, lower: Double, upper: Double, lowerPct: Double, upperPct: Double) {
        self.number = number; self.lower = lower; self.upper = upper
        self.lowerPct = lowerPct; self.upperPct = upperPct
    }
}

public struct HRZoneSet: Equatable, Sendable {
    public let zones: [HRZone]
    public let maxHR: Double
    /// Where `maxHR` came from — "manual" or the estimator's name. Carried so the UI can say
    /// whether the zones rest on a measurement or on an age formula.
    public let source: String

    public init(zones: [HRZone], maxHR: Double, source: String) {
        self.zones = zones; self.maxHR = maxHR; self.source = source
    }

    /// Which zone a bpm falls in, or 0 for below zone 1.
    ///
    /// The top zone is INCLUSIVE at its upper edge so HRmax itself lands in zone 5 rather than
    /// falling out of every zone at exactly the hardest moment of a session.
    public func zoneNumber(forBPM bpm: Double) -> Int {
        for z in zones {
            if z.number == 5 {
                if bpm >= z.lower { return 5 }
            } else if bpm >= z.lower && bpm < z.upper {
                return z.number
            }
        }
        return 0
    }
}

/// Seconds accumulated in each zone.
public struct TimeInZone: Equatable, Sendable {
    /// Five entries, zone 1 first.
    public let seconds: [Double]
    /// Time below zone 1. Kept separate rather than dropped — a session spent mostly under the
    /// first threshold is a real fact about it, and folding that into zone 1 would overstate it.
    public let belowZone1: Double
    public init(seconds: [Double], belowZone1: Double) {
        self.seconds = seconds; self.belowZone1 = belowZone1
    }
}

public enum HRZones {
    /// Zone edges as fractions of maximum heart rate.
    public static let zoneEdges: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90, 1.00]

    /// Tanaka's age estimate, preferred over the older 220−age rule.
    ///
    /// The two cross at age 40. Below it 220−age reads HIGHER, so a young user's zones sit too
    /// high and ordinary efforts under-register; above it 220−age reads LOWER, so an older user's
    /// zones sit too low and every session looks harder than it was. Tanaka is the better fit at
    /// both ends, and being wrong in opposite directions either side of forty is the specific
    /// failure it avoids.
    public static func tanakaMaxHR(age: Double) -> Double { 208.0 - 0.7 * age }

    public static func zones(age: Double, maxHROverride: Double? = nil) -> HRZoneSet {
        if let override = maxHROverride { return zones(maxHR: override, source: "manual") }
        return zones(maxHR: tanakaMaxHR(age: age), source: "tanaka")
    }

    public static func zones(maxHR: Double, source: String = "manual") -> HRZoneSet {
        let built = (0..<5).map { i in
            HRZone(number: i + 1,
                   lower: zoneEdges[i] * maxHR, upper: zoneEdges[i + 1] * maxHR,
                   lowerPct: zoneEdges[i], upperPct: zoneEdges[i + 1])
        }
        return HRZoneSet(zones: built, maxHR: maxHR, source: source)
    }

    /// Median gap between samples — the representative duration for the stream.
    static func medianInterval(_ sorted: [HRSample]) -> Double {
        guard sorted.count >= 2 else { return 1 }
        var gaps: [Double] = []
        for i in 1..<sorted.count {
            let g = Double(sorted[i].ts - sorted[i - 1].ts)
            if g > 0 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return 1 }
        return HRVAnalyzer.median(gaps)
    }

    /// Accumulate time in each zone.
    ///
    /// Every sample's duration is CAPPED at the stream's median gap. Uncapped, one wall-clock gap
    /// — the strap off the wrist mid-session — credits hours to whichever zone the sample either
    /// side happened to sit in, and a single gap can dominate a whole session's profile.
    ///
    /// The final sample takes that same median, so the series is fully counted rather than losing
    /// its last interval.
    public static func timeInZone(_ hr: [HRSample], zoneSet: HRZoneSet) -> TimeInZone {
        let sorted = hr.sorted { $0.ts < $1.ts }
        var zoneSeconds = [Double](repeating: 0, count: 5)
        var below: Double = 0
        guard !sorted.isEmpty else { return TimeInZone(seconds: zoneSeconds, belowZone1: 0) }

        let tailDuration = medianInterval(sorted)
        for i in sorted.indices {
            let dur: Double
            if i < sorted.count - 1 {
                let gap = Double(sorted[i + 1].ts - sorted[i].ts)
                dur = gap > 0 ? min(gap, tailDuration) : tailDuration
            } else {
                dur = tailDuration
            }
            let z = zoneSet.zoneNumber(forBPM: Double(sorted[i].bpm))
            if z >= 1 { zoneSeconds[z - 1] += dur } else { below += dur }
        }
        return TimeInZone(seconds: zoneSeconds, belowZone1: below)
    }
}

// MARK: - Sleep debt

public struct SleepDebtNight: Equatable, Sendable {
    public let day: String
    public let sleptMin: Double
    /// Signed: negative is a shortfall.
    public let deltaMin: Double
    public init(day: String, sleptMin: Double, deltaMin: Double) {
        self.day = day; self.sleptMin = sleptMin; self.deltaMin = deltaMin
    }
}

public struct SleepDebtLedger: Equatable, Sendable {
    public let balanceMin: Double
    public let nights: [SleepDebtNight]
    public let needMin: Double
    public init(balanceMin: Double, nights: [SleepDebtNight], needMin: Double) {
        self.balanceMin = balanceMin; self.nights = nights; self.needMin = needMin
    }

    /// Nights that actually contributed. Not the window length — an unworn night is not a night of
    /// no sleep, and counting it as one manufactures debt out of a missing strap.
    public var nightCount: Int { nights.count }
    public var isDebt: Bool { balanceMin < 0 }
    public var magnitudeMin: Double { abs(balanceMin) }
}

/// Running sleep balance against a nightly need.
public enum SleepDebt {
    public static let defaultWindowNights: Int = 14
    /// Within this of zero, the balance reads as on target rather than as a surplus or a debt.
    public static let onTargetBandMin: Double = 30.0
    public static let defaultNeedHours: Double = 8.0

    /// Build the ledger over the most recent nights WITH DATA.
    ///
    /// The window counts nights that banked sleep, not calendar days. Counting calendar days would
    /// let a week without the strap silently age real nights out of the window, so a returning
    /// user's debt would reset itself rather than persist — and an unworn night is not a night of
    /// no sleep.
    public static func ledger(series: [(day: String, totalSleepMin: Double?)],
                              needHours: Double = defaultNeedHours,
                              window: Int = defaultWindowNights) -> SleepDebtLedger {
        let needMin = max(needHours, 0) * 60.0
        let cap = max(window, 1)
        let windowed = series.filter { ($0.totalSleepMin ?? 0) > 0 }.suffix(cap)

        var nights: [SleepDebtNight] = []
        nights.reserveCapacity(windowed.count)
        var balance = 0.0
        for row in windowed {
            let slept = row.totalSleepMin ?? 0
            let delta = slept - needMin
            balance += delta
            nights.append(SleepDebtNight(day: row.day, sleptMin: slept, deltaMin: delta))
        }
        return SleepDebtLedger(balanceMin: (balance * 10).rounded() / 10,
                               nights: nights, needMin: needMin)
    }
}
