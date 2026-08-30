import XCTest
import StrapStore
@testable import whoopmaxx

/// The launch sweep that repairs ORPHANED `liveSession` rows — the ones `upsertLiveSession`'s start call
/// created and whose matching end call never ran (a link drop or process kill in between; the v22
/// migration comment already assumes "the app closes it on next launch"). A real backup carries exactly
/// one: `startTs = 1784005519`, all totals zero, `BLE_CONNECTION_DOWN` two seconds after the start.
///
/// The behaviours worth pinning are the ones that make this a repair rather than an invention: the end
/// is reconstructed from the session's OWN accrued totals (never from wall-clock `now`, which on the real
/// orphan would claim 12.25 days), an in-flight session is left open, an already-closed row is not
/// touched, and the sweep is idempotent because the upsert is keyed by `(deviceId, startTs)`.
final class LiveSessionRecoveryTests: XCTestCase {

    private let deviceId = "my-whoop"
    /// Comfortably past the 24 h staleness cap.
    private var staleStart: Int { Int(Date().timeIntervalSince1970) - 48 * 3_600 }

    func testProductiveOrphanIsClosedFromItsOwnTotals() async throws {
        let (store, dir) = try await Fixtures.tempStore("live-session-close")
        defer { Fixtures.cleanUp(dir) }
        // The invariant every healthy row in the real backup satisfies, to the second:
        // inBandSec + belowSec + aboveSec == endTs - startTs.
        let start = staleStart
        try await store.upsertLiveSession(row(startTs: start, endTs: nil, chargeAtStart: 68.5,
                                              inBandSec: 600, belowSec: 90, aboveSec: 30),
                                          deviceId: deviceId)

        let closed = await LiveSessionRecovery.sweepStaleOpenSessions(store: store, deviceId: deviceId)

        XCTAssertEqual(closed, 1)
        let rows = try await store.recentLiveSessions(deviceId: deviceId, limit: 10)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.endTs, start + 720,
                       "endTs must reconstruct the coverage the session actually accrued; `now` would "
                       + "invent wall-clock time it never guarded (12.25 days of it, on the real orphan)")
        XCTAssertEqual(row.chargeAtStart, 68.5, "the repair fills in endTs and changes nothing else")
        XCTAssertEqual(row.inBandSec, 600)
    }

    func testEmptyOrphanClosesAtZeroLengthNotAtNow() async throws {
        let (store, dir) = try await Fixtures.tempStore("live-session-orphan")
        defer { Fixtures.cleanUp(dir) }
        // The real orphan's shape: a start-upsert with a guarded band and a Charge, and nothing else.
        // It recorded nothing, so the honest close is zero-length — NOT `now`, which would claim the
        // whole 12 days since the link died as guarded time.
        let start = staleStart
        try await store.upsertLiveSession(row(startTs: start, endTs: nil, chargeAtStart: 62.9),
                                          deviceId: deviceId)

        let closed = await LiveSessionRecovery.sweepStaleOpenSessions(store: store, deviceId: deviceId)

        XCTAssertEqual(closed, 1)
        let rows = try await store.recentLiveSessions(deviceId: deviceId, limit: 10)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.endTs, start,
                       "a session that accrued zero seconds closes at zero length — the `endTs ?? 0` "
                       + "hazard (−1 784 005 519 s on this row) is gone either way")
    }

    func testInFlightSessionIsLeftOpen() async throws {
        let (store, dir) = try await Fixtures.tempStore("live-session-inflight")
        defer { Fixtures.cleanUp(dir) }
        // Younger than the 24 h staleness cap — once the feature IS wired this is a session someone is
        // in the middle of, and closing it out from under them would be the bug.
        let start = Int(Date().timeIntervalSince1970) - 60
        try await store.upsertLiveSession(row(startTs: start, endTs: nil, inBandSec: 55), deviceId: deviceId)

        let closed = await LiveSessionRecovery.sweepStaleOpenSessions(store: store, deviceId: deviceId)

        XCTAssertEqual(closed, 0)
        let rows = try await store.recentLiveSessions(deviceId: deviceId, limit: 10)
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.endTs, "a session inside the staleness cap is in progress, not orphaned")
    }

    func testAlreadyClosedSessionIsUntouchedAndSweepIsIdempotent() async throws {
        let (store, dir) = try await Fixtures.tempStore("live-session-closed")
        defer { Fixtures.cleanUp(dir) }
        let start = staleStart
        try await store.upsertLiveSession(row(startTs: start, endTs: start + 120, inBandSec: 120),
                                          deviceId: deviceId)

        // First pass: nothing open, nothing to do. Second pass on a store the sweep already repaired
        // must also be a no-op — the upsert is keyed by (deviceId, startTs), so a re-run can neither
        // duplicate a row nor re-close one.
        let firstPass = await LiveSessionRecovery.sweepStaleOpenSessions(store: store, deviceId: deviceId)
        XCTAssertEqual(firstPass, 0)
        try await store.upsertLiveSession(row(startTs: start + 5_000, endTs: nil, inBandSec: 30),
                                          deviceId: deviceId)
        let repairPass = await LiveSessionRecovery.sweepStaleOpenSessions(store: store, deviceId: deviceId)
        XCTAssertEqual(repairPass, 1)
        let rerunPass = await LiveSessionRecovery.sweepStaleOpenSessions(store: store, deviceId: deviceId)
        XCTAssertEqual(rerunPass, 0)

        let rows = try await store.recentLiveSessions(deviceId: deviceId, limit: 10)
        XCTAssertEqual(rows.count, 2, "the repair replaces rows by natural key; it never inserts")
        XCTAssertEqual(rows.first(where: { $0.startTs == start })?.endTs, start + 120,
                       "an already-closed row keeps the endTs its own close path wrote")
    }

    // MARK: - Support

    private func row(startTs: Int, endTs: Int?, chargeAtStart: Double? = nil,
                     inBandSec: Double = 0, belowSec: Double = 0, aboveSec: Double = 0) -> LiveSessionRow {
        LiveSessionRow(startTs: startTs, endTs: endTs, chargeAtStart: chargeAtStart,
                       floorBpm: 133.3, ceilingBpm: 155.8,
                       inBandSec: inBandSec, belowSec: belowSec, aboveSec: aboveSec,
                       pushCount: 0, easeCount: 0, hrSource: "whoop")
    }
}
