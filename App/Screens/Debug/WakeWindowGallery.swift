#if DEBUG
import SwiftUI
import StrapAnalytics

/// DEBUG-only render proof for the Rest wake-window row (W9) and the bedtime row beside it under
/// "Tonight". Reachable via `--wake-gallery` (see `AppShell`), so agents can screenshot every state —
/// disabled (row + explainer), enabled with the backup-only / confirming / armed status dots and their
/// inline controls, and the bedtime row populated and cold — light AND dark, without scrolling past the
/// Rest hero on the real screen. (`#Preview`s in WakeWindowSection.swift and OptimalBedtimeSection.swift
/// cover the same in Xcode; this covers the running app.) Each row renders identically here and in
/// RestScreen — same view, same tokens.
struct WakeWindowGallery: View {
    // Volatile defaults so the gallery never touches the app's real alarm settings.
    private let enabledSettings = WakeWindowGallery.demoSettings(enabled: true)
    private let confirmingSettings = WakeWindowGallery.demoSettings(enabled: true)
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

                Text("Enabled · confirming on the strap").wmOverline()
                WakeWindowSection(settings: confirmingSettings, strapArmed: false, strapConfirming: true, onApply: {})

                Text("Enabled · armed on the strap").wmOverline()
                WakeWindowSection(settings: armedSettings, strapArmed: true, onApply: {})

                Text("Bedtime · populated").wmOverline()
                OptimalBedtimeSection(recommendation: .constrainedSpecimen)

                Text("Bedtime · cold start").wmOverline()
                OptimalBedtimeSection(recommendation: nil)
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
