import XCTest
@testable import whoopmaxx

/// In the zones whose DST springs forward AT midnight, local 00:00 does not exist on the transition
/// date, so a non-lenient `yyyy-MM-dd` parse returned nil for a key `DayKey.local(_:)` itself produced.
/// Every app-layer day-key parse funnels through `DayKey.date(from:)`, so that nil took out the whole
/// day: both score carries blanked (Today, widget, Live Activity), the day-browser chevron became a
/// no-op, and habit history read empty.
///
/// These tests drive the parse through EXPLICITLY zoned formatters rather than by overriding the process
/// zone. `DayKey.formatter` is a shared `static let` that resolves its zone once, so a mid-suite
/// `NSTimeZone.default` override does not reliably reach it — a test written that way passes or fails on
/// suite ordering. The zone-independent properties of `DayKey.date(from:)` are asserted directly.
final class DstDayKeyTests: XCTestCase {

    /// One real transition per zone. Each is a date on which local midnight genuinely does not exist —
    /// asserted below rather than assumed, so a tzdata change turns into a clear failure.
    private static let skipCases: [(zone: String, key: String)] = [
        ("America/Havana", "2026-03-08"),
        ("America/Santiago", "2026-09-06"),
        ("Africa/Cairo", "2026-04-24"),
        ("Asia/Beirut", "2026-03-29"),
    ]

    private func midnightFormatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        return f
    }

    private func hourFormatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        return f
    }

    /// The premise: these really are dates whose local midnight does not exist, so a strict parse of the
    /// bare day key fails. If this ever stops holding, the fix below is guarding nothing.
    func testTheseZonesReallySkipMidnight() throws {
        for c in Self.skipCases {
            let zone = try XCTUnwrap(TimeZone(identifier: c.zone), "tzdata is missing \(c.zone)")
            XCTAssertNil(midnightFormatter(zone).date(from: c.key),
                         "\(c.zone) \(c.key): expected local midnight to be skipped")
        }
    }

    /// The fix's mechanism: noon always exists, and snapping it back with the SAME zone lands on the
    /// day's real first instant — still the same civil day.
    func testNoonParsesAndSnapsBackToTheSameCivilDay() throws {
        for c in Self.skipCases {
            let zone = try XCTUnwrap(TimeZone(identifier: c.zone))
            let noon = try XCTUnwrap(hourFormatter(zone).date(from: c.key + " 12"),
                                     "\(c.zone) \(c.key): noon must always exist")
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let start = cal.startOfDay(for: noon)
            XCTAssertEqual(midnightFormatter(zone).string(from: start), c.key,
                           "\(c.zone): the snapped instant must still be that civil day")
            // …and it is NOT midnight, which is the whole reason the strict parse failed.
            let hour = cal.component(.hour, from: start)
            XCTAssertNotEqual(hour, 0, "\(c.zone): the day's first instant is past midnight here")
        }
    }

    // MARK: - Zone-independent contract of DayKey.date(from:)

    /// Ordinary keys parse and round-trip in whatever zone the shared formatter resolved.
    func testOrdinaryKeysRoundTrip() throws {
        for key in ["2026-01-15", "2026-03-08", "2026-06-30", "2026-09-06", "2026-12-31"] {
            let d = try XCTUnwrap(DayKey.date(from: key), "\(key) must parse")
            XCTAssertEqual(DayKey.local(d), key, "\(key) must round-trip")
        }
    }

    /// The carry age-gate — `daysBetween` is nil-guarded on both parses and is the gate inside both
    /// `carriedChargeRow` and `carriedRest`, so a nil there blanks Charge and Rest everywhere.
    func testDaysBetweenSpansTheKnownTransitionDates() {
        XCTAssertEqual(TodayModel.daysBetween("2026-09-05", "2026-09-07"), 2)
        XCTAssertEqual(TodayModel.daysBetween("2026-03-07", "2026-03-09"), 2)
        XCTAssertEqual(TodayModel.daysBetween("2026-04-23", "2026-04-25"), 2)
        XCTAssertEqual(TodayModel.daysBetween("2026-09-06", "2026-09-06"), 0)
    }

    /// Spans that START on a transition date. This is where the first cut of the fix was wrong: the
    /// fallback returns the day's real first instant (01:00 in these zones), and differencing that
    /// against a 00:00 anchor truncated a day off every forward span — which at the carry gate would
    /// have let a stale Charge/Rest be presented as today's for an extra day.
    func testDaysBetweenIsExactWhenTheSpanStartsOnATransitionDate() throws {
        for c in Self.skipCases {
            let zone = try XCTUnwrap(TimeZone(identifier: c.zone))
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let fmt = midnightFormatter(zone)
            let hourFmt = hourFormatter(zone)

            // Reproduce DayKey's fallback in this zone, then count days the way daysBetween does.
            let startNoon = try XCTUnwrap(hourFmt.date(from: c.key + " 12"))
            let start = cal.startOfDay(for: startNoon)
            for offset in 1...4 {
                let laterDay = try XCTUnwrap(cal.date(byAdding: .day, value: offset, to: start))
                let laterKey = fmt.string(from: laterDay)
                let laterNoon = try XCTUnwrap(hourFmt.date(from: laterKey + " 12"))
                let later = cal.startOfDay(for: laterNoon)

                // Mirrors `TodayModel.daysBetween`'s calendar-day counting in this zone.
                let da = try XCTUnwrap(cal.ordinality(of: .day, in: .era, for: start))
                let db = try XCTUnwrap(cal.ordinality(of: .day, in: .era, for: later))
                XCTAssertEqual(db - da, offset,
                               "\(c.zone): \(c.key) → \(laterKey) must be \(offset) days")

                // The naive elapsed-time count is what was wrong — pin that it really does differ here,
                // so this test cannot silently stop covering the defect.
                let naive = cal.dateComponents([.day], from: start, to: later).day
                if offset == 1 {
                    XCTAssertEqual(naive, 0, "\(c.zone): the first day after a skip date is only 23 h")
                }
            }
        }
    }

    /// The day-browser chevron: `shiftKey` must move off every transition date in both directions.
    func testShiftKeyMovesOffTheTransitionDates() {
        XCTAssertEqual(TodayModel.shiftKey("2026-09-06", by: -1), "2026-09-05")
        XCTAssertEqual(TodayModel.shiftKey("2026-09-06", by: 1), "2026-09-07")
        XCTAssertEqual(TodayModel.shiftKey("2026-03-08", by: -1), "2026-03-07")
        XCTAssertEqual(TodayModel.shiftKey("2026-04-24", by: 1), "2026-04-25")
    }

    /// Junk must STILL be nil — the fallback only engages after a strict y/m/d parse of the appended
    /// hour, and lenient parsing is deliberately left off.
    func testMalformedKeysStillReturnNil() {
        XCTAssertNil(DayKey.date(from: "garbage"))
        XCTAssertNil(DayKey.date(from: "2026-13-01"))
        XCTAssertNil(DayKey.date(from: ""))
        XCTAssertNil(DayKey.date(from: "2026-03"))
        XCTAssertNil(DayKey.date(from: "not-a-day"))
        XCTAssertNil(TodayModel.daysBetween("garbage", "2026-03-08"))
    }
}
