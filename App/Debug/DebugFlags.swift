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
/// --tab <today|rest|log|live|data>    open on a tab (`--tab more` = Today with Settings presented)
/// --settings                          present the Settings sheet over the opening tab
/// --widget-gallery                    widget / Live-Activity surfaces at canonical sizes (no tab shell)
/// --wake-gallery                      the Rest wake-window section in every state (no tab shell)
/// --signal-lab [history|hrv|detection|stages]  auto-present the Signal Lab cover at that mode
/// --breathe                           auto-present the Breathe cover AND start a paced session
/// --diagnostics                       auto-present the Diagnostics cover
/// --charge-detail                     push Today → Charge detail after first render
/// --demo-drivers                      fill the Charge detail with specimen drivers
/// --journal                           push Log → Insights after first render
/// --weed                              push Log → Weed after first render
/// --intake                            push Log → Intake after first render
/// --intake-response                   …and on into the seeded tape dinner's response
/// --workouts-list                     push Live → workouts list
/// --workout-detail                    …and on into the newest workout's detail
/// --manual-workout                    …and open the add-workout sheet
/// --honesty-gallery                   every refusal the Rest screen can make, above the fold
/// --rest-night <n>                    open Rest already browsed to the nth slept night back
/// --night-detail                      push Rest → Night detail (movement, why you woke, posture)
/// --reduce-motion                     force the Reduce Motion rendering (simctl can't toggle it)
/// --demo-active-workout               inject a synthetic in-workout session (sim has no BLE)
/// ```
enum DebugFlags {
    /// Read once per process; every flag below derives from this snapshot.
    private static let args = ProcessInfo.processInfo.arguments

    /// `--tab <today|rest|log|live|data>` — the tab AppShell opens on. nil ⇒ the default (`.today`).
    ///
    /// `--tab more` names no tab since 037 removed More, so it resolves to nil here (Today) and
    /// `settings` below presents the Settings sheet the More tab's contents moved into — the old
    /// screenshot route still lands on the same controls.
    ///
    /// `--journal`, `--weed`, `--intake` and `--intake-response` resolve this to `.log` on their own.
    /// `AppShell` builds all five tabs into a `TabView` and an unselected tab's `.task` never runs, so a
    /// seed consumed by `LogScreen` fires only when Log is the tab on screen — on the default `.today`
    /// the flag would be silently inert, the app would launch looking completely normal, and the agent
    /// would be left reading a screenshot of Today unable to tell which link of the route was broken.
    /// Each of these worked with no companion argument before 037 moved its screen to Log (Weed and
    /// the journal from More, Intake from Today), and a rehoming that quietly added one would be a
    /// regression dressed as a cleanup.
    ///
    /// Only the Log chain is defaulted, deliberately — the Live deep links (`--workouts-list` and
    /// friends) still expect `--tab live`, and widening this to a general rule would change flags no
    /// one asked about in a file every screenshot route reads. Resolved here rather than at `AppShell`
    /// because this file is the registry: the whole chain a flag walks should be readable in one
    /// place. An explicit `--tab` still wins: `--tab today --intake` opens Today, where the seed is
    /// inert, exactly as the flag says.
    static let tab: WMTab? = {
        if let explicit = value(after: "--tab").flatMap({ WMTab(rawValue: $0.lowercased()) }) {
            return explicit
        }
        if nightDetail { return .rest }
        return (journal || intake || intakeResponse) ? .log : nil
    }()

    /// `--settings`, or the legacy `--tab more` — present the Settings sheet on launch (037). `AppShell`
    /// reads this to seed its sheet flag, over whichever tab `tab` resolves to (Today for `--tab more`).
    static let settings: Bool = args.contains("--settings")
        || value(after: "--tab")?.lowercased() == "more"

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
    /// Settings › More, and simctl can neither tap nor scroll, so this is the only way to photograph it.
    static let diagnostics = args.contains("--diagnostics")

    /// `--charge-detail` — push Today's Charge detail once the screen has rendered.
    static let chargeDetail = args.contains("--charge-detail")

    /// `--demo-drivers` — specimen driver rows in the Charge detail.
    static let demoDrivers = args.contains("--demo-drivers")

    /// `--weed` — push `WeedScreen` from the Log tab once it has rendered (009; rehomed in 030 and
    /// again in 037).
    ///
    /// It used to push from Today, where the Weed section lived until 029 moved it, and a screenshot
    /// route that diverges from the production route stops being evidence about the production route.
    /// So the seed lives on `LogScreen`, beside the "Weed" row that is Weed's real entry point, and
    /// photographs exactly what a user's tap does.
    ///
    /// The route is two links long — Log → Weed — and the flag needs no help: `tab` above resolves to
    /// `.log` because `journal` below ORs `--weed` in, so `--seed-demo --weed` lands on `WeedScreen`
    /// on its own.
    static let weed = args.contains("--weed")

    /// `--intake` — push Log → Intake once the Log tab has rendered (024; Intake moved from Today to
    /// Log in 037). `tab` above resolves to `.log` for it.
    static let intake = args.contains("--intake")

    /// `--journal` — push Log → Insights (the journal's ranked effects) once the Log tab has rendered
    /// (029; the journal moved from More to Log in 037). Exists because the row shipped with no
    /// destination and nothing caught it: a build cannot tell you a push does nothing, only a run can.
    ///
    /// `--weed` sets it too. Weed hung off the journal screen when the chain was three links long, and
    /// `tab` above keys its `.log` default on this flag, so the OR is what still routes `--weed` alone
    /// to the Log tab — written here rather than at `LogScreen` so one line describes the whole chain.
    /// `LogScreen` reads `weed` on its own to push Weed, so its Insights push has to stand down when
    /// `weed` is set (both are pushes off the same Log stack).
    static let journal = args.contains("--journal") || args.contains("--weed")

    /// `--intake-response` — push Log → Intake AND on into the seeded tape dinner's response: the
    /// newest entry that actually has a tape to draw, so the response screen is reviewable without
    /// tapping through. The demo seed pins one dinner to the 1 Hz fixture it plants
    /// (`DemoSeed.intakeTapeDayIndex`); this is how that tape gets screenshotted in both themes.
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

    /// `--night-detail` — push Rest's Night detail once the first night has been derived (037). The
    /// screen gathers movement, why-you-woke and wrist orientation, which used to sit on the Rest
    /// scroll; without this it is one tap deep and out of simctl's reach. Resolves the tab to Rest on
    /// its own; combine with `--rest-night n` to open an older night's detail.
    static let nightDetail = args.contains("--night-detail")

    /// The token following `flag`, when present (`--tab today` → "today").
    private static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
}
#endif
