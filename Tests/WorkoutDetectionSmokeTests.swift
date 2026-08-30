import XCTest
import StrapProtocol
import StrapStore
import StrapAnalytics
@testable import whoopmaxx

/// Headless smoke test of the W7 detected-workout persistence CONTRACT (the mechanism ScoreEngine
/// re-enabled): a synthetic elevated-HR + gravity day yields a detected bout; persisting it under the
/// computed id round-trips as a sport="detected" row; a time-overlapping real (manual) session suppresses
/// it (the overlap-skip); and the delete-by-(sport,window)-then-upsert is idempotent under re-runs.
///
/// The full `analyzeRecent` pipeline (sleep staging, baselines, day-owner resolution) is integration
/// territory — it can't inject a fixture store (`Repository` opens the fixed default path). This test
/// exercises the exact detection engine (`WorkoutDetector.detect`) + the exact persistence primitives
/// (`deleteWorkouts` / `upsertWorkouts`) + the exact overlap rule the engine uses, against a fixture store.
final class WorkoutDetectionSmokeTests: XCTestCase {

    private let deviceId = "my-whoop"
    private let computedId = "my-whoop-computed"

    // MARK: - Fixtures

    /// A synthetic day: quiet rest at 60 bpm, then a 40-minute bout RAMPING 110 → 175 bpm with strongly
    /// oscillating gravity (motion), then rest again — enough to clear the detector's HR + motion +
    /// duration + zone gates.
    ///
    /// The bout ramps rather than sitting flat at 150 bpm so this fixture does not pass VACUOUSLY. A
    /// rectangle puts 100 % of the bout's samples in zone 2+, which clears the intensity gate no matter
    /// where that gate is set — the detector could be arbitrarily miscalibrated and this test would stay
    /// green, which is how the "no workouts are ever detected" defect shipped. A ramp spends its warm-up
    /// and early minutes below the zone-2 cut, landing at ~59 % zone 2+: still a clear pass, but a
    /// number that would actually move if the gate regressed.
    private func syntheticDay(base: Int) -> (hr: [HRSample], gravity: [GravitySample]) {
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        func rest(_ start: Int, _ minutes: Int) {
            for i in 0..<(minutes * 60) {
                hr.append(HRSample(ts: start + i, bpm: 60))
                grav.append(GravitySample(ts: start + i, x: 0.0, y: 0.0, z: 1.0))
            }
        }
        rest(base, 12)
        let activeStart = base + 12 * 60
        let activeDur = 40 * 60
        for i in 0..<activeDur {
            let bpm = 110.0 + 65.0 * Double(i) / Double(activeDur)
            hr.append(HRSample(ts: activeStart + i, bpm: Int(bpm.rounded())))
            let x = (i % 2 == 0) ? 0.9 : -0.9   // ±0.9 flip each second → large motion delta
            grav.append(GravitySample(ts: activeStart + i, x: x, y: 0.0, z: 0.4))
        }
        rest(activeStart + activeDur, 12)
        return (hr, grav)
    }

    private func detectedRows(_ sessions: [ExerciseSession], realWorkouts: [WorkoutRow]) -> [WorkoutRow] {
        sessions.compactMap { s in
            // The exact overlap-skip ScoreEngine applies (bare time overlap, any source).
            if realWorkouts.contains(where: { s.start < $0.endTs && $0.startTs < s.end }) { return nil }
            return Fixtures.workoutRow(startTs: s.start, endTs: s.end, sport: "detected",
                                       source: computedId, durationS: s.durationS,
                                       energyKcal: s.caloriesKcal, avgHr: Int(s.avgHR),
                                       maxHr: s.peakHR, strain: s.strain)
        }
    }

    // MARK: - Tests

    func testDetectedBoutPersistsSuppressesOnOverlapAndIsIdempotent() async throws {
        let (store, dir) = try await Fixtures.tempStore("workout-detect")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        let base = 1_700_000_000
        let day = syntheticDay(base: base)
        let from = base - 86_400, to = base + 86_400
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

        // 1) The engine detects a bout from the synthetic elevated-HR + gravity day.
        let sessions = WorkoutDetector.detect(hr: day.hr, gravity: day.gravity, age: 30, profile: profile)
        XCTAssertGreaterThanOrEqual(sessions.count, 1, "a sustained elevated-HR + motion window must detect")

        // 2) Persist under the computed id (no real workout yet) → a sport="detected" row round-trips.
        try await persist(detectedRows(sessions, realWorkouts: []), store: store, from: from, to: to)
        let afterFirst = try await store.workouts(deviceId: computedId, from: from, to: to, limit: 1000)
        XCTAssertEqual(afterFirst.filter { $0.sport == "detected" }.count, sessions.count)
        XCTAssertEqual(afterFirst.first?.source, computedId)

        // 3) A time-overlapping MANUAL session suppresses the detected twin (no double-count).
        let bout = sessions[0]
        let manual = Fixtures.workoutRow(startTs: bout.start + 30, endTs: bout.end - 30,
                                         sport: "Tennis", source: "manual",
                                         durationS: Double(bout.end - bout.start - 60),
                                         energyKcal: 380, avgHr: 148, maxHr: 172, strain: 12.0)
        _ = try await store.upsertWorkouts([manual], deviceId: deviceId)
        let real = try await store.workouts(deviceId: deviceId, from: from, to: to, limit: 1000)
        let suppressed = detectedRows(sessions, realWorkouts: real)
        XCTAssertTrue(suppressed.isEmpty, "a detected bout overlapping a real session must be skipped")
        try await persist(suppressed, store: store, from: from, to: to)
        let afterSuppress = try await store.workouts(deviceId: computedId, from: from, to: to, limit: 1000)
        XCTAssertEqual(afterSuppress.filter { $0.sport == "detected" }.count, 0)

        // 4) Idempotency: re-running the delete+upsert (no real workout) never duplicates the bout.
        let rows = detectedRows(sessions, realWorkouts: [])
        try await persist(rows, store: store, from: from, to: to)
        try await persist(rows, store: store, from: from, to: to)
        let afterTwice = try await store.workouts(deviceId: computedId, from: from, to: to, limit: 1000)
        XCTAssertEqual(afterTwice.filter { $0.sport == "detected" }.count, rows.count,
                       "delete-by-(sport,window)-then-upsert must not accumulate duplicates")
    }

    /// The exact persist sequence ScoreEngine runs: clear the window's detected rows, then re-insert.
    private func persist(_ rows: [WorkoutRow], store: StrapStore, from: Int, to: Int) async throws {
        _ = try await store.deleteWorkouts(deviceId: computedId, sport: "detected", from: from, to: to)
        if !rows.isEmpty { _ = try await store.upsertWorkouts(rows, deviceId: computedId) }
    }
}
