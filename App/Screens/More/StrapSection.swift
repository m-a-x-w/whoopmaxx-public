import SwiftUI

/// The rows of Settings › Strap (037): the strap itself — its name over its live state, opening
/// Strap health — then pair, then forget. `SettingsScreen` supplies the section label around them.
///
/// P7 (T2.19): this view itself observes NOTHING. The live-fed rows declare their own
/// `@EnvironmentObject` — so `LiveState`'s ~1 Hz publishes (and `AppRoot`'s `bpm` republish) re-render
/// those rows instead of the whole Settings scroll body. Same idiom as RestScreen's `WakeWindowArmed`
/// and StrapHealthScreen's leaf views.
///
/// The cover/sheet launchers take their presentation as plain closures so SettingsScreen keeps owning
/// the one `activeCover` state.
struct StrapSection: View {
    let onStrapHealth: () -> Void
    let onPair: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StrapRowsArmed(onStrapHealth: onStrapHealth, onPair: onPair)
            WMRule()
            ForgetStrapRow()
        }
    }
}

/// True when there is a strap to release: a live link, or a paired-but-idle bond. One owner, read by
/// both live-fed rows below.
private extension LiveState {
    var hasStrap: Bool { connected || bonded }
}

/// P7 (T2.19): the strap row and the pair row, isolated so their `LiveState` reads (connection, bond,
/// advertising name, battery, status label) re-render THESE rows on the strap's ~1 Hz publishes instead
/// of all of Settings — RestScreen's `WakeWindowArmed` idiom.
private struct StrapRowsArmed: View {
    @EnvironmentObject private var live: LiveState
    let onStrapHealth: () -> Void
    let onPair: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The strap by name, its state and battery underneath; the row opens the strap health
            // center cover (battery / capture / signal), which is what the tail of the subtitle names.
            WMNavRow(title: live.hasStrap ? (live.advertisingName ?? "WHOOP") : "No strap",
                     subtitle: deviceStateText + " · battery, capture & signal",
                     hint: "Opens the strap's battery, capture and signal health",
                     action: onStrapHealth)
            WMRule()
            // Presents the scan/pair sheet — the same present-scan flow first run embeds inline.
            WMNavRow(title: live.hasStrap ? "Pair a different strap" : "Pair a strap",
                     hint: "Searches for nearby straps to pair",
                     action: onPair)
        }
    }

    private var deviceStateText: String {
        var text = live.connectionStatusLabel
        if let pct = live.batteryPct { text += " · \(Int(pct.rounded()))%" }
        return text
    }
}

/// Releases the strap fully (`AppRoot.forgetStrap` — stops auto-reconnect, drops the link, clears
/// targeting and the persisted pin) so it can enter pairing mode elsewhere. A destructive row: its
/// title reads in `WM.Semantic.bad`, and nothing happens until the dialog is confirmed.
///
/// P7 (T2.19): declares its own `live` (which gates the row) and `root` (the action), so the ~1 Hz
/// churn off either object re-renders this row only.
private struct ForgetStrapRow: View {
    @EnvironmentObject private var root: AppRoot
    @EnvironmentObject private var live: LiveState

    @State private var confirmingForget = false

    var body: some View {
        WMNavRow(title: "Forget this strap",
                 hint: live.hasStrap ? "Asks to confirm first" : nil,
                 titleColor: live.hasStrap ? WM.Semantic.bad : WM.Ground.inkTertiary,
                 showsDisclosure: false) {
            confirmingForget = true
        }
        .disabled(!live.hasStrap)
        .confirmationDialog("Forget this strap?", isPresented: $confirmingForget,
                            titleVisibility: .visible) {
            Button("Forget device", role: .destructive) { root.forgetStrap() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops auto-reconnect and releases the strap so it can pair with another device.")
        }
    }
}
