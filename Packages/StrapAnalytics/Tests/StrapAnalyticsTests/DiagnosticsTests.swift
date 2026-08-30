import XCTest
@testable import StrapAnalytics

final class ClockTraceTests: XCTestCase {

    private let wall = 1_800_000_000

    func testAHealthyClockReadsOk() {
        let line = ConnectionTrace.clockDriftLine(oldestUnix: wall - 3 * 86_400,
                                                  newestUnix: wall, wallNowUnix: wall)
        XCTAssertTrue(line.hasSuffix("clockOk"))
        XCTAssertTrue(line.contains("spanDays=3"))
    }

    func testTheTwoLinesRoundTheirSpanDifferently() {
        // A real inconsistency between the two diagnostics, pinned rather than smoothed over: the
        // connection line TRUNCATES the span while the universal line ROUNDS it. A window a minute
        // shy of three days therefore reads 2 in one place and 3 in the other. Harmless for a
        // reader, confusing for anyone comparing two lines of the same report.
        let oldest = wall - (3 * 86_400 - 60)
        XCTAssertTrue(ConnectionTrace.clockDriftLine(oldestUnix: oldest, newestUnix: wall,
                                                     wallNowUnix: wall).contains("spanDays=2"))
        XCTAssertTrue(UniversalTrace.clockDriftLine(newestUnix: wall, wallNowUnix: wall,
                                                    oldestUnix: oldest).contains("spanDays=3"))
    }

    func testAFutureDatedClockIsFlagged() {
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: wall + 3600,
                                                  wallNowUnix: wall)
        XCTAssertTrue(line.contains("FUTURE-DATED"))
    }

    func testANeverSetClockIsNamedSpecifically() {
        // Reporting this as merely "behind" would send a user looking for a sync problem when the
        // fix is to charge the strap.
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: 100,
                                                  wallNowUnix: wall)
        XCTAssertTrue(line.contains("RTC-EPOCH"))
        XCTAssertTrue(line.contains("charge to 100%"))
    }

    func testAStaleClockWarns() {
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil,
                                                  newestUnix: wall - 5 * 86_400, wallNowUnix: wall)
        XCTAssertTrue(line.contains("CLOCK-WARNING"))
        XCTAssertTrue(line.contains("5d behind"))
    }

    func testTheUniversalAndConnectionLinesNeverDisagree() {
        // Two diagnostics contradicting each other is worse than either being absent.
        for newest in [wall - 60, wall + 3600, 100, wall - 5 * 86_400] {
            let a = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: newest, wallNowUnix: wall)
            let b = UniversalTrace.clockDriftLine(newestUnix: newest, wallNowUnix: wall)
            for verdict in ["clockOk", "FUTURE-DATED", "RTC-EPOCH", "CLOCK-WARNING"] {
                XCTAssertEqual(a.contains(verdict), b.contains(verdict),
                               "\(verdict) disagreed at newest=\(newest)")
            }
        }
    }

    func testTheUniversalLineRoundsItsSpan() {
        // A window a minute shy of three days should read three, not two.
        let line = UniversalTrace.clockDriftLine(newestUnix: wall,
                                                 wallNowUnix: wall,
                                                 oldestUnix: wall - (3 * 86_400 - 60))
        XCTAssertTrue(line.contains("spanDays=3"))
    }

    func testFirmwareIsReportedEvenWhenUnknown() {
        XCTAssertTrue(UniversalTrace.clockDriftLine(newestUnix: wall, wallNowUnix: wall)
                        .contains("firmware=unknown"))
        XCTAssertTrue(UniversalTrace.clockDriftLine(newestUnix: wall, wallNowUnix: wall,
                                                    firmwareLayout: 24).contains("firmware=v24"))
    }

    func testAnUnmappedLayoutSaysSoOutright() {
        // Reporting only a version leaves the reader to infer that nothing came out of it.
        XCTAssertTrue(ConnectionTrace.firmwareLine(version: 31, decodable: false).contains("UNMAPPED"))
        XCTAssertTrue(ConnectionTrace.firmwareLine(version: 24, decodable: true).contains("decodable"))
    }

    func testNoCursorLine() {
        XCTAssertTrue(ConnectionTrace.noCursorLine().contains("noCursor"))
    }
}

final class ConnectionReadoutTests: XCTestCase {

    func testUptimeStopsAtADisconnect() {
        // A "connect down" after a start means the session is over regardless of what preceded it.
        let tail = ["connect up uptimeStart=1000", "connect down"]
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: tail, nowUnix: 5000), "not connected")
    }

    func testUptimeIsFormattedByMagnitude() {
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: ["uptimeStart=1000"], nowUnix: 1030), "30s")
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: ["uptimeStart=1000"], nowUnix: 1150), "2m 30s")
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: ["uptimeStart=0"], nowUnix: 7800), "2h 10m")
    }

    func testNoUptimeLineAtAll() {
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: [], nowUnix: 100), "not connected")
    }

    func testReconnectCountTakesTheMaximumNotTheLast() {
        // The counter resets on a fresh connection, so the last line would report 0 for a session
        // that reconnected a dozen times and then settled.
        let tail = ["reconnect n=1", "reconnect n=7", "reconnect n=1"]
        XCTAssertEqual(ConnectionReadout.reconnectCount(taggedTail: tail), 7)
        XCTAssertEqual(ConnectionReadout.reconnectCount(taggedTail: []), 0)
    }

    func testLastOffloadResult() {
        let tail = ["offload result=ok rows=120", "noise", "offload result=empty (console only)"]
        XCTAssertEqual(ConnectionReadout.lastOffloadResult(taggedTail: tail), "empty (console only)")
        XCTAssertNil(ConnectionReadout.lastOffloadResult(taggedTail: ["nothing here"]))
    }

    func testAnEmptyResultMeansZeroRowsNotAnOlderTotal() {
        // A naive scan would surface the previous session's total and make an empty sync look
        // successful.
        let tail = ["sessionRows=900", "offload result=empty (console only)"]
        XCTAssertEqual(ConnectionReadout.sessionRows(taggedTail: tail), 0)
    }

    func testSessionRowsFromAResultLine() {
        XCTAssertEqual(ConnectionReadout.sessionRows(taggedTail: ["offload result=ok rows=120"]), 120)
        XCTAssertEqual(ConnectionReadout.sessionRows(taggedTail: ["sessionRows=44"]), 44)
        XCTAssertNil(ConnectionReadout.sessionRows(taggedTail: ["unrelated"]))
    }

    func testDrainedRowsSummary() {
        XCTAssertEqual(ConnectionReadout.drainedRowsFromSummary("session persisted 812 rows"), 812)
        XCTAssertNil(ConnectionReadout.drainedRowsFromSummary("session persisted 812 things"))
        XCTAssertNil(ConnectionReadout.drainedRowsFromSummary("nothing"))
    }

    func testClockCorrelatedDevice() {
        let lines = ["Clock correlated: device=1700000000 wall=1800000000", "later noise"]
        XCTAssertEqual(ConnectionReadout.clockCorrelatedDevice(logLines: lines), 1_700_000_000)
        XCTAssertNil(ConnectionReadout.clockCorrelatedDevice(logLines: ["none"]))
    }

    func testALatchedClockIsDistinguishedFromANeverSetOne() {
        XCTAssertEqual(ConnectionReadout.clockLatchedLabel(deviceClockUnix: 1_800_000_000), "yes")
        XCTAssertTrue(ConnectionReadout.clockLatchedLabel(deviceClockUnix: 100).contains("1970/71"))
        XCTAssertTrue(ConnectionReadout.clockLatchedLabel(deviceClockUnix: nil).contains("waiting"))
    }
}

final class TestDomainTests: XCTestCase {

    func testEveryDomainHasAStableRawValue() {
        XCTAssertEqual(TestDomain.dataImport.rawValue, "dataImport",
                       "import is a reserved word, so the raw value is spelled out")
        XCTAssertTrue(TestDomain.allCases.contains(.universal))
        XCTAssertEqual(Set(TestDomain.allCases.map(\.rawValue)).count, TestDomain.allCases.count)
    }

    func testAQuestionKeepsAStableIdentity() {
        // Renaming a prompt must not orphan answers already recorded against it.
        let q = Question(id: "felt_rested", prompt: "Did you feel rested?", kind: .yesNo)
        let renamed = Question(id: "felt_rested", prompt: "Rested this morning?", kind: .yesNo)
        XCTAssertEqual(q.id, renamed.id)
        XCTAssertNotEqual(q, renamed)
        XCTAssertTrue(q.choices.isEmpty, "choices are only meaningful for .choice")
    }

    func testAQuestionRoundTripsThroughCodable() throws {
        let q = Question(id: "how", prompt: "How was it?", kind: .choice, choices: ["good", "bad"])
        let back = try JSONDecoder().decode(Question.self, from: JSONEncoder().encode(q))
        XCTAssertEqual(back, q)
    }
}

final class ModuleIdentityTests: XCTestCase {
    func testVersionIsPresent() {
        XCTAssertFalse(StrapAnalytics.version.isEmpty)
    }
}
