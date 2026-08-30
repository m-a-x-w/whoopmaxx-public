import XCTest
@testable import whoopmaxx

/// W9 smart-alarm pure surface: the `nextSmartAlarmDate` date math, the `SmartWakeWatcher`
/// fire-once/trough/reset behaviour, the coordinator's window-gated early fire + arm/disarm gating, and
/// the `SmartAlarmSettings` persistence round-trip + validation.
///
/// Mirrors the original StrandTests/SmartAlarmWeekdayTests.swift + android SleepWindowWatcherTest.kt. The strap
/// buzz / firmware alarm / real notifications are DEVICE-ONLY and out of scope here — the fakes stand in.
/// The readback verify loop is driven by a hand-fired `ManualScheduler`, so timeouts/backoffs are exact.
final class SmartAlarmTests: XCTestCase {

    // Fixed UTC calendar so the date math is deterministic regardless of the machine's zone.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: - nextSmartAlarmDate

    func testNextAlarm_todayWhenTimeAhead() {
        // now = 06:00, latest 07:00 → today 07:00.
        let next = SmartAlarmCoordinator.nextSmartAlarmDate(minutes: 7 * 60, from: date(2026, 6, 17, 6, 0),
                                                            calendar: utc)
        XCTAssertEqual(next, date(2026, 6, 17, 7, 0))
    }

    func testNextAlarm_tomorrowWhenTimePassed() {
        // now = 08:00, latest 07:00 → tomorrow 07:00.
        let next = SmartAlarmCoordinator.nextSmartAlarmDate(minutes: 7 * 60, from: date(2026, 6, 17, 8, 0),
                                                            calendar: utc)
        XCTAssertEqual(next, date(2026, 6, 18, 7, 0))
    }

    func testNextAlarm_strictlyFuture() {
        // Exactly at the wake minute → skip to the next occurrence, never "now".
        let next = SmartAlarmCoordinator.nextSmartAlarmDate(minutes: 7 * 60, from: date(2026, 6, 17, 7, 0),
                                                            calendar: utc)
        XCTAssertEqual(next, date(2026, 6, 18, 7, 0))
    }

    func testNextAlarm_lateEdgeNearMidnight() {
        // latest 23:50; now 23:00 → today 23:50; now 23:55 → tomorrow 23:50.
        let m = 23 * 60 + 50
        XCTAssertEqual(SmartAlarmCoordinator.nextSmartAlarmDate(minutes: m, from: date(2026, 6, 17, 23, 0),
                                                                calendar: utc),
                       date(2026, 6, 17, 23, 50))
        XCTAssertEqual(SmartAlarmCoordinator.nextSmartAlarmDate(minutes: m, from: date(2026, 6, 17, 23, 55),
                                                                calendar: utc),
                       date(2026, 6, 18, 23, 50))
    }

    // MARK: - SmartWakeWatcher

    private func watcher() -> SmartWakeWatcher {
        SmartWakeWatcher(riseBpm: 6, minSamples: 5, troughCeilingBpm: 90)
    }

    func testWatcher_quietBeforeEnoughSamples() {
        let w = watcher()
        for _ in 0..<4 { XCTAssertFalse(w.shouldWake(bpm: 80)) }
    }

    func testWatcher_firesOnceOnRise() {
        let w = watcher()
        for _ in 0..<6 { XCTAssertFalse(w.shouldWake(bpm: 50)) }
        XCTAssertTrue(w.shouldWake(bpm: 58))   // +8 over the trough of 50
        XCTAssertFalse(w.shouldWake(bpm: 60))  // no re-fire
        XCTAssertFalse(w.shouldWake(bpm: 58))
    }

    func testWatcher_smallWobbleDoesNotFire() {
        let w = watcher()
        for _ in 0..<6 { XCTAssertFalse(w.shouldWake(bpm: 52)) }
        XCTAssertFalse(w.shouldWake(bpm: 56))  // +4 is below the 6 bpm threshold
    }

    func testWatcher_ignoresNonPositiveHr() {
        let w = watcher()
        for _ in 0..<6 { XCTAssertFalse(w.shouldWake(bpm: 50)) }
        XCTAssertFalse(w.shouldWake(bpm: 0))
        XCTAssertFalse(w.shouldWake(bpm: -1))
    }

    func testWatcher_highSpikeDoesNotPoisonTrough() {
        let w = watcher()
        XCTAssertFalse(w.shouldWake(bpm: 120))     // above the ceiling — not a trough candidate
        for _ in 0..<6 { XCTAssertFalse(w.shouldWake(bpm: 48)) }
        XCTAssertTrue(w.shouldWake(bpm: 55))       // +7 over the real trough of 48
    }

    func testWatcher_resetReArms() {
        let w = watcher()
        for _ in 0..<6 { _ = w.shouldWake(bpm: 50) }
        XCTAssertTrue(w.shouldWake(bpm: 58))
        w.reset()
        XCTAssertFalse(w.shouldWake(bpm: 58))      // warm-up gate applies again
    }

    // MARK: - Settings persistence + validation

    @MainActor
    func testSettings_roundTrip() {
        let suite = "wm.test.alarm.roundtrip"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let s = SmartAlarmSettings(defaults: d)
        s.enabled = true
        s.setEarliest(6 * 60)
        s.setLatest(6 * 60 + 40)
        // A fresh instance reads the same persisted values.
        let s2 = SmartAlarmSettings(defaults: d)
        XCTAssertTrue(s2.enabled)
        XCTAssertEqual(s2.earliestMin, 6 * 60)
        XCTAssertEqual(s2.latestMin, 6 * 60 + 40)
        d.removePersistentDomain(forName: suite)
    }

    @MainActor
    func testSettings_validationForcesLatestAtOrAfterEarliest() {
        let s = SmartAlarmSettings(defaults: volatileDefaults("wm.test.alarm.valid1"))
        s.setEarliest(7 * 60)
        s.setLatest(6 * 60)          // below earliest → clamped up to earliest
        XCTAssertEqual(s.latestMin, 7 * 60)
        XCTAssertGreaterThanOrEqual(s.latestMin, s.earliestMin)
    }

    @MainActor
    func testSettings_validationClampsWindowWidth() {
        let s = SmartAlarmSettings(defaults: volatileDefaults("wm.test.alarm.valid2"))
        s.setEarliest(6 * 60)
        s.setLatest(6 * 60 + 600)    // a 10-hour window → clamped to the max width
        XCTAssertEqual(s.latestMin, 6 * 60 + SmartAlarmSettings.maxWindowMin)
    }

    @MainActor
    func testNormalize_pure() {
        XCTAssertEqual(SmartAlarmSettings.normalize(earliest: 400, latest: 300).latest, 400)
        let wide = SmartAlarmSettings.normalize(earliest: 100, latest: 100 + 999)
        XCTAssertEqual(wide.latest, 100 + SmartAlarmSettings.maxWindowMin)
    }

    // MARK: - Coordinator apply() gating

    @MainActor
    func testApply_disabled_disarmsAndCancels() {
        let h = harness(now: date(2026, 6, 17, 6, 0))
        h.settings.enabled = false
        h.coord.apply()
        XCTAssertEqual(h.strap.armCount, 0)
        XCTAssertGreaterThanOrEqual(h.strap.disableCount, 1)
        XCTAssertGreaterThanOrEqual(h.notifier.cancelCount, 1)
    }

    @MainActor
    func testApply_enabledUnbonded_backupOnly_noStrapArm() {
        let h = harness(now: date(2026, 6, 17, 6, 0))
        h.live.encryptedBond = false
        h.settings.enabled = true
        h.coord.apply()
        XCTAssertEqual(h.strap.armCount, 0, "no genuine bond → the firmware backstop is not armed")
        XCTAssertEqual(h.notifier.scheduleCount, 1, "the backup notification is scheduled regardless")
        XCTAssertEqual(h.notifier.pendingBackupMinute, h.settings.latestMin)
    }

    @MainActor
    func testApply_enabledBonded_armsStrapAtLatestEdge_andSchedulesBackup() {
        let now = date(2026, 6, 17, 6, 0)
        let h = harness(now: now)
        h.live.encryptedBond = true
        h.settings.enabled = true
        h.coord.apply()
        XCTAssertEqual(h.strap.armCount, 1)
        XCTAssertEqual(h.strap.legacyArmCount, 0, "the coordinator arms only through the acked armBackstop")
        let expected = SmartAlarmCoordinator.nextSmartAlarmDate(minutes: h.settings.latestMin, from: now,
                                                                calendar: utc)
        XCTAssertEqual(h.strap.lastArmDate, expected)
        XCTAssertEqual(h.notifier.scheduleCount, 1)
        XCTAssertEqual(h.coord.backstop, .confirming, "sent is not armed until the strap echoes it back")
        XCTAssertFalse(h.coord.isArmedOnStrap)
    }

    // MARK: - Readback verify loop

    @MainActor
    func testVerify_matchingReadbackVerifiesOnFirstAttempt() {
        let h = harness(now: date(2026, 6, 17, 6, 0))
        h.live.encryptedBond = true; h.settings.enabled = true
        h.coord.apply()
        XCTAssertEqual(h.sched.pending.map { $0.delay }, [SmartAlarmCoordinator.readbackTimeout])
        h.coord.onReadback(UInt32(h.settings.scheduledDeadlineEpoch))
        XCTAssertEqual(h.coord.backstop, .verified)
        XCTAssertTrue(h.coord.isArmedOnStrap)
        h.sched.fireAll()   // the stale timeout is a no-op
        XCTAssertEqual(h.coord.backstop, .verified)
        XCTAssertEqual(h.strap.armCount, 1)
    }

    @MainActor
    func testVerify_nilReadbackThreeTimesFails_withBackoff3Then6() {
        let h = harness(now: date(2026, 6, 17, 6, 0))
        h.live.encryptedBond = true; h.settings.enabled = true
        h.coord.apply()
        h.coord.onReadback(nil)                                   // attempt 1 failed → retry in 3
        XCTAssertEqual(h.sched.pending.last?.delay, 3)
        h.sched.fireAll()                                         // stale timeout + retry → attempt 2 sent
        XCTAssertEqual(h.strap.armCount, 2)
        h.coord.onReadback(nil)                                   // attempt 2 failed → retry in 6
        XCTAssertEqual(h.sched.pending.last?.delay, 6)
        h.sched.fireAll()
        XCTAssertEqual(h.strap.armCount, 3)
        XCTAssertEqual(h.coord.backstop, .confirming)
        h.coord.onReadback(nil)                                   // attempt 3 failed → give up
        XCTAssertEqual(h.coord.backstop, .failed)
        XCTAssertFalse(h.coord.isArmedOnStrap)
        h.sched.fireAll()
        XCTAssertEqual(h.strap.armCount, 3, "no further arms after .failed")
    }

    @MainActor
    func testVerify_mismatchedReadbackCountsAsFailedAttempt() {
        let h = harness(now: date(2026, 6, 17, 6, 0))
        h.live.encryptedBond = true; h.settings.enabled = true
        h.coord.apply()
        h.coord.onReadback(UInt32(h.settings.scheduledDeadlineEpoch) + 60)
        XCTAssertEqual(h.coord.backstop, .confirming)
        XCTAssertEqual(h.sched.pending.last?.delay, 3, "a mismatch schedules the retry")
    }

    @MainActor
    func testVerify_timeoutRetries_thenMatchVerifies() {
        let h = harness(now: date(2026, 6, 17, 6, 0))
        h.live.encryptedBond = true; h.settings.enabled = true
        h.coord.apply()
        h.sched.fireAll()   // 5 s timeout → retry scheduled (3 s)
        XCTAssertEqual(h.strap.armCount, 1)
        XCTAssertEqual(h.sched.pending.map { $0.delay }, [3])
        h.sched.fireAll()   // retry → attempt 2 sent + fresh timeout
        XCTAssertEqual(h.strap.armCount, 2)
        XCTAssertEqual(h.sched.pending.map { $0.delay }, [SmartAlarmCoordinator.readbackTimeout])
        h.coord.onReadback(UInt32(h.settings.scheduledDeadlineEpoch))
        XCTAssertEqual(h.coord.backstop, .verified)
        h.sched.fireAll()
        XCTAssertEqual(h.strap.armCount, 2, "verified: the stale timeout does not re-send")
    }

    @MainActor
    func testVerify_secondApplyForNewDeadlineRetiresFirstLoop() {
        let clock = Clock(date(2026, 6, 17, 6, 0))
        let h = harness(now: { clock.date })
        h.live.encryptedBond = true; h.settings.enabled = true
        h.coord.apply()                                           // deadline = Jun 17 07:00
        let first = h.sched.pending.removeFirst()                 // hold the first loop's timeout
        clock.date = self.date(2026, 6, 18, 6, 0)
        h.coord.apply()                                           // deadline = Jun 18 07:00 → new loop
        XCTAssertEqual(h.strap.armCount, 2)
        first.work()                                              // the stale timeout must do nothing
        XCTAssertEqual(h.sched.pending.map { $0.delay }, [SmartAlarmCoordinator.readbackTimeout],
                       "no retry was scheduled by the stale generation")
        XCTAssertEqual(h.coord.backstop, .confirming)
        h.coord.onReadback(UInt32(h.settings.scheduledDeadlineEpoch))
        XCTAssertEqual(h.coord.backstop, .verified)
    }

    @MainActor
    func testVerify_earlyFireDropsBackstop_andLateReadbackIsIgnored() {
        let clock = Clock(date(2026, 6, 17, 6, 0))
        let h = harness(now: { clock.date }, watcher: SmartWakeWatcher(riseBpm: 6, minSamples: 3, troughCeilingBpm: 90))
        h.live.encryptedBond = true; h.live.connected = true; h.live.worn = true
        h.settings.enabled = true
        h.coord.apply()
        let deadline = UInt32(h.settings.scheduledDeadlineEpoch)
        XCTAssertEqual(h.coord.backstop, .confirming)
        clock.date = self.date(2026, 6, 17, 6, 40)
        for bpm in [50, 50, 50] { h.coord.feedHR(bpm) }
        h.coord.feedHR(60)
        XCTAssertEqual(h.strap.disableCount, 1, "early fire drops the backstop through the acked write")
        XCTAssertEqual(h.strap.legacyDisableCount, 0)
        XCTAssertEqual(h.coord.backstop, .none)
        h.coord.onReadback(deadline)   // a late echo of the dropped arm
        XCTAssertEqual(h.coord.backstop, .none, "a readback after the loop was retired is ignored")
        XCTAssertFalse(h.coord.isArmedOnStrap)
        h.sched.fireAll()
        XCTAssertEqual(h.strap.armCount, 1, "the retired loop never re-sends")
    }

    @MainActor
    func testVerify_unverifiableFamilyIsSentButNeverReadsArmed() {
        let h = harness(now: date(2026, 6, 17, 6, 0))
        h.strap.verifiable = false
        h.live.encryptedBond = true; h.settings.enabled = true
        h.coord.apply()
        XCTAssertEqual(h.strap.armCount, 1)
        XCTAssertEqual(h.coord.backstop, .none, "no echo, no armed claim")
        XCTAssertFalse(h.coord.isArmedOnStrap)
        XCTAssertTrue(h.sched.pending.isEmpty, "no verify loop for a family the router cannot read back")
    }

    @MainActor
    func testVerify_lateMatchingReadbackAfterFailedStillVerifies() {
        let h = harness(now: date(2026, 6, 17, 6, 0))
        h.live.encryptedBond = true; h.settings.enabled = true
        h.coord.apply()
        for _ in 0..<3 { h.sched.fireAll(); h.sched.fireAll() }   // 3 timeouts + 2 retries
        XCTAssertEqual(h.coord.backstop, .failed)
        XCTAssertEqual(h.strap.armCount, 3)
        h.coord.onReadback(UInt32(h.settings.scheduledDeadlineEpoch))   // attempt 3's slow echo
        XCTAssertEqual(h.coord.backstop, .verified, "a matching echo is ground truth even after giving up")
        h.coord.onReadback(nil)
        XCTAssertEqual(h.coord.backstop, .verified, "a later nil never downgrades a verified arm")
        XCTAssertEqual(h.strap.armCount, 3)
    }

    @MainActor
    func testVerify_disarmAndStrapFireRetireTheLoop() {
        let clock = Clock(date(2026, 6, 17, 6, 0))
        let h = harness(now: { clock.date })
        h.live.encryptedBond = true; h.settings.enabled = true
        h.coord.apply()
        let stale = h.sched.pending.removeFirst()
        h.coord.disarm()
        XCTAssertEqual(h.coord.backstop, .none)
        stale.work()
        XCTAssertEqual(h.strap.armCount, 1, "a timeout from before disarm never re-sends")
        XCTAssertTrue(h.sched.pending.isEmpty)

        h.coord.apply()                                           // fresh loop for today 07:00
        XCTAssertEqual(h.strap.armCount, 2)
        let stale2 = h.sched.pending.removeFirst()
        clock.date = self.date(2026, 6, 17, 7, 0)
        h.coord.onStrapFired()                                    // spent → apply() arms tomorrow's
        XCTAssertEqual(h.strap.armCount, 3)
        XCTAssertEqual(h.coord.backstop, .confirming)
        stale2.work()
        XCTAssertEqual(h.sched.pending.map { $0.delay }, [SmartAlarmCoordinator.readbackTimeout],
                       "the fired night's timeout schedules nothing")
        h.coord.onReadback(UInt32(h.settings.scheduledDeadlineEpoch))
        XCTAssertEqual(h.coord.backstop, .verified)
    }

    @MainActor
    func testApply_backupNeverStacks_andDisarmClears() {
        let h = harness(now: date(2026, 6, 17, 6, 0))
        h.settings.enabled = true
        h.coord.apply()
        h.coord.apply()
        // The fake models the real fixed-identifier replace: still a single pending backup.
        XCTAssertEqual(h.notifier.scheduleCount, 2)
        XCTAssertNotNil(h.notifier.pendingBackupMinute)
        h.settings.enabled = false
        h.coord.apply()   // disarm
        XCTAssertNil(h.notifier.pendingBackupMinute)
    }

    // MARK: - Window-gated early fire (the advance clamp analog)

    @MainActor
    func testEarlyFire_onlyInsideWindow() {
        let clock = Clock(date(2026, 6, 17, 6, 0))
        // A watcher that trips after a few samples so the test is deterministic.
        let h = harness(now: { clock.date }, watcher: SmartWakeWatcher(riseBpm: 6, minSamples: 3, troughCeilingBpm: 90))
        h.live.encryptedBond = true
        h.live.connected = true
        h.live.worn = true
        h.settings.enabled = true
        h.coord.apply()   // deadline = today 07:00, window-start = 06:30
        let deadlineBefore = h.settings.scheduledDeadlineEpoch

        // BEFORE the window (06:00 < 06:30): a clear rise must NOT fire.
        for bpm in [50, 50, 50, 60] { h.coord.feedHR(bpm) }
        XCTAssertEqual(h.strap.buzzCount, 0, "outside the window nothing fires")

        // INSIDE the window (06:40): settle a trough, then a rise → fire exactly once.
        clock.date = self.date(2026, 6, 17, 6, 40)
        for bpm in [50, 50, 50] { h.coord.feedHR(bpm) }
        h.coord.feedHR(60)
        XCTAssertEqual(h.strap.buzzCount, 1)
        XCTAssertGreaterThanOrEqual(h.strap.disableCount, 1, "early fire drops the firmware backstop")
        XCTAssertGreaterThanOrEqual(h.notifier.cancelCount, 1, "and cancels the backup so it can't double-fire")
        XCTAssertGreaterThanOrEqual(h.notifier.postCount, 1)
        // The latest-edge deadline is never pushed later or dropped by a detection.
        XCTAssertEqual(h.settings.scheduledDeadlineEpoch, deadlineBefore)
    }

    @MainActor
    func testEarlyFire_notAfterDeadline() {
        let clock = Clock(date(2026, 6, 17, 6, 0))
        let h = harness(now: { clock.date }, watcher: SmartWakeWatcher(riseBpm: 6, minSamples: 3, troughCeilingBpm: 90))
        h.live.encryptedBond = true; h.live.connected = true; h.live.worn = true
        h.settings.enabled = true
        h.coord.apply()   // deadline = today 07:00
        clock.date = self.date(2026, 6, 17, 7, 5)   // past the deadline
        for bpm in [50, 50, 50, 60] { h.coord.feedHR(bpm) }
        XCTAssertEqual(h.strap.buzzCount, 0)
    }

    // MARK: - Double-fire guard

    @MainActor
    func testDoubleFireGuard_andNextDayResets() {
        let clock = Clock(date(2026, 6, 17, 6, 0))
        let h = harness(now: { clock.date }, watcher: SmartWakeWatcher(riseBpm: 6, minSamples: 3, troughCeilingBpm: 90))
        h.live.encryptedBond = true; h.live.connected = true; h.live.worn = true
        h.settings.enabled = true
        h.coord.apply()

        clock.date = self.date(2026, 6, 17, 6, 40)
        for bpm in [50, 50, 50] { h.coord.feedHR(bpm) }
        h.coord.feedHR(60)
        XCTAssertEqual(h.strap.buzzCount, 1)

        // Same night: further rises / a strap-fired signal must NOT buzz again.
        h.coord.feedHR(70)
        h.coord.onStrapFired()
        XCTAssertEqual(h.strap.buzzCount, 1, "the night is already fired — no second buzz")

        // Next day: the daily re-arm resets the night, so a fresh rise can fire again.
        clock.date = self.date(2026, 6, 18, 6, 0)
        h.coord.apply()
        clock.date = self.date(2026, 6, 18, 6, 40)
        for bpm in [52, 52, 52] { h.coord.feedHR(bpm) }
        h.coord.feedHR(62)
        XCTAssertEqual(h.strap.buzzCount, 2)
    }

    /// C6: an early fire cancels only TODAY's single backup; the next daily `apply()` re-arms the backup
    /// for the following occurrence. Because the OS backup is a SINGLE (non-repeating) request, cancelling
    /// it on an early wake can't wipe every future day's wake — a repeating trigger would have.
    @MainActor
    func testEarlyFire_doesNotWipeFutureBackups() {
        let clock = Clock(date(2026, 6, 17, 6, 0))
        let h = harness(now: { clock.date },
                        watcher: SmartWakeWatcher(riseBpm: 6, minSamples: 3, troughCeilingBpm: 90))
        h.live.encryptedBond = true; h.live.connected = true; h.live.worn = true
        h.settings.enabled = true
        h.coord.apply()   // arms today's single backup
        XCTAssertEqual(h.notifier.pendingBackupMinute, h.settings.latestMin)

        // Early fire inside the window drops today's single backup.
        clock.date = self.date(2026, 6, 17, 6, 40)
        for bpm in [50, 50, 50] { h.coord.feedHR(bpm) }
        h.coord.feedHR(60)
        XCTAssertEqual(h.strap.buzzCount, 1)
        XCTAssertNil(h.notifier.pendingBackupMinute, "early fire cancels today's backup")

        // A same-day re-apply must NOT re-arm the already-fired deadline (the double-fire guard).
        h.coord.apply()
        XCTAssertNil(h.notifier.pendingBackupMinute, "the already-fired deadline is not re-scheduled today")

        // Next day: apply() re-arms the backup for the next occurrence — future wakes are intact.
        clock.date = self.date(2026, 6, 18, 6, 0)
        h.coord.apply()
        XCTAssertEqual(h.notifier.pendingBackupMinute, h.settings.latestMin,
                       "the daily re-arm restores the backup for the next occurrence")
    }

    /// After an early fire, force-quitting and relaunching INSIDE the same window must NOT re-arm the
    /// backstop the fire dropped (the double-fire guard is persisted, not in-memory only).
    @MainActor
    func testFiredDeadlinePersists_noReArmAfterRelaunch() {
        let suite = "wm.test.alarm.relaunch.\(UUID().uuidString)"
        let clock = Clock(date(2026, 6, 17, 6, 0))

        // Session 1: arm + early-fire at 06:40.
        let s1 = SmartAlarmSettings(defaults: volatileDefaults(suite))
        let live1 = LiveState(); live1.encryptedBond = true; live1.connected = true; live1.worn = true
        let strap1 = FakeStrap(); let notif1 = FakeNotifier()
        let c1 = SmartAlarmCoordinator(ble: strap1, live: live1, settings: s1, notifier: notif1,
                                       watcher: SmartWakeWatcher(riseBpm: 6, minSamples: 3, troughCeilingBpm: 90),
                                       now: { clock.date }, calendar: utc)
        s1.enabled = true
        c1.apply()
        XCTAssertEqual(strap1.armCount, 1)
        clock.date = date(2026, 6, 17, 6, 40)
        for bpm in [50, 50, 50] { c1.feedHR(bpm) }; c1.feedHR(60)
        XCTAssertEqual(strap1.buzzCount, 1)
        XCTAssertEqual(strap1.disableCount, 1, "early fire drops the backstop")

        // Session 2 (relaunch): fresh coordinator + settings on the SAME suite, still inside the window.
        clock.date = date(2026, 6, 17, 6, 50)
        let s2 = SmartAlarmSettings(defaults: UserDefaults(suiteName: suite)!)   // reads persisted fired flag
        let live2 = LiveState(); live2.encryptedBond = true; live2.connected = true; live2.worn = true
        let strap2 = FakeStrap(); let notif2 = FakeNotifier()
        let c2 = SmartAlarmCoordinator(ble: strap2, live: live2, settings: s2, notifier: notif2,
                                       watcher: SmartWakeWatcher(riseBpm: 6, minSamples: 3, troughCeilingBpm: 90),
                                       now: { clock.date }, calendar: utc)
        c2.apply()
        XCTAssertEqual(strap2.armCount, 0, "relaunch must not re-arm the already-fired backstop")
        XCTAssertEqual(notif2.scheduleCount, 0, "relaunch must not re-schedule the backup")
        for bpm in [50, 50, 50] { c2.feedHR(bpm) }; c2.feedHR(60)
        XCTAssertEqual(strap2.buzzCount, 0, "relaunch must not buzz a second time")
    }

    // MARK: - Harness

    @MainActor
    private func harness(now: Date) -> Harness { harness(now: { now }) }

    @MainActor
    private func harness(now: @escaping () -> Date,
                         watcher: SmartWakeWatcher = SmartWakeWatcher()) -> Harness {
        let strap = FakeStrap()
        let notifier = FakeNotifier()
        let live = LiveState()
        let sched = ManualScheduler()
        let settings = SmartAlarmSettings(defaults: volatileDefaults("wm.test.alarm.coord.\(UUID().uuidString)"))
        let coord = SmartAlarmCoordinator(ble: strap, live: live, settings: settings,
                                          notifier: notifier, watcher: watcher,
                                          now: now, calendar: utc,
                                          schedule: { delay, work in sched.pending.append((delay, work)) })
        return Harness(coord: coord, strap: strap, notifier: notifier, live: live, settings: settings, sched: sched)
    }

    @MainActor
    private struct Harness {
        let coord: SmartAlarmCoordinator
        let strap: FakeStrap
        let notifier: FakeNotifier
        let live: LiveState
        let settings: SmartAlarmSettings
        let sched: ManualScheduler
    }

    private func volatileDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
}

// MARK: - Fakes

private final class Clock {
    var date: Date
    init(_ d: Date) { self.date = d }
}

/// Queues the coordinator's verify-loop timers so a test fires them by hand, in order.
private final class ManualScheduler {
    var pending: [(delay: TimeInterval, work: () -> Void)] = []
    /// Fire everything queued so far (not what those closures queue in turn).
    func fireAll() {
        let batch = pending
        pending.removeAll()
        batch.forEach { $0.work() }
    }
}

@MainActor
private final class FakeStrap: AlarmStrap {
    /// The acked pair — the only arm/drop the coordinator calls.
    var armCount = 0
    var lastArmDate: Date?
    var disableCount = 0
    /// The legacy unacked methods, which must stay uncalled.
    var legacyArmCount = 0
    var legacyDisableCount = 0
    var buzzCount = 0
    var verifiable = true
    var backstopVerifiable: Bool { verifiable }
    func armBackstop(at date: Date) { armCount += 1; lastArmDate = date }
    func dropBackstop() { disableCount += 1 }
    func armStrapAlarm(at date: Date) { legacyArmCount += 1 }
    func disableStrapAlarm() { legacyDisableCount += 1 }
    func buzzStrapOnce() { buzzCount += 1 }
    func buzzStrap(loops: Int) { buzzCount += 1 }
}

private final class FakeNotifier: WakeNotifier {
    var log: ((String) -> Void)?
    /// Models the real notifier's fixed-identifier replace: at most one pending backup at a time.
    var pendingBackupMinute: Int?
    var scheduleCount = 0
    var cancelCount = 0
    var postCount = 0
    func scheduleBackup(atMinute minute: Int) { scheduleCount += 1; pendingBackupMinute = minute }
    func cancelBackup() { cancelCount += 1; pendingBackupMinute = nil }
    func postWakeNow() { postCount += 1 }
}
