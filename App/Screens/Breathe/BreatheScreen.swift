import SwiftUI

/// breathe — the immersive full-screen cover (from More → Breathe). Its own ground canvas, an ink X to
/// close top-trailing, and the pacing hero: a `BreathColumn` that rises on the inhale, holds full, and
/// drains on the exhale, paced by `BreathController`. Presets switch via an ink-underline word row (the
/// Live raw/5s idiom); Start/Stop is an ink control; elapsed + breath count read as overline+numeral.
/// Optional strap-haptic pacing rides the same clock (device-only — sim is always visual-only).
///
/// One idempotent `controller.stop()` funnels every exit (Stop, X, swipe-dismiss, onDisappear) so no
/// clock, keep-awake, or wedged buzz leaks out of the session.
struct BreatheScreen: View {
    /// Start the paced session on appear instead of waiting for a Start tap. ONLY the DEBUG
    /// `--breathe` cover in `AppShell` passes true — reaching Breathe from More always waits for the tap,
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

    private var pattern: BreathPattern { BreathPattern.named(presetName) }

    /// The fill the column draws: the live target while running, a steady mid-fill under Reduce Motion
    /// (the phase word + haptics carry the breath there — no pulsing column).
    private var columnExpansion: CGFloat {
        reduceMotionActive ? 0.5 : CGFloat(controller.expansionTarget)
    }

    /// Reduce Motion, honoring the environment — plus a DEBUG `--reduce-motion` launch override so agents
    /// can screenshot the parked-column a11y state on the simulator (simctl can't toggle Reduce Motion).
    private var reduceMotionActive: Bool {
        #if DEBUG
        if DebugFlags.reduceMotion { return true }
        #endif
        return reduceMotion
    }

    /// The strap can only buzz over a genuine encrypted bond. Read off `live` so the status updates live.
    private var canBuzz: Bool { live.bonded && live.encryptedBond }

    var body: some View {
        ZStack {
            WM.Ground.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Text("Breathe").wmOverline()
                presetSwitcher
                    .padding(.top, WM.Space.m)

                Spacer(minLength: WM.Space.l)

                BreathColumn(expansion: columnExpansion,
                             phaseWord: controller.phase.word,
                             bpm: live.heartRate)
                    .frame(width: 116, height: 360)
                    .animation(WMMotion.resolved(.easeInOut(duration: controller.phaseDuration),
                                                 reduceMotion: reduceMotionActive),
                               value: controller.expansionTarget)

                Spacer(minLength: WM.Space.l)

                startStop
                    .padding(.top, WM.Space.s)
                readout
                    .padding(.top, WM.Space.section)
                hapticsStatus
                    .padding(.top, WM.Space.l)
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .onAppear {
            controller.configure(ble: root.ble, live: root.live)
            // Auto-start so agents can screenshot the immersive column mid-breath deterministically.
            // Only AppShell's DEBUG `--breathe` cover passes `autoStart` — nothing in a release build does.
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

    // MARK: - Top bar (ink close)
    //
    // Untitled — the "Breathe" overline sits BELOW the bar, so this is a bare `WMCloseButton` rather
    // than a `WMCoverHeader`. Closing must stop the controller first (the session owns a timer + strap
    // buzzes), never just dismiss.

    private var topBar: some View {
        HStack {
            Spacer()
            WMCloseButton {
                controller.stop()
                dismiss()
            }
            .accessibilityLabel("Close breathing session")
        }
        .padding(.top, WM.Space.s)
    }

    // MARK: - Preset switcher (ink-underline word row — the Live raw/5s idiom)

    private var presetSwitcher: some View {
        HStack(spacing: WM.Space.l) {
            ForEach(BreathPattern.all, id: \.name) { preset in
                presetWord(preset)
            }
        }
        .wmAnimation(value: presetName)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Breathing preset")
    }

    private func presetWord(_ preset: BreathPattern) -> some View {
        let active = preset.name == presetName
        return Button {
            presetName = preset.name
            if controller.running { controller.retarget(to: preset) }
        } label: {
            Text(preset.name)
                .wmOverline(active ? WM.Ground.ink : WM.Ground.inkTertiary)
                .overlay(alignment: .bottom) {
                    if active {
                        Rectangle().fill(WM.Ground.ink).frame(height: 1).offset(y: 3)
                    }
                }
                .padding(.horizontal, WM.Space.m)
                .frame(minHeight: 44)               // HIG 44pt target for the mid-session preset switch
                .contentShape(Rectangle())          // (11pt visual text unchanged; only the hit area grows)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityHint(preset.tagline)
    }

    // MARK: - Start / Stop (ink control)

    private var startStop: some View {
        Button {
            if controller.running {
                controller.stop()
            } else {
                controller.start(pattern: pattern)
            }
        } label: {
            Text(controller.running ? "Stop" : "Start")
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
                .frame(minWidth: 132)
                .padding(.vertical, WM.Space.m)
                .overlay(
                    Capsule().strokeBorder(WM.Ground.ruleHeavy, lineWidth: WM.hairline)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(controller.running ? "Ends the breathing session"
                           : "Starts pacing your breath")
    }

    // MARK: - Readout (elapsed + breaths)

    private var readout: some View {
        HStack(spacing: WM.Space.sectionLoose) {
            readoutCell(label: "Elapsed", value: controller.elapsedText)
            readoutCell(label: "Breaths", value: String(controller.breathCount))
        }
    }

    private func readoutCell(label: String, value: String) -> some View {
        VStack(spacing: WM.Space.xs) {
            Text(label).wmOverline()
            Text(value)
                .font(WMType.numeral())
                .foregroundStyle(WM.Ground.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }

    // MARK: - Haptics status / mute toggle

    @ViewBuilder
    private var hapticsStatus: some View {
        if canBuzz {
            VStack(spacing: WM.Space.xs) {
                HStack(spacing: WM.Space.m) {
                    Text("Haptics").wmOverline()
                    hapticWord("on", active: hapticsEnabled) { hapticsEnabled = true }
                    hapticWord("off", active: !hapticsEnabled) { hapticsEnabled = false }
                }
                Text(hapticsEnabled ? "One pulse in · two out" : "Muted for this session")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            .wmAnimation(value: hapticsEnabled)
        } else {
            Text("Visual only — connect strap for haptic pacing")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hapticWord(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .wmOverline(active ? WM.Ground.ink : WM.Ground.inkTertiary)
                .overlay(alignment: .bottom) {
                    if active {
                        Rectangle().fill(WM.Ground.ink).frame(height: 1).offset(y: 3)
                    }
                }
                .padding(.horizontal, WM.Space.m)
                .frame(minHeight: 44)               // HIG 44pt target (also widens narrow "on"/"off")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Haptics \(label)")
        .accessibilityAddTraits(active ? .isSelected : [])
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
