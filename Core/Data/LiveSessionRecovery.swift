import Foundation
import StrapStore

/// Launch-time repair for ORPHANED `liveSession` rows — a row whose `endTs` is still NULL long after the
/// session could possibly still be running.
///
/// `upsertLiveSession` is called twice per session (natural key `(deviceId, startTs)`): once at start
/// with `endTs: nil`, once at end with the final totals. If the process dies between the two — the case
/// the v22 migration comment already anticipates ("a crash/kill leaves it open; the app closes it on
/// next launch") — nothing ever repairs the NULL. Nothing in whoopmaxx did that close, so the row is
/// permanent: `BackupImport` replaces the store file wholesale and `WmBackup` zips `store.sqlite`
/// verbatim, so an orphan round-trips into every `.wmbak` forever.
///
/// Confirmed on a real backup: `startTs = 1784005519` carries a start-upsert (chargeAtStart 62.9, a
/// guarded band of 133–156 bpm) and all-zero totals, and the strap's own event log dates the cause to
/// the second — `BLE_CONNECTION_DOWN` at `startTs + 2 s`, followed by an 11h54m hole in realtime-HR
/// events. The link died two seconds in and the close never ran. The three healthy rows in the same
/// table all satisfy `inBandSec + belowSec + aboveSec == endTs − startTs` EXACTLY, which is what makes
/// the repair below reconstructive rather than invented.
///
/// CLOSE, NEVER FABRICATE: `endTs = startTs + (inBandSec + belowSec + aboveSec)` restores the coverage
/// the session actually accrued. `endTs = now` would invent wall-clock time it never guarded — 12.25
/// days of it, on the real orphan. An orphan that accrued NOTHING therefore closes at
/// `endTs == startTs`, the honest "this session recorded nothing" value; a reader is expected to treat a
/// zero-length session as having nothing to show, exactly as `WorkoutSessionController.endWorkout()`
/// already discards a bout with fewer than two samples. (Deleting such a row outright would be tidier
/// still, but `StrapStore` exposes no live-session delete and this stays inside the app layer.)
///
/// The Live Sessions reader is not wired in whoopmaxx yet (`LiveSessionStore` is out of scope by
/// decision; the Live tab uses `WorkoutSessionController`), so today's blast
/// radius is zero — this sweep exists so the orphan is repaired BEFORE a reader lands and does the naive
/// `endTs ?? 0`, which on this exact row yields −1 784 005 519 s.
enum LiveSessionRecovery {

    /// How stale an open session must be before it counts as dead. Mirrors the #529 crash-recovery
    /// staleness cap `WorkoutSessionController` already uses, so a genuinely in-flight session is never
    /// closed out from under the user once the feature IS wired.
    static let staleAfterS = 24 * 3_600

    /// How many recent sessions the sweep inspects. Orphans are created one per crashed session, so the
    /// realistic count is single digits; this is simply a bound on a launch-path read.
    static let scanLimit = 500

    /// Close every stale open session for `deviceId`. Returns how many were closed, so the launch caller
    /// can log once and a test can assert. A no-op on every normal launch (one indexed read).
    @discardableResult
    static func sweepStaleOpenSessions(store: StrapStore, deviceId: String, now: Date = Date()) async -> Int {
        let cutoff = Int(now.timeIntervalSince1970) - staleAfterS
        do {
            let orphans = try await store.recentLiveSessions(deviceId: deviceId, limit: scanLimit)
                .filter { $0.endTs == nil && $0.startTs < cutoff }
            guard !orphans.isEmpty else { return 0 }
            for row in orphans {
                let covered = Swift.max(0, Int((row.inBandSec + row.belowSec + row.aboveSec).rounded()))
                // Idempotent by the natural key (deviceId, startTs) — the upsert REPLACES this row
                // rather than adding one, so a sweep that is interrupted and re-runs is harmless.
                try await store.upsertLiveSession(row.closed(at: row.startTs + covered), deviceId: deviceId)
            }
            NSLog("LiveSessionRecovery: closed \(orphans.count) stale open live session(s)")
            return orphans.count
        } catch {
            // A store that can't be read/written (locked device post-reboot) is not worth surfacing —
            // the sweep simply runs again next launch.
            NSLog("LiveSessionRecovery: sweep skipped (\(error))")
            return 0
        }
    }
}

private extension LiveSessionRow {
    /// The same session with `endTs` filled in. `LiveSessionRow` is an immutable value type, so closing
    /// one means rebuilding it; every other field is carried through untouched, since the sweep repairs
    /// the missing end and asserts nothing else about what the session recorded.
    func closed(at endTs: Int) -> LiveSessionRow {
        LiveSessionRow(startTs: startTs, endTs: endTs, chargeAtStart: chargeAtStart,
                       floorBpm: floorBpm, ceilingBpm: ceilingBpm,
                       inBandSec: inBandSec, belowSec: belowSec, aboveSec: aboveSec,
                       pushCount: pushCount, easeCount: easeCount, hrSource: hrSource)
    }
}
