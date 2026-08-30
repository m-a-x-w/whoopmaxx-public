#if os(iOS)
import WidgetKit
import SwiftUI
import ActivityKit

/// Live Activity for an active live-HR session — Lock Screen banner + Dynamic Island. Read-only glance
/// (no interactive controls): the huge live bpm alongside the Charge / Effort pair. Restyled from the
/// original LiveActivity to the WM language — ink chrome, signal-red HR, ember Charge.
struct WMLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WMActivityAttributes.self) { context in
            // Honor the in-app appearance pref (mirrored into the App Group — WMAppearance): force the
            // scheme on the banner, and resolve the tints to CONCRETE variants (both are applied outside
            // the view environment, so the override alone wouldn't reach them). The Dynamic Island stays
            // system-styled — it always renders on the island's own dark surface.
            lockScreen(context)
                .wmAppearance()
                .activityBackgroundTint(WMAppearance.resolve(WM.Ground.ground))
                .activitySystemActionForegroundColor(WMAppearance.resolve(WM.Ground.ink))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(bpmText(context.state.bpm), systemImage: "waveform.path.ecg")
                        .foregroundStyle(WM.Domain.effort.color)
                        .font(WMType.numeral(22))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: WM.Space.m) {
                        if let c = context.state.charge { islandStat("Charge", "\(c)", .charge) }
                        if let e = context.state.effort { islandStat("Effort", "\(e)", .effort) }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.title).wmOverline()
                }
            } compactLeading: {
                Image(systemName: "waveform.path.ecg").foregroundStyle(WM.Domain.effort.color)
            } compactTrailing: {
                Text(bpmText(context.state.bpm)).font(WMType.numeral(15))
            } minimal: {
                Image(systemName: "waveform.path.ecg").foregroundStyle(WM.Domain.effort.color)
            }
        }
    }

    private func lockScreen(_ context: ActivityViewContext<WMActivityAttributes>) -> some View {
        WMLiveActivityBanner(state: context.state, title: context.attributes.title)
    }

    private func bpmText(_ bpm: Int?) -> String { bpm.map(String.init) ?? "—" }

    private func islandStat(_ label: String, _ value: String, _ domain: WM.Domain) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(label).wmOverline()
            Text(value).font(WMType.numeral(17)).foregroundStyle(domain.color)
        }
        .fixedSize()
    }
}
#endif
