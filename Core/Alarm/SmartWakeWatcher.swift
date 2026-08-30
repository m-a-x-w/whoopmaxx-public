import Foundation

/// The live light-sleep detector for the smart alarm (W9) — a PURE Swift port of the original's Android
/// `SleepWindowWatcher.kt`, so it can be reasoned about and unit-tested with no BLE, no timers, no
/// Foundation clock.
///
/// It never touches the strap or the OS alarm itself; it only DECIDES whether the current overnight
/// HR pattern looks like a lighter sleep phase (or an arousal) within the wake window. The coordinator
/// feeds it the smoothed live heart rate once the app is inside the window and connected, and — if
/// `shouldWake` returns true — buzzes the strap early and drops the latest-edge firmware backstop.
/// Detection only ever advances the wake EARLIER; the latest-edge alarm remains the floor of safety.
///
/// HONEST signal, no over-claiming: during deep sleep heart rate sits near its nightly trough and is
/// steady; in lighter sleep / on an arousal it lifts above that trough. We track the lowest smoothed
/// HR seen this night (the trough proxy) and fire when the current HR rises a meaningful margin above
/// it AND is itself off the floor. This is a coarse "you're stirring" heuristic — NOT a sleep-stage
/// classifier, and it makes no clinical claim. If the strap streams nothing (BLE down / not worn) the
/// detector simply never fires and the firmware backstop + notification wake the user.
final class SmartWakeWatcher {
    /// How far above the nightly trough (bpm) counts as "lighter / stirring".
    private let riseBpm: Int
    /// Don't trust the trough until we've seen at least this many samples this night.
    private let minSamples: Int
    /// Ignore obviously-awake-high HR as a trough candidate (e.g. the user got up briefly).
    private let troughCeilingBpm: Int

    private var troughBpm: Int = .max
    private var sampleCount: Int = 0
    /// Set once we've fired so we don't re-advance every subsequent sample.
    private var fired: Bool = false

    init(riseBpm: Int = 6, minSamples: Int = 30, troughCeilingBpm: Int = 90) {
        self.riseBpm = riseBpm
        self.minSamples = minSamples
        self.troughCeilingBpm = troughCeilingBpm
    }

    /// Reset for a fresh night (called when the watcher (re)enters a window).
    func reset() {
        troughBpm = .max
        sampleCount = 0
        fired = false
    }

    // MARK: - Decision snapshot (read-only)
    //
    // These expose the watcher's current internal decision state so the coordinator can CAPTURE it at the
    // instant of an early fire (for the Rest "This morning's wake" panel). They are PURE reads — they never
    // mutate state, and `shouldWake`'s logic + fire semantics are untouched.

    /// The lowest smoothed HR (bpm) seen this night — the trough the fire test compares against. `nil`
    /// until at least one below-ceiling sample has been seen (the `.max` sentinel is not yet a real trough).
    var currentTrough: Int? { troughBpm == .max ? nil : troughBpm }

    /// The HR (bpm) at which the CURRENT trough trips a fire (`trough + riseBpm`); `nil` before a trough
    /// exists. When `shouldWake` returns true, the fed reading is `>=` this value.
    var fireThreshold: Int? {
        guard let trough = currentTrough else { return nil }
        return trough + riseBpm
    }

    /// How many samples have been fed this night (a fire needs `>= minSamples`).
    var samplesSeen: Int { sampleCount }

    /// Feed one smoothed HR reading. Returns true exactly once — when the reading first looks like a
    /// lighter phase inside the window — so the caller advances the wake a single time. All later calls
    /// return false until `reset()`. A non-positive HR (no live data) is ignored: no sample, no fire.
    func shouldWake(bpm: Int) -> Bool {
        if bpm <= 0 { return false }
        sampleCount += 1
        if bpm <= troughCeilingBpm && bpm < troughBpm { troughBpm = bpm }
        if fired { return false }
        if sampleCount < minSamples || troughBpm == .max { return false }
        // Rise of >= riseBpm above the trough, and the current reading is itself off the floor.
        if bpm >= troughBpm + riseBpm && bpm > troughBpm {
            fired = true
            return true
        }
        return false
    }
}
