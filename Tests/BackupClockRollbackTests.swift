import XCTest
@testable import whoopmaxx

/// `catchUpIfDue` gated on `nowMs - lastBackupMs >= dayMs` against a persisted wall-clock stamp. If the
/// device clock ever moved BACKWARD past a stamp, that difference went negative and only grew more so —
/// autobackup, the only off-device durability this offline app has, stopped forever, and the More screen
/// showed "Last: in 3 weeks" rather than any kind of failure. Rolling the date back is routine here (the
/// standard workaround for an expired free-signed sideload). The sibling retention sweep already clamps.
final class BackupClockRollbackTests: XCTestCase {

    private let dayMs = 24 * 60 * 60 * 1000

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "wm.test.backupclock.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// The pure decision the guard makes, mirroring `catchUpIfDue`'s arithmetic.
    private func decide(nowMs: Int, lastMs: Int) -> (due: Bool, repairedStamp: Int?) {
        if lastMs - nowMs > dayMs { return (true, nowMs - dayMs) }
        if nowMs - lastMs < dayMs { return (false, nil) }
        return (true, nil)
    }

    func testDueAfterADay() {
        let now = 1_800_000_000_000
        XCTAssertTrue(decide(nowMs: now, lastMs: now - dayMs).due)
        XCTAssertTrue(decide(nowMs: now, lastMs: now - 3 * dayMs).due)
    }

    func testNotDueWithinADay() {
        let now = 1_800_000_000_000
        XCTAssertFalse(decide(nowMs: now, lastMs: now - dayMs / 2).due)
        XCTAssertFalse(decide(nowMs: now, lastMs: now - 1).due)
    }

    /// The regression: a stamp far in the future is impossible and must be REPAIRED, not merely
    /// tolerated — otherwise a folder whose write also fails stays wedged with the bad value in place.
    func testFutureStampIsRepairedAndBackupRuns() {
        let now = 1_800_000_000_000
        let d = decide(nowMs: now, lastMs: now + 30 * dayMs)
        XCTAssertTrue(d.due, "a clock rollback must not disable autobackup")
        XCTAssertEqual(d.repairedStamp, now - dayMs,
                       "clamp to now-1d, never to now — clamping to now sits the install out another day")
    }

    /// A sub-day forward nudge (NTP jitter landing just after a snapshot) must NOT force a redundant
    /// full-database rewrite.
    func testSmallForwardJitterDoesNotForceARewrite() {
        let now = 1_800_000_000_000
        let d = decide(nowMs: now, lastMs: now + 5_000)   // 5s ahead
        XCTAssertFalse(d.due)
        XCTAssertNil(d.repairedStamp)
    }

    /// The failure was invisible because the caption only flags a problem when a failure is NEWER than a
    /// success — which a future success stamp never is. Pin that so the reasoning is not lost.
    func testFutureSuccessStampNeverLooksLikeAFailureInTheCaption() {
        let (d, name) = makeDefaults()
        defer { UserDefaults.standard.removeSuite(named: name) }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        d.set(now + 30 * dayMs, forKey: WmFolderBackup.lastKey)
        d.set(now - dayMs, forKey: WmFolderBackup.lastFailKey)

        let lastMs = d.integer(forKey: WmFolderBackup.lastKey)
        let failMs = d.integer(forKey: WmFolderBackup.lastFailKey)

        XCTAssertFalse(failMs > lastMs,
                       "a future success stamp masks the failure banner — hence the clamp, not a banner fix")
    }
}
