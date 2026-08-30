import XCTest
import SwiftUI
import StrapStore
@testable import whoopmaxx

/// The App-Group glance snapshot and the pure anchor/baseline inputs `WidgetSnapshot.publish` feeds it.
/// The publish function itself needs a live `AppRoot`; these cover the parts that can drift — the wire
/// format (round-trip + forward-compat) and the derivation the widget's numbers come from.
@MainActor
final class WidgetSnapshotTests: XCTestCase {

    // MARK: - Wire format

    func testRoundTripPreservesEveryField() throws {
        let snap = WidgetSnapshot(recovery: 82, bpm: 58, batteryPct: 84, bonded: true,
                                  updated: Date(timeIntervalSinceReferenceDate: 12_345),
                                  effort: 47, rest: 91, hrv: 64, restingHr: 52,
                                  chargeBaseline: 61, effortBaseline: 55, restBaseline: 74)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    /// A snapshot written by an OLDER app build (only the original headline keys) must still decode — the
    /// new optional fields fill with nil rather than throwing. Guards the "never break an installed
    /// widget on app update" invariant. `updated` uses the default deferredToDate encoding (a Double
    /// seconds-since-reference-date), so the fixture mirrors that.
    func testForwardCompatDecodeOfOlderSnapshot() throws {
        let json = """
        {"recovery":72,"bpm":58,"batteryPct":84,"bonded":true,"updated":1000}
        """
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.recovery, 72)
        XCTAssertEqual(decoded.bpm, 58)
        XCTAssertTrue(decoded.bonded)
        XCTAssertNil(decoded.effort)
        XCTAssertNil(decoded.rest)
        XCTAssertNil(decoded.hrv)
        XCTAssertNil(decoded.restingHr)
        XCTAssertNil(decoded.chargeBaseline)
        XCTAssertNil(decoded.effortBaseline)
        XCTAssertNil(decoded.restBaseline)
    }

    /// Perf2: `sameValues` compares every glance field EXCEPT `updated`, so the publish path can skip a
    /// WidgetKit reload when only the timestamp advanced but a value changing still forces one.
    func testSameValuesIgnoresOnlyTheUpdatedStamp() {
        let base = WidgetSnapshot(recovery: 82, bpm: 58, batteryPct: 84, bonded: true,
                                  updated: Date(timeIntervalSinceReferenceDate: 0),
                                  effort: 47, rest: 91, hrv: 64, restingHr: 52,
                                  chargeBaseline: 61, effortBaseline: 55, restBaseline: 74)
        var laterStampOnly = base
        laterStampOnly.updated = Date(timeIntervalSinceReferenceDate: 9_999)
        XCTAssertTrue(base.sameValues(as: laterStampOnly), "only `updated` differs → same values")

        var bpmChanged = laterStampOnly
        bpmChanged.bpm = 61
        XCTAssertFalse(base.sameValues(as: bpmChanged), "a changed value is not the same")

        var baselineChanged = laterStampOnly
        baselineChanged.restBaseline = 70
        XCTAssertFalse(base.sameValues(as: baselineChanged), "a changed baseline is not the same")
    }

    // MARK: - Anchor (the day the widget describes)

    func testAnchorUsesTodayWhenScored() {
        let days = [Fixtures.dailyMetric(day: "2026-07-14", recovery: 61),
                    Fixtures.dailyMetric(day: "2026-07-15", recovery: 80)]
        let anchor = Repository.widgetAnchor(days: days, logicalKey: "2026-07-15", localKey: "2026-07-15")
        XCTAssertEqual(anchor?.day, "2026-07-15")
        XCTAssertEqual(anchor?.recovery, 80)
    }

    /// Today present but not yet recovery-scored → carry the freshest strictly-prior scored day, so the
    /// widget never blanks at the day rollover (the #911 fix the Today screen also relies on).
    func testAnchorCarriesPriorScoredDayWhenTodayUnscored() {
        let days = [Fixtures.dailyMetric(day: "2026-07-14", recovery: 61),
                    Fixtures.dailyMetric(day: "2026-07-15", strain: 12)]
        let anchor = Repository.widgetAnchor(days: days, logicalKey: "2026-07-15", localKey: "2026-07-15")
        XCTAssertEqual(anchor?.day, "2026-07-14")
        XCTAssertEqual(anchor?.recovery, 61)
    }

    // MARK: - Baselines (the trio's tick)

    func testChargeBaselineIsTrailingMeanStrictlyBeforeAnchor() {
        let days = [Fixtures.dailyMetric(day: "2026-07-12", recovery: 50),
                    Fixtures.dailyMetric(day: "2026-07-13", recovery: 60),
                    Fixtures.dailyMetric(day: "2026-07-14", recovery: 70),
                    Fixtures.dailyMetric(day: "2026-07-15", recovery: 90)]
        // Strictly before the 15th → mean(50,60,70) = 60.
        let baseline = TodayModel.priorMean(days: days, before: "2026-07-15") { $0.recovery }
        XCTAssertEqual(baseline ?? -1, 60, accuracy: 0.0001)
    }

    func testEffortBaselineSkipsRowsMissingTheField() {
        let days = [Fixtures.dailyMetric(day: "2026-07-11", strain: 30),
                    Fixtures.dailyMetric(day: "2026-07-12", strain: 40),
                    Fixtures.dailyMetric(day: "2026-07-13", strain: 50),
                    Fixtures.dailyMetric(day: "2026-07-14"),                 // no strain — skipped
                    Fixtures.dailyMetric(day: "2026-07-15", strain: 99)]     // not "before"
        // Three rows carry strain before the 15th → mean(30,40,50) = 40. The field-less 14th is skipped
        // rather than counted as a zero, which is what this test exists for.
        let baseline = TodayModel.priorMean(days: days, before: "2026-07-15") { $0.strain }
        XCTAssertEqual(baseline ?? -1, 40, accuracy: 0.0001)
    }

    func testRestBaselineFromSeries() {
        let series = ["2026-07-11": 60.0, "2026-07-12": 70.0, "2026-07-13": 80.0, "2026-07-15": 100.0]
        // Strictly before the 15th → mean(60,70,80) = 70.
        let baseline = TodayModel.priorRestMean(restSeries: series, before: "2026-07-15")
        XCTAssertEqual(baseline ?? -1, 70, accuracy: 0.0001)
    }

    // MARK: - the minimum-sample floor

    /// ONE DAY IS NOT A TREND. On day 3 of a fresh install the Today hero drew a "30-day typical" tick
    /// and a coloured up/down verdict against a single prior night, while the Data tab — reading the same
    /// series through `MetricSeriesSet`, which already required 3 — correctly showed nothing. Two
    /// surfaces contradicting each other, with a code comment claiming they agreed.
    func testATypicalNeedsMoreThanOneOrTwoPriorDays() {
        let one = [Fixtures.dailyMetric(day: "2026-07-14", recovery: 60),
                   Fixtures.dailyMetric(day: "2026-07-15", recovery: 80)]
        XCTAssertNil(TodayModel.priorMean(days: one, before: "2026-07-15") { $0.recovery },
                     "a single prior day is not a typical")

        let two = [Fixtures.dailyMetric(day: "2026-07-13", recovery: 50),
                   Fixtures.dailyMetric(day: "2026-07-14", recovery: 60),
                   Fixtures.dailyMetric(day: "2026-07-15", recovery: 80)]
        XCTAssertNil(TodayModel.priorMean(days: two, before: "2026-07-15") { $0.recovery },
                     "two prior days is still not a typical")

        let three = [Fixtures.dailyMetric(day: "2026-07-12", recovery: 40)] + two
        XCTAssertEqual(TodayModel.priorMean(days: three, before: "2026-07-15") { $0.recovery } ?? -1,
                       50, accuracy: 0.0001, "three is the floor, matching the Data tab")
    }

    /// The Rest series uses the same floor — it is keyed independently, so it needs its own guard.
    func testTheRestTypicalUsesTheSameFloor() {
        let two = ["2026-07-13": 70.0, "2026-07-14": 80.0, "2026-07-15": 100.0]
        XCTAssertNil(TodayModel.priorRestMean(restSeries: two, before: "2026-07-15"))

        var three = two; three["2026-07-12"] = 60.0
        XCTAssertEqual(TodayModel.priorRestMean(restSeries: three, before: "2026-07-15") ?? -1,
                       70, accuracy: 0.0001)
    }

    func testBaselineNilWhenNoPriorData() {
        let days = [Fixtures.dailyMetric(day: "2026-07-15", recovery: 80)]
        XCTAssertNil(TodayModel.priorMean(days: days, before: "2026-07-15") { $0.recovery })
        XCTAssertNil(TodayModel.priorRestMean(restSeries: [:], before: "2026-07-15"))
    }

    // MARK: - WidgetDayResolver (the publish carry rules, mirroring the Today screen)

    /// Local noon → the logical day equals the local day (hour ≥ 4 rollover), so `now`-derived keys are
    /// deterministic regardless of the machine's calendar date or zone.
    private func noon() -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    /// The regression: today not yet scored → Charge carries yesterday, but Effort must NOT carry
    /// yesterday's full-day strain (showing it as today's Effort would lie).
    func testEffortNeverCarriesWhenTodayUnscored() {
        let now = noon()
        let today = Repository.localDayKey(now)
        let yst = TodayModel.shiftKey(today, by: -1)!
        let f = WidgetDayResolver.fields(days: [Fixtures.dailyMetric(day: yst, recovery: 60, strain: 68)],
                                         restSeries: [:], now: now)
        XCTAssertEqual(f.charge, 60)   // Charge legitimately carries
        XCTAssertNil(f.effort)         // Effort must not surface yesterday's 68
    }

    /// Today present but only strain-scored so far → Effort is today's own strain, never yesterday's.
    func testEffortUsesTodaysOwnStrain() {
        let now = noon()
        let today = Repository.localDayKey(now)
        let yst = TodayModel.shiftKey(today, by: -1)!
        let days = [Fixtures.dailyMetric(day: yst, recovery: 60, strain: 68),
                    Fixtures.dailyMetric(day: today, strain: 5)]
        let f = WidgetDayResolver.fields(days: days, restSeries: [:], now: now)
        XCTAssertEqual(f.charge, 60)   // carried (today recovery nil)
        XCTAssertEqual(f.effort, 5)    // today's own strain, not 68
    }

    /// Rest borrow respects TodayModel.carriedRest's 2-day freshness cap — a stale score never pins as
    /// today's, but a 1-day-old one carries.
    func testRestBorrowRespectsFreshnessCap() {
        let now = noon()
        let today = Repository.localDayKey(now)
        let scored = Fixtures.dailyMetric(day: today, recovery: 55)
        let stale = TodayModel.shiftKey(today, by: -5)!
        let fresh = TodayModel.shiftKey(today, by: -1)!
        XCTAssertNil(WidgetDayResolver.fields(days: [scored], restSeries: [stale: 88], now: now).rest)
        XCTAssertEqual(WidgetDayResolver.fields(days: [scored], restSeries: [fresh: 90], now: now).rest, 90)
    }

    func testRestUsesTodaysOwnWhenPresent() {
        let now = noon()
        let today = Repository.localDayKey(now)
        let f = WidgetDayResolver.fields(days: [Fixtures.dailyMetric(day: today, recovery: 55)],
                                         restSeries: [today: 77], now: now)
        XCTAssertEqual(f.rest, 77)
    }

    /// A carried Charge's baseline is computed strictly before its SOURCE day, not before today — so the
    /// carried value never sits inside its own mean and the widget never fabricates an "at typical" tick
    /// (mirrors TodayScreen.chargeBaselineKey; the W6 bug used before:todayKey).
    func testCarriedChargeBaselineExcludesTheCarriedValue() {
        let now = noon()
        let today = Repository.localDayKey(now)
        let yst = TodayModel.shiftKey(today, by: -1)!
        // Only yesterday scored; today absent → Charge carries 80, baseline before yesterday = nil (no tick).
        let f = WidgetDayResolver.fields(days: [Fixtures.dailyMetric(day: yst, recovery: 80)],
                                         restSeries: [:], now: now)
        XCTAssertEqual(f.charge, 80)
        XCTAssertNil(f.chargeBaseline)   // must NOT be 80 (the fabricated-at-typical bug)
    }

    /// Same for Rest: a carried Rest score is not included in its own baseline mean.
    func testCarriedRestBaselineExcludesTheCarriedValue() {
        let now = noon()
        let today = Repository.localDayKey(now)
        let yst = TodayModel.shiftKey(today, by: -1)!
        // Today scored (for anchor) but no Rest today; yesterday's Rest carries → baseline before it = nil.
        let f = WidgetDayResolver.fields(days: [Fixtures.dailyMetric(day: today, recovery: 55)],
                                         restSeries: [yst: 90], now: now)
        XCTAssertEqual(f.rest, 90)
        XCTAssertNil(f.restBaseline)
    }

    func testBaselinesAreTrailingMeansBeforeToday() {
        let now = noon()
        let today = Repository.localDayKey(now)
        let d = { (n: Int) in TodayModel.shiftKey(today, by: n)! }
        let days = [Fixtures.dailyMetric(day: d(-3), recovery: 50),
                    Fixtures.dailyMetric(day: d(-2), recovery: 60),
                    Fixtures.dailyMetric(day: d(-1), recovery: 70),
                    Fixtures.dailyMetric(day: today, recovery: 90)]
        let f = WidgetDayResolver.fields(days: days, restSeries: [:], now: now)
        XCTAssertEqual(f.charge, 90)          // today scored
        XCTAssertEqual(f.chargeBaseline, 60)  // mean(50,60,70)
    }

    // MARK: - Appearance mirror (the widget/Live-Activity scheme forcing, WMAppearance)

    /// The raw-pref → forced-scheme mapping the extension applies. "system", an unknown value, and a
    /// missing key (a pre-mirror install) must all degrade to nil — follow the system, never crash.
    func testAppearanceSchemeMapping() {
        XCTAssertEqual(WMAppearance.scheme(for: "light"), .light)
        XCTAssertEqual(WMAppearance.scheme(for: "dark"), .dark)
        XCTAssertNil(WMAppearance.scheme(for: "system"))
        XCTAssertNil(WMAppearance.scheme(for: nil))
        XCTAssertNil(WMAppearance.scheme(for: "sepia"))
    }
}
