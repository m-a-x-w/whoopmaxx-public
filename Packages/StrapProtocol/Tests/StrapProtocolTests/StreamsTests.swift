import XCTest
@testable import StrapProtocol

final class StreamsTests: XCTestCase {

    func testEmptyStreamsIsEmpty() {
        XCTAssertTrue(Streams().isEmpty)
    }

    func testAnySingleLaneMakesItNonEmpty() {
        // isEmpty is the silent-data-loss signal: a chunk whose frames all dropped looks
        // identical to a quiet strap unless every lane is checked. Pin all eleven.
        XCTAssertFalse(Streams(hr: [HRSample(ts: 1, bpm: 60)]).isEmpty)
        XCTAssertFalse(Streams(rr: [RRInterval(ts: 1, rrMs: 900)]).isEmpty)
        XCTAssertFalse(Streams(spo2: [SpO2Sample(ts: 1, red: 1, ir: 2)]).isEmpty)
        XCTAssertFalse(Streams(skinTemp: [SkinTempSample(ts: 1, raw: 1)]).isEmpty)
        XCTAssertFalse(Streams(resp: [RespSample(ts: 1, raw: 1)]).isEmpty)
        XCTAssertFalse(Streams(gravity: [GravitySample(ts: 1, x: 0, y: 0, z: 1)]).isEmpty)
        XCTAssertFalse(Streams(steps: [StepSample(ts: 1, counter: 1)]).isEmpty)
        XCTAssertFalse(Streams(sleepState: [SleepStateSample(ts: 1, state: 2)]).isEmpty)
        XCTAssertFalse(Streams(ppgHr: [PpgHrSample(ts: 1, bpm: 60)]).isEmpty)
        XCTAssertFalse(Streams(events: [WhoopEvent(ts: 1, kind: "k", payload: [:])]).isEmpty)
        XCTAssertFalse(Streams(battery: [BatterySample(ts: 1, soc: 50, mv: 3800)]).isEmpty)
    }

    func testDroppedImplausibleDoesNotRoundTripThroughCodable() throws {
        // It is a transient diagnostic, not data. If it serialised it would start appearing in
        // stored fixtures and shifting them.
        var s = Streams(hr: [HRSample(ts: 10, bpm: 61)])
        s.droppedImplausible = 7
        let back = try JSONDecoder().decode(Streams.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.droppedImplausible, 0)
        XCTAssertEqual(back.hr, s.hr, "the real lanes still round-trip")
    }

    func testRawAdcLanesLabelTheirUnit() {
        // The default is the whole point: these are ADC counts, and an unlabelled count is one
        // consumer away from being read as a physical measurement.
        XCTAssertEqual(SkinTempSample(ts: 1, raw: 100).unit, "raw_adc")
        XCTAssertEqual(SpO2Sample(ts: 1, red: 1, ir: 2).unit, "raw_adc")
        XCTAssertEqual(RespSample(ts: 1, raw: 1).unit, "raw_adc")
        XCTAssertEqual(GravitySample(ts: 1, x: 0, y: 0, z: 1).unit, "g")
    }

    func testBatteryChargingIsNilUnlessReported() {
        // Only the battery-level event carries it; nil must stay distinguishable from false.
        XCTAssertNil(BatterySample(ts: 1, soc: 50, mv: 3800).charging)
        XCTAssertEqual(BatterySample(ts: 1, soc: 50, mv: 3800, charging: false).charging, false)
    }
}
