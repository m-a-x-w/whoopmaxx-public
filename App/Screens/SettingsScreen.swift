import SwiftUI

/// Settings (037) — the sheet `AppShell` presents when a screen calls `AppActions.openSettings`
/// (Today's gear). It replaces the More tab: a pinned header (title + Done) over one scroll of open
/// sections on ground, no table chrome — Strap · Profile · Backup · Preferences · More · About.
///
/// Same controls, bindings and side effects the More tab carried. The display preferences persist to
/// the SAME UserDefaults keys the original reads, per the BackupSettings whitelist (`units.system`,
/// `ui.appearance`), so a backup import and this screen read/write the same settings. The Tools rows More
/// also held moved to where they are used: Breathe to Live, Body Clock and Signal Lab to Data › Labs,
/// the journal to Log.
///
/// P7 (T2.19): this screen observes NOTHING that publishes at ~1 Hz. `LiveState` (strap state) and
/// `AppRoot` (which republishes `bpm` every second) are declared only inside the small leaf views that
/// actually need them — `StrapSection`'s armed rows, `DataSection`, and the two AppRoot-driven
/// Preferences toggles below — so the live churn re-renders those rows instead of the whole scroll
/// body. Same idiom as RestScreen's `WakeWindowArmed`.
struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss

    // Display preferences — the original's exact keys and raw values (Units.swift / BackupSettings
    // whitelist), so a backup import and this screen read/write the same settings:
    //   units.system       "metric" (°C) | "imperial" (°F) — also drives temperature display
    @AppStorage("ui.appearance") private var appearance: String = "system"
    @AppStorage(TempUnit.systemKey) private var unitSystem: String = "metric"

    // GLANCES — auto-start the live-HR Live Activity when the strap connects. Default OFF: nothing pins
    // to the Lock Screen until the user opts in (the Live tab's pin toggle covers per-session starts).
    @AppStorage(LiveActivityController.autoStartKey) private var liveActivityAutoStart = false

    // WORKOUTS — opt-in auto-detection. Default OFF: nothing is suggested until the user turns it on
    // (drives whether the Today "Looks like a workout?" row surfaces).
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectWorkouts = false

    // STRAP ALERTS — one "battery is low" notification per discharge cycle (007 F4).
    @AppStorage(StrapAlerts.lowBatteryKey) private var lowBatteryAlert = StrapAlerts.lowBatteryDefault

    /// The one full-screen presentation state. Every wave adds another cover launcher here, and parallel
    /// `@State` Bools + one `.fullScreenCover(isPresented:)` each is exactly how two of them end up
    /// presentable at once; `item:` makes the covers mutually exclusive by construction.
    @State private var activeCover: SettingsCover?

    // Pairing (Strap section).
    @State private var showPairSheet = false

    // Experimental (protocol probes / broadcast HR / R22 unlock / V2 stager) — a sheet reached from the
    // More section.
    @State private var showExperimental = false

    /// Between sections. The sheet is a dense list, so its sections sit at the tight end of the scale.
    private static let sectionGap = WM.Space.sectionTight

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    RuleSection("Strap", topGap: WM.Space.l) {
                        StrapSection(onStrapHealth: { activeCover = .strapHealth },
                                     onPair: { showPairSheet = true })
                    }

                    RuleSection("Profile", topGap: Self.sectionGap) {
                        // Age / sex / body metrics / max-HR override. These drive Effort, HR zones and
                        // calories, and until the profile screen existed nothing in the app could set
                        // them — every user was scored as a 30-year-old 75 kg male.
                        ProfileRow { activeCover = .profile }
                    }

                    RuleSection("Backup", topGap: Self.sectionGap) {
                        DataSection()
                    }

                    RuleSection("Preferences", topGap: Self.sectionGap) {
                        preferences
                    }

                    RuleSection("More", topGap: Self.sectionGap) {
                        more
                    }

                    RuleSection("About", topGap: Self.sectionGap) {
                        about
                    }
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
            }
        }
        .background(WM.Ground.ground.ignoresSafeArea())
        .sheet(isPresented: $showPairSheet) {
            PairSheet()   // AppRoot / LiveState propagate through the sheet's environment
        }
        // AppRoot / Repository / LiveState / ProfileStore / StrapHealthModel all propagate through the
        // cover's environment, so each case is a bare screen init.
        .fullScreenCover(item: $activeCover) { cover in
            switch cover {
            case .strapHealth: StrapHealthScreen()
            case .profile:     ProfileScreen()
            case .diagnostics: DiagnosticsScreen()
            }
        }
        .sheet(isPresented: $showExperimental) {
            ExperimentalScreen()   // AppRoot / LiveState propagate through the sheet's environment
                .presentationCornerRadius(WM.Radius.sheet)
        }
    }

    // MARK: - Header

    /// Pinned above the scroll: the sheet's title with the app's name under it, and Done. The top gap
    /// clears the sheet's grabber.
    private var header: some View {
        TabHeader("Settings", subtitle: "whoopmaxx") {
            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(WM.Ground.ink)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Closes settings")
        }
        .padding(.horizontal, WM.Space.gutter)
        .padding(.top, WM.Space.m)
    }

    // MARK: - Preferences

    private var preferences: some View {
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
            WMSettingToggle(label: "Start Live Activity on connect",
                            isOn: $liveActivityAutoStart)
            WMRule()
            WMSettingToggle(label: "Suggest detected workouts",
                            isOn: $autoDetectWorkouts,
                            caption: "Scans recent heart rate for a sustained effort and offers to save it as a workout on Today. Nothing is saved until you tap Save.")
            WMRule()
            ContinuousHrvToggles()
            WMRule()
            WMSettingToggle(label: "Low battery alert",
                            isOn: $lowBatteryAlert,
                            caption: "Warns once when the strap drops to 15%, then again at 5%. Both reset when it charges.")
            // No onChange — BatteryNotifier reads StrapAlerts.lowBatteryEnabled at each battery event,
            // so the persisted flip alone takes effect immediately.
        }
    }

    // MARK: - More

    private var more: some View {
        VStack(spacing: 0) {
            // Protocol probes, Broadcast HR, the R22 unlock and the V2 stager — power-user switches, so
            // they sit behind a row rather than among the daily-driver Preferences.
            WMNavRow(title: "Experimental",
                     subtitle: "Protocol and analysis switches",
                     hint: "Opens experimental strap protocol and analysis switches") { showExperimental = true }
            WMRule()
            // 034: whether this INSTALL is wired correctly — the App Group, the widget's freshness, the
            // outbox, the schema, the backup. Added after a build shipped with no App Group and nothing
            // in the app could report it.
            WMNavRow(title: "Diagnostics",
                     subtitle: "Install health & bug report",
                     hint: "Opens install diagnostics and the shareable bug report") { activeCover = .diagnostics }
        }
    }

    // MARK: - About

    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Shown ONLY when the shared container is unreachable. A working install says nothing here —
            // this is a fault report, not a status readout.
            if !Self.groupProvisioned {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Widget link")
                            .font(WMType.body)
                            .foregroundStyle(WM.Ground.ink)
                        Spacer(minLength: WM.Space.s)
                        Text("unavailable")
                            .font(WMType.label)
                            .foregroundStyle(WM.Ground.inkSecondary)
                    }
                    Text("This build was installed without its App Group, so widgets can't "
                         + "read your data and anything you log from one can't reach the app. "
                         + "See More › Diagnostics above.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, WM.Space.s)
                .frame(maxWidth: .infinity, minHeight: WM.Space.row + 8, alignment: .leading)
                .accessibilityElement(children: .combine)
                .padding(.bottom, WM.Space.m)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("whoopmaxx \(Self.versionText)")
                    .accessibilityLabel("Version \(Self.versionText)")
                Text("Not affiliated with WHOOP, Inc.")
            }
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
        }
    }

    /// Read once per process: the version cannot change under a running app.
    private static let versionText: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

    /// Read once per process rather than per render: the App Group entitlement is fixed for the life of
    /// the process, and each read is a container lookup.
    private static let groupProvisioned = WidgetSnapshot.isGroupProvisioned
}

// MARK: - Covers

/// The full-screen covers Settings can present, as ONE presentation state (see `activeCover`).
private enum SettingsCover: String, Identifiable {
    case strapHealth, profile, diagnostics

    var id: String { rawValue }
}

// MARK: - Profile row

/// "You", with the three numbers that most change a score under it. Isolated so its `ProfileStore`
/// observation re-renders this row alone; the store only publishes when the profile is edited.
private struct ProfileRow: View {
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(TempUnit.systemKey) private var unitSystem: String = "metric"
    let action: () -> Void

    var body: some View {
        WMNavRow(title: "You",
                 subtitle: "Age \(profile.age) · max HR \(profile.hrMax) · "
                    + ProfileScreen.weightText(kg: profile.weightKg, imperial: unitSystem == "imperial"),
                 hint: "Opens your profile: age, sex, weight, height and max heart rate",
                 action: action)
    }
}

// MARK: - AppRoot-driven Preferences toggles

/// P7 (T2.19): the "Write to Apple Health" row, isolated so the observation it needs — `AppRoot` for
/// the enable action, `HealthExport` for the auth caption — re-renders THIS row rather than all of
/// Settings on AppRoot's ~1 Hz `bpm` republish.
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

    /// Auth-state-driven caption for the Health row. Honest per state: an entitlement-stripped build or
    /// a device without Health says so plainly rather than pointing at a Settings pane the app can't
    /// reach; a declined grant routes to the Settings toggle. The normal states (`.unknown`, never
    /// requested; `.authorized`) show no caption — the toggle label speaks for itself.
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
/// BLE reconcile) re-renders THESE rows instead of all of Settings.
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
            WMSettingToggle(label: "Continuous HRV", isOn: $continuousHrv)
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

#Preview("Settings — light") {
    SettingsScreenSpecimen().preferredColorScheme(.light)
}

#Preview("Settings — dark") {
    SettingsScreenSpecimen().preferredColorScheme(.dark)
}

private struct SettingsScreenSpecimen: View {
    private let root = AppRoot()

    var body: some View {
        SettingsScreen()
            .environmentObject(root)
            .environmentObject(root.live)
            .environmentObject(root.healthExport)
            .environmentObject(root.profile)
    }
}
