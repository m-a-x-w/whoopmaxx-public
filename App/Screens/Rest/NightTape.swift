import Foundation
import StrapStore
import StrapProtocol
import StrapAnalytics

// MARK: - Tape model (wrapped clock-hour lanes, decimated once)

/// The drum tape derived once from a `NightMovement.Analysis`: one lane per LOCAL clock hour from bed→wake
/// with its samples decimated to a fixed column count, so the Canvas never re-decimates per frame. Hour
/// boundaries roll via `Calendar`, so they cross midnight (and DST) correctly.
///
/// Lives beside `NightMovementScreen` (not in `Core/`) because it is a Rest-screen read model — a `Core/`
/// home would point Core at App/Screens. `load` carries the night's raw-store READ, so the screen keeps
/// only its `.task` and the main-actor `motionKey` lookup, and the `my-whoop` vs `my-whoop-computed` lane rule
/// plus the 500,000-sample gravity cap become testable without a View.
struct NightTape {
    let analysis: NightMovement.Analysis
    let lanes: [Lane]

    /// One clock-hour row of the tape.
    struct Lane: Identifiable {
        let hourStart: Int          // unix seconds at the top of the local hour
        let hourEnd: Int
        let label: String           // "11p", "12a", "1a"
        let envelopes: [NightMovement.Envelope]
        var id: Int { hourStart }
        /// The lane's peak deflection (0…1), for the tap readout + "did anything happen" test.
        var peak: Double { envelopes.map(\.hi).max() ?? 0 }
        var hasMovement: Bool { peak > 0 }
    }

    /// Fixed decimation width per lane — enough columns to read as a continuous jittery trace, cached once
    /// so the seismograph math runs at load, not per render frame.
    static let laneColumns = 220

    var isEmpty: Bool { lanes.isEmpty }
    var source: NightMovement.Source { analysis.source }

    /// Reads the night's raw gravity (or the persisted per-epoch motion fallback) and runs `NightMovement`
    /// + `NightTape.build`. `nonisolated`, so it runs on a background executor rather than the main actor.
    nonisolated static func load(store: StrapStore, strapId: String, computedId: String,
                                 start: Int, end: Int, motionSessionStart: Int?) async -> NightTape {
        // Primary: RAW tri-axial gravity under the raw strap id (`my-whoop`) — the same id ScoreEngine reads
        // raw streams from; NOT the computed `-computed` sibling.
        let grav = (try? await store.gravitySamples(deviceId: strapId, from: start, to: end,
                                                    limit: 500_000)) ?? []
        var analysis = NightMovement.fromGravity(grav, start: start, end: end)

        // Fallback when raw gravity is thin/absent: the persisted per-epoch motion series, banked under the
        // computed id and keyed by the session's DETECTED startTs (the read counterpart of
        // `persistSessionMotion`).
        if grav.count < NightMovement.minGravitySamples, let sessionStart = motionSessionStart,
           let motion = try? await store.sessionMotion(deviceId: computedId, sessionStart: sessionStart),
           motion.count >= 2 {
            analysis = NightMovement.fromEpochMotion(motion, sessionStart: sessionStart, end: end)
        }
        return NightTape.build(analysis: analysis)
    }

    static func build(analysis: NightMovement.Analysis, calendar: Calendar = .current) -> NightTape {
        guard !analysis.isEmpty, analysis.end > analysis.start else {
            return NightTape(analysis: analysis, lanes: [])
        }
        let bedDate = Date(timeIntervalSince1970: TimeInterval(analysis.start))
        // Floor bed to the top of its local clock hour, then walk hour-by-hour to wake.
        var hourDate = calendar.dateInterval(of: .hour, for: bedDate)?.start ?? bedDate
        var lanes: [Lane] = []
        while Int(hourDate.timeIntervalSince1970) < analysis.end {
            let hs = Int(hourDate.timeIntervalSince1970)
            let nextDate = calendar.date(byAdding: .hour, value: 1, to: hourDate)
                ?? hourDate.addingTimeInterval(3600)
            let he = Int(nextDate.timeIntervalSince1970)
            let env = NightMovement.laneEnvelope(analysis.samples, from: hs, to: he, columns: laneColumns)
            lanes.append(Lane(hourStart: hs, hourEnd: he,
                              label: hourLabel(hourDate, calendar: calendar), envelopes: env))
            hourDate = nextDate
        }
        return NightTape(analysis: analysis, lanes: lanes)
    }

    /// "11p" / "12a" / "1a" — the local clock hour in tabular shorthand.
    static func hourLabel(_ date: Date, calendar: Calendar) -> String {
        let h = calendar.component(.hour, from: date)       // 0…23 local
        var h12 = h % 12
        if h12 == 0 { h12 = 12 }
        return "\(h12)\(h < 12 ? "a" : "p")"
    }
}
