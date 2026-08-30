import XCTest
import StrapAnalytics
import StrapStore
@testable import whoopmaxx

/// "Nothing yet" must never render as a measurement.
///
/// On a fresh install the app had three ways of inventing data: the widget fell back to the GALLERY
/// sample (Charge 82, 58 bpm, 84 % battery, green bonded dot) whenever the App Group was empty; an
/// unknown strap battery drew a half-full glyph; and a Charge column that the engine had deliberately
/// suppressed rendered a bare em-dash with no caption, byte-identical to a broken engine.
final class ColdStartHonestyTests: XCTestCase {

    /// The gallery sample is still invented on purpose — the user is picking a widget, not reading health.
    func testTheGallerySampleStillCarriesSampleNumbers() {
        XCTAssertNotNil(WidgetSnapshot.placeholder.recovery)
        XCTAssertFalse(WidgetSnapshot.placeholder.isEmpty)
    }

    /// THE REGRESSION. A never-published snapshot carries no measurement and knows it.
    func testTheEmptySnapshotCarriesNoMeasurement() {
        let e = WidgetSnapshot.empty
        XCTAssertTrue(e.isEmpty)
        XCTAssertNil(e.recovery); XCTAssertNil(e.effort); XCTAssertNil(e.rest)
        XCTAssertNil(e.bpm); XCTAssertNil(e.hrv); XCTAssertNil(e.restingHr)
        XCTAssertNil(e.batteryPct)
        XCTAssertFalse(e.bonded, "a phone that has never seen the strap must not show a bonded dot")
    }

    /// A real published snapshot is never mistaken for empty — otherwise the widget would caption a
    /// genuine reading "not set up".
    func testARealSnapshotIsNotEmpty() {
        let real = WidgetSnapshot(recovery: 61, bpm: nil, batteryPct: nil, bonded: false,
                                  updated: Date(), effort: nil, rest: nil, hrv: nil, restingHr: nil,
                                  chargeBaseline: nil, effortBaseline: nil, restBaseline: nil)
        XCTAssertFalse(real.isEmpty, "one real score is enough to be a real snapshot")
    }

    /// A nil score captions itself rather than rendering a bare em-dash.
    func testANilScoreEntryIsMarkedCalibrating() {
        let e = ScoreTrio.Entry(score: nil, baseline: nil, calibratingNote: nil)
        XCTAssertNil(e.score)
        XCTAssertNil(e.calibratingNote, "no progress detail supplied → the view falls back to 'calibrating'")

        let withNote = ScoreTrio.Entry(score: nil, baseline: nil, calibratingNote: "2 of 4 nights")
        XCTAssertEqual(withNote.calibratingNote, "2 of 4 nights")
    }

    /// The note SHARPENS "calibrating"; it must never replace it.
    ///
    /// The first cut rendered `calibratingNote ?? "calibrating"`, so supplying progress DELETED the
    /// word — day 0 read "0 of 4 nights" under a blank numeral, beside Effort and Rest both saying
    /// "calibrating". A bare fraction with nothing on screen naming what it counts parses as something
    /// Charge measured, which is the opposite of what this caption exists to prevent. The two
    /// assertions above pin the FIELD, and stayed green through all of that; these pin what renders.
    func testTheProgressNoteSharpensTheWordRatherThanReplacingIt() {
        let bare = ScoreTrio.Entry(score: nil, baseline: nil, calibratingNote: nil)
        XCTAssertEqual(bare.calibratingCaption, "calibrating",
                       "nothing to report is still an explanation")

        let withNote = ScoreTrio.Entry(score: nil, baseline: nil, calibratingNote: "2 of 4 nights")
        XCTAssertEqual(withNote.calibratingCaption, "calibrating \u{00B7} 2 of 4 nights")
        XCTAssertTrue(withNote.calibratingCaption.hasPrefix("calibrating"),
                      "a blank column must say WHY it is blank before it says how far along it is")
    }

    /// A carried score is a different state from calibrating and keeps its own caption.
    func testACarriedScoreIsNotCalibrating() {
        let e = ScoreTrio.Entry(score: 61, baseline: 55, carriedFrom: "Mon", calibratingNote: nil)
        XCTAssertNotNil(e.score)
        XCTAssertEqual(e.carriedFrom, "Mon")
    }

    // MARK: - The note now has a supplier (015 P2)

    /// Consecutive day keys from 2026-06-01, oldest first.
    private func dayKeys(_ n: Int) -> [String] {
        (1...n).map { String(format: "2026-06-%02d", $0) }
    }

    /// The note answers the day-stepper's question, and its numerator is the seed gate's own count.
    func testTheNoteCountsTheNightsTheSeedGateCounts() {
        let keys = dayKeys(2)
        let days = keys.map { Fixtures.dailyMetric(day: $0, avgHrv: 70.0) }
        XCTAssertEqual(TodayCalibration.note(days: days, through: keys[1], loaded: true, offsetSec: 0),
                       "2 of \(Baselines.minNightsSeed) nights",
                       "the denominator is the gate's constant, never a literal 4")
    }

    /// THE decision-2 test. A physiologically impossible night is `skip-and-hold` inside
    /// `Baselines.update` — it does not advance `nValid` — so a caption derived from a plain
    /// "has an avgHrv" count would claim a night the suppressed score does not have.
    func testAnImplausibleNightDoesNotAdvanceTheNote() {
        let keys = dayKeys(3)
        let days = [Fixtures.dailyMetric(day: keys[0], avgHrv: 70.0),
                    Fixtures.dailyMetric(day: keys[1], avgHrv: 300.0),   // outside hrvCfg's 5…250
                    Fixtures.dailyMetric(day: keys[2], avgHrv: 72.0)]
        XCTAssertEqual(TodayCalibration.note(days: days, through: keys[2], loaded: true, offsetSec: 0),
                       "2 of \(Baselines.minNightsSeed) nights",
                       "three rows carry HRV; only two of them are nights the baseline folded")
    }

    /// Both directions of the boundary: one night short of the seed still reports progress, and the
    /// night that crosses it reports nothing — the score is there to speak for itself.
    func testTheNoteStopsExactlyAtTheSeedThreshold() {
        let hrv: [Double] = [70, 71, 69, 72]
        let keys = dayKeys(hrv.count)
        let days = zip(keys, hrv).map { Fixtures.dailyMetric(day: $0.0, avgHrv: $0.1) }

        let short = Array(days.prefix(Baselines.minNightsSeed - 1))
        XCTAssertEqual(TodayCalibration.note(days: short, through: keys.last!, loaded: true, offsetSec: 0),
                       "\(Baselines.minNightsSeed - 1) of \(Baselines.minNightsSeed) nights")
        XCTAssertNil(TodayCalibration.note(days: days, through: keys.last!, loaded: true, offsetSec: 0),
                     "a seeded baseline scores, and a scored column captions itself")
    }

    /// A seeded baseline gone STALE is un-usable too. Gating the note on `usable` rather than on the
    /// seed count would caption a returning wearer's blank column "4 of 4 nights".
    func testAStaleButSeededBaselineCaptionsNoProgress() {
        var days = zip(dayKeys(4), [70.0, 71.0, 69.0, 72.0]).map {
            Fixtures.dailyMetric(day: $0.0, avgHrv: $0.1)
        }
        // Fifteen banked days with no HRV — one more than `Baselines.staleDays`.
        days += (5...19).map { Fixtures.dailyMetric(day: String(format: "2026-06-%02d", $0)) }

        let state = Baselines.foldHistory(days.map { $0.avgHrv }, dayKeys: days.map { $0.day },
                                          cfg: Baselines.hrvCfg)
        XCTAssertFalse(state.usable, "the fixture really is the stale case")
        XCTAssertEqual(state.nValid, Baselines.minNightsSeed)
        XCTAssertNil(TodayCalibration.note(days: days, through: days.last!.day, loaded: true, offsetSec: 0))
    }

    /// The note follows the BROWSED day, not today (the 014 lesson): stepping back to the second
    /// night reports what that night had behind it, not what tonight has.
    func testTheNoteIsAsOfTheDayOnScreen() {
        let keys = dayKeys(5)
        let days = keys.map { Fixtures.dailyMetric(day: $0, avgHrv: 70.0) }
        XCTAssertEqual(TodayCalibration.note(days: days, through: keys[1], loaded: true, offsetSec: 0),
                       "2 of \(Baselines.minNightsSeed) nights")
        XCTAssertNil(TodayCalibration.note(days: days, through: keys[4], loaded: true, offsetSec: 0))
    }

    /// "Not read yet" is not "zero nights". Before the first refresh lands `days` is empty for a
    /// reason the caption cannot see, so it says nothing; once loaded, an empty record genuinely is
    /// zero banked nights and says so.
    func testAnUnreadCacheIsNotCaptionedAsZeroNights() {
        XCTAssertNil(TodayCalibration.note(days: [], through: "2026-06-01", loaded: false, offsetSec: 0))
        XCTAssertEqual(TodayCalibration.note(days: [], through: "2026-06-01", loaded: true, offsetSec: 0),
                       "0 of \(Baselines.minNightsSeed) nights")
    }
}
