import SwiftUI

// MARK: - Model

/// A strap surfaced by the present-scan (`BLEManager.discoveredWhoops`), shaped for the UI.
struct DiscoveredStrap: Identifiable, Equatable {
    let uuid: String
    let name: String
    let rssi: Int
    var id: String { uuid }
    /// Advertised name, or the family placeholder when the advert carried none.
    var displayName: String { name.isEmpty ? "WHOOP" : name }
}

/// The pair flow's three states — minimal by design: searching → connecting → paired.
enum PairPhase: Equatable {
    case searching
    case connecting(name: String)
    case paired(name: String)
}

/// The `.task(id:)` key for the per-phase timer: the phase PLUS a scan nonce, so a re-scan that leaves the
/// phase unchanged (`.searching` → `.searching`) still restarts the timer.
private struct PhaseTimerKey: Equatable {
    let phase: PairPhase
    let nonce: Int
}

// MARK: - Sheet

/// The scan/pair sheet: title + close chrome around the live pair flow. Present from More ("Pair
/// strap"); the first-run flow embeds `PairFlowLive` inline instead. Everything renders gracefully
/// with dead BLE (simulator): the search state is calm and a reassurance line appears after a beat.
struct PairSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Pair strap")
                        .font(WMType.title)
                        .foregroundStyle(WM.Ground.ink)
                    Spacer()
                    Button("Close") { dismiss() }
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.inkSecondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                }
                .padding(.top, WM.Space.l)
                .padding(.bottom, WM.Space.m)

                WMRule()
                    .padding(.bottom, WM.Space.l)

                PairFlowLive { dismiss() }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .background(WM.Ground.ground)
        .presentationDetents([.medium, .large])
        .presentationBackground(WM.Ground.ground)
        .presentationDragIndicator(.hidden)
    }
}

// MARK: - Live flow (BLE wiring)

/// The live pairing flow: pulls `AppRoot`/`LiveState` from the environment and hands the observable
/// objects to the engine below. `onDone` fires when the user confirms the paired state (the sheet
/// dismisses; first-run advances).
struct PairFlowLive: View {
    @EnvironmentObject private var root: AppRoot
    @EnvironmentObject private var live: LiveState
    var onDone: (() -> Void)? = nil

    var body: some View {
        PairEngine(ble: root.ble, live: live, onDone: onDone)
    }
}

/// Owns the scan lifecycle + phase machine over BLEManager's present-scan API, exactly the sequence
/// the original Add-a-WHOOP wizard proved out (AppModel.presentWhoopScan → pick → stopWhoopScan +
/// setPreferredPeripheral + connect):
///   present:  prepareForPresentScan (keeps a live same-family bond, #74) → connect(model:) (selects
///             the family + framing) → scanForWhoops() (present-only, never auto-connects)
///   pick:     stopWhoopScan() → setPreferredPeripheral(uuid) → connect(model:)
///   paired:   `live.connected && live.bonded` flips true (the wizard's own bond signal)
/// Every state renders without BLE: `scanForWhoops` no-ops when Bluetooth isn't powered on, so on
/// the simulator this simply stays in the calm searching state.
private struct PairEngine: View {
    @ObservedObject var ble: BLEManager
    @ObservedObject var live: LiveState
    var onDone: (() -> Void)?

    @State private var phase: PairPhase = .searching
    /// After a calm beat with nothing found: the "straps don't show in Bluetooth settings" line.
    @State private var showReassurance = false
    /// After a long connect with no bond: plain "still working" copy.
    @State private var connectStalled = false
    /// Bumped on every `beginScan` so the phase timer re-runs even when the phase is unchanged. "Scan again"
    /// from the searching screen sets `phase = .searching` again (a no-op for `.task(id: phase)`), so without
    /// this nonce the 12 s reassurance timer would never restart and a latched reassurance line could never
    /// be cleared.
    @State private var scanNonce = 0

    var body: some View {
        PairFlow(phase: phase,
                 straps: straps,
                 hint: live.pairingHint ?? live.reconnectGuide,
                 radioProblem: live.radio.problem,
                 showReassurance: showReassurance,
                 connectStalled: connectStalled,
                 batteryPct: live.batteryPct.map { Int($0.rounded()) },
                 onPick: pick,
                 onRescan: beginScan,
                 onDone: { onDone?() })
            .onAppear(perform: start)
            .onDisappear {
                ble.stopWhoopScan()   // idempotent; releases present-mode on any exit
                // …but releasing present-mode is not enough. `beginScan` took the central AWAY from the
                // normal connect path (prepareForPresentScan → disconnect, then a present-only scan that
                // cancelled the service scan and its family-rotation fallback), and `stopWhoopScan` only
                // stops scanning — it neither restarts a scan nor re-enters connectCore. On an install
                // whose pin doesn't resolve (i.e. before the first successful connect, since the paired
                // key is only written once a connect lands) that leaves the radio fully idle: no scan, no
                // pending connect, no auto-reconnect for the rest of the process. Dismissing FirstRun's
                // "Skip for now" then meant the strap was never discovered and NO data was ever collected,
                // silently, until a relaunch.
                //
                // `connectFromSystem`, not `connect`: the latter is the user-initiated entry that clears
                // the bond-refusal give-up latch, and re-arming that hammer on every sheet dismiss would
                // re-open the refusal loop for a strap that keeps saying no. This makes exactly the one
                // bounded attempt that poweredOn already makes. The guard keeps a live bond (#74) from
                // being re-run through connectCore; mid-pick it is harmless, since `pick` has already
                // pinned the peripheral and CoreBluetooth treats the repeat targeted connect as a no-op.
                if !live.connected { ble.connectFromSystem() }
            }
            .onChange(of: pairedNow) { _, paired in
                guard paired else { return }
                switch phase {
                case .connecting(let name):
                    phase = .paired(name: live.advertisingName ?? name)
                case .searching:
                    // BLEManager's own poweredOn auto-connect can win the race and bond while the
                    // sheet is still scanning — a connected strap stops advertising, so the list
                    // would sit empty forever. Accept the bond from .searching too.
                    phase = .paired(name: live.advertisingName ?? "WHOOP")
                default:
                    break
                }
            }
            .task(id: PhaseTimerKey(phase: phase, nonce: scanNonce)) { await runPhaseTimer() }
            .wmAnimation(WMMotion.transition, value: phase)
    }

    private var straps: [DiscoveredStrap] {
        ble.discoveredWhoops
            .map { DiscoveredStrap(uuid: $0.uuid, name: $0.name, rssi: $0.rssi) }
            .sorted { $0.rssi > $1.rssi }
    }

    /// The wizard's bond signal: the link is up AND bonded. (`bonded` alone survives a disconnect,
    /// so it can't be trusted without `connected`.)
    private var pairedNow: Bool { live.connected && live.bonded }

    /// A strap that's already connected + bonded stops advertising, so a scan would show nothing —
    /// open straight onto the paired confirmation instead ("Scan again" still allows a re-scan).
    private func start() {
        if pairedNow {
            phase = .paired(name: live.advertisingName ?? "WHOOP")
        } else {
            beginScan()
        }
    }

    private func beginScan() {
        // Clear any latched reassurance / stall copy up front, and bump the nonce so the phase timer
        // re-runs even if `phase` is already `.searching` (a re-scan from the searching screen).
        showReassurance = false
        connectStalled = false
        scanNonce += 1
        let model = WhoopModel.persisted
        // Persist the family so later reconnects (power-on, state restoration) target the same strap.
        UserDefaults.standard.set(model.rawValue, forKey: WhoopModel.persistedKey)
        ble.prepareForPresentScan(model: model)   // idle for a family switch; keep a live bond (#74)
        ble.connect(model: model)                 // select the family + install its framing
        ble.scanForWhoops()                       // take over the central: present, don't auto-connect
        phase = .searching
    }

    private func pick(_ strap: DiscoveredStrap) {
        ble.stopWhoopScan()
        ble.setPreferredPeripheral(strap.uuid)
        ble.connect(model: WhoopModel.persisted)
        // Always go through `.connecting`, never a `pairedNow` shortcut. `pairedNow` can't tell "picked the
        // strap I already hold" from "picked a NEW strap while a previous same-family bond is still live"
        // (beginScan keeps the old bond up during the present-scan, #74) — a connected strap doesn't
        // advertise, so the strap the user tapped is NEVER the one already held. Taking the shortcut on a
        // re-pair skipped `.connecting`, showed the OLD strap's advertisingName as a false success, and left
        // no stall recovery if the new strap failed to connect. `.onChange(of: pairedNow)` transitions
        // `.connecting → .paired(live.advertisingName ?? name)` once the PICKED strap actually bonds, and
        // the 25s connecting-stall timer still offers "Start over" if it never does.
        phase = .connecting(name: strap.displayName)
    }

    /// One quiet timer per phase, auto-cancelled by `.task(id:)` on every phase change.
    private func runPhaseTimer() async {
        switch phase {
        case .searching:
            showReassurance = false
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            if straps.isEmpty { showReassurance = true }
        case .connecting:
            connectStalled = false
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled else { return }
            connectStalled = true
        case .paired:
            break
        }
    }
}

// MARK: - Pure flow content (previewable with mock states)

/// The pair flow rendered from plain values — no BLE, so previews can drive every state in both
/// themes. Open editorial on the ground; the discovered straps are the one contained surface
/// (groundRaised panel rows, per the design contract).
struct PairFlow: View {
    let phase: PairPhase
    let straps: [DiscoveredStrap]
    /// Plain, calm guidance (bond-refusal pairing hint / re-pair guide). nil = quiet.
    let hint: String?
    /// Non-nil when the BLUETOOTH RADIO is the problem, not the strap (off / permission denied /
    /// unsupported). Takes over the searching screen, which otherwise tells the user to check a strap
    /// that was never the issue.
    var radioProblem: String? = nil
    let showReassurance: Bool
    let connectStalled: Bool
    let batteryPct: Int?
    var doneLabel: String = "Done"
    let onPick: (DiscoveredStrap) -> Void
    let onRescan: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.l) {
            switch phase {
            case .searching:            searching
            case .connecting(let name): connecting(name)
            case .paired(let name):     paired(name)
            }

            if let hint {
                Text(hint)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Searching

    @ViewBuilder private var searching: some View {
        // A dead radio is not a missing strap. Say so instead of spinning forever on copy that blames
        // the strap — `.unauthorized` in particular never self-heals, so the honest line is the only
        // route out of this screen.
        if let radioProblem {
            statusLine(symbol: "exclamationmark.triangle", pulsing: false,
                       title: "Bluetooth unavailable",
                       caption: radioProblem)
        } else {
            statusLine(symbol: "dot.radiowaves.left.and.right", pulsing: true,
                       title: "Searching for nearby straps",
                       caption: "Keep the strap close to your iPhone.")
        }

        if !straps.isEmpty {
            strapPanel
        }

        if showReassurance, radioProblem == nil {
            VStack(alignment: .leading, spacing: WM.Space.s) {
                Text("WHOOP straps never appear in iPhone Bluetooth settings — whoopmaxx finds them directly. Make sure the strap is charged and nearby, and that the official WHOOP app isn't holding it.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                quietButton("Scan again", action: onRescan)
            }
        }
    }

    /// The one contained surface: discovered strap rows in a groundRaised panel, hairline-separated.
    private var strapPanel: some View {
        VStack(spacing: 0) {
            ForEach(Array(straps.enumerated()), id: \.element.id) { index, strap in
                if index > 0 {
                    WMRule()
                        .padding(.leading, WM.Space.l)
                }
                Button {
                    onPick(strap)
                } label: {
                    HStack(spacing: WM.Space.m) {
                        RSSIBars(rssi: strap.rssi)
                        Text(strap.displayName)
                            .font(WMType.body)
                            .foregroundStyle(WM.Ground.ink)
                        Spacer(minLength: WM.Space.s)
                        Text("\(strap.rssi) dBm")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                        WMDisclosure()
                    }
                    .padding(.horizontal, WM.Space.l)
                    .padding(.vertical, WM.Space.m)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pair \(strap.displayName)")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: WM.Radius.panel, style: .continuous)
                .fill(WM.Ground.groundRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WM.Radius.panel, style: .continuous)
                .strokeBorder(WM.Ground.rule, lineWidth: WM.hairline)
        )
    }

    // MARK: Connecting

    @ViewBuilder private func connecting(_ name: String) -> some View {
        statusLine(symbol: "link", pulsing: true,
                   title: "Pairing \(name)",
                   caption: "Hold the strap near your iPhone. This can take a moment.")

        if connectStalled {
            VStack(alignment: .leading, spacing: WM.Space.s) {
                Text("Still working. If it never finishes, put the strap on charge for a minute and try again.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                quietButton("Start over", action: onRescan)
            }
        }
    }

    // MARK: Paired

    @ViewBuilder private func paired(_ name: String) -> some View {
        HStack(alignment: .center, spacing: WM.Space.m) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WM.Semantic.good)
            VStack(alignment: .leading, spacing: WM.Space.xs) {
                Text(name)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                Text(pairedCaption)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)

        WMPrimaryButton(doneLabel, action: onDone)

        quietButton("Pair a different strap", action: onRescan)
    }

    private var pairedCaption: String {
        if let batteryPct { return "Paired · \(batteryPct)% battery — reconnects automatically from now on." }
        return "Paired — reconnects automatically from now on."
    }

    // MARK: Shared bits

    private func statusLine(symbol: String, pulsing: Bool, title: String, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WM.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(WM.Ground.inkSecondary)
                .symbolEffect(.pulse, options: .repeating, isActive: pulsing)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WM.Space.xs) {
                Text(title)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                Text(caption)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(WMType.label)
                .foregroundStyle(WM.Ground.inkSecondary)
                .frame(minHeight: 44, alignment: .leading)   // HIG target for the pairing recovery actions
                .contentShape(Rectangle())                    // (frame BEFORE contentShape hit-tests the 44pt)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Signal strength in the bar motif

/// RSSI as 4 ascending micro bars (the app's bar motif): filled in ink, empty in rule ink.
private struct RSSIBars: View {
    let rssi: Int

    private var filled: Int {
        switch rssi {
        case (-55)...: return 4
        case (-65)...: return 3
        case (-75)...: return 2
        default:       return 1
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < filled ? WM.Ground.ink : WM.Ground.rule)
                    .frame(width: 2.5, height: 4 + CGFloat(i) * 3)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews (mock states, both themes — no BLE needed)

#Preview("Pair — searching (empty, reassured)") {
    PairFlowSpecimen(phase: .searching, straps: [], reassured: true)
}

#Preview("Pair — straps found") {
    PairFlowSpecimen(phase: .searching,
                     straps: [DiscoveredStrap(uuid: "A", name: "WHOOP 4A0BC1", rssi: -52),
                              DiscoveredStrap(uuid: "B", name: "", rssi: -71),
                              DiscoveredStrap(uuid: "C", name: "WHOOP 887D02", rssi: -83)])
}

#Preview("Pair — connecting (stalled) — dark") {
    PairFlowSpecimen(phase: .connecting(name: "WHOOP 4A0BC1"), straps: [], stalled: true,
                     hint: "The strap refused the pairing. Unpair it in the official WHOOP app, fully close that app, then try again.")
        .preferredColorScheme(.dark)
}

#Preview("Pair — paired — dark") {
    PairFlowSpecimen(phase: .paired(name: "WHOOP 4A0BC1"), straps: [], battery: 62)
        .preferredColorScheme(.dark)
}

private struct PairFlowSpecimen: View {
    let phase: PairPhase
    let straps: [DiscoveredStrap]
    var reassured = false
    var stalled = false
    var battery: Int? = nil
    var hint: String? = nil

    var body: some View {
        PairFlow(phase: phase, straps: straps, hint: hint,
                 showReassurance: reassured, connectStalled: stalled, batteryPct: battery,
                 onPick: { _ in }, onRescan: {}, onDone: {})
            .padding(WM.Space.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(WM.Ground.ground)
    }
}
