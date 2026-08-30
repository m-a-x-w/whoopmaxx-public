import XCTest
@testable import whoopmaxx

/// The SPOKEN half of the read-side App Intent (032): `GlanceAnswer.sentence` and the provenance
/// resolution behind it (`GlanceCarry.source`).
///
/// WHY THIS SUITE EXISTS. `GlanceReadingIntent` is reachable by voice, from a locked phone, with the
/// app closed — the surface in this codebase with the widest reach and the least supervision. Every
/// other surface renders an absent value as blank space, and blank space cannot be misheard; a
/// sentence has to SAY the absence, and there is no compiler check that it does. The whole answer was
/// deliberately written as a pure `(reading, snapshot, carry, now) -> String` so these rules could be
/// pinned without an intent host, a strap or a clock, and until now nothing pinned them.
///
/// Each test below stands for one way the answer could assert something the app never measured:
/// speaking a zero for a nil, speaking a stale number as if it were this morning's, or speaking a
/// carried score as the answered day's own.
final class GlanceAnswerTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed midday `now`, built through `Calendar.current` so the day arithmetic under test
    /// (`Calendar.ordinality(of: .day, in: .era)`) measures against the same calendar the fixture was
    /// built in. Midday on purpose: a stamp near midnight plus a DST transition is the one case where
    /// "three days ago" and "72 hours ago" disagree, and that is the divide the implementation
    /// deliberately avoids — it is not what these tests are trying to exercise.
    private static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 17; c.hour = 14; c.minute = 30
        return Calendar.current.date(from: c)!
    }()

    /// `now` shifted back by whole CALENDAR days — the same unit the stamp widening counts in.
    private func daysAgo(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: Self.now)!
    }

    /// A published glance carrying every value. `updated` defaults to today so a test that is not
    /// about staleness does not accidentally exercise the widening branches.
    private func snapshot(charge: Int? = 62, effort: Int? = 41, rest: Int? = 88,
                          bpm: Int? = 57, battery: Int? = 76,
                          updated: Date? = nil) -> WidgetSnapshot {
        WidgetSnapshot(recovery: charge, bpm: bpm, batteryPct: battery, bonded: true,
                       updated: updated ?? Self.now, effort: effort, rest: rest,
                       hrv: 61, restingHr: 50)
    }

    /// A provenance record that MATCHES a snapshot — the only state in which the answer is entitled
    /// to make a claim about which day a score came from.
    private func carry(for snap: WidgetSnapshot,
                       charge: String? = nil, rest: String? = nil) -> GlanceCarry {
        GlanceCarry(updated: snap.updated, chargeCarriedFrom: charge, restCarriedFrom: rest)
    }

    private func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    // MARK: - Absent snapshot

    /// NOTHING PUBLISHED is its own answer, distinct from "published, but this reading is empty".
    /// Every reading has to give it, or one of the five would invent a value for an install that has
    /// never run the app.
    func testAbsentSnapshotSaysNotPublishedForEveryReading() {
        for reading in GlanceReading.allCases {
            let line = GlanceAnswer.sentence(reading: reading, snapshot: nil,
                                             carry: nil, now: Self.now)
            XCTAssertEqual(line, GlanceAnswer.notPublished,
                           "\(reading) invented an answer for an unpublished App Group")
            XCTAssertFalse(line.contains("as of"),
                           "\(reading) stamped a time onto a snapshot that does not exist")
        }
    }

    /// An App Group holding a snapshot with no measurement in it is the SAME state to a listener —
    /// the app has not produced a reading. Reusing the snapshot's own `isEmpty` keeps this answer and
    /// the widget's "Open whoopmaxx to set up" from disagreeing about whether an install is set up.
    func testEmptyPublishedSnapshotAlsoSaysNotPublished() {
        let blank = WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false,
                                   updated: Self.now)
        XCTAssertTrue(blank.isEmpty, "fixture no longer models a never-published snapshot")
        XCTAssertEqual(GlanceAnswer.sentence(reading: .charge, snapshot: blank,
                                             carry: nil, now: Self.now),
                       GlanceAnswer.notPublished)
    }

    // MARK: - Absence within a published snapshot

    /// nil is NOT RECORDED and must be spoken as absence. The failure this guards is a sentence like
    /// "Charge 0" or "Charge —": a zero the strap never measured, or a dash that a listener hears as
    /// a reading. The snapshot here is non-empty (it still carries a heart rate), so the answer
    /// cannot fall back to the never-published line.
    func testAbsentScoreIsSpokenAsAbsenceNotZero() {
        let snap = snapshot(charge: nil, effort: nil, rest: nil)
        for (reading, label) in [(GlanceReading.charge, "Charge"),
                                 (.effort, "Effort"), (.rest, "Rest")] {
            let line = GlanceAnswer.sentence(reading: reading, snapshot: snap,
                                             carry: carry(for: snap), now: Self.now)
            XCTAssertTrue(line.hasPrefix("\(label) not recorded yet,"), line)
            XCTAssertFalse(line.contains("\(label) 0"), "spoke a fabricated zero: \(line)")
            XCTAssertFalse(line.contains("\u{2014}"), "spoke an em dash as a value: \(line)")
            // Still stamped: "not recorded yet" is a statement about a specific publish, and without
            // the stamp it would sound permanent rather than as-of.
            XCTAssertTrue(line.contains("as of"), line)
        }
    }

    /// The two non-score readings take the same rule through a different code path (`plain`), so they
    /// are pinned separately — a unit suffix is exactly the kind of thing that invites a "0 bpm".
    func testAbsentHeartRateAndBatteryAreSpokenAsAbsence() {
        let snap = snapshot(bpm: nil, battery: nil)
        let hr = GlanceAnswer.sentence(reading: .heartRate, snapshot: snap, carry: nil, now: Self.now)
        XCTAssertTrue(hr.hasPrefix("Heart rate not recorded yet,"), hr)
        XCTAssertFalse(hr.contains("0 bpm"), hr)
        let batt = GlanceAnswer.sentence(reading: .battery, snapshot: snap, carry: nil, now: Self.now)
        XCTAssertTrue(batt.hasPrefix("Strap battery not recorded yet,"), batt)
        XCTAssertFalse(batt.contains("0%"), batt)
    }

    /// `bonded` is deliberately never spoken: it is true for a 5/MG streaming over the UNBONDED
    /// standard profile (#69), so "strap connected" would state something the flag does not mean.
    func testBatteryAnswerMakesNoConnectionClaim() {
        let line = GlanceAnswer.sentence(reading: .battery, snapshot: snapshot(),
                                         carry: nil, now: Self.now)
        XCTAssertTrue(line.contains("76%"), line)
        for word in ["connected", "disconnected", "paired", "bonded"] {
            XCTAssertFalse(line.lowercased().contains(word), "battery answer claimed \(word): \(line)")
        }
    }

    // MARK: - Staleness

    /// A bare clock time is only an answer for TODAY's publish. On an older snapshot "as of 9:40"
    /// invites the listener to hear "this morning", so the stamp widens: weekday within the week,
    /// full date beyond it (where a weekday is ambiguous again).
    func testStaleSnapshotStampWidensFromTimeToWeekdayToDate() {
        func stamp(_ n: Int) -> String {
            GlanceAnswer.sentence(reading: .charge, snapshot: snapshot(updated: daysAgo(n)),
                                  carry: nil, now: Self.now)
        }
        let today = stamp(0), threeDays = stamp(3), tenDays = stamp(10)

        // Today: the clock alone, and specifically NOT a weekday.
        XCTAssertFalse(today.contains(weekday(Self.now)), "today's stamp named a weekday: \(today)")

        // Within the week: the source day's weekday, so "9:40" cannot be heard as this morning.
        XCTAssertTrue(threeDays.contains(weekday(daysAgo(3))),
                      "a three-day-old stamp did not name its weekday: \(threeDays)")

        // Past the week: a weekday no longer identifies a day, so the date is spelled out. The year
        // is the part a weekday form can never contain, which is what makes this a real distinction.
        let year = String(Calendar.current.component(.year, from: daysAgo(10)))
        XCTAssertTrue(tenDays.contains(year), "a ten-day-old stamp did not name its date: \(tenDays)")
        XCTAssertFalse(tenDays.contains(weekday(daysAgo(10))),
                       "the beyond-a-week stamp fell back to the ambiguous weekday form: \(tenDays)")

        XCTAssertNotEqual(today, threeDays)
        XCTAssertNotEqual(threeDays, tenDays)
    }

    /// A stamp in the future (the user moved the clock back) is not a negative day count to be
    /// rounded down into "today" — it falls to the unambiguous full-date spelling.
    func testFutureStampFallsToTheUnambiguousDateForm() {
        let ahead = Calendar.current.date(byAdding: .day, value: 2, to: Self.now)!
        let line = GlanceAnswer.sentence(reading: .charge, snapshot: snapshot(updated: ahead),
                                         carry: nil, now: Self.now)
        XCTAssertTrue(line.contains(String(Calendar.current.component(.year, from: ahead))), line)
    }

    // MARK: - Provenance

    /// A carried score names the day it came from. Today dims the column and captions it
    /// "carried · Tue"; a sentence has no dim, so the day has to be said or the answer presents a
    /// two-day-old measurement as the answered day's own — the #977 failure in a different medium.
    func testCarriedScoreNamesItsSourceDay() {
        let snap = snapshot()
        let line = GlanceAnswer.sentence(reading: .charge, snapshot: snap,
                                         carry: carry(for: snap, charge: "Tue"), now: Self.now)
        XCTAssertTrue(line.contains("carried from Tue"), line)
        XCTAssertTrue(line.contains("62"), line)
    }

    /// The mirror image: when the snapshot's own row is scored, nothing is said about carrying. An
    /// answer that hedged every score would make the carried case unremarkable.
    func testOwnScoreMakesNoCarryClaim() {
        let snap = snapshot()
        let line = GlanceAnswer.sentence(reading: .charge, snapshot: snap,
                                         carry: carry(for: snap), now: Self.now)
        XCTAssertEqual(line, "Charge 62, as of \(Self.now.formatted(date: .omitted, time: .shortened)).")
    }

    /// THE ONE THAT MATTERS MOST. A provenance record that does not belong to this snapshot must not
    /// be read as "the day's own" — that is the single wrong answer available here, because it would
    /// state a carried score as a fresh measurement. The number is still spoken (refusing it would be
    /// its own dishonesty); what is withheld is the claim about which day it is.
    func testStaleProvenanceRecordIsNeverReportedAsTheDaysOwn() {
        let snap = snapshot()
        // A record left behind by an EARLIER publish: right shape, wrong publish.
        let previous = GlanceCarry(updated: daysAgo(1), chargeCarriedFrom: nil, restCarriedFrom: nil)
        let line = GlanceAnswer.sentence(reading: .charge, snapshot: snap,
                                         carry: previous, now: Self.now)
        XCTAssertTrue(line.contains("62"), "withheld a real measurement: \(line)")
        XCTAssertTrue(line.contains("The day it came from isn't recorded"), line)
        XCTAssertNotEqual(line, "Charge 62, as of \(Self.now.formatted(date: .omitted, time: .shortened)).",
                          "a mismatched provenance record was spoken as the day's own score")
    }

    /// The upgrade path: a snapshot published by a build that wrote no `GlanceCarry` at all. Same
    /// rule — unknown, never assumed own.
    func testMissingProvenanceRecordIsUnknownNotOwn() {
        let line = GlanceAnswer.sentence(reading: .rest, snapshot: snapshot(),
                                         carry: nil, now: Self.now)
        XCTAssertTrue(line.contains("88"), line)
        XCTAssertTrue(line.contains("The day it came from isn't recorded"), line)
    }

    /// An ABSENT score short-circuits before provenance is consulted: there is no source day to argue
    /// about, and appending "the day it came from isn't recorded" to "Rest not recorded yet" would be
    /// noise about a value that does not exist.
    func testAbsentScoreDoesNotAlsoReportUnknownProvenance() {
        let line = GlanceAnswer.sentence(reading: .rest, snapshot: snapshot(rest: nil),
                                         carry: nil, now: Self.now)
        XCTAssertTrue(line.hasPrefix("Rest not recorded yet,"), line)
        XCTAssertFalse(line.contains("came from"), line)
    }

    /// Effort NEVER carries — `WidgetDayResolver` refuses to present yesterday's full-day strain as
    /// today's accumulating total — so its answer is unconditionally the resolved day's own, and no
    /// carry record may make it say otherwise.
    func testEffortNeverSpeaksACarryOrAnUnknownDay() {
        let snap = snapshot()
        for c in [nil, carry(for: snap, charge: "Tue", rest: "Mon"),
                  GlanceCarry(updated: daysAgo(1), chargeCarriedFrom: "Tue", restCarriedFrom: "Mon")] {
            let line = GlanceAnswer.sentence(reading: .effort, snapshot: snap, carry: c, now: Self.now)
            XCTAssertFalse(line.contains("carried from"), line)
            XCTAssertFalse(line.contains("came from"), line)
            XCTAssertTrue(line.contains("41"), line)
        }
    }

    // MARK: - GlanceCarry.source

    /// The resolver under the sentences, pinned directly: three states, and the two that mean
    /// "cannot tell" both land on `.unknown` rather than collapsing into `.own`.
    func testCarrySourceIsTotalOverItsThreeStates() {
        let snap = snapshot()
        XCTAssertEqual(GlanceCarry.source(for: snap, carry: carry(for: snap), \.chargeCarriedFrom),
                       .own)
        XCTAssertEqual(GlanceCarry.source(for: snap, carry: carry(for: snap, charge: "Tue"),
                                          \.chargeCarriedFrom), .carried("Tue"))
        XCTAssertEqual(GlanceCarry.source(for: snap, carry: nil, \.chargeCarriedFrom), .unknown)
        XCTAssertEqual(GlanceCarry.source(for: snap,
                                          carry: GlanceCarry(updated: daysAgo(1),
                                                             chargeCarriedFrom: nil,
                                                             restCarriedFrom: nil),
                                          \.chargeCarriedFrom), .unknown)
    }

    /// The two fields are resolved independently: a night carried from Monday alongside a Charge
    /// scored on the answered day must not drag the Charge into a carry claim.
    func testChargeAndRestProvenanceAreResolvedIndependently() {
        let snap = snapshot()
        let c = carry(for: snap, rest: "Mon")
        XCTAssertEqual(GlanceCarry.source(for: snap, carry: c, \.chargeCarriedFrom), .own)
        XCTAssertEqual(GlanceCarry.source(for: snap, carry: c, \.restCarriedFrom), .carried("Mon"))
        XCTAssertFalse(GlanceAnswer.sentence(reading: .charge, snapshot: snap,
                                             carry: c, now: Self.now).contains("carried"))
        XCTAssertTrue(GlanceAnswer.sentence(reading: .rest, snapshot: snap,
                                            carry: c, now: Self.now).contains("carried from Mon"))
    }

    /// The stamp is whole seconds on BOTH sides, so a snapshot whose `updated` carries a fraction
    /// still matches the record written from that same `Date`. Were the two sides to round
    /// differently, every carried answer would degrade to "day unknown" — the failure the shared
    /// truncation exists to prevent.
    func testStampMatchesAcrossASubSecondUpdatedValue() {
        let fractional = Date(timeIntervalSince1970: 1_781_000_000.734)
        let snap = snapshot(updated: fractional)
        XCTAssertEqual(GlanceCarry.source(for: snap, carry: carry(for: snap, charge: "Wed"),
                                          \.chargeCarriedFrom), .carried("Wed"))
    }

    /// Wire format, for the same reason `WidgetSnapshotTests` pins the snapshot's: this record
    /// crosses a process boundary and an install that decodes it wrong reads as "day unknown"
    /// forever rather than failing loudly.
    func testCarryRoundTripsThroughJSON() throws {
        let original = GlanceCarry(updated: Self.now, chargeCarriedFrom: "Tue", restCarriedFrom: nil)
        let decoded = try JSONDecoder().decode(GlanceCarry.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.updatedUnix, Int(Self.now.timeIntervalSince1970))
    }

    // MARK: - Register

    /// The app grades the user nowhere else, and a spoken answer is the easiest place to start by
    /// accident. No verdict words, no advice, in any reachable state.
    func testNoAnswerGradesTheUser() {
        let snap = snapshot()
        let states: [(GlanceReading, WidgetSnapshot?, GlanceCarry?)] = [
            (.charge, snap, carry(for: snap)),
            (.charge, snap, carry(for: snap, charge: "Tue")),
            (.charge, snap, nil),
            (.charge, snapshot(charge: nil), carry(for: snap)),
            (.rest, snapshot(updated: daysAgo(9)), nil),
            (.effort, snap, nil), (.heartRate, snap, nil), (.battery, snap, nil),
            (.charge, nil, nil)
        ]
        let banned = ["good", "bad", "low", "high", "poor", "great", "should",
                      "recommend", "healthy", "risk", "improve", "better", "worse"]
        for (reading, s, c) in states {
            let line = GlanceAnswer.sentence(reading: reading, snapshot: s, carry: c,
                                             now: Self.now).lowercased()
            for word in banned {
                XCTAssertFalse(line.contains(word), "\(reading) answer graded the user (\(word)): \(line)")
            }
        }
    }
}
