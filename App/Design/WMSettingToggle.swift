import SwiftUI

/// The Preferences switch row: ink body label + a `WM.Ground.control`-tinted `Toggle`, with an
/// optional explanatory caption underneath.
///
/// One shape for all of them — the font / tint / vertical rhythm and the caption block were retyped
/// per toggle in More, so every new wave's switch re-spelled six lines to look like its neighbours.
///
/// The `.onChange` stays at the CALL SITE: what a flip has to re-issue (a Health authorization, a BLE
/// reconcile, nothing at all) is the caller's business, not the row's.
struct WMSettingToggle: View {
    let label: String
    @Binding var isOn: Bool
    /// Explanatory line under the switch. Empty/nil renders nothing (a caption that is empty in some
    /// states — More's Apple Health auth caption — can pass its string straight through).
    let caption: String?

    init(label: String, isOn: Binding<Bool>, caption: String? = nil) {
        self.label = label
        self._isOn = isOn
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $isOn) {
                Text(label)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
            }
            .tint(WM.Ground.control)
            .padding(.vertical, WM.Space.m)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, WM.Space.m)
            }
        }
    }
}

#Preview("WMSettingToggle — light") {
    WMSettingToggleSpecimen().preferredColorScheme(.light)
}

#Preview("WMSettingToggle — dark") {
    WMSettingToggleSpecimen().preferredColorScheme(.dark)
}

private struct WMSettingToggleSpecimen: View {
    @State private var on = true
    @State private var off = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WMSettingToggle(label: "Auto-start Live Activity on connect", isOn: $on)
            WMRule()
            WMSettingToggle(label: "Auto-detect workouts", isOn: $off,
                            caption: "Scans recent heart rate for a sustained effort and offers to save it as a workout on Today.")
        }
        .padding(.horizontal, WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
