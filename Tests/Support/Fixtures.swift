import Foundation
import StrapStore

/// Shared builders for the store's value types and for a throwaway on-disk store.
///
/// `DailyMetric` carries 19 fields, `WorkoutRow` 12 — hand-constructing either means writing a wall of
/// `nil` around the two or three values a test actually asserts on, which ten test files each grew their
/// own private copy of. These mirror the initializers 1:1 with EVERY optional defaulted, so a test names
/// only the fields it cares about and a new store column costs one edit here instead of ten.
enum Fixtures {

    // MARK: - Store value types

    /// One `DailyMetric` with every field but `day` defaulted to nil.
    static func dailyMetric(day: String,
                            totalSleepMin: Double? = nil,
                            efficiency: Double? = nil,
                            deepMin: Double? = nil,
                            remMin: Double? = nil,
                            lightMin: Double? = nil,
                            disturbances: Int? = nil,
                            restingHr: Int? = nil,
                            avgHrv: Double? = nil,
                            recovery: Double? = nil,
                            strain: Double? = nil,
                            exerciseCount: Int? = nil,
                            spo2Pct: Double? = nil,
                            skinTempDevC: Double? = nil,
                            respRateBpm: Double? = nil,
                            steps: Int? = nil,
                            activeKcalEst: Double? = nil,
                            solMin: Double? = nil,
                            remLatencyMin: Double? = nil,
                            wasoMin: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances,
                    restingHr: restingHr, avgHrv: avgHrv, recovery: recovery, strain: strain,
                    exerciseCount: exerciseCount, spo2Pct: spo2Pct, skinTempDevC: skinTempDevC,
                    respRateBpm: respRateBpm, steps: steps, activeKcalEst: activeKcalEst,
                    solMin: solMin, remLatencyMin: remLatencyMin, wasoMin: wasoMin)
    }

    /// One `CachedSleepSession` — only the (startTs, endTs) span is required; the flag defaults mirror
    /// the store's own (an un-edited, confident night).
    static func sleepSession(startTs: Int,
                             endTs: Int,
                             efficiency: Double? = nil,
                             restingHr: Int? = nil,
                             avgHrv: Double? = nil,
                             stagesJSON: String? = nil,
                             userEdited: Bool = false,
                             startTsAdjusted: Int? = nil,
                             lowConfidence: Bool = false) -> CachedSleepSession {
        CachedSleepSession(startTs: startTs, endTs: endTs, efficiency: efficiency,
                           restingHr: restingHr, avgHrv: avgHrv, stagesJSON: stagesJSON,
                           userEdited: userEdited, startTsAdjusted: startTsAdjusted,
                           lowConfidence: lowConfidence)
    }

    /// One `WorkoutRow` — the natural key (startTs, sport) plus its span and lane are required; every
    /// metric column defaults to nil.
    static func workoutRow(startTs: Int,
                           endTs: Int,
                           sport: String,
                           source: String,
                           durationS: Double? = nil,
                           energyKcal: Double? = nil,
                           avgHr: Int? = nil,
                           maxHr: Int? = nil,
                           strain: Double? = nil,
                           distanceM: Double? = nil,
                           zonesJSON: String? = nil,
                           notes: String? = nil) -> WorkoutRow {
        WorkoutRow(startTs: startTs, endTs: endTs, sport: sport, source: source,
                   durationS: durationS, energyKcal: energyKcal, avgHr: avgHr, maxHr: maxHr,
                   strain: strain, distanceM: distanceM, zonesJSON: zonesJSON, notes: notes)
    }

    // MARK: - Throwaway on-disk store

    /// A fresh, empty temp directory named `<label>-<uuid>`. The single temp-dir idiom for the whole
    /// suite (test files had drifted between `NSTemporaryDirectory()` and
    /// `FileManager.default.temporaryDirectory`). Pair every call with `cleanUp`.
    static func tempDir(_ label: String = "wm-tests") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An empty file-backed `StrapStore` (migrations applied) in its own temp directory. File-backed
    /// rather than `inMemory()` so tests that hand a PATH to production code (backup/import, a second
    /// handle on the same DB) work against the real Pool. Returns the directory too — pass it to
    /// `cleanUp` from a `defer`/`tearDown`.
    static func tempStore(_ label: String = "wm-tests") async throws -> (StrapStore, URL) {
        let dir = try tempDir(label)
        let store = try await StrapStore(path: dir.appendingPathComponent("store.sqlite").path)
        return (store, dir)
    }

    /// Remove a `tempDir` / `tempStore` directory and everything in it. Best-effort: a test that already
    /// failed must not also fail its own cleanup.
    static func cleanUp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
