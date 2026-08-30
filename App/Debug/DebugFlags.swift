#if DEBUG
import Foundation

/// THE registry of DEBUG launch arguments. Per-wave screenshot verification is a
/// requirement, and the simulator has no BLE — so every "open straight to this surface" entry point an
/// agent needs is declared here, in one list, instead of being spelled out as a raw `argv` string at the
/// site that happens to consume it.
///
/// Two invariants this replaces the old scattered reads with:
///
/// - **Snapshotted ONCE.** `args` is read a single time at first touch and every flag is a `static let`,
///   so nothing re-scans `ProcessInfo.processInfo.arguments` on every SwiftUI body evaluation (AppShell
///   and BreatheScreen both used to) and no flag can read differently at two points in a launch.
/// - **One idiom.** `ProcessInfo.processInfo.arguments` everywhere; `CommandLine.arguments` (the other
///   spelling that was in the tree) names the same array.
///
/// Whole file is `#if DEBUG` — no launch argument reaches a release build. (`--seed-demo` /
/// `--seed-demo-edge` stay on `DemoSeed.requested`, which is `#if DEBUG` in the data layer where the seed
/// itself lives.)
///
/// Usage, all alongside `--seed-demo` unless noted:
///
/// ```
/// --tab <today|rest|data|live|more>   open on a tab
/// --widget-gallery                    widget / Live-Activity surfaces at canonical sizes (no tab shell)
/// --wake-gallery                      the Rest wake-window section in every state (no tab shell)
/// --signal-lab [history|hrv|detection]  auto-present the Signal Lab cover
/// --breathe                           auto-present the Breathe cover AND start a paced session
/// --charge-detail                     push Today → Charge detail after first render
/// --demo-drivers                      fill the Charge detail with specimen drivers
/// --journal                           push More → Journal insights after first render
/// --weed                              …and on into the Weed detail
/// --workouts-list                     push Live → workouts list
/// --workout-detail                    …and on into the newest workout's detail
/// --manual-workout                    …and open the add-workout sheet
/// --honesty-gallery                   every refusal the Rest screen can make, above the fold
/// --rest-night <n>                    open Rest already browsed to the nth slept night back
/// --reduce-motion                     force the Reduce Motion rendering (simctl can't toggle it)
/// --demo-active-workout               inject a synthetic in-workout session (sim has no BLE)
/// ```
enum DebugFlags {
    /// Read once per process; every flag below derives from this snapshot.
    private static let args = ProcessInfo.processInfo.arguments

    /// `--tab <today|rest|data|live|more>` — the tab AppShell opens on. nil ⇒ the default (`.today`).
    ///
    /// `--journal` (and `--weed`, which ORs into it) resolves this to `.more` on its own. `AppShell`
    /// builds all five tabs into a `TabView` and an unselected tab's `.task` never runs, so a seed
    /// consumed by `MoreScreen` fires only when More is the tab on screen — on the default `.today`
    /// the flag would be silently inert, the app would launch looking completely normal, and the agent
    /// would be left reading a screenshot of Today unable to tell which link of the route was broken.
    /// `--weed` reached its detail from Today until 030 rehomed it, i.e. it worked with no companion
    /// argument, and a rehoming that quietly added one would be a regression dressed as a cleanup.
    ///
    /// Only the More chain is defaulted, deliberately — the Live deep links (`--workouts-list` and
    /// friends) still expect `--tab live`, and widening this to a general rule would change flags no
    /// one asked about in a file every screenshot route reads. Resolved here rather than at `AppShell`
    /// because this file is the registry: the whole chain a flag walks should be readable in one
    /// place. An explicit `--tab` still wins, so `--tab more --journal` behaves exactly as before.
    static let tab: WMTab? = {
        if let explicit = value(after: "--tab").flatMap({ WMTab(rawValue: $0.lowercased()) }) {
            return explicit
        }
        return journal ? .more : nil
    }()

    /// A full-screen gallery that BYPASSES the tab shell entirely.
    enum Gallery {
        /// `--widget-gallery`
        case widget
        /// `--wake-gallery`
        case wake
        /// `--honesty-gallery` — every refusal the Rest screen can make, above the fold.
        case honesty
    }

    /// `--widget-gallery` / `--wake-gallery`. Widget wins if both are passed (the old if/else-if order).
    static let gallery: Gallery? = args.contains("--widget-gallery") ? .widget
        : (args.contains("--wake-gallery") ? .wake
           : (args.contains("--honesty-gallery") ? .honesty : nil))

    /// `--signal-lab [history|hrv|detection|stages]` — non-nil ⇒ present the cover, at this mode. The
    /// mode defaults to `.history` when the value is missing or unrecognized (the flag alone is valid).
    ///
    /// The `default:` arm is what keeps an unrecognized value harmless, and it is also what silently ate
    /// `stages` when 030 added the per-stage HRV panel: the panel shipped as a fourth
    /// `SignalLabScreen.Mode`, but with no line here `--signal-lab stages` opened History instead and the
    /// only route to the new surface was a manual tap. Every case of `Mode` needs its own arm — the
    /// fallback cannot tell "no value was passed" from "a mode nobody mapped".
    static let signalLab: SignalLabScreen.Mode? = {
        guard args.contains("--signal-lab") else { return nil }
        switch value(after: "--signal-lab")?.lowercased() {
        case "hrv":       return .hrv
        case "detection": return .detection
        case "stages":    return .stages
        default:          return .history
        }
    }()

    /// `--breathe` — present the immersive Breathe cover on launch and auto-start the paced session.
    static let breathe = args.contains("--breathe")

    /// `--diagnostics` — present the Diagnostics cover on launch (034). The screen is a cover behind
    /// More → Tools, and simctl can neither tap nor scroll, so this is the only way to photograph it.
    static let diagnostics = args.contains("--diagnostics")

    /// `--charge-detail` — push Today's Charge detail once the screen has rendered.
    static let chargeDetail = args.contains("--charge-detail")

    /// `--demo-drivers` — specimen driver rows in the Charge detail.
    static let demoDrivers = args.contains("--demo-drivers")

    /// `--weed` — push `WeedScreen` once the JOURNAL screen has rendered (009; rehomed in 030).
    ///
    /// It used to push from Today, where the Weed section lived until 029 moved it. After that move
    /// the flag was the last weed reference on that screen: a `@State` and a `#if DEBUG`
    /// `.navigationDestination` kept alive for one launch argument, pushing a detail whose section
    /// had been deleted, under a "Today" back label naming an origin no user can push from. A
    /// screenshot route that diverges from the production route stops being evidence about the
    /// production route. The seed now lives on `JournalScreen`, beside the "Weed" row that is Weed's
    /// real entry point, and photographs exactly what a user's tap does.
    ///
    /// The route is three links long — More → Journal → Weed — and the flag still needs no help:
    /// `journal` below ORs `--weed` in, and `tab` above resolves to `.more` because of it, so
    /// `--seed-demo --weed` lands on `WeedScreen` on its own.
    static let weed = args.contains("--weed")

    /// `--intake` — push Today's Intake detail once the screen has rendered (024). The Today
    /// "Intake" section needs no flag: it mounts on every day, seeded or not.
    static let intake = args.contains("--intake")

    /// `--journal` — push More's Journal once the screen has rendered (029). Exists because the row
    /// shipped with no destination and nothing caught it: a build cannot tell you a push does
    /// nothing, only a run can.
    ///
    /// `--weed` sets it too, because Weed now hangs off the Journal screen: a flag that seeds the far
    /// end of a chain has to seed every link before it. Same idiom as `LiveScreen`, whose
    /// workouts-list seed ORs in the two flags that push PAST the list — written here rather than at
    /// `MoreScreen` so one line describes the whole chain.
    static let journal = args.contains("--journal") || args.contains("--weed")

    /// `--intake-response` — push the Intake detail AND on into the newest entry that actually has a
    /// tape to draw, so the response screen is reviewable without tapping through. The demo seed
    /// pins one dinner to the 1 Hz fixture it plants (`DemoSeed.intakeTapeDayIndex`); this is how
    /// that tape gets screenshotted in both themes.
    static let intakeResponse = args.contains("--intake-response")
    /// `--workouts-list` — push Live's workouts list.
    static let workoutsList = args.contains("--workouts-list")

    /// `--workout-detail` — push the workouts list AND on into the newest workout.
    static let workoutDetail = args.contains("--workout-detail")

    /// `--manual-workout` — push the workouts list AND open its add-workout sheet.
    static let manualWorkout = args.contains("--manual-workout")

    /// `--reduce-motion` — force the Reduce Motion rendering (simctl can't toggle the real setting).
    static let reduceMotion = args.contains("--reduce-motion")

    /// `--demo-active-workout` — inject a synthetic in-workout session so the Live session block renders.
    static let demoActiveWorkout = args.contains("--demo-active-workout")

    /// `--rest-night <n>` — open Rest already BROWSED to the nth slept night back (0 = newest, the
    /// default). nil ⇒ no browse at all, byte-identical to before.
    ///
    /// EXISTS BECAUSE THE HONEST STATES WERE THE UNPHOTOGRAPHABLE ONES. Five plans running ended their
    /// verification section with some form of "this cannot be screenshot-verified": the aged-out lines,
    /// the low-confidence caveat, the clipped-window silence and the browsed copy all live on nights
    /// the simulator can only reach by tapping a chevron a dozen times. So the states this project
    /// works hardest to get right were the only ones nobody ever looked at. One integer closes that.
    static let restNight: Int? = value(after: "--rest-night").flatMap(Int.init).map { max(0, $0) }

    /// The token following `flag`, when present (`--tab today` → "today").
    private static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
}
#endif
