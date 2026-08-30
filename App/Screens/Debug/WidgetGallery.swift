#if DEBUG
import SwiftUI
import WidgetKit

/// DEBUG-only render proof for the widget surfaces. Reachable via `--widget-gallery` (see `AppShell`),
/// so agents can screenshot every family + the Live-Activity banner at their canonical sizes on seeded
/// data — light AND dark — without fighting the simulator's Home/Lock-Screen widget-placement flow.
/// (`#Preview`s cover the same in Xcode; this covers the running app.)
struct WidgetGallery: View {
    private let snap = WidgetSnapshot.placeholder
    private var liveState: WMActivityAttributes.ContentState {
        WMActivityAttributes.ContentState(bpm: 132, charge: 82, effort: 47, bonded: true)
    }
    /// One configured preset and one bare one — the two states every 031 tile has to render honestly.
    private let intakePresets: [IntakeQuickPreset] = [
        .make(kind: .caffeine, form: .pill, amountMg: 200),
        .make(kind: .meal)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WM.Space.section) {
                Text("Widget gallery").font(WMType.title).foregroundStyle(WM.Ground.ink)

                group("systemSmall") {
                    tile(width: 158, height: 158) { WMWidgetContent(family: .systemSmall, snap: snap) }
                }
                group("systemMedium") {
                    tile(width: 338, height: 158) { WMWidgetContent(family: .systemMedium, snap: snap) }
                }
                group("accessoryCircular") {
                    accessoryTile { WMWidgetContent(family: .accessoryCircular, snap: snap) }
                        .frame(width: 76, height: 76)
                }
                group("accessoryRectangular") {
                    accessoryTile { WMWidgetContent(family: .accessoryRectangular, snap: snap) }
                        .frame(width: 172, height: 76)
                }
                group("accessoryInline") {
                    accessoryTile { WMWidgetContent(family: .accessoryInline, snap: snap) }
                        .frame(height: 40)
                }
                // 031 — the Lock Screen quick-log surfaces. Two configurations per family: one with a
                // standing amount and one BARE, because "bare draws no amount at all" is the rule most
                // likely to regress into a stray "0" or "—" and the only way to see it is side by side.
                // The Control has no in-app twin: the system draws it, the app only supplies the label.
                group("accessoryCircular — log intake") {
                    HStack(spacing: WM.Space.m) {
                        ForEach(intakePresets, id: \.caption) { preset in
                            accessoryTile {
                                WMIntakeAccessoryContent(family: .accessoryCircular, preset: preset)
                            }
                            .frame(width: 76, height: 76)
                        }
                    }
                }
                group("accessoryRectangular — log intake") {
                    VStack(alignment: .leading, spacing: WM.Space.s) {
                        ForEach(intakePresets, id: \.caption) { preset in
                            accessoryTile {
                                WMIntakeAccessoryContent(family: .accessoryRectangular,
                                                         preset: preset, pending: 2)
                            }
                            .frame(width: 172, height: 76)
                        }
                    }
                }
                group("Live Activity — banner") {
                    tile(width: 360, height: 92) { WMLiveActivityBanner(state: liveState) }
                }
            }
            .padding(WM.Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text(title).wmOverline()
            content()
        }
    }

    /// A system-widget tile: content on ground, hairline border + widget corner radius to delineate it.
    private func tile<Content: View>(width: CGFloat, height: CGFloat,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: width, height: height, alignment: .topLeading)
            .background(WM.Ground.ground)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(WM.Ground.rule, lineWidth: WM.hairline))
    }

    /// Lock-screen accessories render on a dark vibrant chrome; approximate that here so the layout reads.
    private func accessoryTile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(WM.Ground.ink)
            .padding(WM.Space.s)
            .background(WM.Ground.groundRaised)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview("Widget gallery — light") {
    WidgetGallery().preferredColorScheme(.light)
}

#Preview("Widget gallery — dark") {
    WidgetGallery().preferredColorScheme(.dark)
}
#endif
