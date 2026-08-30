import SwiftUI
import StrapProtocol

/// experimental — the power-user surface for the opt-in switches `PuffinExperiment` gates. Reached
/// from a caption-weight footer link at the bottom of More → Preferences, presented as a sheet (the
/// Buzz-history idiom: present, not prominent). Open editorial rows on ground, chrome neutral ink.
///
/// Only the experiments NOT already surfaced in Preferences live here: the 5/MG protocol probes,
/// Broadcast HR (#181), the R22 deep-data unlock (#174) and the V2 sleep stager. Continuous HRV,
/// overnight-only and auto-detect workouts stay in Preferences — they're daily-driver settings.
///
/// Family handling: the three strap rows are 5/MG-only. They stay visible (and writable — the
/// defaults keys are family-agnostic) with the selected WHOOP 4.0 called out in the caption, but the
/// immediate-apply BLE calls are skipped there. Family is read from the same AppStorage key the
/// pickers write (`selectedWhoopModel`, the StrapHealth idiom) — `BLEManager.selectedModel` is
/// private, and its own guards remain authoritative on every call.
struct ExperimentalScreen: View {
    @EnvironmentObject private var root: AppRoot
    @EnvironmentObject private var live: LiveState
    @Environment(\.dismiss) private var dismiss

    @AppStorage(WhoopModel.persistedKey) private var modelRaw: String = WhoopModel.whoop4.rawValue

    // Each key persists via @AppStorage BEFORE onChange runs (the MoreScreen idiom), so the
    // BLEManager guards that re-read PuffinExperiment see the fresh value on the immediate apply.
    @AppStorage(PuffinExperiment.defaultsKey) private var protocolProbes = false
    @AppStorage(PuffinExperiment.broadcastHrKey) private var broadcastHr = false
    @AppStorage(PuffinExperiment.deepDataKey) private var deepData = false
    // Default MUST match `PuffinExperiment.experimentalSleepV2Default` — @AppStorage returns this when the
    // key is unset, exactly as the engine's `object(forKey:) ?? default` read does. If the two disagree the
    // toggle renders the opposite of what the scorer is actually doing.
    @AppStorage(PuffinExperiment.experimentalSleepV2Key)
    private var sleepV2 = PuffinExperiment.experimentalSleepV2Default

    private var isWhoop5: Bool {
        (WhoopModel(rawValue: modelRaw) ?? .whoop4).deviceFamily == .whoop5
    }

    /// The full `enable_r22_*` flag count (15) — the denominator of the acceptance status line,
    /// taken from the same sequence BLEManager sends so the two can never drift.
    private static let r22Total = Whoop5Config.enableR22Sequence.count

    var body: some View {
        ZStack {
            WM.Ground.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    Text("Opt-in switches for mapping and unlocking the strap's protocol. All are off by default and reversible; each caption says exactly what flipping it sends or changes.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, WM.Space.m)

                    RuleSection("Strap protocol") {
                        VStack(alignment: .leading, spacing: 0) {
                            probesRow
                            WMRule()
                            broadcastHrRow
                            WMRule()
                            deepDataRow
                        }
                    }

                    RuleSection("Analysis") {
                        sleepV2Row
                    }
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
            }
        }
    }

    // MARK: - Header (title + ink close)

    private var header: some View {
        WMCoverHeader(title: "Experimental", closeLabel: "Close experimental settings") { dismiss() }
    }

    // MARK: - Strap protocol (WHOOP 5.0 / MG)

    /// The read-only puffin probes (`PuffinExperiment.defaultsKey`). No immediate apply — BLEManager
    /// reads the flag at each probe site, so the persisted flip alone takes effect.
    private var probesRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $protocolProbes) {
                Text("5/MG protocol probes")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
            }
            .tint(WM.Ground.control)
            .padding(.vertical, WM.Space.m)
            caption("Sends read-only probe commands over the 5.0/MG command channel to help map what the strap answers. They're educated guesses — expect no visible change, just log lines.")
            familyNote
        }
    }

    /// Broadcast HR (`PuffinExperiment.broadcastHrKey`, #181). Applied immediately while a 5/MG is
    /// connected; BLEManager re-applies an ON flag on each 5/MG connection (an OFF flip while
    /// disconnected is NOT pushed later — the caption says so honestly).
    private var broadcastHrRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $broadcastHr) {
                Text("Broadcast heart rate")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
            }
            .tint(WM.Ground.control)
            .padding(.vertical, WM.Space.m)
            // Immediate apply while linked; the manager's own connected/bonded guards are
            // authoritative and log a refusal instead of failing silently.
            .onChange(of: broadcastHr) { _, on in
                if isWhoop5 { root.ble.setBroadcastHr(on) }
            }
            caption("Makes the strap advertise its live heart rate as a standard Bluetooth HR sensor a Garmin, Zwift or gym console can pair to. Applies now if the strap is connected; switched on while disconnected it applies on the next connection, but switching OFF only reaches the strap while connected.")
            familyNote
        }
    }

    /// The R22 deep-data unlock (`PuffinExperiment.deepDataKey`, #174) + the acceptance status line
    /// over `LiveState.r22FlagsAccepted` and a quiet re-send link (the unlock is refused off-wrist or
    /// without the full encrypted bond, so one tap must be repeatable without toggling).
    private var deepDataRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $deepData) {
                Text("Deep biometric stream (R22)")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
            }
            .tint(WM.Ground.control)
            .padding(.vertical, WM.Space.m)
            .onChange(of: deepData) { _, on in
                if on && isWhoop5 { root.ble.enableWhoop5DeepData() }
            }
            caption("Writes the official app's 15 enable_r22 flags so the strap emits its deeper biometric records. Needs a bonded, worn 5.0/MG. This changes what the strap sends; turning it off stops future sends but does not unwrite flags the strap already accepted.")
            if deepData && isWhoop5 {
                Text(r22Status)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, WM.Space.m)
                Button("Send unlock sequence again") {
                    root.ble.enableWhoop5DeepData()
                }
                .buttonStyle(.plain)
                .font(WMType.caption)
                .foregroundStyle(live.connected ? WM.Ground.ink : WM.Ground.inkTertiary)
                .disabled(!live.connected)
                .padding(.bottom, WM.Space.m)
                .accessibilityHint("Re-sends the 15-flag R22 unlock to the connected strap")
            }
            familyNote
        }
    }

    /// Honest session telemetry: how many of the 15 SET_CONFIG flags the strap has ACKed since the
    /// last send (`r22FlagsAccepted` resets per attempt and per session — this is live state, not a
    /// persisted "unlocked" badge).
    private var r22Status: String {
        if live.r22FlagsAccepted <= 0 {
            return live.connected
                ? "No flag acknowledgements yet this session."
                : "Connect the strap to send the unlock."
        }
        if live.r22FlagsAccepted >= Self.r22Total {
            return "Strap accepted all \(Self.r22Total) flags."
        }
        return "Strap accepted \(live.r22FlagsAccepted) of \(Self.r22Total) flags."
    }

    // MARK: - Analysis

    /// The V2 sleep stager (`PuffinExperiment.experimentalSleepV2Key`). No immediate apply —
    /// ScoreEngine reads the flag at each staging pass, so the persisted flip alone takes effect.
    /// Default ON since the round-4 staging review; the copy below describes turning it OFF, because
    /// that is now the non-default action.
    private var sleepV2Row: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $sleepV2) {
                Text("Sleep staging (V2)")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
            }
            .tint(WM.Ground.control)
            .padding(.vertical, WM.Space.m)
            caption("Stages each detected night with a cardiorespiratory recipe that reads deep and REM against your own night, not a fixed share of it. On by default. Turning it off falls back to the older V1 stager, which under-reports deep sleep and can report none at all on a real night. Staging only — sleep detection and scores keep their own paths. Takes effect at the next scoring pass; flip back any time. Works on any strap.")
        }
    }

    // MARK: - Shared row pieces

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, WM.Space.m)
    }

    /// The family call-out under each strap row when the selected strap is a WHOOP 4.0: the switch
    /// still writes its key, but nothing is sent to a 4.0 (BLEManager refuses these commands there).
    @ViewBuilder private var familyNote: some View {
        if !isWhoop5 {
            Text("WHOOP 5.0 / MG only — has no effect on your WHOOP 4.0.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, WM.Space.m)
        }
    }
}

// MARK: - Previews

#Preview("Experimental — light") {
    ExperimentalScreenSpecimen().preferredColorScheme(.light)
}

#Preview("Experimental — dark") {
    ExperimentalScreenSpecimen().preferredColorScheme(.dark)
}

private struct ExperimentalScreenSpecimen: View {
    private let root = AppRoot()

    var body: some View {
        ExperimentalScreen()
            .environmentObject(root)
            .environmentObject(root.live)
    }
}
