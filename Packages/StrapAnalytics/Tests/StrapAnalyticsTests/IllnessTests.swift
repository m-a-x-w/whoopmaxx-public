import XCTest
@testable import StrapAnalytics

final class IllnessSignalTests: XCTestCase {

    private let labels = ["restingHR": "resting HR", "skinTemp": "skin temp",
                          "hrv": "HRV", "respiration": "respiration"]

    private func reading(_ z: Double) -> IllnessSignalEngine.SignalReading {
        .init(zIllnessward: z)
    }

    private func evaluate(_ inputs: IllnessSignalEngine.Inputs,
                          _ ctx: IllnessSignalEngine.Context = .init()) -> IllnessSignalEngine.Result {
        IllnessSignalEngine.evaluate(inputs, context: ctx, firedLabels: labels)
    }

    func testNothingUpIsQuiet() {
        let r = evaluate(.init(restingHR: reading(0.2), hrv: reading(-0.1)))
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.signalCount, 0)
    }

    func testOneSignalIsNeverEnough() {
        // Any single vital drifts two sigmas often enough on its own — a bad night moves HRV that
        // far — and warning on one would fire most weeks.
        let r = evaluate(.init(restingHR: reading(6.0)))
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.signalCount, 1)
        XCTAssertGreaterThan(r.score, 0, "the score is still reported for a detail view")
    }

    func testOneExtremeSignalCannotBypassCorroborationByArithmetic() {
        // The per-signal cap is what stops a single wild reading reaching the raise threshold.
        let r = evaluate(.init(restingHR: reading(100)))
        XCTAssertLessThanOrEqual(r.score, IllnessSignalEngine.perSignalCap)
        XCTAssertEqual(r.level, .quiet)
    }

    func testTwoAgreeingSignalsRaise() {
        let r = evaluate(.init(restingHR: reading(3.5), skinTemp: reading(3.5)))
        XCTAssertEqual(r.level, .raised)
        XCTAssertEqual(r.signalCount, 2)
        XCTAssertTrue(r.copy.contains("Heads-up"))
        XCTAssertTrue(r.copy.contains("not a diagnosis"))
    }

    func testAMildCompositeStaysInTheDetailView() {
        // Two signals at 2.8 sigma: 0.8 over threshold each, 17.6 points each, 35.2 composite —
        // past mild (25) and short of raised (50).
        let r = evaluate(.init(restingHR: reading(2.8), skinTemp: reading(2.8)))
        XCTAssertEqual(r.level, .mild)
        XCTAssertGreaterThanOrEqual(r.score, IllnessSignalEngine.mildThreshold)
        XCTAssertLessThan(r.score, IllnessSignalEngine.raiseThreshold)
        XCTAssertTrue(r.copy.contains("Nothing alarming"))
    }

    func testTwoSignalsJustOverThresholdAreStillQuiet() {
        // Corroboration alone is not enough — the composite must also clear the mild floor, or a
        // pair of barely-notable drifts would surface every other week.
        let r = evaluate(.init(restingHR: reading(2.4), skinTemp: reading(2.4)))
        XCTAssertEqual(r.signalCount, 2)
        XCTAssertEqual(r.level, .quiet)
    }

    func testAnUntrustedBaselineNeverWarns() {
        // "Unusual for you" is meaningless before there is a "for you".
        let r = evaluate(.init(restingHR: reading(5), skinTemp: reading(5)),
                         .init(baselineTrusted: false))
        XCTAssertEqual(r.level, .quiet)
        XCTAssertTrue(r.copy.contains("Still learning"))
        XCTAssertGreaterThan(r.score, 0, "the working is still available")
    }

    func testALoggedConfounderDowngradesRatherThanFiring() {
        // Telling someone they might be ill the morning after a hard workout and a drink is how
        // warnings get dismissed unread.
        let strong = IllnessSignalEngine.Inputs(restingHR: reading(4), skinTemp: reading(4))
        let plain = evaluate(strong)
        let withDrink = evaluate(strong, .init(alcohol: true))
        XCTAssertEqual(plain.level, .raised)
        XCTAssertEqual(withDrink.level, .suppressed)
        XCTAssertLessThan(withDrink.score, plain.score)
        XCTAssertEqual(withDrink.suppressedBy, ["alcohol"])
        XCTAssertTrue(withDrink.copy.contains("likely that, not illness"))
    }

    func testEveryConfounderSuppresses() {
        let strong = IllnessSignalEngine.Inputs(restingHR: reading(4), skinTemp: reading(4))
        let contexts: [(IllnessSignalEngine.Context, String)] = [
            (.init(alcohol: true), "alcohol"), (.init(stress: true), "stress"),
            (.init(sauna: true), "sauna"), (.init(weed: true), "weed"),
            (.init(hardOrLateWorkout: true), "a hard or late workout"),
            (.init(travelPhaseJump: true), "travel"),
        ]
        for (ctx, name) in contexts {
            let r = evaluate(strong, ctx)
            XCTAssertEqual(r.level, .suppressed, name)
            XCTAssertEqual(r.suppressedBy, [name])
        }
    }

    func testMultipleConfoundersReadNaturally() {
        let r = evaluate(.init(restingHR: reading(4), skinTemp: reading(4)),
                         .init(alcohol: true, stress: true, sauna: true))
        XCTAssertEqual(r.suppressedBy.count, 3)
        XCTAssertTrue(r.copy.contains("alcohol, stress and sauna"))
    }

    func testAUserWhoSaysTheyAreIllIsNotWarnedAtAll() {
        // Their own report is ground truth. The job stops being to warn.
        let r = evaluate(.init(restingHR: reading(5), skinTemp: reading(5)),
                         .init(alreadyUnwell: true))
        XCTAssertEqual(r.level, .alreadyUnwell)
        XCTAssertTrue(r.copy.contains("Rest up"))
        XCTAssertTrue(r.copy.contains("numbers agree"))
        XCTAssertFalse(r.copy.contains("Heads-up"))
    }

    func testAUserWhoFeelsIllWithQuietNumbersIsStillToldToRest() {
        let r = evaluate(.init(restingHR: reading(0.1)), .init(alreadyUnwell: true))
        XCTAssertEqual(r.level, .alreadyUnwell)
        XCTAssertTrue(r.copy.contains("Take it easy"))
        XCTAssertFalse(r.copy.contains("numbers agree"), "no false corroboration")
    }

    func testAnAbsentSignalIsNotAZero() {
        let absent = IllnessSignalEngine.SignalReading(zIllnessward: 9, present: false)
        let r = evaluate(.init(restingHR: absent, skinTemp: reading(4)))
        XCTAssertEqual(r.signalCount, 1, "an unmeasured signal cannot corroborate")
        XCTAssertEqual(r.level, .quiet)
    }

    func testFiredSignalOrderIsDeterministic() {
        // The copy quotes this list; a set's iteration order would reword the same morning
        // differently on each launch.
        let inputs = IllnessSignalEngine.Inputs(restingHR: reading(4), skinTemp: reading(4),
                                                hrv: reading(4), respiration: reading(4))
        for _ in 0..<20 {
            XCTAssertEqual(evaluate(inputs).firedSignals,
                           ["resting HR", "skin temp", "HRV", "respiration"])
        }
    }

    func testScoreIsCappedAtOneHundred() {
        let r = evaluate(.init(restingHR: reading(50), skinTemp: reading(50),
                               hrv: reading(50), respiration: reading(50)))
        XCTAssertLessThanOrEqual(r.score, 100)
    }

    func testRaisedCopyDoesNotNameConfoundersItDidNotCheckIndividually() {
        // This path knows exactly one thing: none of them fired. Naming two would go stale as the
        // list grows and would claim each was ruled out on its own.
        let r = evaluate(.init(restingHR: reading(4), skinTemp: reading(4)))
        XCTAssertTrue(r.copy.contains("nothing logged to explain it"))
        XCTAssertFalse(r.copy.contains("alcohol"))
    }

    func testJoinReasons() {
        XCTAssertEqual(IllnessSignalEngine.joinReasons([]), "something")
        XCTAssertEqual(IllnessSignalEngine.joinReasons(["a"]), "a")
        XCTAssertEqual(IllnessSignalEngine.joinReasons(["a", "b"]), "a and b")
        XCTAssertEqual(IllnessSignalEngine.joinReasons(["a", "b", "c"]), "a, b and c")
    }
}
