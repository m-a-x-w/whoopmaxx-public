import Foundation
import ActivityKit

/// Starts, updates, and ends the live-HR Live Activity (Lock Screen + Dynamic Island). Ported from
/// the original LiveActivityController, split so the start/stop logic lives in the pure `LiveActivityDecision`
/// (unit-tested) and this type only bridges to ActivityKit. Two entry points:
///
/// - `sync(...)` — the continuous driver called on every live HR / connection change (auto path). It
///   auto-starts only when the user's `wm.liveActivity.autoStart` toggle is on; once an activity exists it
///   keeps updating regardless of the toggle and ends the instant the link drops.
/// - `startManually(...)` — the Live tab's "Pin to Lock Screen" button. Forces a start (ignoring the
///   toggle) as long as the system allows it, a link is up, and a bpm is present.
///
/// `isRunning` is published so the Live tab's button can flip between Pin and Stop.
@MainActor
final class LiveActivityController: ObservableObject {
    @Published private(set) var isRunning = false

    private var activity: Activity<WMActivityAttributes>?
    private var lastPush: Date = .distantPast
    /// Cached auth bridge — `sync` runs at ~1 Hz off the live HR stream, and instantiating this per tick
    /// is needless allocation. Live-Activity auth only changes via Settings, so caching is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent starts — a second tick arriving while the first `request` is in
    /// flight would otherwise spawn a duplicate activity.
    private var isStarting = false
    /// Latch set when the user taps Stop, so the auto path doesn't re-start the activity on the very next
    /// HR tick (the toggle would otherwise defeat an explicit Stop). Cleared on a manual pin and whenever
    /// the link drops — a dropped link ends the session, so the next fresh connect may auto-start again.
    private var userStopped = false
    /// Ids of activities currently being torn down (the async end() is in flight). `adoptExistingActivity`
    /// skips these so a reconnect can't re-grab a dying activity mid-teardown.
    private var endingIDs: Set<String> = []
    /// How long after the last push iOS keeps the activity "fresh". Refreshed every ~2 s while streaming,
    /// so this never bites a live session; it auto-greys a frozen activity if the app is suspended/killed
    /// without an explicit end.
    private static let staleAfter: TimeInterval = 120

    /// UserDefaults key for the auto-start preference (default OFF — nothing pins until the user opts in).
    /// `nonisolated` so the (nonisolated) `.wmbak` settings whitelist can name it — an immutable `String`.
    nonisolated static let autoStartKey = "wm.liveActivity.autoStart"
    static func autoStartEnabled() -> Bool { UserDefaults.standard.bool(forKey: autoStartKey) }

    /// The iOS master switch for Live Activities. The Live tab reads this to disable the pin button with
    /// a "turn it on in Settings" hint.
    var systemEnabled: Bool { authInfo.areActivitiesEnabled }

    // MARK: - Drivers

    /// Continuous auto path — called on every live HR / connection change.
    func sync(bpm: Int?, charge: Int?, effort: Int?, connected: Bool) {
        // A dropped link ends the session; clear the manual-stop latch so auto-start can fire again on the
        // next fresh connect (else one Stop tap would suppress auto-start until relaunch).
        if !connected { userStopped = false }
        apply(autoStartEnabled: Self.autoStartEnabled() && !userStopped,
              bpm: bpm, charge: charge, effort: effort, connected: connected)
    }

    /// Manual path — the Live tab's "Pin to Lock Screen" button. Forces a start regardless of the toggle,
    /// and clears the stop latch (the user explicitly wants it pinned).
    func startManually(bpm: Int?, charge: Int?, effort: Int?, connected: Bool) {
        userStopped = false
        apply(autoStartEnabled: true,
              bpm: bpm, charge: charge, effort: effort, connected: connected)
    }

    /// Re-push the running activity's CURRENT content unchanged so the extension re-renders — the
    /// appearance-pref path (the extension re-reads the mirrored `ui.appearance` on every render, but a
    /// pref change alone doesn't trigger one). Bypasses the 2 s throttle deliberately: pref flips are rare,
    /// user-driven, and should restyle at once. No-op when nothing is running.
    func refreshContent() {
        adoptExistingActivity()
        guard let activity else { return }
        lastPush = Date()
        let content = ActivityContent(state: activity.content.state,
                                      staleDate: Date().addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content) }
    }

    /// Explicit user stop — ends any running activity immediately and latches so the auto path won't
    /// re-start it on the next heartbeat.
    func stop() {
        userStopped = true
        endCurrentActivities()
    }

    // MARK: - Apply

    private func apply(autoStartEnabled: Bool, bpm: Int?, charge: Int?, effort: Int?, connected: Bool) {
        adoptExistingActivity()

        let action = LiveActivityDecision.decide(
            systemEnabled: systemEnabled, connected: connected, hasBpm: bpm != nil,
            activityExists: activity != nil, autoStartEnabled: autoStartEnabled)

        switch action {
        case .none:
            break
        case .end:
            endCurrentActivities()
        case .start:
            start(bpm: bpm, charge: charge, effort: effort, connected: connected)
        case .update:
            update(bpm: bpm, charge: charge, effort: effort, connected: connected)
        }
    }

    private func state(bpm: Int?, charge: Int?, effort: Int?, connected: Bool) -> WMActivityAttributes.ContentState {
        WMActivityAttributes.ContentState(bpm: bpm, charge: charge, effort: effort, bonded: connected)
    }

    private func start(bpm: Int?, charge: Int?, effort: Int?, connected: Bool) {
        // Set the start gate SYNCHRONOUSLY before any await so a second tick arriving on the main actor
        // bails here instead of issuing a second request.
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        let staleDate = Date().addingTimeInterval(Self.staleAfter)
        do {
            let act = try Activity.request(
                attributes: WMActivityAttributes(title: String(localized: "Live HR")),
                content: ActivityContent(state: state(bpm: bpm, charge: charge, effort: effort, connected: connected),
                                         staleDate: staleDate),
                pushType: nil)
            activity = act
            lastPush = Date()
            isRunning = true
            observeState(of: act)
        } catch {
            activity = nil
            isRunning = false
        }
    }

    /// C4: watch an activity's state so an EXTERNAL end (user swipes it away, or iOS ends a stale one)
    /// clears our cached handle + `isRunning` — otherwise the Live tab keeps showing "Pinned — Stop" for a
    /// dead activity and re-adopt logic reasons about a ghost. The Task inherits this @MainActor context,
    /// self-terminates when the activity ends, and only clears state if we still hold THAT activity.
    private func observeState(of act: Activity<WMActivityAttributes>) {
        Task { [weak self] in
            for await phase in act.activityStateUpdates {
                guard phase == .ended || phase == .dismissed else { continue }
                guard let self else { return }
                if self.activity?.id == act.id {
                    self.activity = nil
                    self.isRunning = false
                }
                return
            }
        }
    }

    private func update(bpm: Int?, charge: Int?, effort: Int?, connected: Bool) {
        guard let activity else { return }
        // Throttle to ~once every 2 s so we stay well under the Live-Activity update budget.
        guard Date().timeIntervalSince(lastPush) > 2 else { return }
        lastPush = Date()
        let staleDate = Date().addingTimeInterval(Self.staleAfter)
        let content = ActivityContent(state: state(bpm: bpm, charge: charge, effort: effort, connected: connected),
                                      staleDate: staleDate)
        Task { await activity.update(content) }
        isRunning = true
    }

    /// Re-adopt an activity that outlived a previous app session (ActivityKit keeps Live Activities alive
    /// across launches, but a fresh controller starts with `activity == nil`, so without recovering the
    /// handle we could neither update nor END an already-showing activity). Skips any activity currently
    /// being torn down (`endingIDs`) so a reconnect racing an end() can't re-grab a dying activity — which
    /// would leave `isRunning` stale after the teardown completes.
    private func adoptExistingActivity() {
        guard activity == nil else { return }
        activity = Activity<WMActivityAttributes>.activities.first { !endingIDs.contains($0.id) }
        if let act = activity {
            // An adopted activity is by definition currently live (it's in `Activity.activities`), so mark it
            // running. Without this, a fresh controller that adopts a Lock-Screen activity surviving an app
            // relaunch keeps isRunning=false while `decide` returns .none (linked but no bpm yet) — so the Live
            // tab shows "Pin" (calling pinLiveActivity, which .none's again) and stop() is unreachable, leaving
            // a stale activity the user can't dismiss. observeState still flips it false on external end.
            isRunning = true
            observeState(of: act)   // C4: watch a re-adopted activity too
        }
    }

    /// End every whoopmaxx activity that exists RIGHT NOW. The live list is snapshotted SYNCHRONOUSLY and
    /// the handle + `isRunning` cleared before the await, so a concurrent reconnect that starts a FRESH
    /// activity during the teardown isn't in the snapshot and survives. The snapshot's ids are held in
    /// `endingIDs` until the teardown finishes so `adoptExistingActivity` can't re-adopt a dying one.
    /// Also covers a straggler from a prior session we never re-adopted and any rare duplicate.
    private func endCurrentActivities() {
        let toEnd = Activity<WMActivityAttributes>.activities
        activity = nil
        isRunning = false
        guard !toEnd.isEmpty else { return }
        let ids = toEnd.map(\.id)
        endingIDs.formUnion(ids)
        Task {
            for act in toEnd { await act.end(nil, dismissalPolicy: .immediate) }
            endingIDs.subtract(ids)
        }
    }
}
