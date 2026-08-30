import Foundation
import StrapProtocol
import StrapStore
import StrapAnalytics

/// How much of one night the stager actually had to look at. Two measures, both read off the streams
/// the forensics pass already loads: HR sample density, and the share of the HR window the wrist-motion
/// (gravity) stream spans.
///
/// VOCABULARY — this is the app's existing *capture coverage* idea (`GapScan.DayCoverage.coverage`, the
/// persisted `effort_coverage` series, the Strap Health "capture coverage" bars) narrowed to one night's
/// staging window. It is deliberately NOT a fourth notion, and it is NOT `SignalQuality`, which grades
/// the BLE LINK of a session rather than the data that reached the store.
///
/// Health-framing register (011 decision 5): descriptive, within-user, no condition name, no
/// probability, no call to action. Banned from this type's copy — thermoregulation, vasodilation,
/// impaired, poor, abnormal, apnea, insomnia, hypoxemia, arrhythmia, "consider", "you should",
/// "talk to". It describes the RECORDING, never the sleeper.
struct CaptureQuality: Equatable, Sendable {

    /// HR samples per minute over the HR stream's own span (`SleepReadout.hrDensityPerMinute`).
    let hrPerMinute: Double
    /// 0–1 share of the HR window the gravity stream spans (`SleepReadout.gravityCoverageFraction`).
    let gravityCoverage: Double

    /// True when gravity spans less than `SleepDetection.sparseGravitySpanFrac` of the HR window — the
    /// exact test `SleepDetection.isGravitySparse` keys its sparse-gravity staging path on. So this says
    /// "tonight's staging ran on the sparse path", not a verdict of our own invention.
    var gravityIsSparse: Bool { gravityCoverage < SleepDetection.sparseGravitySpanFrac }

    /// The one caption line, or nil when there is nothing to explain — a dense night's staging had the
    /// whole window to work with, and saying so unprompted would be noise.
    var caption: String? {
        guard gravityIsSparse else { return nil }
        // A 0.04/min night must not round to "0.0×/min": that reads as "no HR at all" beside a ledger
        // built out of HR. Below a tenth, print the second decimal instead.
        let density = String(format: hrPerMinute < 0.1 ? "%.2f" : "%.1f", hrPerMinute)
        let pct = Int((gravityCoverage * 100).rounded())
        // "spanned", not "covered": `gravityCoverageFraction` is the distance from the FIRST gravity
        // sample to the LAST, over the HR window, and is blind to every gap between them. A stream that
        // runs densely for two hours, drops one stray sample at hour five and then stops has SPANNED
        // 62% of the night while covering far less of it. "Covered" would claim a density this never
        // measured. The sparse GATE above is deliberately left alone — it mirrors
        // `SleepDetection.isGravitySparse` exactly, so it says which staging path ran, not a verdict of
        // our own; re-deriving it from gap-summed coverage would silently decouple the two.
        return "HR sampled \(density)\u{00D7}/min and the wrist-motion stream spanned \(pct)% of the night."
    }

    /// Measure one night's window from the two streams the forensics pass already holds.
    ///
    /// The HR stream is the REFERENCE window — with fewer than two HR samples (or a degenerate span)
    /// there is nothing to measure a share OF, and this returns nil rather than a fraction of nothing.
    /// `hrDensityPerMinute` returns 0 in exactly those cases, so the density is the gate. Gravity is
    /// measured AGAINST that window: an empty gravity stream spans nothing and is a true 0%, not an
    /// unknown, and it is the night this caption exists for.
    static func measure(hr: [HRSample], gravity: [GravitySample]) -> CaptureQuality? {
        let density = SleepReadout.hrDensityPerMinute(hr: hr)
        guard density > 0 else { return nil }
        return CaptureQuality(hrPerMinute: density,
                              gravityCoverage: SleepReadout.gravityCoverageFraction(gravity: gravity, hr: hr))
    }
}

/// App-layer bridge that pulls one night's streams from the store and runs `ArousalForensics.classify`
/// ONCE for a Rest day-view. Pure orchestration on top of existing read APIs — NO StrapStore schema
/// change, NO migration: it reads the already-stored raw streams + the persisted per-epoch `motionJSON`
/// and the session's decoded `stagesJSON`, exactly the inputs the score pass already banked.
///
/// The Rest screen caches the returned read per dayKey (see `ArousalForensicsSection` wiring), so this
/// never runs per SwiftUI frame.
enum ArousalForensicsLoader {

    /// One night's forensics read: the cause-tagged awakenings, plus how much of the night the stager
    /// had to look at while producing them.
    struct Night: Equatable, Sendable {
        let arousals: [Arousal]
        /// nil when the night never staged, or when its HR window is too short to measure a share of.
        let capture: CaptureQuality?

        /// Nothing to explain — no window, or no stage timeline to attribute wakes to.
        static let empty = Night(arousals: [], capture: nil)
    }

    /// Classify the meaningful mid-sleep awakenings for one detected session.
    ///
    /// Kept as the arousals-only face of `load` for the ledger call site; both run the SAME single pass.
    /// - Returns: the chronological, cause-tagged awakenings (empty when the night slept through).
    static func classify(session: CachedSleepSession,
                         store: StrapStore,
                         strapDeviceId: String,
                         computedDeviceId: String,
                         family: DeviceFamily) async -> [Arousal] {
        await load(session: session, store: store, strapDeviceId: strapDeviceId,
                   computedDeviceId: computedDeviceId, family: family).arousals
    }

    /// The full read: the awakenings AND the night's capture measure.
    ///
    /// - Parameters:
    ///   - session: the night to explain (its window, `restingHr`, and `stagesJSON` are read).
    ///   - store: an open StrapStore (from `Repository.storeHandle()`).
    ///   - strapDeviceId: the strap/import lane the RAW streams live under (`Repository.deviceId`).
    ///   - computedDeviceId: the computed lane the detected session + its `motionJSON` are persisted under.
    ///   - family: device family for the family-aware skin-temp raw→°C scale. Defaults to the paired
    ///     family (`WhoopModel.persisted`), the same source `ScoreEngine.skinTempFamily` falls back to.
    static func load(session: CachedSleepSession,
                     store: StrapStore,
                     strapDeviceId: String,
                     computedDeviceId: String,
                     family: DeviceFamily) async -> Night {
        // The persisted per-epoch grid, `stagesJSON`, and motion are all keyed on the DETECTED `startTs`.
        let start = session.startTs
        let end = session.endTs
        guard end > start else { return .empty }

        // Decode the stored stage timeline directly into the stager's StageSegment (identical JSON shape
        // to `DayEngine.encodeStages`). No timeline → nothing to attribute.
        // NOT via `SleepStage.decode`: `ArousalForensics.classify` wants the RAW `[StageSegment]` back
        // (frozen-package API), so tokenizing here would only mean mapping them straight back to strings.
        guard let json = session.stagesJSON,
              let data = json.data(using: .utf8),
              let stages = try? JSONDecoder().decode([StageSegment].self, from: data),
              !stages.isEmpty else { return .empty }

        // Raw streams for the session window (they live under the strap/import lane).
        let hr = (try? await store.hrSamples(deviceId: strapDeviceId, from: start, to: end, limit: 200_000)) ?? []
        let rr = (try? await store.rrIntervals(deviceId: strapDeviceId, from: start, to: end, limit: 200_000)) ?? []
        let resp = (try? await store.respSamples(deviceId: strapDeviceId, from: start, to: end, limit: 200_000)) ?? []
        let grav = (try? await store.gravitySamples(deviceId: strapDeviceId, from: start, to: end, limit: 200_000)) ?? []
        let skin = (try? await store.skinTempSamples(deviceId: strapDeviceId, from: start, to: end, limit: 200_000)) ?? []

        // The capture measure rides the two arrays already in hand — no extra read, no extra query.
        let capture = CaptureQuality.measure(hr: hr, gravity: grav)

        // Persisted per-epoch motion (H8), keyed by the detected startTs. Try the computed lane the score
        // pass wrote it under, then the strap lane (imported nights), then recompute from gravity as a
        // last resort so the motion bar still has a series to read.
        var motion = (try? await store.sessionMotion(deviceId: computedDeviceId, sessionStart: start)) ?? nil
        if motion == nil {
            motion = (try? await store.sessionMotion(deviceId: strapDeviceId, sessionStart: start)) ?? nil
        }
        let motionEpochs = motion ?? SleepStaging.sessionEpochMotion(start: start, end: end, grav: grav)

        let rebuilt = SleepSession(start: start, end: end,
                                   efficiency: session.efficiency ?? 0,
                                   stages: stages,
                                   restingHR: session.restingHr,
                                   avgHRV: session.avgHrv,
                                   lowConfidence: session.lowConfidence)

        let arousals = ArousalForensics.classify(session: rebuilt,
                                                 motionEpochs: motionEpochs,
                                                 hr: hr, rr: rr, resp: resp, skinTemp: skin,
                                                 gravity: grav, family: family)
        return Night(arousals: arousals, capture: capture)
    }
}
