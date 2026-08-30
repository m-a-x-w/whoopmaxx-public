import XCTest
import StrapProtocol
import StrapStore
@testable import whoopmaxx

/// #547 session-relative ingest gate — the WIRING, not the predicate (`HistoricalTimestampGateTests` in
/// StrapProtocol already pins the predicate). The gate shipped dead: `Backfiller.begin` cleared the
/// GET_DATA_RANGE markers, and because the range is requested exactly once per connection — inside a
/// handshake that then defers the first offload by 1.5 s — the clear always landed AFTER the markers
/// arrived and BEFORE the offload that needed them. Every real sync therefore ran with (nil, nil).
@MainActor
final class SessionRangeGateTests: XCTestCase {

    private func makeBackfiller(deviceId: String = "my-whoop") -> Backfiller {
        Backfiller(store: FakeBackfillStore(), deviceId: deviceId, ackTrim: { _, _ in })
    }

    /// The regression itself: markers published by the connect handshake must survive into the offload.
    func testBeginKeepsSessionRangeMarkersWithinAFamily() {
        let b = makeBackfiller()
        b.begin(family: .whoop4)          // establish the family first, as a real connect does
        b.sessionOldestUnix = 1_752_537_600   // 2025-07-15
        b.sessionNewestUnix = 1_754_352_000   // 2025-08-05

        b.begin(family: .whoop4)          // a later trigger (.periodic / .foreground / .autoContinue)

        XCTAssertEqual(b.sessionOldestUnix, 1_752_537_600,
                       "begin() must not wipe the markers — nothing re-requests GET_DATA_RANGE afterwards")
        XCTAssertEqual(b.sessionNewestUnix, 1_754_352_000)
    }

    /// The clear that actually fires. A 5/MG never gets a range reply (`.getDataRange` is not in the
    /// puffin allowlist), so a WHOOP 4's latched `oldest` would gate — and permanently discard, since
    /// `finishChunk` acks regardless — the 5/MG's deep backlog.
    func testFamilySwitchClearsSessionRangeMarkers() {
        let b = makeBackfiller()
        b.begin(family: .whoop4)
        b.sessionOldestUnix = 1_752_537_600
        b.sessionNewestUnix = 1_754_352_000

        b.begin(family: .whoop5)

        XCTAssertNil(b.sessionOldestUnix, "one family's window must never gate the other's offload")
        XCTAssertNil(b.sessionNewestUnix)
    }

    /// Belt-and-braces path: kept correct in case the WHOOP<->WHOOP switch is ever wired up
    /// (`BLEManager.setActiveDeviceId` currently has no call site).
    func testStrapIdentityChangeClearsSessionRangeMarkers() {
        let b = makeBackfiller()
        b.sessionOldestUnix = 1_752_537_600
        b.sessionNewestUnix = 1_754_352_000

        b.deviceId = "my-whoop-2"

        XCTAssertNil(b.sessionOldestUnix, "a different strap's window must never be reused")
        XCTAssertNil(b.sessionNewestUnix)
    }

    func testSameDeviceIdAssignmentKeepsMarkers() {
        let b = makeBackfiller(deviceId: "my-whoop")
        b.sessionOldestUnix = 1_752_537_600
        b.sessionNewestUnix = 1_754_352_000

        b.deviceId = "my-whoop"   // re-asserting the same id must not count as a strap change

        XCTAssertEqual(b.sessionOldestUnix, 1_752_537_600)
        XCTAssertEqual(b.sessionNewestUnix, 1_754_352_000)
    }

    // MARK: - Upper-bound clamp

    /// Reviving the gate makes it able to DROP records, so the upper bound is clamped to wall-now: a
    /// `newest` that latched a stale/wrong-epoch value (the #451 shape) would otherwise reject every
    /// genuinely recent record — silent loss of exactly the data the user most wants.
    func testGateBoundsClampStaleNewestToWallNow() {
        let b = makeBackfiller()
        let now = Int(Date().timeIntervalSince1970)
        b.sessionOldestUnix = now - 30 * 86_400
        b.sessionNewestUnix = now - 400 * 86_400   // strap reported a newest over a year stale

        let bounds = b.gateSessionBounds
        XCTAssertEqual(bounds.oldest, now - 30 * 86_400, "the lower bound is the half that catches pollution")
        XCTAssertGreaterThanOrEqual(bounds.newest ?? 0, now,
                                    "a stale newest must not become an upper bound that rejects today's records")

        // …and a record captured right now survives the gate with those bounds.
        XCTAssertTrue(isPlausibleHistoricalUnix(now, wallNow: now,
                                                sessionOldestUnix: bounds.oldest,
                                                sessionNewestUnix: bounds.newest))
    }

    /// A healthy window is passed through untouched apart from the clamp, and still rejects the
    /// months-off pollution the gate exists for.
    func testHealthyWindowStillRejectsWanderingClockPollution() {
        let b = makeBackfiller()
        let now = Int(Date().timeIntervalSince1970)
        b.sessionOldestUnix = now - 21 * 86_400
        b.sessionNewestUnix = now

        let bounds = b.gateSessionBounds
        let polluted = now - 400 * 86_400   // clears the absolute 2023-11 floor, months outside the window
        XCTAssertFalse(isPlausibleHistoricalUnix(polluted, wallNow: now,
                                                 sessionOldestUnix: bounds.oldest,
                                                 sessionNewestUnix: bounds.newest),
                       "a record dated far before the strap's own oldest marker is wandering-clock pollution")
        XCTAssertTrue(isPlausibleHistoricalUnix(now - 10 * 86_400, wallNow: now,
                                                sessionOldestUnix: bounds.oldest,
                                                sessionNewestUnix: bounds.newest),
                      "real history inside the window is always kept")
    }

    /// A strap whose RTC is set AHEAD (#928) publishes a window in strap-RTC epoch while the extractor
    /// rebases every record back to wall epoch (FIX #72/#471). Applying that window would put the LOWER
    /// bound in the future and reject the entire offload — which `finishChunk` still acks, freeing the
    /// strap's only copy. The window must be voided, not clamped.
    func testFutureDatedWindowIsVoidedNotApplied() {
        let b = makeBackfiller()
        let now = Int(Date().timeIntervalSince1970)
        b.sessionOldestUnix = now + 27 * 86_400
        b.sessionNewestUnix = now + 30 * 86_400

        let bounds = b.gateSessionBounds
        XCTAssertNil(bounds.oldest, "a future-dated window is in a different epoch from the records it judges")
        XCTAssertNil(bounds.newest)

        // A record correctly rebased to two days ago still survives the absolute-only gate.
        XCTAssertTrue(isPlausibleHistoricalUnix(now - 2 * 86_400, wallNow: now,
                                                sessionOldestUnix: bounds.oldest,
                                                sessionNewestUnix: bounds.newest),
                      "voiding the window must restore the known-good absolute-only behaviour")
    }

    /// No range yet (replay / import / a strap that never answered) stays byte-identical to the
    /// absolute-only gate.
    func testAbsentMarkersLeaveTheGateAbsoluteOnly() {
        let b = makeBackfiller()
        let bounds = b.gateSessionBounds
        XCTAssertNil(bounds.oldest)
        XCTAssertNil(bounds.newest)
    }
}

/// Minimal `BackfillStoreWriting` stand-in — these tests never drive a chunk through, they only pin
/// marker lifetime and the bound clamp.
private final class FakeBackfillStore: BackfillStoreWriting {
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        (hr: 0, rr: 0, events: 0, battery: 0, spo2: 0, skinTemp: 0, resp: 0, gravity: 0)
    }
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
    func setCursor(_ name: String, _ value: Int) async throws {}
}
