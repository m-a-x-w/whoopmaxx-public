import Foundation
import StrapProtocol

/// Durable persistence for an in-flight, manually-started workout (#529).
///
/// A manual workout used to live ONLY in `WorkoutSessionController.activeWorkout` (in memory), so if iOS killed the app
/// mid-session — a backgrounded phone under memory pressure — the whole session was lost and could never
/// be ended + saved. A tiny `Codable` snapshot (start time, sport, the accumulated HR samples + running
/// stats) is written to `UserDefaults` on start and on every captured sample, and read back on launch so
/// an interrupted session can still be ended and saved.
///
/// The encode/decode is pure (no `UserDefaults` dependency on the codec itself) so the persist/rehydrate
/// round-trip is unit-testable — `store(into:)` / `load(from:)` just thread a `UserDefaults` through it.
/// Ported verbatim from the original `Strand/App/ActiveWorkoutPersistence.swift` (defaults key renamed to the
/// whoopmaxx namespace).
enum ActiveWorkoutPersistence {

    /// The durable shape of an in-flight manual workout — the minimum needed to rebuild
    /// `WorkoutSessionController.ActiveWorkout` on relaunch and still End + save it.
    struct Snapshot: Codable, Equatable {
        /// Workout start, as unix seconds.
        var startSec: Int
        var sport: String
        var samples: [HRSample]
        var avgHr: Int
        var peakHr: Int
        var liveStrain: Double
    }

    /// The single `UserDefaults` key (JSON-encoded `Snapshot`).
    static let defaultsKey = "wm.activeWorkout"

    /// Encode a snapshot to JSON `Data`. Returns nil only if encoding somehow fails.
    static func encode(_ snapshot: Snapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Decode a snapshot from JSON `Data`, bound-checking the untrusted persisted values. Returns nil for
    /// nil/garbage/empty input or an implausible start time, so a corrupt write is treated as "no in-flight
    /// session" rather than reviving a broken card.
    static func decode(_ data: Data?) -> Snapshot? {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        guard raw.startSec > 0 else { return nil }
        // Drop any out-of-range persisted HR samples (a real bpm + a positive ts only).
        let samples = raw.samples.filter { $0.ts > 0 && (1...300).contains($0.bpm) }
        return Snapshot(
            startSec: raw.startSec,
            sport: raw.sport,
            samples: samples,
            avgHr: max(0, raw.avgHr),
            peakHr: max(0, raw.peakHr),
            liveStrain: raw.liveStrain.isFinite ? max(0, raw.liveStrain) : 0
        )
    }

    /// Persist (overwrite) the snapshot. Cheap; called on start + each captured sample.
    static func store(_ snapshot: Snapshot, into defaults: UserDefaults = .standard) {
        guard let data = encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Read back the persisted snapshot, or nil if none is stored (or it was corrupt).
    static func load(from defaults: UserDefaults = .standard) -> Snapshot? {
        decode(defaults.data(forKey: defaultsKey))
    }

    /// Clear the snapshot — called the instant a session ends (saved or discarded).
    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
