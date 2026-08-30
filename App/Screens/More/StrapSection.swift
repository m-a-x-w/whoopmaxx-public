import SwiftUI

/// The STRAP section of More: live device state, the strap-health cover launcher, pair, forget.
///
/// P7 (T2.19): the section body itself observes NOTHING. The two live-fed rows declare their own
/// `@EnvironmentObject` — so `LiveState`'s ~1 Hz publishes (and `AppRoot`'s `bpm` republish) re-render
/// those two rows instead of the whole More scroll body. Same idiom as RestScreen's `WakeWindowArmed`
/// and StrapHealthScreen's leaf views.
///
/// The two cover/sheet launchers take their presentation as plain closures so MoreScreen keeps owning
/// the one `activeCover` state.
struct StrapSection: View {
    let onStrapHealth: () -> Void
    let onPair: () -> Void

    var body: some View {
        RuleSection("Strap") {
            VStack(spacing: 0) {
                StrapRowArmed()
                WMRule()
                // Opens the strap health center cover (battery / capture / signal).
                WMNavRow(title: "Strap health",
                         subtitle: "Battery, capture & signal",
                         hint: "Opens the strap's battery, capture and signal health",
                         action: onStrapHealth)
                WMRule()
                // Presents the scan/pair sheet — the same present-scan flow first-run embeds inline.
                WMNavRow(title: "Pair strap", action: onPair)
                WMRule()
                ForgetStrapRow()
            }
        }
    }
}

/// True when there is a strap to release: a live link, or a paired-but-idle bond. One owner, read by
/// both live-fed rows below.
private extension LiveState {
    var hasStrap: Bool { connected || bonded }
}

/// P7 (T2.19): the device-state row, isolated so its `LiveState` reads (connection, bond, advertising
/// name, battery, status label) re-render THIS row on the strap's ~1 Hz publishes instead of all of
/// MoreScreen — RestScreen's `WakeWindowArmed` idiom.
private struct StrapRowArmed: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        HStack(spacing: WM.Space.m) {
            Circle()
                .fill(live.connected ? WM.Semantic.good
                      : live.bonded ? WM.Semantic.warn
                      : WM.Ground.inkTertiary)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(live.hasStrap ? (live.advertisingName ?? "WHOOP") : "No strap")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Spacer()
            Text(deviceStateText)
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, WM.Space.m)
        .accessibilityElement(children: .combine)
    }

    private var deviceStateText: String {
        var text = live.connectionStatusLabel
        if let pct = live.batteryPct { text += " · \(Int(pct.rounded()))%" }
        return text
    }
}

/// Releases the strap fully (`AppRoot.forgetStrap` — stops auto-reconnect, drops the link, clears
/// targeting and the persisted pin) so it can enter pairing mode elsewhere.
///
/// P7 (T2.19): declares its own `live` (which gates the row) and `root` (the action), so the ~1 Hz
/// churn off either object re-renders this row only.
private struct ForgetStrapRow: View {
    @EnvironmentObject private var root: AppRoot
    @EnvironmentObject private var live: LiveState

    @State private var confirmingForget = false

    var body: some View {
        Button {
            confirmingForget = true
        } label: {
            HStack {
                Text("Forget device")
                    .font(WMType.body)
                    .foregroundStyle(live.hasStrap ? WM.Ground.ink : WM.Ground.inkTertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!live.hasStrap)
        .padding(.vertical, WM.Space.m)
        .confirmationDialog("Forget this strap?", isPresented: $confirmingForget,
                            titleVisibility: .visible) {
            Button("Forget device", role: .destructive) { root.forgetStrap() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops auto-reconnect and releases the strap so it can pair with another device.")
        }
    }
}
