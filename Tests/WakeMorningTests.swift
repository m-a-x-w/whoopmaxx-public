import XCTest
@testable import whoopmaxx

/// W9.5 "This morning's wake" pure surface: the `WakeConfidence` honesty rubric (each trigger + coverage
/// → expected tier/reasons/pips), the `WakeEvent` Codable round-trip + the settings ring cap, the new
/// `SmartWakeWatcher` decision-snapshot accessors, and that the coordinator records an event on both fire
/// paths. Everything here is deterministic (no clock/BLE/notifications — the fakes stand in).
final class WakeMorningTests: XCTestCase {

    // MARK: - WakeConfidence rubric

    private func earlyEvent(worn: Bool = true, bond: Bool = true) -> WakeEvent {
        WakeEvent(firedEpoch: 100, deadlineEpoch: 800, windowStartEpoch: 0,
                  trigger: .earlyWatcher, troughBpm: 52, thresholdBpm: 58,
                  connected: true, worn: worn, encryptedBond: bond)
    }

    func testConfidence_earlyWatcher_highWithPlainReasons() {
        let a = WakeConfidence.assess(event: earlyEvent(), hrCoverageFraction: 0.82, deadlinePassed: false)
        XCTAssertEqual(a.tier, .high)
        XCTAssertGreaterThan(a.score, WakeConfidence.highCutoff)
        XCTAssertTrue(a.reasons.contains("detection engaged"))
        XCTAssertTrue(a.reasons.contains("streamed 82% of the window"))
        XCTAssertTrue(a.reasons.contains("strap on your wrist"))
        XCTAssertTrue(a.reasons.contains("strap bonded"))
    }

    func testConfidence_earlyWatcher_coverageRaisesScore() {
        let hi = WakeConfidence.assess(event: earlyEvent(), hrCoverageFraction: 0.90, deadlinePassed: false)
        let lo = WakeConfidence.assess(event: earlyEvent(), hrCoverageFraction: 0.30, deadlinePassed: false)
        XCTAssertGreaterThan(hi.score, lo.score)
        // The bonus is exactly coverageWeight × the coverage delta.
        XCTAssertEqual(hi.score - lo.score, (0.90 - 0.30) * WakeConfidence.coverageWeight, accuracy: 1e-9)
    }

    func testConfidence_earlyWatcher_wornAndBondModifiers() {
        let full = WakeConfidence.assess(event: earlyEvent(worn: true, bond: true),
                                         hrCoverageFraction: 0.5, deadlinePassed: false)
        let noBond = WakeConfidence.assess(event: earlyEvent(worn: true, bond: false),
                                           hrCoverageFraction: 0.5, deadlinePassed: false)
        XCTAssertEqual(full.score - noBond.score, WakeConfidence.bondWeight, accuracy: 1e-9)
        XCTAssertFalse(noBond.reasons.contains("strap bonded"))
    }

    func testConfidence_strapBackstop_medium_honestReason() {
        let e = WakeEvent(firedEpoch: 800, deadlineEpoch: 800, windowStartEpoch: 0,
                          trigger: .strapBackstop, troughBpm: nil, thresholdBpm: nil,
                          connected: true, worn: true, encryptedBond: true)
        let a = WakeConfidence.assess(event: e, hrCoverageFraction: 0.4, deadlinePassed: true)
        XCTAssertEqual(a.tier, .medium)
        XCTAssertTrue(a.reasons.contains { $0.contains("latest edge") && $0.contains("watcher didn't run") })
        XCTAssertFalse(a.reasons.contains("detection engaged"))
    }

    func testConfidence_strapBackstop_unbonded_stillMedium() {
        let e = WakeEvent(firedEpoch: 800, deadlineEpoch: 800, windowStartEpoch: 0,
                          trigger: .strapBackstop, troughBpm: nil, thresholdBpm: nil,
                          connected: true, worn: true, encryptedBond: false)
        let a = WakeConfidence.assess(event: e, hrCoverageFraction: 0.0, deadlinePassed: true)
        XCTAssertEqual(a.tier, .medium)                       // backstopBase == mediumCutoff
        XCTAssertEqual(a.score, WakeConfidence.backstopBase, accuracy: 1e-9)
    }

    func testConfidence_noEvent_deadlinePassed_low() {
        let a = WakeConfidence.assess(event: nil, hrCoverageFraction: 0, deadlinePassed: true)
        XCTAssertEqual(a.tier, .low)
        XCTAssertEqual(a.score, WakeConfidence.inferredBackupScore, accuracy: 1e-9)
        XCTAssertTrue(a.reasons.contains { $0.contains("inferred backup") })
    }

    func testConfidence_noEvent_notPassed_zero() {
        let a = WakeConfidence.assess(event: nil, hrCoverageFraction: 0, deadlinePassed: false)
        XCTAssertEqual(a.tier, .low)
        XCTAssertEqual(a.score, 0, accuracy: 1e-9)
    }

    func testConfidence_scoreAndPipsClamp() {
        XCTAssertEqual(WakeConfidence.filledPips(for: 1.0), 5)
        XCTAssertEqual(WakeConfidence.filledPips(for: 0.0), 0)
        XCTAssertEqual(WakeConfidence.filledPips(for: 0.5), 3)   // 2.5 rounds away from zero
        XCTAssertEqual(WakeConfidence.filledPips(for: -1), 0)
        XCTAssertEqual(WakeConfidence.filledPips(for: 2), 5)
        // Score never exceeds 1 even with every early-watcher modifier maxed.
        let maxed = WakeConfidence.assess(event: earlyEvent(), hrCoverageFraction: 1, deadlinePassed: false)
        XCTAssertLessThanOrEqual(maxed.score, 1.0)
    }

    // MARK: - WakeEvent Codable round-trip

    func testWakeEvent_codableRoundTrip_earlyAndBackstop() throws {
        let early = earlyEvent()
        let backEarly = try JSONDecoder().decode(WakeEvent.self, from: JSONEncoder().encode(early))
        XCTAssertEqual(early, backEarly)

        let backstop = WakeEvent(firedEpoch: 2, deadlineEpoch: 2, windowStartEpoch: 0,
                                 trigger: .strapBackstop, troughBpm: nil, thresholdBpm: nil,
                                 connected: false, worn: true, encryptedBond: false)
        let backBackstop = try JSONDecoder().decode(WakeEvent.self, from: JSONEncoder().encode(backstop))
        XCTAssertEqual(backstop, backBackstop)
        XCTAssertNil(backBackstop.troughBpm)
        XCTAssertNil(backBackstop.thresholdBpm)
    }

    // MARK: - Settings wake-event ring (append + cap + persist)

    @MainActor
    func testWakeEventRing_capsAtRingSize_newestKept_andPersists() {
        let suite = "wm.test.wakering.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let s = SmartAlarmSettings(defaults: d)
        for i in 0..<9 {
            s.record(WakeEvent(firedEpoch: Double(i), deadlineEpoch: Double(i), windowStartEpoch: 0,
                               trigger: .earlyWatcher, troughBpm: 50, thresholdBpm: 56,
                               connected: true, worn: true, encryptedBond: true))
        }
        XCTAssertEqual(s.recentWakeEvents.count, SmartAlarmSettings.wakeEventRingSize)
        XCTAssertEqual(s.recentWakeEvents.first?.firedEpoch, 2)   // oldest two dropped (9 - 7)
        XCTAssertEqual(s.latestWakeEvent?.firedEpoch, 8)

        // A fresh instance reads the same persisted ring.
        let s2 = SmartAlarmSettings(defaults: d)
        XCTAssertEqual(s2.recentWakeEvents.count, SmartAlarmSettings.wakeEventRingSize)
        XCTAssertEqual(s2.latestWakeEvent?.firedEpoch, 8)
        d.removePersistentDomain(forName: suite)
    }

    // MARK: - Watcher decision-snapshot accessors

    func testWatcherAccessors_nilBeforeTrough_thenTrack() {
        let w = SmartWakeWatcher(riseBpm: 6, minSamples: 3, troughCeilingBpm: 90)
        XCTAssertNil(w.currentTrough)
        XCTAssertNil(w.fireThreshold)
        XCTAssertEqual(w.samplesSeen, 0)

        _ = w.shouldWake(bpm: 50)                    // first trough
        XCTAssertEqual(w.currentTrough, 50)
        XCTAssertEqual(w.fireThreshold, 56)          // 50 + riseBpm(6)
        XCTAssertEqual(w.samplesSeen, 1)

        _ = w.shouldWake(bpm: 48)                    // trough drops
        XCTAssertEqual(w.currentTrough, 48)
        XCTAssertEqual(w.fireThreshold, 54)

        _ = w.shouldWake(bpm: 120)                   // above the ceiling — not a trough candidate
        XCTAssertEqual(w.currentTrough, 48)
        XCTAssertEqual(w.samplesSeen, 3)
    }

    func testWatcherAccessors_captureValuesAtFire() {
        let w = SmartWakeWatcher(riseBpm: 6, minSamples: 3, troughCeilingBpm: 90)
        for _ in 0..<3 { _ = w.shouldWake(bpm: 50) }
        XCTAssertTrue(w.shouldWake(bpm: 58))         // +8 over the trough of 50
        XCTAssertEqual(w.currentTrough, 50)          // what the coordinator records
        XCTAssertEqual(w.fireThreshold, 56)
        XCTAssertGreaterThanOrEqual(w.samplesSeen, 4)
    }

    // MARK: - Coordinator records on both fire paths

    @MainActor
    func testCoordinator_earlyFire_recordsEarlyWatcherEvent() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let settings = freshSettings()
        let live = LiveState(); live.encryptedBond = true; live.connected = true; live.worn = true
        let coord = SmartAlarmCoordinator(ble: StubStrap(), live: live, settings: settings,
                                          notifier: StubNotifier(),
                                          watcher: SmartWakeWatcher(riseBpm: 6, minSamples: 3,
                                                                    troughCeilingBpm: 90),
                                          now: { clock.date })
        settings.enabled = true
        coord.apply()
        clock.date = Date(timeIntervalSince1970: settings.scheduledWindowStartEpoch + 10)
        for bpm in [50, 50, 50] { coord.feedHR(bpm) }
        coord.feedHR(60)

        let ev = settings.latestWakeEvent
        XCTAssertEqual(ev?.trigger, .earlyWatcher)
        XCTAssertEqual(ev?.troughBpm, 50)
        XCTAssertEqual(ev?.thresholdBpm, 56)
        XCTAssertEqual(ev?.worn, true)
        XCTAssertEqual(ev?.encryptedBond, true)
        XCTAssertEqual(ev?.deadlineEpoch, settings.scheduledDeadlineEpoch)
    }

    @MainActor
    func testCoordinator_onStrapFired_recordsBackstopEvent() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let settings = freshSettings()
        let live = LiveState(); live.encryptedBond = true; live.connected = true; live.worn = false
        let coord = SmartAlarmCoordinator(ble: StubStrap(), live: live, settings: settings,
                                          notifier: StubNotifier(), now: { clock.date })
        settings.enabled = true
        coord.apply()
        coord.onStrapFired()

        let ev = settings.latestWakeEvent
        XCTAssertEqual(ev?.trigger, .strapBackstop)
        XCTAssertNil(ev?.troughBpm)
        XCTAssertNil(ev?.thresholdBpm)
        XCTAssertEqual(ev?.worn, false)
        XCTAssertEqual(ev?.encryptedBond, true)
    }

    // MARK: - Helpers

    @MainActor
    private func freshSettings() -> SmartAlarmSettings {
        let suite = "wm.test.wake.coord.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return SmartAlarmSettings(defaults: d)
    }
}

// MARK: - Fakes (minimal — recording paths only need no-op strap/notifier)

private final class TestClock {
    var date: Date
    init(_ d: Date) { self.date = d }
}

@MainActor
private final class StubStrap: AlarmStrap {
    func armStrapAlarm(at date: Date) {}
    func disableStrapAlarm() {}
    func buzzStrapOnce() {}
    func buzzStrap(loops: Int) {}
}

private final class StubNotifier: WakeNotifier {
    var log: ((String) -> Void)?
    func scheduleBackup(atMinute minute: Int) {}
    func cancelBackup() {}
    func postWakeNow() {}
}
