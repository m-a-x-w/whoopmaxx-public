import XCTest
import StrapProtocol
import StrapStore
@testable import whoopmaxx

/// The Collector frame buffer must stay bounded in BOTH phases — pre-clock (GET_CLOCK never lands
/// while data flows) and post-clock (a sustained `store.insert` outage re-buffers each drained batch
/// at the front while `ingest` keeps appending). Regression pin for the universal `maxPreClockFrames`
/// ceiling: it was previously gated on `clockRef == nil`, so a persistent write outage grew the
/// post-clock buffer without bound (a memory leak for the outage's duration). The cap trims
/// synchronously inside `ingest`, so these tests never need a flush to run.
final class CollectorBufferCapTests: XCTestCase {

    /// Store stub — the synchronous cap trims before any cadence flush, so `insert` is never reached.
    private final class StubStore: StoreWriting {
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
    }

    /// Tiny cap, huge cadence threshold → the synchronous cap (not a flush) does the bounding.
    @MainActor
    private func makeCollector() -> Collector {
        let policy = CollectorPolicy(maxFrames: 100_000, maxInterval: 100_000, maxPreClockFrames: 10)
        return Collector(store: StubStore(), deviceId: "my-whoop", policy: policy)
    }

    /// POST-clock: with a clock ref set, the OLD pre-clock-only guard would have skipped bounding.
    @MainActor
    func testPostClockBufferBoundedByCap() {
        let c = makeCollector()
        c.clockRef = ClockRef(device: 1_000, wall: 1_000)   // post-clock steady state
        for i in 0..<200 { c.ingest([UInt8(i & 0xFF)]) }
        XCTAssertEqual(c.bufferedCount, 10, "post-clock buffer must hold at most the cap (most-recent frames)")
    }

    /// PRE-clock: the cap must still bound (unchanged behavior — no regression).
    @MainActor
    func testPreClockBufferStillBounded() {
        let c = makeCollector()   // clockRef nil → pre-clock path
        for i in 0..<200 { c.ingest([UInt8(i & 0xFF)]) }
        XCTAssertEqual(c.bufferedCount, 10)
    }

    /// Below the cap: nothing is dropped.
    @MainActor
    func testUnderCapKeepsEverything() {
        let c = makeCollector()
        c.clockRef = ClockRef(device: 1_000, wall: 1_000)
        for i in 0..<7 { c.ingest([UInt8(i)]) }
        XCTAssertEqual(c.bufferedCount, 7)
    }
}
