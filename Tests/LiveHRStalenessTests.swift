import XCTest
@testable import whoopmaxx

/// The stuck-at-84 bug: a live stream that dies mid-connection (an unbonded strap throttling its
/// standard notify, a realtime arm the handshake reset) left the last rate painting forever —
/// `clearBiometrics` blanks on DISCONNECT only, and the 1 Hz sampler re-appended the stale value
/// every second. A reading older than `hrStaleAfterSeconds` with the link still up must read as
/// absent, exactly like a disconnect would render it.
@MainActor
final class LiveHRStalenessTests: XCTestCase {

    func testFreshReadingKeepsPainting() {
        let live = LiveState()
        live.noteHRSeen(now: 1_000)
        live.heartRate = 84
        live.sampleHRStream(now: 1_005)
        XCTAssertEqual(live.heartRate, 84)
        XCTAssertEqual(live.hrStream, [84])
    }

    func testSteadyRateStaysAliveAsLongAsArrivalsStamp() {
        // The change guard publishes nothing for a steady 84 — arrivals stamp anyway, so a steady
        // heart is indistinguishable from a changing one as far as staleness is concerned.
        let live = LiveState()
        live.heartRate = 84
        for t in stride(from: 1_000, through: 1_060, by: 1) { live.noteHRSeen(now: t) }
        live.sampleHRStream(now: 1_065)
        XCTAssertEqual(live.heartRate, 84)
        XCTAssertFalse(live.hrStream.isEmpty)
    }

    func testDeadStreamBlanksInsteadOfSticking() {
        let live = LiveState()
        live.noteHRSeen(now: 1_000)
        live.heartRate = 84
        live.sampleHRStream(now: 1_000 + LiveState.hrStaleAfterSeconds + 1)
        XCTAssertNil(live.heartRate, "a dead stream reads as absent, not as the last value forever")
        XCTAssertTrue(live.hrStream.isEmpty, "the strip blanks with it, matching disconnect behaviour")
    }

    func testSeededDemoWithoutArrivalStampIsNeverBlanked() {
        // Previews and the demo seeder set a rate with no arrival to stamp; a nil stamp is fresh.
        let live = LiveState()
        live.heartRate = 84
        live.sampleHRStream(now: 999_999_999)
        XCTAssertEqual(live.heartRate, 84)
    }

    func testClearBiometricsDropsTheStamp() {
        let live = LiveState()
        live.noteHRSeen(now: 1_000)
        live.clearBiometrics()
        XCTAssertNil(live.hrSeenAtUnix)
    }
}
