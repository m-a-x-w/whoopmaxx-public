import XCTest
import SwiftUI
import StrapAnalytics
@testable import whoopmaxx

/// Past the raw-retention horizon, an absence must not render as a finding (014 decision 5).
///
/// Browsing back through Rest reaches nights whose durable record is intact — the score, the duration,
/// the stage timeline and the regularity all ride `sleepSession` / `dailyMetric` / `metricSeries`, which
/// `SampleRetention` never prunes — but whose RAW 1 Hz streams are gone. The two clusters derived from
/// those streams then have nothing to read, and each renders its emptiness as a confident sentence: the
/// arousal ledger prints "Slept through — no awakenings over 2 minutes", and the wrist-orientation tape
/// disappears as though the night had no lane. Neither is a measurement.
///
/// Three things have to hold. (a) The horizon is `SampleRetention.retentionDays`, read from the constant
/// and pinned at the sweep's own boundary in BOTH directions — the day exactly `retentionDays` back is
/// still kept, the next one is the first that is out. (b) "Aged out" is distinguished from "never
/// captured": a night INSIDE the horizon with no gravity is a real measurement of a night the strap did
/// not record and keeps today's behaviour, and so does a night PAST the horizon that still has its raw
/// (the sweep's scored-day gate holds an unscored day's samples all the way to `hardCapDays`). (c) The
/// copy describes the DATA — what is no longer stored — never the sleeper.
@MainActor
final class RawHorizonTests: XCTestCase {

    /// Midday on today's local day. The keys below are built from its `startOfDay`, which is also what
    /// the sections' own `Date()` resolves to, so fixture and production agree on which day "today" is.
    private let cal = Calendar.current
    private lazy var now: Date = cal.date(byAdding: .hour, value: 12, to: cal.startOfDay(for: Date()))!

    /// The `yyyy-MM-dd` key `daysAgo` local days back — calendar-stepped, not 86 400 s, so the 23- and
    /// 25-hour DST days land on the day they really are.
    private func key(daysAgo: Int) -> String {
        DayKey.local(cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!)
    }

    // MARK: - The boundary

    /// THE CORE CONTRACT, pinned at both ends. `SampleRetention.sweep` keeps the day exactly
    /// `retentionDays` back and prunes every day that STARTS before it (`SampleRetention.swift:205`;
    /// `SampleRetentionTests.testPrunesScoredDaysPastTheHorizonAndKeepsTheBoundaryDay` pins the same
    /// edge against the sweep itself). A horizon that never fires is as wrong as one that fires on
    /// last night.
    func testTheBoundaryDayIsInsideAndTheNextOneIsOut() {
        let horizon = SampleRetention.retentionDays

        XCTAssertFalse(RawHorizon.hasAgedOut(dayKey: key(daysAgo: horizon), now: now),
                       "day -\(horizon) is the oldest day the sweep KEEPS — its raw is still there")
        XCTAssertTrue(RawHorizon.hasAgedOut(dayKey: key(daysAgo: horizon + 1), now: now),
                      "day -\(horizon + 1) starts before today − \(horizon) and is the first pruned")
    }

    /// Last night, and every night in the last week, is never past the horizon. Pins the SIGN of the
    /// step: reaching forward instead of back would age out the whole record.
    func testARecentNightIsNeverAgedOut() {
        for daysAgo in [0, 1, 7] {
            XCTAssertFalse(RawHorizon.hasAgedOut(dayKey: key(daysAgo: daysAgo), now: now),
                           "day -\(daysAgo) is inside every horizon this app has")
        }
    }

    /// The horizon is `retentionDays`, NOT `hardCapDays`. They govern different things — the sample
    /// sweep and the unscored-day backstop — and reading the wrong one would leave a month of nights
    /// rendering an empty ledger as "slept through".
    func testTheHorizonIsRetentionDaysAndNotTheHardCap() {
        XCTAssertGreaterThan(SampleRetention.hardCapDays, SampleRetention.retentionDays + 1,
                             "the two constants must stay far enough apart for this test to separate them")
        let between = (SampleRetention.retentionDays + SampleRetention.hardCapDays) / 2

        XCTAssertTrue(RawHorizon.hasAgedOut(dayKey: key(daysAgo: between), now: now),
                      "day -\(between) is past the SAMPLE horizon, whatever the chatter hard cap is")
    }

    /// A key the app cannot resolve is not evidence about storage. Nil, empty and junk all read as
    /// "don't claim anything" — the same direction every other unknown takes on this screen.
    func testAnAbsentOrUnparseableKeyClaimsNothing() {
        for raw in [nil, "", "not-a-day", "2026-13-01"] as [String?] {
            XCTAssertFalse(RawHorizon.hasAgedOut(dayKey: raw, now: now),
                           "\(raw ?? "nil") is not a date, so it is not a night past the horizon")
        }
    }

    // MARK: - The arousal ledger

    /// THE REGRESSION. An empty ledger on a night whose raw HR is gone printed the most confident
    /// sentence on the screen. One day either side of the boundary, and only the outside one is
    /// replaced.
    func testTheLedgerIsReplacedPastTheHorizonAndNotBefore() {
        let horizon = SampleRetention.retentionDays

        let inside = ArousalForensicsSection(arousals: [], capture: nil, dayKey: key(daysAgo: horizon))
        XCTAssertFalse(inside.rawAgedOut,
                       "inside the horizon an empty ledger is a real reading — it keeps \"slept through\"")

        let outside = ArousalForensicsSection(arousals: [], capture: nil,
                                              dayKey: key(daysAgo: horizon + 1))
        XCTAssertTrue(outside.rawAgedOut, "past the horizon there was no HR to find no awakenings in")
    }

    /// The replacement is not conditional on the ledger being EMPTY. Stages survive the sweep, so
    /// `ArousalForensics` still emits wake segments past the horizon — with every cause resolved
    /// `unexplained` because nothing was left to explain them with. "We looked and found nothing" is
    /// the same false confidence in a different shape.
    func testAPopulatedLedgerPastTheHorizonIsReplacedToo() {
        let wake = Arousal(start: 1_753_400_000, end: 1_753_400_180, cause: .unexplained,
                           evidence: "no clear signal", durationMin: 3)
        let section = ArousalForensicsSection(arousals: [wake], capture: nil,
                                              dayKey: key(daysAgo: SampleRetention.retentionDays + 1))

        XCTAssertTrue(section.rawAgedOut,
                      "an \"unexplained\" row past the horizon claims a search that never ran")
    }

    /// "Aged out" is not the same as "old". The sweep prunes a day only once it has been SCORED, so an
    /// unscored night keeps its samples to `hardCapDays` — and a capture measure proves the pass really
    /// read a window there. That night's ledger is real and must keep rendering.
    func testANightPastTheHorizonThatStillHasItsRawKeepsItsLedger() {
        let measured = CaptureQuality(hrPerMinute: 1.2, gravityCoverage: 0.9)
        let section = ArousalForensicsSection(arousals: [], capture: measured,
                                              dayKey: key(daysAgo: SampleRetention.retentionDays + 1))

        XCTAssertFalse(section.rawAgedOut,
                       "the pass measured an HR window on this night — the raw is there and the ledger stands")
    }

    /// Every caller that does not name a night — the specimen previews, and any surface that renders
    /// the ledger without a day key — behaves exactly as it did before. This is what makes the new
    /// parameter safe to default.
    func testAnUnkeyedLedgerIsUnchanged() {
        XCTAssertFalse(ArousalForensicsSection(arousals: [], capture: nil, dayKey: nil).rawAgedOut)
    }

    // MARK: - The wrist-orientation tape

    /// One night, one orientation, held throughout — enough of a read for the section to have something
    /// to draw.
    private func read() -> PostureLoader.Night {
        let start = 1_753_400_000
        let night = PostureEngine.Night(
            start: start, end: start + 60 * Int(PostureEngine.epochS),
            epochs: Array(repeating: PostureEngine.Epoch.orientation(0), count: 60),
            orientations: [PostureEngine.Orientation(index: 0, epochs: 60, share: 1,
                                                     longestHoldEpochs: 60)],
            summary: PostureEngine.Summary(switches: 0, stableFraction: 1, dominantFraction: 1,
                                           entropyBits: 0, orientationCount: 1))
        return PostureLoader.Night(read: night, mix: [])
    }

    /// The tape's absence is silent, which past the horizon reads as a night with no lane rather than a
    /// night whose lane is no longer stored. Both ends pinned, plus the "it still has gravity" case.
    func testTheTapeSaysItAgedOutRatherThanVanishing() {
        let horizon = SampleRetention.retentionDays

        XCTAssertTrue(PostureSection(night: nil, hadGravity: false, dayKey: key(daysAgo: horizon + 1)).rawAgedOut,
                      "past the horizon there was no gravity to cluster — say so")
        XCTAssertFalse(PostureSection(night: nil, hadGravity: false, dayKey: key(daysAgo: horizon)).rawAgedOut,
                       "inside the horizon a missing tape is a night the strap did not record")
        XCTAssertFalse(PostureSection(night: read(), hadGravity: true, dayKey: key(daysAgo: horizon + 1)).rawAgedOut,
                       "an unscored day keeps its samples to hardCapDays — a real read still renders")
        XCTAssertFalse(PostureSection(night: nil, hadGravity: false, dayKey: nil).rawAgedOut,
                       "an un-keyed section behaves exactly as it did before")
    }

    // MARK: - The copy

    /// Both lines name the horizon FROM the constant, so moving the retention window moves the sentence
    /// with the gate; and neither claims anything about the sleeper. The aged-out line must also not be
    /// the slept-through one wearing a different hat — that is the sentence it exists to displace.
    func testTheAgedOutCopyNamesTheHorizonAndDescribesOnlyTheData() {
        let arousal = ArousalForensicsSection.agedOutLine
        let posture = PostureSection.agedOutLine

        // The LEDGER owns the explanation and prints the horizon from the constant. The posture line
        // deliberately does not repeat it: on a browsed night past the horizon both sections render
        // consecutively, and two adjacent sentences opening "This night is past the 28-day raw-signal
        // window, so its..." read as an app repeating itself rather than as two findings. Neither
        // sentence was wrong; the pair was.
        XCTAssertTrue(arousal.contains("\(SampleRetention.retentionDays)-day"),
                      "the horizon must be printed from the constant, never a literal: \(arousal)")
        XCTAssertFalse(posture.contains("\(SampleRetention.retentionDays)-day"),
                       "the second sentence must not restate the window the first one just named")
        XCTAssertTrue(posture.contains("no longer stored"),
                      "it still has to say the motion is gone, standalone: \(posture)")

        for line in [arousal, posture] {
            let lower = line.lowercased()
            for word in ["thermoregulation", "vasodilation", "impaired", "poor", "abnormal", "apnea",
                         "insomnia", "hypoxemia", "arrhythmia", "consider", "you should", "talk to"] {
                XCTAssertFalse(lower.contains(word), "011 decision 5 bans \"\(word)\" from this copy")
            }
            XCTAssertFalse(lower.contains("slept through"), "an aged-out night is not a slept-through one")
            XCTAssertFalse(lower.contains("no awakenings"),
                           "counting nothing is the claim this line replaces: \(line)")
        }

        XCTAssertNotEqual(arousal, ArousalForensicsSection.sleptThroughLine)
        XCTAssertTrue(ArousalForensicsSection.sleptThroughLine.contains("no awakenings"),
                      "the copy this displaces must stay the sentence the test above is guarding against")
    }

    // MARK: - The wiring, not the struct

    /// EVERY test in this file builds its section directly — which is exactly how this packet shipped
    /// dead.
    ///
    /// `ArousalForensicsSection` gained `dayKey` and the SCREEN never passed it, so `hasAgedOut(nil)`
    /// answered false for every night and the aged-out line was unreachable in the binary while these
    /// tests stayed green. `PostureSection` was worse: it was only constructed when its night was
    /// non-nil, and a nil night IS the aged-out case, so its line was unreachable by construction.
    ///
    /// A view test would be the honest fix and this project has no host for one. So these pin the
    /// PROPERTY that made the bug possible — a nil key silently disables the whole feature — and the
    /// shape a caller has to satisfy to reach each line.
    func testANilKeyDisablesTheHorizonEntirely() {
        let old = agedOutKey()
        XCTAssertTrue(RawHorizon.hasAgedOut(dayKey: old), "premise: this key is past the horizon")
        XCTAssertFalse(RawHorizon.hasAgedOut(dayKey: nil),
                       "a missing key reads as 'not aged out' \u{2014} which is why forgetting to pass "
                       + "one silently disables every aged-out state instead of failing")

        let unkeyed = ArousalForensicsSection(arousals: [], hasSession: true, capture: nil, dayKey: nil)
        let keyed = ArousalForensicsSection(arousals: [], hasSession: true, capture: nil, dayKey: old)
        XCTAssertFalse(unkeyed.rawAgedOut, "no key, no horizon \u{2014} the shipped-dead shape")
        XCTAssertTrue(keyed.rawAgedOut, "keyed, it knows the raw signal is gone")
    }

    /// The posture section must be renderable with a NIL night, because that is the aged-out case. A
    /// caller that only builds it for a non-nil night can never reach the line.
    func testThePostureSectionIsTheOneThatDecidesNotItsCaller() {
        XCTAssertTrue(PostureSection(night: nil, hadGravity: false, dayKey: agedOutKey()).rawAgedOut,
                      "a nil night past the horizon IS the aged-out state")
        XCTAssertFalse(PostureSection(night: nil, hadGravity: false, dayKey: nil).rawAgedOut)
        XCTAssertFalse(PostureSection(night: nil, hadGravity: false, dayKey: insideHorizonKey()).rawAgedOut,
                       "inside the horizon a nil night is a night the strap did not record \u{2014} unchanged")
    }

    /// The Movement screen became reachable for every night in the record when browsing landed, and its
    /// empty state promises the seismograph "fills in once a night is worn and synced". Past the
    /// horizon nothing can keep that promise, and it reads as an accusation the strap was never worn.
    func testTheMovementEmptyStateStopsPromisingDataThatCannotArrive() {
        let agedLine = NightMovementContent.emptyLine(dayKey: agedOutKey())
        XCTAssertEqual(agedLine, NightMovementContent.agedOutLine)
        XCTAssertFalse(agedLine.contains("worn and synced"),
                       "a pruned night is not an unworn one: \(agedLine)")
        XCTAssertTrue(agedLine.contains("\(SampleRetention.retentionDays)-day"))

        XCTAssertEqual(NightMovementContent.emptyLine(dayKey: insideHorizonKey()),
                       NightMovementContent.neverRecordedLine)
        XCTAssertEqual(NightMovementContent.emptyLine(dayKey: nil),
                       NightMovementContent.neverRecordedLine)
    }

    /// A day key comfortably past the raw horizon.
    private func agedOutKey() -> String {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: -(SampleRetention.retentionDays + 7),
                         to: cal.startOfDay(for: Date()))!
        return DayKey.local(d)
    }

    /// ...and one comfortably inside it.
    private func insideHorizonKey() -> String {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        return DayKey.local(d)
    }

    // MARK: - "No longer stored" is a claim about the STORE

    /// A night past the horizon whose gravity is STILL ON DISK, and simply would not cluster, must not
    /// be told its motion "is no longer stored".
    ///
    /// `PostureLoader` returns no night for several distinct reasons — nothing banked, too little held
    /// still, no orientation the night returned to — and folding them into one nil let the section
    /// blame retention for a limit of the analysis. `SampleRetention`'s scored-day gate keeps an
    /// UNSCORED day's samples to `hardCapDays` (56), so a 40-day-old unscored night really can hold
    /// gravity that will not cluster: this is a reachable state, not a hypothetical.
    ///
    /// Turns red: drop `!hadGravity` from `PostureSection.rawAgedOut`.
    func testAnUnclusterableNightPastTheHorizonIsNotCalledUnstored() {
        let old = key(daysAgo: SampleRetention.retentionDays + 1)

        XCTAssertFalse(PostureSection(night: nil, hadGravity: true, dayKey: old).rawAgedOut,
                       "the gravity is on disk — the analysis declined it, and saying otherwise "
                       + "blames retention for a limit of the clustering")
        XCTAssertTrue(PostureSection(night: nil, hadGravity: false, dayKey: old).rawAgedOut,
                      "an empty read past the horizon IS the aged-out state")
    }
}
