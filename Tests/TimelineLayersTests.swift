import XCTest
import StrapStore
@testable import whoopmaxx

/// 015 P1 — the Today timeline's two new layers say only what the day actually held.
///
/// Both failures these pin are silent. A workout band drawn from unclipped timestamps still draws a
/// band, just in the wrong place on the wrong day; HR shading normalized to the day's own maximum
/// still shades, just with a scale that changes every time the day stepper moves. Neither crashes,
/// neither renders empty, and both state something the data does not support.
///
/// So: one fixed 24-hour window, named in epoch seconds rather than borrowed from the device's
/// calendar, and every expected value below derived by hand from it.
///
/// WHAT THESE DO NOT COVER. They exercise the two pure derivations, not the screen. Nothing here
/// proves `TodayContent` hands either layer to `TimelineStrip`, that the `.task(id:)` fires, or that
/// the shading is visible in the binary — a view host would be needed for that. The compiler is what
/// enforces the wiring: `TodayContent.workouts` and `TodayContent.hrIntensity` are REQUIRED with no
/// defaults, so no call site can silently omit them.
final class TimelineLayersTests: XCTestCase {

    // MARK: - Fixture
    //
    // Midnight is a whole number of DAYS after the epoch, so it is also a whole number of 15-minute
    // buckets — bucket index i is exactly quarter-hour i of the day, by hand.

    private let dayStartTs = 20_600 * 86_400

    private var dayStart: Date { Date(timeIntervalSince1970: TimeInterval(dayStartTs)) }
    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }

    /// An instant `hour` hours into the rendered day (negative = the day before).
    private func at(_ hour: Double) -> Int { dayStartTs + Int(hour * 3600) }

    private func date(_ hour: Double) -> Date { Date(timeIntervalSince1970: TimeInterval(at(hour))) }

    private func bucket(_ hour: Double, _ bpm: Double) -> HRBucket {
        HRBucket(ts: at(hour), bpm: bpm)
    }

    /// The scale the shading tests use throughout: resting 50, HRmax 200, so the reserve is exactly
    /// 150 bpm and 125 bpm is exactly half of it.
    private let resting = 50, hrMax = 200

    private func shading(_ buckets: [HRBucket], from: Date? = nil, to: Date? = nil,
                         resting: Int? = nil, hrMax: Int? = nil) -> [Double] {
        TodayTimeline.hrIntensity(buckets, dayStart: from ?? dayStart, dayEnd: to ?? dayEnd,
                                  restingBpm: resting ?? self.resting,
                                  hrMaxBpm: hrMax ?? self.hrMax)
    }

    // MARK: - Workout spans

    /// A session that ran across midnight contributes to BOTH days, each time only the part that fell
    /// on that day. The band is a picture of one day; the rest of the session is drawn where it
    /// happened. Unclipped timestamps would put an 01:00 finish at the far left of today's strip and
    /// paint the whole of today's track for a run that ended an hour after midnight.
    func testAWorkoutIsClippedToTheDayItIsDrawnOn() {
        let crossing = Fixtures.workoutRow(startTs: at(-2), endTs: at(1),
                                           sport: "Running", source: "manual")

        let today = TodayTimeline.workoutSpans([crossing], dayStart: dayStart, dayEnd: dayEnd)
        XCTAssertEqual(today.count, 1)
        XCTAssertEqual(today.first?.start, dayStart, "the part before midnight is yesterday's")
        XCTAssertEqual(today.first?.end, date(1))

        let yesterday = TodayTimeline.workoutSpans([crossing],
                                                   dayStart: dayStart.addingTimeInterval(-86_400),
                                                   dayEnd: dayStart)
        XCTAssertEqual(yesterday.count, 1)
        XCTAssertEqual(yesterday.first?.start, date(-2))
        XCTAssertEqual(yesterday.first?.end, dayStart, "and the part after it is today's")
    }

    /// A session that misses the day draws NOTHING — no band, not a hairline at the edge. Both sides,
    /// because a filter that only guards one of them passes on the other every day.
    func testAWorkoutOnAnotherDayDrawsNoBand() {
        let yesterday = Fixtures.workoutRow(startTs: at(-5), endTs: at(-4),
                                            sport: "Lifting", source: "manual")
        let tomorrow = Fixtures.workoutRow(startTs: at(26), endTs: at(27),
                                           sport: "Lifting", source: "manual")
        // Ends exactly at midnight: it belongs to the day before, and a zero-width band on this one
        // would be a mark where nothing happened.
        let endsAtMidnight = Fixtures.workoutRow(startTs: at(-1), endTs: at(0),
                                                 sport: "Walking", source: "manual")

        XCTAssertTrue(TodayTimeline.workoutSpans([yesterday, tomorrow, endsAtMidnight],
                                                 dayStart: dayStart, dayEnd: dayEnd).isEmpty)
    }

    /// The band list is oldest-first, whichever way the cache is ordered — `WorkoutRepository.workouts`
    /// publishes NEWEST first, so an unsorted pass-through hands the strip a reversed day.
    func testSpansComeBackOldestFirstWhateverOrderTheCacheIsIn() {
        let evening = Fixtures.workoutRow(startTs: at(18), endTs: at(19),
                                          sport: "Running", source: "manual")
        let morning = Fixtures.workoutRow(startTs: at(7), endTs: at(8),
                                          sport: "Lifting", source: "manual")

        let spans = TodayTimeline.workoutSpans([evening, morning],   // newest first, as published
                                               dayStart: dayStart, dayEnd: dayEnd)
        XCTAssertEqual(spans.map { $0.start }, [date(7), date(18)])
    }

    // MARK: - HR intensity: what the 0–1 means

    /// THE JUDGMENT CALL, pinned. The scale is fraction of HR RESERVE, so the same heart rate reads
    /// the same on every day — not the day's own maximum, which would make a day whose hardest moment
    /// was a walk shade exactly like a day with an interval session in it.
    ///
    /// 125 bpm is half of the 50→200 reserve. It stays half whether the day peaked at 200, at 125, or
    /// nowhere near either.
    func testTheScaleIsHeartRateReserveNotTheDaysOwnMaximum() {
        let hardDay = shading([bucket(9, 125), bucket(18, 200)])
        let quietDay = shading([bucket(9, 125)])

        XCTAssertEqual(hardDay[36], 0.5, accuracy: 1e-9)
        XCTAssertEqual(quietDay[36], 0.5, accuracy: 1e-9,
                       "the same 125 bpm, on a day that never went higher — still half the reserve")
        XCTAssertEqual(hardDay[72], 1.0, accuracy: 1e-9)
    }

    /// Both ends are clamped: a heart rate above the profile's HRmax cannot shade past full, and one
    /// below resting cannot shade negative (which `TimelineStrip` would read as "skip this bucket").
    func testTheScaleIsClampedAtBothEnds() {
        let over = shading([bucket(12, 260)])
        XCTAssertEqual(over[48], 1.0, accuracy: 1e-9)

        let under = shading([bucket(12, 30)])
        XCTAssertEqual(under[48], TodayTimeline.measuredFloor, accuracy: 1e-12)
        XCTAssertGreaterThan(under[48], 0)
    }

    /// A bucket the strap RECORDED but that sits at resting is still a reading, and must not be drawn
    /// as the identical nothing an off-wrist hour is. The floor is what separates them.
    func testAMeasuredQuietBucketIsNotTheSameAsAnUnmeasuredOne() {
        let out = shading([bucket(3, 50)])

        XCTAssertEqual(out[12], TodayTimeline.measuredFloor, accuracy: 1e-12)
        XCTAssertGreaterThan(out[12], 0, "measured and quiet still draws")
        XCTAssertEqual(out[11], 0, "the hour beside it was never measured, and draws nothing")
        XCTAssertEqual(out.filter { $0 > 0 }.count, 1)
    }

    // MARK: - HR intensity: absence

    /// A day with no HR yields NO layer — not 96 zeros, which the strip would still lay out as a row
    /// and which reads as a measured floor. Absent stays absent (decision 1).
    func testADayWithNoHrDrawsNoShadingRatherThanARowOfZeros() {
        XCTAssertTrue(shading([]).isEmpty)
        // …including when the read came back non-empty but every bucket in it belongs to another day.
        XCTAssertTrue(shading([bucket(-6, 120), bucket(30, 120)]).isEmpty)
    }

    /// And within a day: hours the strap did not record stay at zero so the strip skips them, rather
    /// than being levelled up to the floor along with the measured ones.
    func testUnmeasuredHoursInsideAMeasuredDayStayAbsent() {
        let out = shading([bucket(0, 60), bucket(23.75, 60)])

        XCTAssertEqual(out.count, 96)
        XCTAssertEqual(out.filter { $0 > 0 }.count, 2, "two readings, 94 gaps")
    }

    /// No reserve to divide by — an HRmax override typed at or below the resting HR — means there is
    /// no scale, so there is no shading. Both directions: with a reserve the same buckets do shade,
    /// so this is a real gate and not a layer that never draws.
    func testNoReserveMeansNoLayer() {
        let buckets = [bucket(9, 120)]

        XCTAssertTrue(shading(buckets, resting: 50, hrMax: 50).isEmpty)
        XCTAssertTrue(shading(buckets, resting: 50, hrMax: 40).isEmpty)
        XCTAssertFalse(shading(buckets, resting: 50, hrMax: 51).isEmpty)
    }

    // MARK: - HR intensity: the window

    /// A bucket lands in its own quarter-hour and nowhere else, and a bucket from the next day is
    /// dropped rather than clamped onto this day's last one — the day stepper's whole point, and the
    /// 014 lesson in the screen that already had the stepper.
    func testABucketLandsInItsOwnQuarterHourAndNowhereElse() {
        let out = shading([bucket(0, 200), bucket(6, 200), bucket(23.75, 200),
                           bucket(24, 200), bucket(24.25, 200)])

        XCTAssertEqual(out.count, 96)
        XCTAssertEqual(out.indices.filter { out[$0] > 0 }, [0, 24, 95],
                       "midnight, 06:00 and 23:45 — and nothing from tomorrow piled onto slot 95")
    }

    /// The same read, rendered for the day BEFORE, shades nothing: every layer takes the selected
    /// day's window, never today's.
    func testTheLayerIsTheSelectedDaysWindowNotAnotherDays() {
        let buckets = [bucket(9, 150), bucket(18, 150)]

        XCTAssertFalse(shading(buckets).isEmpty)
        XCTAssertTrue(shading(buckets, from: dayStart.addingTimeInterval(-86_400), to: dayStart)
                        .isEmpty)
    }

    /// A bucket key that sits FRACTIONALLY before midnight still overlaps the day's first quarter-hour
    /// and lands there. `hrBuckets` floors every key to an absolute grid, so in a zone whose local
    /// midnight is not a whole number of buckets (Kathmandu, Chatham) the first key really is early —
    /// dropping it would blank the first quarter-hour of every day there. A key a whole bucket or more
    /// early is another day's and is dropped.
    func testAKeyFractionallyBeforeMidnightLandsInTheFirstBucket() {
        let straddling = HRBucket(ts: dayStartTs - 300, bpm: 200)
        let wholeBucketEarly = HRBucket(ts: dayStartTs - 900, bpm: 200)

        XCTAssertEqual(shading([straddling])[0], 1.0, accuracy: 1e-9)
        XCTAssertTrue(shading([wholeBucketEarly]).isEmpty)
    }

    /// The layer is one value per bucket of the day's REAL length, so a DST day is 23 or 25 hours of
    /// buckets rather than 24 hours of them stretched across a shorter strip.
    func testTheLayerHasOneValuePerBucketOfTheDaysRealLength() {
        let hr = [bucket(1, 120)]

        XCTAssertEqual(shading(hr).count, 96)
        XCTAssertEqual(shading(hr, to: dayStart.addingTimeInterval(23 * 3600)).count, 92)
        XCTAssertEqual(shading(hr, to: dayStart.addingTimeInterval(25 * 3600)).count, 100)
        XCTAssertEqual(TodayTimeline.hrBucketSeconds, 900, "96 buckets a day is 15 minutes each")
    }
}
