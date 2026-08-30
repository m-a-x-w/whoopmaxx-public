import XCTest
import StrapAnalytics
import StrapStore
@testable import whoopmaxx

/// The CAUSAL Charge seed gate, and the write guard behind it.
///
/// The gate exists so a day that genuinely had fewer than `Baselines.minNightsSeed` HRV nights behind it
/// is not back-filled with a score the model itself declares unscoreable. As first landed it folded its
/// prefix over `hist ∪ nightlyHrvByDay` — the IMPORTED lane (empty for a strap-only user, which is the
/// app's stated core user) plus only the days the current pass scanned. With `maxDays: 21` on every
/// production caller, that set is at most the trailing 21 days, so the fold restarted its seed count at
/// the WINDOW's oldest day and marked the first `minNightsSeed − 1` days of the WINDOW unusable however
/// much real history preceded them.
///
/// That is a history shredder, not a cosmetic bug: a day's LAST scoring pass is the one where it sits at
/// the oldest offset — i.e. the pass that suppresses it — and `MetricsCache.upsertDailyMetrics`
/// substitutes rather than coalesces (`recovery = excluded.recovery`), so every day's final write is a
/// NULL. A strap-only user's whole Charge history dies at ~3 weeks, one day at a time.
///
/// The store's own numbers made this invisible when it landed: the real backup's data starts 2026-07-09,
/// essentially where its 21-day window starts, so the window edge and the history edge coincided and
/// "exactly 3 days suppressed" looked correct.
final class ChargeSeedGateTests: XCTestCase {

    private let hrvCfg = Baselines.metricCfg["hrv"]!

    /// `n` consecutive day keys ending at `2026-07-26`, oldest first.
    private func dayKeys(_ n: Int) -> [String] {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        let end = fmt.date(from: "2026-07-26")!
        return (0..<n).map { fmt.string(from: end.addingTimeInterval(-Double(n - 1 - $0) * 86_400)) }.sorted()
    }

    // MARK: - The defect

    func testWindowScopedPrefixSuppressesTheWindowEdgeNotTheHistoryEdge() {
        // A 60-night record, all plausible HRV. Folded over the WHOLE record, only the first
        // `minNightsSeed - 1` days are unusable. Folded over any 21-day WINDOW of it, the window's own
        // first three days are unusable — days with dozens of banked nights behind them.
        let keys = dayKeys(60)
        let values: [Double?] = Array(repeating: 72.0, count: 60)

        let whole = Baselines.foldPrefixUsable(values, dayKeys: keys, cfg: hrvCfg)
        let unusableWhole = keys.filter { whole[$0] == false }
        XCTAssertEqual(unusableWhole, Array(keys.prefix(Baselines.minNightsSeed - 1)))

        // Slide a 21-day window across the record: EVERY start position suppresses its own first days.
        for start in stride(from: 0, through: 39, by: 13) {
            let wk = Array(keys[start..<(start + 21)])
            let wv = Array(values[start..<(start + 21)])
            let windowed = Baselines.foldPrefixUsable(wv, dayKeys: wk, cfg: hrvCfg)
            XCTAssertEqual(windowed[wk[0]], false,
                           "window starting \(wk[0]) wrongly suppresses a day with \(start) nights behind it")
        }
    }

    // MARK: - The fix: the prefix is rebuilt from the persisted record

    func testSeedSequenceExtendsThePrefixWithPersistedComputedHistory() {
        // The pass scanned only the trailing 21 days; the store holds 60. The prefix must span all 60.
        let keys = dayKeys(60)
        let scanned = Array(keys.suffix(21))
        var histHrvByDay: [String: Double?] = [:]
        for d in scanned { histHrvByDay[d] = 72.0 }
        let persisted = keys.map { Fixtures.dailyMetric(day: $0, avgHrv: 70.0) }

        let seq = ScoreEngine.chargeSeedSequence(histHrvByDay: histHrvByDay, persistedComputed: persisted)
        XCTAssertEqual(seq.dayKeys, keys)
        XCTAssertEqual(seq.values.count, 60)

        let usable = Baselines.foldPrefixUsable(seq.values, dayKeys: seq.dayKeys, cfg: hrvCfg)
        // Only the first three days of the WHOLE record are unusable...
        XCTAssertEqual(keys.filter { usable[$0] == false },
                       Array(keys.prefix(Baselines.minNightsSeed - 1)))
        // ...and in particular every day the pass actually scores keeps its Charge.
        for d in scanned { XCTAssertEqual(usable[d], true, "\(d) must stay scoreable") }
    }

    func testSeedSequencePrefersFreshAndImportedValuesOverPersistedOnes() {
        // Per day, best knowledge wins: this pass's / the imported value, never an older persisted row.
        // A present-but-nil entry is knowledge ("scored, banked no HRV") and must not be overwritten.
        let keys = dayKeys(3)
        let histHrvByDay: [String: Double?] = [keys[1]: 81.0, keys[2]: Double?.none]
        let persisted = [Fixtures.dailyMetric(day: keys[0], avgHrv: 60.0),
                         Fixtures.dailyMetric(day: keys[1], avgHrv: 60.0),
                         Fixtures.dailyMetric(day: keys[2], avgHrv: 60.0)]

        let seq = ScoreEngine.chargeSeedSequence(histHrvByDay: histHrvByDay, persistedComputed: persisted)
        XCTAssertEqual(seq.dayKeys, keys)
        XCTAssertEqual(seq.values[0], 60.0)   // only the store knows this day
        XCTAssertEqual(seq.values[1], 81.0)   // fresh value wins over the persisted one
        XCTAssertNil(seq.values[2] ?? nil)    // an explicit "no HRV" is preserved, not back-filled
    }

    func testConsecutiveSlidingPassesLeaveEveryPastDayScoreable() {
        // Simulate the real failure mode end to end: 60 days of history, scored by successive passes each
        // seeing only a trailing 21-day window, with the persisted record carried forward. Every day past
        // the record's own seed prefix must stay usable on EVERY pass — including the pass where it is the
        // window's oldest key, which is its last chance to be written.
        let keys = dayKeys(60)
        let persisted = keys.map { Fixtures.dailyMetric(day: $0, avgHrv: 70.0) }

        for oldestIdx in 0...39 {
            let window = Array(keys[oldestIdx..<(oldestIdx + 21)])
            var histHrvByDay: [String: Double?] = [:]
            for d in window { histHrvByDay[d] = 72.0 }
            let seq = ScoreEngine.chargeSeedSequence(histHrvByDay: histHrvByDay, persistedComputed: persisted)
            let usable = Baselines.foldPrefixUsable(seq.values, dayKeys: seq.dayKeys, cfg: hrvCfg)
            let oldest = window[0]
            let expected = oldestIdx >= Baselines.minNightsSeed - 1
            XCTAssertEqual(usable[oldest], expected,
                           "\(oldest) as the window's oldest key on pass \(oldestIdx)")
        }
    }

    // MARK: - The write guard

    func testSeedGateStillErasesAFabricatedColdStartScore() {
        // The gate's whole purpose. A day inside the record's genuine seed prefix must write nil even
        // though a previous (pre-gate) pass persisted a number there — those are exactly the fabricated
        // scores being retracted, so the broader "never nil over a stored value" rule was rejected.
        XCTAssertNil(ScoreEngine.recoveryToPersist(scored: nil, asOfUsable: false, stored: 86.7))
    }

    func testAnUnscoreablePassNeverErasesAnAlreadyComputedScore() {
        // Baseline usable, but this pass could not score the day (a night that banked no usable HRV, a
        // partially pruned day). The stored value was legitimately computed, the user has already seen
        // it, and it cannot be re-derived once the raw is gone — carry it forward.
        XCTAssertEqual(ScoreEngine.recoveryToPersist(scored: nil, asOfUsable: true, stored: 64.2), 64.2)
        // With nothing stored there is nothing to protect.
        XCTAssertNil(ScoreEngine.recoveryToPersist(scored: nil, asOfUsable: true, stored: nil))
        // A freshly scored value always wins over the stored one.
        XCTAssertEqual(ScoreEngine.recoveryToPersist(scored: 51.0, asOfUsable: true, stored: 64.2), 51.0)
    }
}
