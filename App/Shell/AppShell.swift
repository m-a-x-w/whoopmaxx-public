import SwiftUI

/// The five-tab shell (037, IA-1): ground-colored stage, one screen per `WMTab` (Today · Rest ·
/// Log · Live · Data), floating `InkTabBar` at the bottom. Each tab lives in its own `NavigationStack`
/// with the system bar hidden — screens draw their own headers per the design contract.
///
/// The shell also owns the two presentations that used to live on the More tab: the Settings sheet and
/// the Strap health cover. Screens reach them through `AppActions` (`@Environment(\.appActions)`), so
/// Today's gear, its strap chip and Live's strap row do not need to know where either lives.
///
/// DEBUG: launch with `--tab <today|rest|log|live|data>` to open on a specific tab, and `--settings`
/// (or the legacy `--tab more`) to open with Settings presented (UI work / screenshots without tapping).
struct AppShell: View {
    @State private var tab: WMTab
    @StateObject private var presentation = ShellPresentation()

    #if DEBUG
    /// DEBUG: `--breathe` auto-presents the immersive Breathe cover over the shell on launch, so agents
    /// can screenshot the paced session (and it exercises the real `.fullScreenCover` env propagation).
    @State private var showBreatheDebug = DebugFlags.breathe

    /// DEBUG: `--signal-lab [history|hrv|detection|stages]` auto-presents the Signal Lab cover on launch
    /// (mode defaults to history when the value is missing/unknown), so agents can screenshot the
    /// lab panels without tapping through Data › Labs.
    @State private var showSignalLabDebug = DebugFlags.signalLab != nil

    /// DEBUG: `--diagnostics` auto-presents the install self-check cover (034), which is otherwise
    /// behind Today's gear → Settings › More.
    @State private var showDiagnosticsDebug = DebugFlags.diagnostics
    #endif

    init() {
        _tab = State(initialValue: Self.initialTab())
    }

    @ViewBuilder
    var body: some View {
        #if DEBUG
        // DEBUG: `--widget-gallery` renders the widget/Live-Activity surfaces at canonical sizes for
        // agent screenshots, bypassing the tab shell (pass alongside `--seed-demo`).
        if DebugFlags.gallery == .widget {
            WidgetGallery()
        } else if DebugFlags.gallery == .wake {
            // DEBUG: render the Rest wake-window section (W9) in every state for agent screenshots,
            // bypassing the tab shell + the Last-night hero that pushes it below the fold.
            WakeWindowGallery()
        } else if DebugFlags.gallery == .honesty {
            // DEBUG: every honest-refusal state Rest can render, side by side. They live on nights the
            // simulator cannot reach and below a hero simctl cannot scroll past, so this is the only
            // place they can be looked at in the running app.
            HonestyGallery()
        } else {
            mainStage
                // `autoStart` is the ONLY thing that starts a paced session unprompted — BreatheScreen no
                // longer re-reads `--breathe` itself, so reaching Breathe from Live in a `--breathe` build
                // still waits for a tap.
                .fullScreenCover(isPresented: $showBreatheDebug) { BreatheScreen(autoStart: true) }
                .fullScreenCover(isPresented: $showSignalLabDebug) {
                    SignalLabScreen(initialMode: DebugFlags.signalLab ?? .history)
                }
                .fullScreenCover(isPresented: $showDiagnosticsDebug) { DiagnosticsScreen() }
        }
        #else
        mainStage
        #endif
    }

    private var mainStage: some View {
        ZStack {
            WM.Ground.ground
                .ignoresSafeArea()
            screen
                // Every tab screen (and everything it pushes) can open Settings or Strap health. The value
                // is built ONCE by `ShellPresentation`, so a tab switch — which re-runs this body — hands
                // the environment the same closures rather than fresh ones.
                .environment(\.appActions, presentation.actions)
        }
        .safeAreaInset(edge: .bottom) {
            // Ground fade behind the floating pill: content scrolling under it dissolves into the paper
            // instead of colliding with the bar's transparent surroundings. The pill's 44pt side inset
            // and 4pt bottom gap are padding inside `InkTabBar`, whose frame already spans the full
            // width, so the fade only has to reach up past the pill's top edge and down through the
            // home indicator.
            InkTabBar(selection: $tab)
                .background(
                    LinearGradient(
                        colors: [WM.Ground.ground.opacity(0), WM.Ground.ground],
                        startPoint: .top, endPoint: .bottom
                    )
                    .padding(.top, -WM.Space.sectionTight)
                    .ignoresSafeArea(edges: .bottom)
                )
        }
        // Settings (037): what the More tab held, as a large sheet over whichever tab is showing.
        .sheet(isPresented: $presentation.showsSettings) {
            SettingsScreen()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(WM.Radius.sheet)
                .presentationBackground(WM.Ground.ground)
        }
        // Strap health stays a full-screen cover, as it was from More → Strap. Every object it reads
        // (StrapHealthModel, Repository, LiveState, AppRoot, BuzzLog) propagates from the app root.
        // Settings' own Strap row presents its own cover from inside the sheet; this one is what the
        // screens outside Settings open.
        .fullScreenCover(isPresented: $presentation.showsStrapHealth) {
            StrapHealthScreen()
        }
    }

    /// The five tab screens. A `TabView` (with the SYSTEM tab bar hidden — the floating `InkTabBar` is the
    /// only visible chrome) rather than a plain `switch`: a switch produces `_ConditionalContent`, which
    /// tears down the inactive branch entirely, so every per-tab `@State` (Data's search + pushed
    /// MetricDetail, Today's day-offset, Live's pushed WorkoutsList, scroll offset) was silently reset on
    /// each tab switch. TabView keeps all five alive so state survives, while still firing each screen's
    /// onAppear/onDisappear per selection (LiveScreen's realtime arm/disarm is unchanged).
    private var screen: some View {
        TabView(selection: $tab) {
            stack { TodayScreen() }.tag(WMTab.today)
            stack { RestScreen() }.tag(WMTab.rest)
            stack { LogScreen() }.tag(WMTab.log)
            stack { LiveScreen() }.tag(WMTab.live)
            stack { DataScreen() }.tag(WMTab.data)
        }
    }

    /// Per-tab navigation container with the system navigation bar hidden. The extra bottom safe-area
    /// clearance guarantees a scroll view's last rows come to rest ABOVE the floating InkTabBar (and its
    /// gradient fade) rather than under it — harmless on short screens (invisible scroll extension), and
    /// it clears the pill on long ones (metric list, rest history, workout detail).
    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .toolbar(.hidden, for: .navigationBar)
                // iOS 26 resolves tab-bar visibility from the SELECTED tab's content, not the TabView:
                // hiding it here (per NavigationStack) suppresses the system Liquid-Glass bar that
                // otherwise renders a faint empty pill BELOW the custom floating InkTabBar. Hiding it on
                // the TabView alone left that leftover bar visible — so it lives here instead.
                .toolbar(.hidden, for: .tabBar)
                .safeAreaPadding(.bottom, WM.Space.sectionLoose)
        }
    }

    /// Initial tab: `.today`, overridable in DEBUG via the `--tab <name>` launch argument (and routed to
    /// `.log` by the Log deep-link flags — see `DebugFlags.tab`).
    private static func initialTab() -> WMTab {
        #if DEBUG
        if let override = DebugFlags.tab { return override }
        #endif
        return .today
    }
}

/// The shell's two presentation flags, plus the `AppActions` that set them.
///
/// A small reference type rather than two `@State` Bools on `AppShell` for one reason: the actions.
/// Closures built inside `AppShell.body` would be new closures on every pass, and the shell's body re-runs
/// on every tab switch — so each switch would hand the environment an `AppActions` that no longer
/// compares equal, invalidating every screen that reads `appActions` (all five tabs). Built once here,
/// the value is the same on every pass.
private final class ShellPresentation: ObservableObject {
    /// The Settings sheet. DEBUG seeds it from `--settings` / `--tab more`.
    @Published var showsSettings: Bool
    /// The Strap health cover.
    @Published var showsStrapHealth = false

    /// Handed to the tab content via `.environment(\.appActions, …)`. Weak: this object owns the value.
    private(set) lazy var actions: AppActions = AppActions(
        openSettings: { [weak self] in self?.showsSettings = true },
        openStrapHealth: { [weak self] in self?.showsStrapHealth = true })

    init() {
        #if DEBUG
        showsSettings = DebugFlags.settings
        #else
        showsSettings = false
        #endif
    }
}
