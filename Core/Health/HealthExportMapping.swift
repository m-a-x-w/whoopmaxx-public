import Foundation
import HealthKit
import StrapStore
import StrapAnalytics

/// Pure, store-free mapping + dedup helpers for the write-only Apple Health export.
///
/// This layer is deliberately HealthKit-*store*-free: it never touches an `HKHealthStore`, requests
/// no authorization, and needs no entitlement — it only reads the SDK's stable type-id / category-value
/// constants. That keeps the windowing + idempotency logic unit-testable without a live Health store
/// (mirrors the original `ShortcutHealthExport` injectable-seam discipline). `HealthExport` turns these value
/// structs into `HKQuantitySample` / `HKCategorySample` objects and does the delete/save.
enum HealthExportMapping {

    // MARK: - Value structs (no HealthKit objects — just the data a sample needs)

    /// One vital sample to write: a quantity type + unit descriptor + value on a civil day, plus the
    /// deterministic external UUID that makes a re-export replace rather than duplicate.
    struct VitalCandidate: Equatable {
        /// `HKQuantityTypeIdentifier` raw string (e.g. the SDNN identifier). Rebuilt into an
        /// `HKQuantityType` in the bridge via `HKQuantityTypeIdentifier(rawValue:)`.
        let typeId: String
        /// The HK unit to attach, as a store-free descriptor.
        let unit: VitalUnit
        /// The value in `unit`'s terms (SpO2 already scaled to the 0–1 fraction HealthKit stores).
        let value: Double
        /// `yyyy-MM-dd` local civil day this vital belongs to.
        let day: String
        /// `wm:health:<deviceId>:<typeIdRaw>:<day>` — stable per (device, type, day).
        let externalUUID: String
    }

    /// The HK unit a vital carries, kept store-free so the mapping is pure. The bridge maps each case to
    /// a real `HKUnit` at save time.
    enum VitalUnit: Equatable {
        case millisecondsSDNN   // HRV SDNN → HKUnit.secondUnit(with: .milli)
        case countPerMinute     // RHR + respiratory rate → count()/minute()
        case fraction           // SpO2 → HKUnit.percent(), value is the 0–1 fraction
    }

    /// One sleep-stage segment to write as an `HKCategorySample(.sleepAnalysis)`.
    struct SleepCandidate: Equatable {
        /// Segment start / end, unix seconds (wall clock, as stored in `stagesJSON`).
        let startTs: Int
        let endTs: Int
        /// `HKCategoryValueSleepAnalysis` raw value (asleepDeep / asleepREM / asleepCore / awake).
        let categoryValue: Int
        /// `wm:health:sleep:<deviceId>:<sessionStartTs>:<segStart>` — provenance stamp. Sleep dedup is
        /// window-delete-per-session (see `HealthExport`), not per-segment UUID matching, because a
        /// restaged night moves segment boundaries; the UUID is metadata, not the delete key.
        let externalUUID: String
    }

    // MARK: - Vitals

    /// Build the vital samples for one merged daily row. Emits ONLY the fields that are present — a nil
    /// field produces nothing (honesty: never a fabricated 0). SpO2 is scaled from percent (94…99) to
    /// the 0–1 fraction HealthKit's `oxygenSaturation` stores (matching the original `spo2 / 100`).
    static func vitalCandidates(from m: DailyMetric, deviceId: String) -> [VitalCandidate] {
        var out: [VitalCandidate] = []
        func add(_ id: HKQuantityTypeIdentifier, _ unit: VitalUnit, _ value: Double) {
            out.append(VitalCandidate(
                typeId: id.rawValue, unit: unit, value: value, day: m.day,
                externalUUID: vitalExternalUUID(typeId: id.rawValue, deviceId: deviceId, day: m.day)))
        }
        if let hrv = m.avgHrv { add(.heartRateVariabilitySDNN, .millisecondsSDNN, hrv) }
        if let rhr = m.restingHr { add(.restingHeartRate, .countPerMinute, Double(rhr)) }
        if let resp = m.respRateBpm { add(.respiratoryRate, .countPerMinute, resp) }
        if let spo2 = m.spo2Pct { add(.oxygenSaturation, .fraction, spo2 / 100) }
        return out
    }

    /// The deterministic per-(device, type, day) external UUID for a vital sample. Exposed so the bridge
    /// can delete OUR prior sample for a type on a given day even when that type has NO current candidate
    /// (a vital that went present→nil), keeping the delete/save gap-free rather than orphaning a stale
    /// sample in Health.
    static func vitalExternalUUID(typeId: String, deviceId: String, day: String) -> String {
        "wm:health:\(deviceId):\(typeId):\(day)"
    }

    // MARK: - Sleep stages

    /// Decode a session's `stagesJSON` (the `[{start,end,stage}]` array `SleepStager`/`DemoSeed` write)
    /// and map each segment to a sleep-stage sample. `SleepStage.decode` owns the token table and the
    /// drop rules (unknown stage tokens and zero/negative-span segments are dropped); this returns []
    /// when there is no stage timeline.
    static func sleepCandidates(from s: CachedSleepSession, deviceId: String) -> [SleepCandidate] {
        let prefix = sleepSessionUUIDPrefix(deviceId: deviceId, sessionStartTs: s.startTs)
        return SleepStage.decode(s.stagesJSON).map { seg in
            SleepCandidate(startTs: seg.start, endTs: seg.end,
                           categoryValue: seg.stage.hkCategoryValue,
                           externalUUID: prefix + String(seg.start))
        }
    }

    /// The external-UUID PREFIX shared by every stage segment of one sleep session —
    /// `wm:health:sleep:<deviceId>:<sessionStartTs>:`. `HealthExport` deletes a session's prior samples by
    /// matching THIS prefix (metadata BEGINSWITH), so a re-stage that moved segment boundaries is still fully
    /// cleared while a NEIGHBORING session (a different start ⇒ a different prefix) is left untouched — no
    /// blanket time-window delete that could eat an adjacent nap. The trailing ':' is load-bearing: it
    /// delimits the start epoch so one session's start can never prefix another's.
    static func sleepSessionUUIDPrefix(deviceId: String, sessionStartTs: Int) -> String {
        "wm:health:sleep:\(deviceId):\(sessionStartTs):"
    }

    // MARK: - Skip-gate fingerprints

    /// A per-day vitals fingerprint: the rounded (rhr | hrv | resp | spo2) tuple. Equal → the day's
    /// vitals are unchanged since the last successful export, so the delete/save is skipped entirely
    /// (mirrors ScoreEngine #836 + the original `hrDayStateKey`). Deterministic across launches (no
    /// `Hashable.hashValue`, which is per-process seeded) so a persisted fingerprint still matches.
    static func dayVitalsFingerprint(_ m: DailyMetric) -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }
        let rhr = m.restingHr.map(String.init) ?? "-"
        return "\(rhr)|\(f(m.avgHrv))|\(f(m.respRateBpm))|\(f(m.spo2Pct))"
    }

    /// A per-session stages fingerprint: a stable hash of `stagesJSON` folded with `endTs` (a restaged
    /// or re-bounded night changes one or both). Skip the session's window-delete/resave when unchanged.
    ///
    /// THIS IS THE HEAL MECHANISM FOR A STAGER CHANGE, and it is worth naming as such. When the stager's
    /// output moves — as it does with the round-4 V1 changes (the motion-restricted reference-percentile
    /// pool and the removal of the deep front-loading rule move REM 12.60 % → 16.51 % and deep 4.47 % →
    /// 6.99 % of TST over the real 21 sessions) — every affected session's fingerprint changes, so
    /// `HealthExport.writeSleepStages` deletes OUR prior `sleepAnalysis` samples for that night and saves
    /// the fresh ones. No new heal is needed for a night the export loop still visits.
    ///
    /// RESIDUAL, measured against the shipped constants and left for a follow-up rather than silently
    /// implied: `writeSleepStages` iterates `repo.sleeps` filtered to `HealthExport.windowDays` (14), so a
    /// session that has already aged past 14 days keeps whatever stage samples were written under the OLD
    /// stager, permanently. The store-side half of the same problem IS closed here — `ScoreEngine`'s
    /// round-4 one-shot widens ONE scoring pass to the raw-retention horizon — but the Health half would
    /// need a matching one-shot widened push in `HealthExport` (the file this mapping feeds, which is
    /// outside this change's scope), in the shape of `purgeStaleHrvIfNeeded`.
    static func sessionStagesFingerprint(_ s: CachedSleepSession) -> String {
        "\(s.endTs):\(stableHash(s.stagesJSON ?? ""))"
    }

    /// FNV-1a 64-bit over the UTF-8 bytes — deterministic across process launches, unlike Swift's
    /// randomly-seeded `String.hashValue`, so a fingerprint written to `UserDefaults` still compares
    /// equal on the next launch.
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

/// The HealthKit half of the stage vocabulary. It lives HERE, not beside `SleepStage` in `Core/Data`,
/// so the one stage owner stays HealthKit-free (`Core/Data` imports no HealthKit) — the token table is
/// shared, the SDK dependency is not.
extension SleepStage {
    /// This stage's `HKCategoryValueSleepAnalysis` raw value — the original `collectSleep` mapping inverted
    /// for writing: deep→asleepDeep, rem→asleepREM, light→asleepCore, wake/awake→awake. Total (no
    /// `default`), so adding a `SleepStage` case is a COMPILE ERROR here rather than a silent drop.
    var hkCategoryValue: Int {
        switch self {
        case .deep:         return HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        case .rem:          return HKCategoryValueSleepAnalysis.asleepREM.rawValue
        case .light:        return HKCategoryValueSleepAnalysis.asleepCore.rawValue
        case .wake, .awake: return HKCategoryValueSleepAnalysis.awake.rawValue
        }
    }
}
