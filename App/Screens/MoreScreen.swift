import SwiftUI

/// more — the flat grouped list (screen contract): open RuleSections on ground, no
/// table chrome. STRAP (device name/state, pair, forget) · DATA (backup import, backup folder +
/// back-up-now) · UNITS (display preferences persisted to the SAME UserDefaults keys the original reads,
/// per the BackupSettings whitelist: `units.system`) · ABOUT (version, disclaimer).
///
/// P7 (T2.19): this screen observes NOTHING that publishes at ~1 Hz. `LiveState` (strap state) and
/// `AppRoot` (which republishes `bpm` every second) are declared only inside the small leaf views that
/// actually need them — `StrapSection`'s armed rows, `DataSection`, and the two AppRoot-driven
/// Preferences toggles below — so the live churn re-renders those rows instead of the whole scroll
/// body. Same idiom as RestScreen's `WakeWindowArmed`.
struct MoreScreen: View {
    /// 029: pushed (not a cover) — it is an ordinary screen with a back link, like Weed's.
    @State private var showsJournal = false
    // Display preferences — the original's exact keys and raw values (Units.swift / BackupSettings
    // whitelist), so a backup import and this screen read/write the same settings:
    //   units.system       "metric" (°C) | "imperial" (°F) — also drives temperature display
    @AppStorage("ui.appearance") private var appearance: String = "system"
    @AppStorage(TempUnit.systemKey) private var unitSystem: String = "metric"

    // GLANCES — auto-start the live-HR Live Activity when the strap connects. Default OFF: nothing pins
    // to the Lock Screen until the user opts in (the Live tab's Pin button covers per-session starts).
    @AppStorage(LiveActivityController.autoStartKey) private var liveActivityAutoStart = false

    // WORKOUTS — opt-in auto-detection. Default OFF: nothing is suggested until the user turns it on
    // (drives whether the Today "Looks like a workout?" row surfaces).
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectWorkouts = false

    // STRAP ALERTS — one "battery is low" notification per discharge cycle (007 F4).
    @AppStorage(StrapAlerts.lowBatteryKey) private var lowBatteryAlert = StrapAlerts.lowBatteryDefault

    /// The one full-screen presentation state. Every wave adds another cover launcher here, and four
    /// parallel `@State` Bools + four `.fullScreenCover(isPresented:)` modifiers is exactly how two of
    /// them end up presentable at once; `item:` makes the covers mutually exclusive by construction.
    @State private var activeCover: MoreCover?

    // Pairing (STRAP section).
    @State private var showPairSheet = false

    // Experimental (protocol probes / broadcast HR / R22 unlock / V2 stager) — a sheet reached from a
    // low-key footer link at the bottom of Preferences (the Buzz-history idiom).
    @State private var showExperimental = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("More")
                    .font(WMType.title)
                    .foregroundStyle(WM.Ground.ink)
                    .padding(.top, WM.Space.m)

                StrapSection(onStrapHealth: { activeCover = .strapHealth },
                             onPair: { showPairSheet = true })

                RuleSection("Tools") {
                    VStack(spacing: 0) {
                        // Age / sex / body metrics / max-HR override. These drive Effort, HR zones and
                        // calories, and until this screen existed nothing in the app could set them —
                        // every user was scored as a 30-year-old 75 kg male.
                        WMNavRow(title: "You",
                                 subtitle: "Age, body metrics & max HR",
                                 hint: "Opens your profile: age, sex, weight, height and max heart rate") { activeCover = .profile }
                        WMRule()
                        // The immersive guided-breathing cover (covers the tab bar).
                        WMNavRow(title: "Breathe",
                                 subtitle: "Guided paced breathing",
                                 hint: "Opens a guided paced-breathing session") { activeCover = .breathe }
                        WMRule()
                        // The Body Clock cover (circadian readout + jet-lag planner).
                        WMNavRow(title: "Body Clock",
                                 subtitle: "Thermal midnight & jet-lag plan",
                                 hint: "Opens your body-clock readout and jet-lag planner") { activeCover = .bodyClock }
                        WMRule()
                        // The raw-sensor oscilloscope cover (live HR/R-R sweep + stored-channel scrubber).
                        // 029: the journal moved off Today, which carried seven sections. Its chips
                        // are day-scoped, so the pushed screen brings its own stepper rather than
                        // silently becoming today-only.
                        WMNavRow(title: "Journal",
                                 subtitle: "Tag days & see what they line up with",
                                 hint: "Opens the journal: tag a day and see its ranked effects") { showsJournal = true }
                        WMRule()
                        WMNavRow(title: "Signal Lab",
                                 subtitle: "Raw-sensor oscilloscope",
                                 hint: "Opens a raw-sensor oscilloscope of the strap's live and stored signals") { activeCover = .signalLab }
                        WMRule()
                        // 034: whether this INSTALL is wired correctly — the App Group, the widget's
                        // freshness, the outbox, the schema, the backup. Added after a build shipped
                        // with no App Group and nothing in the app could report it.
                        WMNavRow(title: "Diagnostics",
                                 subtitle: "Install health & bug report",
                                 hint: "Opens install diagnostics and the shareable bug report") { activeCover = .diagnostics }
                    }
                }

                DataSection()

                RuleSection("Preferences") {
                    VStack(alignment: .leading, spacing: 0) {
                        InkSegmentRow(label: "Appearance",
                                      options: [("system", "Auto"), ("light", "Light"), ("dark", "Dark")],
                                      selection: $appearance)
                        WMRule()
                        InkSegmentRow(label: "Units",
                                      options: [("metric", "Metric"), ("imperial", "Imperial")],
                                      selection: $unitSystem)
                        WMRule()
                        HealthExportToggle()
                        WMRule()
                        WMSettingToggle(label: "Auto-start Live Activity on connect",
                                        isOn: $liveActivityAutoStart)
                        WMRule()
                        WMSettingToggle(label: "Auto-detect workouts",
                                        isOn: $autoDetectWorkouts,
                                        caption: "Scans recent heart rate for a sustained effort and offers to save it as a workout on Today. Nothing is saved until you tap Save.")
                        WMRule()
                        ContinuousHrvToggles()
                        WMRule()
                        WMSettingToggle(label: "Low battery alert", isOn: $lowBatteryAlert)
                        // No onChange — BatteryNotifier reads StrapAlerts.lowBatteryEnabled at each
                        // battery event, so the persisted flip alone takes effect immediately.
                        WMRule()
                        experimentalRow
                    }
                }

                RuleSection("About") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Version")
                                .font(WMType.body)
                                .foregroundStyle(WM.Ground.ink)
                            Spacer()
                            Text(Self.versionText)
                                .font(WMType.body)
                                .foregroundStyle(WM.Ground.inkSecondary)
                        }
                        .padding(.vertical, WM.Space.m)
                        .accessibilityElement(children: .combine)
                        WMRule()
                        // Shown ONLY when the shared container is unreachable. A working install says
                        // nothing here — this is a fault report, not a status readout.
                        if !WidgetSnapshot.isGroupProvisioned {
                            VStack(alignment: .leading, spacing: WM.Space.xs) {
                                HStack {
                                    Text("Widget link")
                                        .font(WMType.body)
                                        .foregroundStyle(WM.Ground.ink)
                                    Spacer()
                                    Text("unavailable")
                                        .font(WMType.body)
                                        .foregroundStyle(WM.Ground.inkSecondary)
                                }
                                Text("This build was installed without its App Group, so widgets can't "
                                     + "read your data and anything you log from one can't reach the app. "
                                     + "See Tools → Diagnostics.")
                                    .font(WMType.caption)
                                    .foregroundStyle(WM.Ground.inkTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, WM.Space.m)
                            .accessibilityElement(children: .combine)
                            WMRule()
                        }
                        Text("whoopmaxx is not affiliated with WHOOP, Inc.")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                            .padding(.vertical, WM.Space.m)
                    }
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .background(WM.Ground.ground)
        .sheet(isPresented: $showPairSheet) {
            PairSheet()   // AppRoot / LiveState propagate through the sheet's environment
        }
        // AppRoot / Repository / LiveState / alarm settings / StrapHealthModel all propagate through
        // the cover's environment, so each case is a bare screen init.
        // 029 shipped the row and the state and NO destination, so tapping Journal did nothing.
        // A push, not a cover: the journal is an ordinary screen with a back link, unlike the four
        // immersive covers below.
        .navigationDestination(isPresented: $showsJournal) {
            JournalScreen(backLabel: "More")
        }
        #if DEBUG
        .task { if DebugFlags.journal { showsJournal = true } }
        #endif
        .fullScreenCover(item: $activeCover) { cover in
            switch cover {
            case .strapHealth: StrapHealthScreen()
            case .bodyClock:   BodyClockScreen()
            case .breathe:     BreatheScreen()
            case .signalLab:   SignalLabScreen()
            case .profile:     ProfileScreen()
            case .diagnostics: DiagnosticsScreen()
            }
        }
        .sheet(isPresented: $showExperimental) {
            ExperimentalScreen()   // AppRoot / LiveState propagate through the sheet's environment
        }
    }

    // MARK: - Experimental

    /// A deliberately low-key link (caption ink, footer of Preferences) into the Experimental sheet —
    /// protocol probes, Broadcast HR, the R22 unlock and the V2 stager. Present but not prominent, per
    /// its power-user placement (the Buzz-history idiom).
    private var experimentalRow: some View {
        Button {
            showExperimental = true
        } label: {
            HStack {
                Text("Experimental")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                Spacer()
                WMDisclosure()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, WM.Space.m)
        .accessibilityHint("Opens experimental strap protocol and analysis switches")
    }

    // MARK: - About

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

// MARK: - Covers

/// The full-screen covers More can present, as ONE presentation state (see `activeCover`).
private enum MoreCover: String, Identifiable {
    case strapHealth, bodyClock, breathe, signalLab, profile, diagnostics

    var id: String { rawValue }
}

// MARK: - AppRoot-driven Preferences toggles

/// P7 (T2.19): the "Write to Apple Health" row, isolated so the observation it needs — `AppRoot` for
/// the enable action, `HealthExport` for the auth caption — re-renders THIS row rather than all of
/// More on AppRoot's ~1 Hz `bpm` republish.
private struct HealthExportToggle: View {
    @EnvironmentObject private var root: AppRoot
    @EnvironmentObject private var health: HealthExport

    // HEALTH — opt-in one-way export of vitals + sleep stages to Apple Health (W8). Default OFF: user
    // intent; the actual writes are gated on auth == .authorized inside HealthExport.
    @AppStorage(HealthExport.exportEnabledKey) private var healthExportEnabled = false

    var body: some View {
        WMSettingToggle(label: "Write to Apple Health",
                        isOn: $healthExportEnabled,
                        caption: caption)
            // Enabling requests write-only permission and runs one export; disabling is one-way
            // (no teardown — samples already in Apple Health remain).
            .onChange(of: healthExportEnabled) { _, enabled in
                if enabled { Task { await root.enableHealthExport() } }
            }
    }

    /// Auth-state-driven caption for the HEALTH section. Honest per state: an entitlement-stripped
    /// build or a device without Health says so plainly rather than pointing at a Settings pane the app
    /// can't reach; a declined grant routes to the Settings toggle. The normal states (`.unknown`,
    /// never requested; `.authorized`) show no caption — the toggle label speaks for itself.
    private var caption: String {
        switch health.auth {
        case .denied:
            return "Turn on whoopmaxx under Settings > Privacy & Security > Health to allow writing."
        case .entitlementMissing:
            return "This build can't write to Apple Health. It needs the HealthKit capability in the signing profile (free AltStore re-signs may strip it)."
        case .unavailable:
            return "Apple Health isn't available on this device."
        case .unknown, .authorized:
            return ""
        }
    }
}

/// P7 (T2.19): the continuous-HRV pair, isolated so its `AppRoot` observation (both flips re-issue the
/// BLE reconcile) re-renders THESE rows instead of all of More.
private struct ContinuousHrvToggles: View {
    @EnvironmentObject private var root: AppRoot

    // CONTINUOUS HRV — holds the strap's dense R-R stream open in the background so overnight recovery has
    // dense data, paired with overnight-only. onChange re-issues the reconcile through AppRoot.
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey)
    private var continuousHrv = PuffinExperiment.keepRealtimeForDataDefault
    @AppStorage(PuffinExperiment.continuousHrvOvernightOnlyKey)
    private var continuousHrvOvernightOnly = PuffinExperiment.continuousHrvOvernightOnlyDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WMSettingToggle(label: "Continuous HRV capture", isOn: $continuousHrv)
                // Both toggles persist via @AppStorage before onChange runs; applyContinuousHrvPreference
                // reads the CURRENT base pref and re-runs the reconciler (which window-gates + arms).
                .onChange(of: continuousHrv) { _, _ in root.applyContinuousHrvPreference() }
            // #927 refinement — only meaningful while the base capture is on, so show it then.
            if continuousHrv {
                WMRule()
                WMSettingToggle(label: "Overnight only (\(Self.overnightWindowText))",
                                isOn: $continuousHrvOvernightOnly)
                    // #927 idiom: re-issue with the UNCHANGED base value purely to re-run the
                    // reconciler with the fresh window gate.
                    .onChange(of: continuousHrvOvernightOnly) { _, _ in root.applyContinuousHrvPreference() }
            }
        }
    }

    /// The nightly window shown on the "Overnight only" row, derived from the ContinuousHrvSchedule
    /// default constants (22:00 → 07:00) rather than hardcoded, and localized (e.g. "10 PM – 7 AM" /
    /// "22:00 – 07:00") so the label tracks the schedule contract and the user's clock format.
    private static let overnightWindowText: String = {
        let start = clockLabel(ContinuousHrvSchedule.defaultStartMinutes)
        let end = clockLabel(ContinuousHrvSchedule.defaultEndMinutes)
        return "\(start) – \(end)"
    }()

    /// Format a minute-of-local-midnight as a locale-aware time (no minutes shown for whole hours).
    private static func clockLabel(_ minuteOfDay: Int) -> String {
        var comps = DateComponents()
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        let date = Calendar.current.date(from: comps) ?? Date()
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(comps.minute == 0 ? "j" : "jm")
        return f.string(from: date)
    }
}

// MARK: - Previews

#Preview("More — light") {
    MoreScreenSpecimen().preferredColorScheme(.light)
}

#Preview("More — dark") {
    MoreScreenSpecimen().preferredColorScheme(.dark)
}

private struct MoreScreenSpecimen: View {
    private let root = AppRoot()

    var body: some View {
        MoreScreen()
            .environmentObject(root)
            .environmentObject(root.live)
            .environmentObject(root.healthExport)
    }
}
