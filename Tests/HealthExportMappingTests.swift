import XCTest
import HealthKit
import StrapStore
@testable import whoopmaxx

/// Unit tests for the pure, store-free HealthKit export mapping (W8). No `HKHealthStore`, no auth, no
/// entitlement needed — the HK-object translation + delete/save in `HealthExport` is thin over these
/// tested value structs (mirrors ShortcutHealthExport's injectable-seam discipline).
final class HealthExportMappingTests: XCTestCase {

    private let device = "my-whoop"

    // MARK: - Sleep stages

    func testSleepStagesMapDeterministically() {
        let onset = 1_700_000_000
        // A DemoSeed-shape timeline (light/deep/rem/wake) plus one unknown token that must be dropped.
        let json = """
        [{"start":\(onset),"end":\(onset + 600),"stage":"light"},
         {"start":\(onset + 600),"end":\(onset + 1200),"stage":"deep"},
         {"start":\(onset + 1200),"end":\(onset + 1800),"stage":"rem"},
         {"start":\(onset + 1800),"end":\(onset + 2100),"stage":"wake"},
         {"start":\(onset + 2100),"end":\(onset + 2400),"stage":"bogus"}]
        """
        let session = Fixtures.sleepSession(startTs: onset, endTs: onset + 2400, stagesJSON: json)
        let cands = HealthExportMapping.sleepCandidates(from: session, deviceId: device)

        XCTAssertEqual(cands.count, 4, "the unknown stage token should be dropped")
        XCTAssertEqual(cands[0].categoryValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue) // light
        XCTAssertEqual(cands[1].categoryValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue) // deep
        XCTAssertEqual(cands[2].categoryValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue)  // rem
        XCTAssertEqual(cands[3].categoryValue, HKCategoryValueSleepAnalysis.awake.rawValue)      // wake
        // Segment bounds preserved verbatim.
        XCTAssertEqual(cands[0].startTs, onset)
        XCTAssertEqual(cands[0].endTs, onset + 600)
        // External UUID shape: wm:health:sleep:<device>:<sessionStart>:<segStart>.
        XCTAssertEqual(cands[1].externalUUID, "wm:health:sleep:\(device):\(onset):\(onset + 600)")
    }

    /// The token table now lives in `SleepStage`; the HK half is `SleepStage.hkCategoryValue`.
    func testStageTokenMappingIncludingAwakeAlias() {
        func hk(_ token: String) -> Int? { SleepStage(token: token)?.hkCategoryValue }
        XCTAssertEqual(hk("deep"), HKCategoryValueSleepAnalysis.asleepDeep.rawValue)
        XCTAssertEqual(hk("rem"), HKCategoryValueSleepAnalysis.asleepREM.rawValue)
        XCTAssertEqual(hk("light"), HKCategoryValueSleepAnalysis.asleepCore.rawValue)
        XCTAssertEqual(hk("wake"), HKCategoryValueSleepAnalysis.awake.rawValue)
        XCTAssertEqual(hk("awake"), HKCategoryValueSleepAnalysis.awake.rawValue)
        XCTAssertEqual(hk("REM"), HKCategoryValueSleepAnalysis.asleepREM.rawValue, "case-insensitive")
        XCTAssertNil(hk("n3"), "an unlisted token stays a silent drop")
    }

    func testSleepCandidatesEmptyWhenNoTimeline() {
        let noStages = Fixtures.sleepSession(startTs: 1, endTs: 2)
        XCTAssertTrue(HealthExportMapping.sleepCandidates(from: noStages, deviceId: device).isEmpty)
    }

    // MARK: - Vitals

    func testVitalCandidatesUnitsAndNilHandling() {
        let m = Fixtures.dailyMetric(day: "2026-07-14", restingHr: 52, avgHrv: 74.2,
                                     spo2Pct: 96.5, respRateBpm: 14.5)
        let cands = HealthExportMapping.vitalCandidates(from: m, deviceId: device)
        XCTAssertEqual(cands.count, 4)

        func candidate(_ id: HKQuantityTypeIdentifier) -> HealthExportMapping.VitalCandidate? {
            cands.first { $0.typeId == id.rawValue }
        }
        let hrv = candidate(.heartRateVariabilitySDNN)
        XCTAssertEqual(hrv?.unit, .millisecondsSDNN)
        XCTAssertEqual(hrv?.value ?? .nan, 74.2, accuracy: 1e-9)   // SDNN in ms

        let rhr = candidate(.restingHeartRate)
        XCTAssertEqual(rhr?.unit, .countPerMinute)
        XCTAssertEqual(rhr?.value ?? .nan, 52, accuracy: 1e-9)     // count/min

        let resp = candidate(.respiratoryRate)
        XCTAssertEqual(resp?.unit, .countPerMinute)
        XCTAssertEqual(resp?.value ?? .nan, 14.5, accuracy: 1e-9)  // count/min

        let spo2 = candidate(.oxygenSaturation)
        XCTAssertEqual(spo2?.unit, .fraction)
        XCTAssertEqual(spo2?.value ?? .nan, 0.965, accuracy: 1e-9) // %/100 → 0–1 fraction

        // All four nil → zero candidates (honesty: never a fabricated 0).
        XCTAssertTrue(HealthExportMapping.vitalCandidates(from: Fixtures.dailyMetric(day: "2026-07-14"),
                                                          deviceId: device).isEmpty)
    }

    func testExternalUUIDStableAndScoped() {
        let m1 = Fixtures.dailyMetric(day: "2026-07-14", avgHrv: 70)
        let a = HealthExportMapping.vitalCandidates(from: m1, deviceId: device)[0]
        let b = HealthExportMapping.vitalCandidates(from: m1, deviceId: device)[0]
        XCTAssertEqual(a.externalUUID, b.externalUUID, "deterministic for (device, type, day)")

        // Changes with the day → a re-export replaces the day's sample rather than duplicating.
        let nextDay = HealthExportMapping.vitalCandidates(
            from: Fixtures.dailyMetric(day: "2026-07-15", avgHrv: 70), deviceId: device)[0]
        XCTAssertNotEqual(a.externalUUID, nextDay.externalUUID)

        // Changes with the device id.
        let otherDevice = HealthExportMapping.vitalCandidates(from: m1, deviceId: "other")[0]
        XCTAssertNotEqual(a.externalUUID, otherDevice.externalUUID)

        // Per-type unique within a day (so RHR and HRV never collide on one external UUID).
        let both = HealthExportMapping.vitalCandidates(
            from: Fixtures.dailyMetric(day: "2026-07-14", restingHr: 50, avgHrv: 70), deviceId: device)
        XCTAssertEqual(Set(both.map(\.externalUUID)).count, both.count)
    }

    /// The bridge's orphan-safe delete keys are built from `vitalExternalUUID` while the saved samples
    /// carry the candidate's `externalUUID`; if those two ever drift, deletes stop matching prior saves
    /// and re-exports would duplicate. Lock them to the same string.
    func testVitalExternalUUIDMatchesCandidateKey() {
        let m = Fixtures.dailyMetric(day: "2026-07-14", avgHrv: 70)
        let c = HealthExportMapping.vitalCandidates(from: m, deviceId: device)[0]
        XCTAssertEqual(c.externalUUID,
                       HealthExportMapping.vitalExternalUUID(typeId: c.typeId, deviceId: device, day: m.day))
    }

    // MARK: - Fingerprints (skip-gate)

    func testDayVitalsFingerprintChangesOnValueChange() {
        let base = Fixtures.dailyMetric(day: "2026-07-14", restingHr: 52, avgHrv: 74,
                                        spo2Pct: 96, respRateBpm: 14)
        let same = Fixtures.dailyMetric(day: "2026-07-14", restingHr: 52, avgHrv: 74,
                                        spo2Pct: 96, respRateBpm: 14)
        XCTAssertEqual(HealthExportMapping.dayVitalsFingerprint(base),
                       HealthExportMapping.dayVitalsFingerprint(same), "unchanged → skip")

        let rhrMoved = Fixtures.dailyMetric(day: "2026-07-14", restingHr: 53, avgHrv: 74,
                                            spo2Pct: 96, respRateBpm: 14)
        XCTAssertNotEqual(HealthExportMapping.dayVitalsFingerprint(base),
                          HealthExportMapping.dayVitalsFingerprint(rhrMoved), "RHR change → re-export")

        let rhrGone = Fixtures.dailyMetric(day: "2026-07-14", restingHr: nil, avgHrv: 74,
                                           spo2Pct: 96, respRateBpm: 14)
        XCTAssertNotEqual(HealthExportMapping.dayVitalsFingerprint(base),
                          HealthExportMapping.dayVitalsFingerprint(rhrGone), "present→nil differs")
    }

    func testSessionStagesFingerprintChangesOnStagesOrEnd() {
        let onset = 1_700_000_000
        let json = "[{\"start\":\(onset),\"end\":\(onset + 600),\"stage\":\"light\"}]"
        func session(end: Int, stages: String) -> CachedSleepSession {
            Fixtures.sleepSession(startTs: onset, endTs: end, stagesJSON: stages)
        }
        let base = session(end: onset + 600, stages: json)
        XCTAssertEqual(HealthExportMapping.sessionStagesFingerprint(base),
                       HealthExportMapping.sessionStagesFingerprint(session(end: onset + 600, stages: json)))

        // endTs moved (a re-detected wake time).
        XCTAssertNotEqual(HealthExportMapping.sessionStagesFingerprint(base),
                          HealthExportMapping.sessionStagesFingerprint(session(end: onset + 900, stages: json)))

        // stagesJSON restaged.
        let restaged = "[{\"start\":\(onset),\"end\":\(onset + 600),\"stage\":\"deep\"}]"
        XCTAssertNotEqual(HealthExportMapping.sessionStagesFingerprint(base),
                          HealthExportMapping.sessionStagesFingerprint(session(end: onset + 600, stages: restaged)))
    }

    func testStableHashIsDeterministicAcrossValues() {
        // Deterministic (a persisted fingerprint must still match next launch — no per-process seeding).
        XCTAssertEqual(HealthExportMapping.stableHash("hello"), HealthExportMapping.stableHash("hello"))
        XCTAssertNotEqual(HealthExportMapping.stableHash("hello"), HealthExportMapping.stableHash("hell0"))
        XCTAssertEqual(HealthExportMapping.stableHash(""), HealthExportMapping.stableHash(""))
    }

    // MARK: - Merged-read precedence (the bridge reads repo's imported-over-computed caches)

    func testMergedReadPrecedenceThroughRepository() {
        // Imported RHR wins field-by-field; computed HRV fills the imported nil — so Health never gets a
        // computed value the dashboard overrode.
        let computed = Fixtures.dailyMetric(day: "2026-07-14", restingHr: 55, avgHrv: 60)
        let imported = Fixtures.dailyMetric(day: "2026-07-14", restingHr: 50, avgHrv: nil)
        let merged = Repository.mergeDaily(imported: [imported], computed: [computed])
        XCTAssertEqual(merged.count, 1)

        let cands = HealthExportMapping.vitalCandidates(from: merged[0], deviceId: device)
        func value(_ id: HKQuantityTypeIdentifier) -> Double? { cands.first { $0.typeId == id.rawValue }?.value }
        XCTAssertEqual(value(.restingHeartRate), 50, "imported RHR wins")
        XCTAssertEqual(value(.heartRateVariabilitySDNN), 60, "computed HRV fills the imported nil")
    }
}
