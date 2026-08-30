import SwiftUI

/// The five-tab shell: ground-colored stage, one screen per `WMTab`, floating `InkTabBar` at the
/// bottom. Each tab lives in its own `NavigationStack` with the system bar hidden — screens draw
/// their own headers per the design contract.
///
/// DEBUG: launch with `--tab <today|rest|data|live|more>` to open on a specific tab (UI work /
/// screenshots without tapping through).
struct AppShell: View {
    @State private var tab: WMTab

    #if DEBUG
    /// DEBUG: `--breathe` auto-presents the immersive Breathe cover over the shell on launch, so agents
    /// can screenshot the paced session (and it exercises the real `.fullScreenCover` env propagation).
    @State private var showBreatheDebug = DebugFlags.breathe

    /// DEBUG: `--signal-lab [history|hrv|detection]` auto-presents the Signal Lab cover on launch
    /// (mode defaults to history when the value is missing/unknown), so agents can screenshot the
    /// lab panels without tapping through More.
    @State private var showSignalLabDebug = DebugFlags.signalLab != nil

    /// DEBUG: `--diagnostics` auto-presents the install self-check cover (034), which is otherwise two
    /// taps deep behind More → Tools.
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
                // longer re-reads `--breathe` itself, so reaching Breathe from More in a `--breathe` build
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
        }
        .safeAreaInset(edge: .bottom) {
            // Ground fade behind the floating pill: content scrolling under it dissolves into the
            // paper instead of colliding with the bar's transparent surroundings.
            InkTabBar(selection: $tab)
                .background(
                    LinearGradient(
                        colors: [WM.Ground.ground.opacity(0), WM.Ground.ground],
                        startPoint: .top, endPoint: .bottom
                    )
                    .padding(.top, -28)
                    .padding(.horizontal, -WM.Space.gutter)
                    .ignoresSafeArea(edges: .bottom)
                )
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
            stack { DataScreen() }.tag(WMTab.data)
            stack { LiveScreen() }.tag(WMTab.live)
            stack { MoreScreen() }.tag(WMTab.more)
        }
    }

    /// Per-tab navigation container with the system navigation bar hidden. The extra bottom safe-area
    /// clearance guarantees a scroll view's last rows come to rest ABOVE the floating InkTabBar (and its
    /// gradient fade) rather than under it — harmless on short screens (invisible scroll extension), and
    /// it clears the pill on long ones (metric wall, rest history, workout detail).
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

    /// Initial tab: `.today`, overridable in DEBUG via the `--tab <name>` launch argument.
    private static func initialTab() -> WMTab {
        #if DEBUG
        if let override = DebugFlags.tab { return override }
        #endif
        return .today
    }
}
