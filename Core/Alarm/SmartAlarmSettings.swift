import Foundation
import Combine

/// A durable record of ONE wake the smart alarm produced, captured at the instant of fire so the Rest
/// "This morning's wake" panel can explain — honestly — how the wake was decided. Forward-only: written on
/// fire, never rewritten or back-filled. Units: epochs are unix SECONDS, bpm is beats/min.
struct WakeEvent: Codable, Equatable {
    /// What produced the wake.
    enum Trigger: String, Codable {
        /// The live light-sleep watcher tripped inside the window — which PROVES the app was alive,
        /// connected + worn, and streaming HR. The inherently confident case.
        case earlyWatcher
        /// The strap's own firmware alarm fired at the latest edge (the kill-proof backstop). The smart
        /// detection did NOT engage; the user woke at the window's latest edge.
        case strapBackstop
    }

    /// The ACTUAL fire instant (unix seconds).
    var firedEpoch: Double
    /// The window's latest-edge deadline this wake was armed against (unix seconds).
    var deadlineEpoch: Double
    /// The window's earliest-edge start (unix seconds).
    var windowStartEpoch: Double
    var trigger: Trigger
    /// The nightly HR trough the watcher measured (bpm) — set for `.earlyWatcher`, `nil` for a backstop
    /// (the watcher never ran).
    var troughBpm: Int?
    /// The fire threshold the watcher used (`trough + riseBpm`, bpm) — set for `.earlyWatcher`, `nil` else.
    var thresholdBpm: Int?
    /// Live context captured AT the fire instant — was the app talking to a connected, worn,
    /// encrypted-bonded strap.
    var connected: Bool
    var worn: Bool
    var encryptedBond: Bool
}

/// Wake-buzz insistence — the motor-loop count the APP-DRIVEN buzz fires (the early-wake buzz + the Test
/// buzz), via `runHapticsPattern`'s loop field. Loops is a safe, known parameter (the haptic-clock +
/// inactivity nudges already vary it). The GUARANTEED latest-edge firmware buzz is a fixed captured
/// pattern and is NOT affected by this.
enum BuzzStrength: Int, CaseIterable, Codable {
    case gentle, standard, insistent

    /// Motor loops for `runHapticsPattern [2, loops, …]`. Standard (3) matches the hardware-confirmed buzz.
    var loops: Int {
        switch self {
        case .gentle: return 1
        case .standard: return 3
        case .insistent: return 6
        }
    }

    var label: String {
        switch self {
        case .gentle: return "Gentle"
        case .standard: return "Standard"
        case .insistent: return "Insistent"
        }
    }

    /// The strength whose loop count is closest to a stored value (so a persisted int maps back cleanly).
    static func nearest(loops: Int) -> BuzzStrength {
        allCases.min { abs($0.loops - loops) < abs($1.loops - loops) } ?? .standard
    }
}

/// Persisted store for the Rest wake-window smart alarm (W9). Minutes are minutes-since-local-midnight.
///
/// Model: earliest + latest (derive width). The user sets a window; detection may advance the wake
/// EARLIER inside it, but the LATEST edge is the guaranteed backstop. Validation forces
/// `latest >= earliest` and clamps the window width so the early edge can never be an unrealistic
/// hours-early wake. Every-day only in MVP (no per-weekday selection).
///
/// The scheduled `deadlineEpoch` / `windowStartEpoch` are bookkeeping the coordinator writes on each
/// arm — the resolved absolute window the live watcher clamps against. Persisted so a relaunch mid-night
/// still knows the window it armed.
@MainActor
final class SmartAlarmSettings: ObservableObject {

    enum Key {
        static let enabled = "wm.alarm.enabled"
        static let earliestMin = "wm.alarm.earliestMin"
        static let latestMin = "wm.alarm.latestMin"
        static let deadlineEpoch = "wm.alarm.deadlineEpoch"
        static let windowStartEpoch = "wm.alarm.windowStartEpoch"
        static let firedDeadlineEpoch = "wm.alarm.firedDeadlineEpoch"
        static let wakeEvents = "wm.alarm.wakeEvents"
        static let buzzLoops = "wm.alarm.buzzLoops"
    }

    /// Minutes in a day — a minute-of-day is always in `0..<minutesPerDay`.
    nonisolated static let minutesPerDay = 24 * 60  // nonisolated: immutable, read from non-isolated context.
    /// How many recent wake events the ring keeps (~a week of mornings). Append + cap, oldest dropped.
    static let wakeEventRingSize = 7
    /// Widest wake window we allow (minutes). A window wider than this clamps its early edge up, so
    /// "detection can wake you earlier" stays a sane band, not a 3 a.m. surprise.
    static let maxWindowMin = 90

    /// Default window: 06:30 → 07:00.
    static let defaultEarliestMin = 6 * 60 + 30
    static let defaultLatestMin = 7 * 60
    /// Default buzz strength = Standard (3 motor loops), matching the hardware-confirmed one-shot buzz.
    static let defaultBuzzLoops = BuzzStrength.standard.loops

    private let defaults: UserDefaults

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.enabled) }
    }
    /// Earliest wake minute (window start). Assign via `setEarliest` to keep the pair valid.
    @Published private(set) var earliestMin: Int {
        didSet { defaults.set(earliestMin, forKey: Key.earliestMin) }
    }
    /// Latest wake minute (the guaranteed backstop edge). Assign via `setLatest` to keep the pair valid.
    @Published private(set) var latestMin: Int {
        didSet { defaults.set(latestMin, forKey: Key.latestMin) }
    }
    /// The resolved absolute latest-edge instant the coordinator armed (epoch seconds); 0 = none.
    @Published var scheduledDeadlineEpoch: Double {
        didSet { defaults.set(scheduledDeadlineEpoch, forKey: Key.deadlineEpoch) }
    }
    /// The resolved absolute window-start instant (epoch seconds); 0 = none.
    @Published var scheduledWindowStartEpoch: Double {
        didSet { defaults.set(scheduledWindowStartEpoch, forKey: Key.windowStartEpoch) }
    }
    /// The latest-edge deadline (epoch seconds) a wake has ALREADY fired for; 0 = none. Persisted so a
    /// force-quit + relaunch inside the same window can't re-arm the backstop the early fire dropped and
    /// wake the user a second time (the double-fire guard is otherwise in-memory only).
    @Published var firedDeadlineEpoch: Double {
        didSet { defaults.set(firedDeadlineEpoch, forKey: Key.firedDeadlineEpoch) }
    }
    /// App-driven buzz insistence (motor loops) for the early-wake buzz + the Test buzz. Does NOT change
    /// the guaranteed latest-edge firmware buzz (a fixed captured pattern). Default = Standard (3).
    @Published var buzzLoops: Int {
        didSet { defaults.set(buzzLoops, forKey: Key.buzzLoops) }
    }
    /// The last few real wake events (append + cap at `wakeEventRingSize`), oldest first / newest last.
    /// Persisted (JSON) so the Rest wake panel can explain this morning's wake after a relaunch; published
    /// so a wake recorded while the Rest screen is open updates it live. Written only via `record(_:)`.
    @Published private(set) var recentWakeEvents: [WakeEvent]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Key.enabled)
        let e = defaults.object(forKey: Key.earliestMin) as? Int ?? Self.defaultEarliestMin
        let l = defaults.object(forKey: Key.latestMin) as? Int ?? Self.defaultLatestMin
        let norm = Self.normalize(earliest: e, latest: l)
        self.earliestMin = norm.earliest
        self.latestMin = norm.latest
        self.scheduledDeadlineEpoch = defaults.double(forKey: Key.deadlineEpoch)
        self.scheduledWindowStartEpoch = defaults.double(forKey: Key.windowStartEpoch)
        self.firedDeadlineEpoch = defaults.double(forKey: Key.firedDeadlineEpoch)
        self.buzzLoops = defaults.object(forKey: Key.buzzLoops) as? Int ?? Self.defaultBuzzLoops
        self.recentWakeEvents = Self.loadWakeEvents(from: defaults)
    }

    // MARK: - Wake-event ring (forward-only diagnostics for the Rest wake panel)

    /// Append a real wake event to the ring (capped at `wakeEventRingSize`, oldest dropped) and persist.
    /// Called by the coordinator at the instant of a fire; never rewrites earlier events.
    func record(_ event: WakeEvent) {
        var ring = recentWakeEvents
        ring.append(event)
        if ring.count > Self.wakeEventRingSize {
            ring.removeFirst(ring.count - Self.wakeEventRingSize)
        }
        recentWakeEvents = ring
        if let data = try? JSONEncoder().encode(ring) {
            defaults.set(data, forKey: Key.wakeEvents)
        }
    }

    /// The most recent recorded wake (nil if none) — the one the Rest "This morning's wake" panel reads.
    var latestWakeEvent: WakeEvent? { recentWakeEvents.last }

    private static func loadWakeEvents(from defaults: UserDefaults) -> [WakeEvent] {
        guard let data = defaults.data(forKey: Key.wakeEvents),
              let ring = try? JSONDecoder().decode([WakeEvent].self, from: data)
        else { return [] }
        return ring
    }

    /// Window width in minutes (latest − earliest, never negative).
    var windowWidthMin: Int { max(0, latestMin - earliestMin) }

    /// Set the earliest edge, re-normalising the pair (latest is pushed out if it would fall before it,
    /// or pulled in if the window would exceed the max width).
    func setEarliest(_ minutes: Int) {
        let norm = Self.normalize(earliest: minutes, latest: latestMin)
        if earliestMin != norm.earliest { earliestMin = norm.earliest }
        if latestMin != norm.latest { latestMin = norm.latest }
    }

    /// Set the latest edge, re-normalising the pair (never before earliest, never wider than the max).
    func setLatest(_ minutes: Int) {
        let norm = Self.normalize(earliest: earliestMin, latest: minutes)
        if earliestMin != norm.earliest { earliestMin = norm.earliest }
        if latestMin != norm.latest { latestMin = norm.latest }
    }

    /// Validate a (earliest, latest) pair: each in-range, `latest >= earliest`, and the window no wider
    /// than `maxWindowMin`. Pure so the round-trip + clamp is unit-testable.
    static func normalize(earliest: Int, latest: Int) -> (earliest: Int, latest: Int) {
        let e = min(max(0, earliest), minutesPerDay - 1)
        var l = min(max(0, latest), minutesPerDay - 1)
        if l < e { l = e }                              // latest never before earliest
        if l > e + maxWindowMin { l = e + maxWindowMin } // clamp the window width
        l = min(l, minutesPerDay - 1)
        return (e, l)
    }
}
