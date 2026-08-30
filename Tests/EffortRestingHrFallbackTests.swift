import XCTest
import StrapAnalytics
import StrapProtocol      // HRSample — StrapAnalytics uses it in analyzeDay's signature but does not re-export it
import StrapStore
@testable import whoopmaxx

/// Effort's personal resting-HR fallback, at the ORCHESTRATION seam — the seam the previous attempt
/// never crossed, which is why it shipped inert.
///
/// `DayEngine.analyzeDay` reaches for a resting HR when the day banked no sleep session (exactly a
/// day with a capture hole). It used to reach for `baselines.restingHR`, and the package-level test
/// injected a synthetic USABLE baseline straight into `analyzeDay` — so it proved the arithmetic and
/// could never see that the PRODUCTION caller hands it an unusable one.
///
/// What the production caller actually hands it: `strain` is produced in ScoreEngine's PASS 1 against
/// `baselines1`, folded over `store.dailyMetrics(deviceId: "my-whoop")` — the IMPORTED lane. On the real
/// 422 MB backup that lane has ZERO rows (`SELECT deviceId, COUNT(*) FROM dailyMetric` returns only
/// `my-whoop-computed|18`), so the fold is `foldHistory([])`: nValid 0, `.calibrating`, `usable == false`,
/// baseline 75.0 (the config's (30+120)/2 midpoint SEED). The `usable` guard therefore dropped straight
/// through to the generic 60 bpm on every single day of a strap-only user's record.
///
/// Measured consequence on the real 2026-07-15 (a 753-min capture hole, no sleep session): Effort 27.01
/// at 60 bpm against 37.44 at this user's real 46.15. So on precisely the days where data is missing,
/// Effort was ALSO scored against a stranger's physiology.
final class EffortRestingHrFallbackTests: XCTestCase {

    private func daily(_ day: String, rhr: Int?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: nil, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    /// `n` consecutive day keys ending 2026-07-26, oldest first.
    private func dayKeys(_ n: Int) -> [String] {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        let end = fmt.date(from: "2026-07-26")!
        return (0..<n).map { fmt.string(from: end.addingTimeInterval(-Double(n - 1 - $0) * 86_400)) }
    }

    // MARK: - The defect

    /// THE DEFECT, stated as the thing that used to be read. Pass 1's imported-only fold is not usable
    /// for a strap-only user, so nothing personal could ever come out of it.
    func testImportedOnlyFoldIsUnusableForAStrapOnlyUser() {
        let importedLane: [DailyMetric] = []          // the real store's `my-whoop` lane
        let fold = Baselines.foldHistory(importedLane.map { $0.restingHr.map(Double.init) },
                                         dayKeys: importedLane.map { $0.day },
                                         cfg: Baselines.metricCfg["resting_hr"]!)
        XCTAssertEqual(fold.nValid, 0)
        XCTAssertEqual(fold.status, .calibrating)
        XCTAssertFalse(fold.usable)
        XCTAssertEqual(fold.baseline, 75.0, accuracy: 1e-9,
                       "and its 'baseline' is the config midpoint SEED, not a measurement")
    }

    // MARK: - The fix

    /// A strap-only fixture: zero imported rows, a real computed lane. The engine must hand `analyzeDay`
    /// a USABLE personal number, not nil and not the seed.
    func testStrapOnlyUserGetsAUsablePersonalFallbackFromTheComputedLane() throws {
        let keys = dayKeys(17)
        // This user's real nightly resting HR over the backup window.
        let rhr = [44, 49, 50, 52, 45, 44, 44, 44, 49, 49, 46, 46, 46, 47, 45, 48, 51]
        let computed = zip(keys, rhr).map { daily($0.0, rhr: $0.1) }

        let fallback = try XCTUnwrap(
            ScoreEngine.restingHRFallback(hist: [], persistedComputed: computed,
                                          recoveryEpoch: 0, offsetSec: -4 * 3_600),
            "a strap-only user with 17 banked nights must get a personal resting HR")
        XCTAssertEqual(fallback, 46.15, accuracy: 0.05,
                       "the measured fold over the real nightly RHR sequence")
        XCTAssertLessThan(fallback, StrainScorer.defaultRestingHR,
                          "…and it is materially below the generic 60 bpm this user was scored against")
    }

    /// The number actually moves Effort, and moves it the right way, through the same `analyzeDay` the
    /// engine calls. 140 bpm straddles an Edwards zone boundary between rhr 60 and rhr 46.
    func testTheFallbackReachesStrainThroughAnalyzeDay() throws {
        let keys = dayKeys(17)
        let rhr = [44, 49, 50, 52, 45, 44, 44, 44, 49, 49, 46, 46, 46, 47, 45, 48, 51]
        let fallback = ScoreEngine.restingHRFallback(hist: [],
                                                     persistedComputed: zip(keys, rhr).map { daily($0.0, rhr: $0.1) },
                                                     recoveryEpoch: 0, offsetSec: -4 * 3_600)
        let profile = UserProfile(weightKg: 87, heightCm: 182, age: 19, sex: "male")
        let dayStart = 1_800_000_000 - (1_800_000_000 % 86_400) + 12 * 3_600
        let samples = (0..<7_200).map { HRSample(ts: dayStart + $0, bpm: 140) }

        let withFallback = DayEngine.analyzeDay(day: "2026-07-15", hr: samples, dayHr: samples,
                                                      profile: profile, restingHRFallbackBpm: fallback)
        let generic = DayEngine.analyzeDay(day: "2026-07-15", hr: samples, dayHr: samples,
                                                 profile: profile)
        XCTAssertGreaterThan(try XCTUnwrap(withFallback.strain), try XCTUnwrap(generic.strain))
    }

    // MARK: - The guards

    /// A first-ever pass — nothing imported, nothing persisted — must fall to the generic default, not to
    /// the fold's 75.0 midpoint seed. 75 bpm NARROWS the reserve and scores the day LOWER than 60
    /// (measured on the real 2026-07-15: 17.93 vs 27.01), so returning it would be worse than returning
    /// nothing.
    func testColdStartReturnsNilRatherThanTheMidpointSeed() {
        XCTAssertNil(ScoreEngine.restingHRFallback(hist: [], persistedComputed: [],
                                                    recoveryEpoch: 0, offsetSec: 0))
        // …and below the seed count too.
        let keys = dayKeys(3)
        let short = keys.map { daily($0, rhr: 46) }
        XCTAssertNil(ScoreEngine.restingHRFallback(hist: [], persistedComputed: short,
                                                    recoveryEpoch: 0, offsetSec: 0),
                     "under Baselines.minNightsSeed the fold is not usable")
    }

    /// Imported rows win per day (the same precedence `chargeSeedSequence` uses for avgHrv), and a
    /// present-but-nil imported value is knowledge — "this day was scored and banked no resting HR" — not
    /// an invitation to fall back to the computed row.
    func testImportedWinsPerDayAndPresentNilIsHonoured() throws {
        let keys = dayKeys(10)
        let computed = keys.map { daily($0, rhr: 60) }
        // Imported disagrees on every day with a much lower value.
        let imported = keys.map { daily($0, rhr: 45) }
        let merged = try XCTUnwrap(ScoreEngine.restingHRFallback(hist: imported, persistedComputed: computed,
                                                                 recoveryEpoch: 0, offsetSec: 0))
        XCTAssertEqual(merged, 45.0, accuracy: 1.0, "imported must win per day")

        // Imported present-but-nil on half the days: those days are skip-and-hold, NOT filled from the
        // computed lane.
        let half = keys.enumerated().map { daily($0.element, rhr: $0.offset % 2 == 0 ? nil : 45) }
        let withNils = try XCTUnwrap(ScoreEngine.restingHRFallback(hist: half, persistedComputed: computed,
                                                                    recoveryEpoch: 0, offsetSec: 0))
        XCTAssertEqual(withNils, 45.0, accuracy: 1.0,
                       "a present-but-nil imported day must not be back-filled with the computed 60")
    }

    /// The recalibration epoch is honoured exactly as the Charge folds honour it: nights before the
    /// epoch are dropped (not skip-and-held), so a reset restarts the ~4-night build-up and the fallback
    /// correctly reports "not yet" instead of the pre-reset number.
    func testRecalibrationEpochDropsPreEpochNights() {
        let keys = dayKeys(17)
        let computed = keys.map { daily($0, rhr: 46) }
        var comps = DateComponents(); comps.year = 2026; comps.month = 7; comps.day = 25
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let epoch = cal.date(from: comps)!.timeIntervalSince1970
        XCTAssertNil(ScoreEngine.restingHRFallback(hist: [], persistedComputed: computed,
                                                    recoveryEpoch: epoch, offsetSec: 0),
                     "only 2 nights survive the epoch — under the seed, so no fallback")
    }
}
