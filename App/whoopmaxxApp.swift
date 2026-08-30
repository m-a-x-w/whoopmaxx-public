import Foundation
import SwiftUI
import WidgetKit

/// whoopmaxx — a standalone WHOOP-strap companion. Precision instrument on paper:
/// vivid data color on warm neutral grounds, SF Pro light numerals, bars everywhere.
/// Not affiliated with WHOOP.
@main
struct WhoopmaxxApp: App {
    @StateObject private var root = AppRoot()
    @Environment(\.scenePhase) private var scenePhase

    /// First-run gate: false until the user finishes (or skips through) the three-step first run.
    /// `--seed-demo` bypasses it — demo-seeded UI work / screenshots land straight on the shell.
    @AppStorage("wm.onboarded") private var onboarded = false

    /// Appearance override: "system" (follow iOS), "light", or "dark" — applied as `.preferredColorScheme`
    /// on the root so it wins over the device setting. Both themes are first-class (design language).
    @AppStorage("ui.appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            Group {
                if root.relaunchRequired {
                    // A restore landed in THIS process. The live GRDB pools now point at the inode Gate 6
                    // deleted, so every further read is pre-restore and every further write goes into a
                    // ghost file that the relaunch discards. The relaunch model is the app's whole safety
                    // argument for the swap, so it has to be a wall, not a caption.
                    RelaunchWall(receipt: root.restoreReceipt)
                } else if onboarded || DemoSeed.requested {
                    AppShell()
                } else {
                    FirstRun()
                }
            }
            .preferredColorScheme(WMAppearance.scheme(for: appearance))
            .environmentObject(root)
            .environmentObject(root.repo)
            .environmentObject(root.workoutRepo)
            // The manual-workout recorder publishes `activeWorkout` / `justEndedWorkout` itself — a
            // nested ObservableObject is NOT observed through `root`, so the Live screens must see it
            // directly or the session block would never re-render.
            .environmentObject(root.workout)
            .environmentObject(root.live)
            .environmentObject(root.profile)
            .environmentObject(root.scores)
            .environmentObject(root.liveActivity)
            .environmentObject(root.healthExport)
            .environmentObject(root.alarm)
            .environmentObject(root.alarm.settings)
            .environmentObject(root.journal)
            .environmentObject(root.weed)
            .environmentObject(root.intake)
            .environmentObject(root.habits)
            .environmentObject(root.strapHealth)
            .environmentObject(root.buzzLog)
            .task {
                // TEST-HOST GUARD. Must stay the FIRST statement here — everything below is a
                // process-global side effect, and the point is that none of them run under the suite.
                //
                // The unit bundle is HOSTED: `whoopmaxxTests` depends on the app target (project.yml),
                // which XcodeGen turns into `TEST_HOST`, so `xcodebuild test` LAUNCHES this app and
                // injects the test bundle into it. Without a guard the launch chain below runs
                // concurrently with the tests, in the same process, over the same
                // `UserDefaults.standard` — and it writes precisely the keys the suite owns:
                // `root.start()` reaches `Spo2Heal.runIfNeeded` and `SleepHrvHeal.finish`, each of which
                // stamps its one-shot done-key. `Spo2HealTests` / `SleepHrvHealTests` clear that key and
                // then assert on a fresh pass, so a launch-chain stamp landing between a test's clear and
                // its own call makes that pass early-return 0 and the test fail — a flake with no bug
                // behind it. The chain also leaves `Job.analyzeTick`, `Job.retentionSweep` and the
                // midnight RunLoop timer armed for the whole run. Those two suites already defend the
                // REVERSE direction (they snapshot and restore the flag so the tests don't corrupt the
                // live app's state, noting the bundle is hosted); this is the missing other half.
                //
                // The justification is UserDefaults isolation plus timer hygiene, nothing more: tests use
                // throwaway temp stores, no `.wmbak` is written, and there is no whole-history rescore.
                //
                // A shipping launch runs exactly the chain it ran before. XCTest is not linked into the
                // app outside a test run, so `NSClassFromString("XCTestCase")` is nil in every normal
                // launch — device, simulator, `--seed-demo` screenshot runs, all of them — and
                // `XCTestConfigurationFilePath` is exported by the test runner only. The class lookup is
                // the load-bearing check (it is what reliably holds for an injected bundle); the env var
                // is belt-and-braces and must NOT be used on its own. Skipping the chain costs the suite
                // nothing: no test constructs or observes an `AppRoot`.
                guard NSClassFromString("XCTestCase") == nil,
                      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                else { return }
                // Arm every process-global launch side effect (notification delegate, midnight re-arm,
                // the periodic jobs, crash-recovery rehydrate). Deliberately NOT in `AppRoot.init`, so a
                // `#Preview` that builds an AppRoot to satisfy an environment object does none of it.
                // FIRST of all: re-apply a heal re-arm left pending by a restore. This MUST run before
                // anything opens the store — `StoreMaintenance.purgeDegenerateRespSamplesIfNeeded` runs
                // inside `Repository.ensureStore`, so a later call would find that entry already spent.
                RestoreHealReset.applyPendingRearm()
                // Then arm every process-global launch side effect (notification delegate, midnight
                // re-arm, the periodic jobs, crash-recovery rehydrate). Deliberately NOT in
                // `AppRoot.init`, so a `#Preview` that builds an AppRoot does none of it.
                // The rehydrate + demo-active-workout injection must land before the seed and the first
                // refresh below.
                root.start()
                // DEBUG `--seed-demo` (sim has no BLE): seed once into an empty store, then run
                // the real loop — refresh surfaces stored data at once, the forced analyze pass
                // scores any raw history and refreshes again when it persists.
                await DemoSeed.runIfRequested(store: root.repo.storeHandle())
                // First journal chip-cache load (after the seed so demo tags surface at once).
                await root.journal.refresh()
                // First weed session-cache load (009). STRICTLY after the journal's: the repair pass
                // compares session days against `journal.tagsByDay`, so an empty tag cache would read
                // every session day as missing its boolean and cost a pointless forced rescore.
                await root.weed.refresh()
                // First intake event-cache load (024). STRICTLY after the journal's for the same
                // reason: the repair pass compares the tags the events OWE against `journal.tagsByDay`,
                // so an empty tag cache would read every one as missing and cost a pointless forced
                // rescore. Unlike weed's, this repair can only ever RAISE a tag.
                await root.intake.refresh()
                // Pull in anything logged from the Home Screen widget while the app was closed (028).
                // AFTER `refresh()` so the drain's writes land on a warm cache, and after the
                // journal's for the same reason every intake path is.
                await root.intake.drainOutbox()
                // First habits cache load (008) — definitions + trailing-window logs.
                await root.habits.refresh()
                // Debug canary: a missing App-Group entitlement makes every widget/Live-Activity write a
                // silent no-op; trip it here rather than let it read as "widget shows nothing yet."
                WidgetSnapshot.assertGroupProvisioned()
                // Launch IS a raw-history change (a relaunch after an import, or just the first read of
                // whatever the strap banked while we were gone): the ONE seam runs refresh → forced
                // rescore → widget publish → Apple Health push, in that order, so launch can't drift from
                // the post-sync path. The leading refresh surfaces stored data before the analyze runs;
                // the Health push is a no-op unless the user already enabled it (auth is resumed silently
                // in AppRoot.start() — launch never REQUESTS auth, only the More toggle does).
                await root.dataDidChange(.rawHistory)
                // Mirror the appearance pref into the App Group so the widget / Live-Activity process can
                // honor it (it can't read standard defaults). On launch covers installs that set the pref
                // before the mirror existed; onChange below keeps it live.
                WMAppearance.mirror(appearance)
            }
            .onChange(of: appearance) { _, raw in
                // Restyle both extension surfaces the moment the pref flips: re-mirror, reload widget
                // timelines, and re-push a running Live Activity's content so it re-renders now instead
                // of on its next natural update.
                WMAppearance.mirror(raw)
                WidgetCenter.shared.reloadAllTimelines()
                root.liveActivity.refreshContent()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    // The one publish point OUTSIDE `dataDidChange`: refresh the glance whenever the app
                    // returns to the foreground (no data changed — only the snapshot's freshness).
                    root.publishWidget()
                    // And pull in any Home Screen taps made while we were backgrounded (028). Safe
                    // to fire on every activation: the drain is idempotent and returns immediately
                    // when the outbox is empty, which is the overwhelmingly common case.
                    Task { await root.intake.drainOutbox() }
                    // Same shape — nothing changed, only what we know about it. The store's data
                    // frontier is otherwise re-read ONLY while an offload runs (AppRoot's two sinks are
                    // both gated on `backfilling`), so a process that comes back after three days away
                    // holds whatever frontier the last mid-sync foreground left behind — or nil, which
                    // reads as "first sync". Every "how far behind is the store" answer is derived from
                    // this value, so re-reading it here is what keeps that answer from being stale by
                    // exactly the amount it is trying to report. One cheap indexed MAX(ts) per
                    // foreground; the offload path throttles the same read to 1/s.
                    root.refreshPersistedFrontier()
                    // iOS can't run timers while suspended, so foreground is a smart-alarm re-arm point
                    // (self-gates on the alarm being enabled). Joins the daily 00:01 timer + bond edge.
                    root.alarm.apply()
                    // Same reason, for the steady-state analyze tick: a suspended process doesn't resume
                    // `Task.sleep`, so returning to the foreground could otherwise sit up to 15 minutes on
                    // stale scores. Fire ONE non-forced pass now — the #836 fingerprint gate makes it free
                    // when nothing new landed while we were away. (Foreground is a catch-up point, not a
                    // reason to suspend the register: `bluetooth-central` grants BLE wake-ups, not
                    // continuous scheduling, so there is nothing to suspend on `.background`.)
                    Task { await root.dataDidChange(.idleTick) }
                    // C5: revalidate Apple Health write-auth on foreground — a revocation in Settings must
                    // downgrade `.authorized → .denied` so the More caption stops claiming we're writing
                    // (a fresh grant likewise resumes export). No-op unless the state is revocable.
                    root.healthExport.refreshAuth()
                    // The retention sweep's real trigger. Its 6-hourly `PeriodicWork` job only ticks while
                    // the process runs AND skips its first interval, so an app the OS keeps recycling never
                    // swept at all — leaving the store's only growth bound unenforced. Self-gates on a
                    // persisted stamp, so the common case is one UserDefaults read.
                    Task { await root.sweepRetentionIfDue() }
                }
            }
        }
    }
}
