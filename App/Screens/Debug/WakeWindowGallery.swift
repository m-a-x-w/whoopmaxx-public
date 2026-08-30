#if DEBUG
import SwiftUI

/// DEBUG-only render proof for the Rest wake-window cluster (W9). Reachable via `--wake-gallery` (see
/// `AppShell`), so agents can screenshot BOTH states — enabled (indigo hero + pickers + armed status) and
/// disabled (toggle + explainer) — light AND dark, without scrolling past the Last-night hero on the real
/// Rest screen. (`#Preview`s in WakeWindowSection.swift cover the same in Xcode; this covers the running
/// app.) The section renders identically here and in RestScreen — same view, same tokens.
struct WakeWindowGallery: View {
    // Volatile defaults so the gallery never touches the app's real alarm settings.
    private let enabledSettings = WakeWindowGallery.demoSettings(enabled: true)
    private let armedSettings = WakeWindowGallery.demoSettings(enabled: true)
    private let disabledSettings = WakeWindowGallery.demoSettings(enabled: false)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WM.Space.section) {
                Text("Wake window gallery")
                    .font(WMType.title)
                    .foregroundStyle(WM.Ground.ink)
                    .padding(.top, WM.Space.gutter)

                Text("Disabled · collapsed").wmOverline()
                WakeWindowSection(settings: disabledSettings, strapArmed: false, onApply: {})

                Text("Enabled · strap not connected (sim)").wmOverline()
                WakeWindowSection(settings: enabledSettings, strapArmed: false, onApply: {})

                Text("Enabled · armed on the strap").wmOverline()
                WakeWindowSection(settings: armedSettings, strapArmed: true, onApply: {})
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }

    @MainActor
    private static func demoSettings(enabled: Bool) -> SmartAlarmSettings {
        let s = SmartAlarmSettings(defaults: UserDefaults(suiteName: "wm.gallery.wakewindow")!)
        s.enabled = enabled
        s.setEarliest(6 * 60 + 30)
        s.setLatest(7 * 60)
        return s
    }
}
#endif
