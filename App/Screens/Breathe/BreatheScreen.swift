import SwiftUI

/// breathe — the immersive full-screen cover (037; opened from Live's "Breathe" button). Its own
/// ground canvas: the "Breathe" title with the close on the right, the presets as word tabs, then the
/// pacing hero — the phase word over a `BreathLine` whose Rest fill runs out on the inhale, holds full,
/// and draws back on the exhale, paced by `BreathController` — with the preset's tagline under it. Below:
/// Elapsed / Breaths / Heart readouts, the Start/Stop primary button, and the strap-haptics toggle (or the
/// visual-only caption when the strap can't buzz). Strap-haptic pacing rides the same clock
/// (device-only — the simulator is always visual-only).
///
/// One idempotent `controller.stop()` funnels every exit (Stop, X, swipe-dismiss, onDisappear) so no
/// clock, keep-awake, or wedged buzz leaks out of the session.
struct BreatheScreen: View {
    /// Start the paced session on appear instead of waiting for a Start tap. ONLY the DEBUG
    /// `--breathe` cover in `AppShell` passes true — reaching Breathe from Live always waits for the tap,
    /// even in a `--breathe` build (the screen used to re-read the launch argument itself and auto-start
    /// on every appearance).
    var autoStart: Bool = false

    @EnvironmentObject private var root: AppRoot
    @EnvironmentObject private var live: LiveState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var controller = BreathController()

    @AppStorage(BreathePrefs.Key.preset) private var presetName = BreathPattern.coherence.name
    @AppStorage(BreathePrefs.Key.haptics) private var hapticsEnabled = true

    /// The preset word tabs — one per shipped pattern, keyed by its persisted name.
    private static let presetOptions = BreathPattern.all.map { (value: $0.name, name: $0.name) }

    private var pattern: BreathPattern { BreathPattern.named(presetName) }

    /// The fill the line draws: the live target while running, a steady mid-fill under Reduce Motion
    /// (the phase word + haptics carry the breath there — no moving fill).
    private var lineExpansion: CGFloat {
        reduceMotionActive ? 0.5 : CGFloat(controller.expansionTarget)
    }

    /// Reduce Motion, honoring the environment — plus a DEBUG `--reduce-motion` launch override so agents
    /// can screenshot the parked-line a11y state on the simulator (simctl can't toggle Reduce Motion).
    private var reduceMotionActive: Bool {
        #if DEBUG
        if DebugFlags.reduceMotion { return true }
        #endif
        return reduceMotion
    }

    /// The strap can only buzz over a genuine encrypted bond. Read off `live` so the status updates live.
    private var canBuzz: Bool { live.bonded && live.encryptedBond }

    /// A preset tap persists the choice and, mid-session, re-paces without ending the session.
    private var presetSelection: Binding<String> {
        Binding(
            get: { presetName },
            set: { name in
                presetName = name
                if controller.running { controller.retarget(to: BreathPattern.named(name)) }
            })
    }

    var body: some View {
        ZStack {
            WM.Ground.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Closing must stop the controller first (the session owns a timer + strap buzzes), never
                // just dismiss.
                WMCoverHeader(title: "Breathe", closeLabel: "Close breathing session", onClose: {
                    controller.stop()
                    dismiss()
                })

                WMTextTabs(options: Self.presetOptions, selection: presetSelection,
                           label: "Breathing preset")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, WM.Space.s)

                Spacer(minLength: WM.Space.l)

                BreathLine(expansion: lineExpansion, phaseWord: controller.phase.word)
                    .animation(WMMotion.resolved(.easeInOut(duration: controller.phaseDuration),
                                                 reduceMotion: reduceMotionActive),
                               value: controller.expansionTarget)
                Text(pattern.tagline)
                    .font(WMType.label)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, WM.Space.l)

                Spacer(minLength: WM.Space.l)

                readout
                WMPrimaryButton(controller.running ? "Stop" : "Start") {
                    if controller.running {
                        controller.stop()
                    } else {
                        controller.start(pattern: pattern)
                    }
                }
                .accessibilityHint(controller.running ? "Ends the breathing session"
                                   : "Starts pacing your breath")
                .padding(.top, WM.Space.section)
                hapticsStatus
                    .padding(.top, WM.Space.m)
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.l)
        }
        .onAppear {
            controller.configure(ble: root.ble, live: root.live)
            // Auto-start so agents can screenshot the pacer mid-breath deterministically. Only AppShell's
            // DEBUG `--breathe` cover passes `autoStart` — nothing in a release build does.
            if autoStart { controller.start(pattern: pattern) }
        }
        .onDisappear { controller.stop() }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding mid-session (home-swipe, not Stop) never fires onDisappear. A suspended
            // asyncAfter advance + the 1 Hz timer would fire on return — snapping the phase, emitting an
            // out-of-phase strap buzz, and undercounting wall-clock. End the session honestly instead of
            // letting the clock desync; the user re-taps Start on return.
            if phase == .background { controller.stop() }
        }
    }

    // MARK: - Readout (elapsed · breaths · heart)

    private var readout: some View {
        HStack(alignment: .top, spacing: WM.Space.m) {
            SignalCell(label: "Elapsed", value: controller.elapsedText, valueSize: 24, fillsWidth: true)
            SignalCell(label: "Breaths", value: String(controller.breathCount), valueSize: 24,
                       fillsWidth: true)
            // The live strap rate, "—" off-strap (the Live headline's no-signal glyph).
            SignalCell(label: "Heart", value: live.heartRate.map(String.init) ?? "—",
                       unit: live.heartRate == nil ? nil : "bpm", valueSize: 24, fillsWidth: true)
        }
    }

    // MARK: - Haptics status / mute toggle

    @ViewBuilder
    private var hapticsStatus: some View {
        if canBuzz {
            WMSettingToggle(label: "Strap haptics", isOn: $hapticsEnabled,
                            caption: hapticsEnabled ? "One pulse in · two out" : "Muted for this session")
        } else {
            Text("Visual only — connect strap for haptic pacing")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: WM.Space.row)
        }
    }
}

#Preview("Breathe — light") {
    BreatheScreenSpecimen().preferredColorScheme(.light)
}

#Preview("Breathe — dark") {
    BreatheScreenSpecimen().preferredColorScheme(.dark)
}

private struct BreatheScreenSpecimen: View {
    private let root = AppRoot()

    var body: some View {
        BreatheScreen()
            .environmentObject(root)
            .environmentObject(root.live)
    }
}
