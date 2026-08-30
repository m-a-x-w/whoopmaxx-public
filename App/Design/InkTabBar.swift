import SwiftUI

/// The app's five tabs (037, IA-1), in display order — `allCases` IS the bar's left-to-right
/// order. There is no More tab: Settings is a sheet `AppShell` presents (`AppActions.openSettings`).
enum WMTab: String, CaseIterable, Identifiable, Hashable {
    case today, rest, log, live, data

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .today: return "sun.max"
        case .rest:  return "moon"
        case .log:   return "plus.square"
        case .live:  return "waveform.path.ecg"
        case .data:  return "square.grid.2x2"
        }
    }

    var title: String { rawValue.capitalized }
}

/// Floating pill tab bar (037): a 58pt groundRaised capsule inset 44pt from the screen edges —
/// soft shadow in light, a hairline in dark where a shadow has nothing to fall on — holding the tabs' SF
/// Symbols; active = ink icon + 4pt ink dot beneath, inactive = inkTertiary. Place via
/// `.safeAreaInset(edge: .bottom) { InkTabBar(selection: $tab) }` so it floats above the home
/// indicator and content scrolls beneath it. The 44pt inset is padding INSIDE this view, so its frame
/// spans the full width — a background behind it (AppShell's ground fade) reaches both screen edges.
struct InkTabBar: View {
    @Binding var selection: WMTab
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WMTab.allCases) { tab in
                item(tab)
            }
        }
        // 44pt items + 7pt above and below = the spec's 58pt pill.
        .padding(.vertical, 7)
        .padding(.horizontal, WM.Space.s)
        .background(
            Capsule()
                .fill(WM.Ground.groundRaised)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.07), radius: 14, y: 6)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.04), radius: 1, y: 1)
        )
        .overlay(Capsule().strokeBorder(WM.Ground.rule.opacity(colorScheme == .dark ? 1 : 0), lineWidth: WM.hairline))
        .padding(.horizontal, 44)
        .padding(.bottom, WM.Space.xs)
    }

    private func item(_ tab: WMTab) -> some View {
        let active = tab == selection
        return Button {
            selection = tab
        } label: {
            // Icon centered in a stable slot; the dot appears only when active, and the icon nudges up
            // just enough to seat the icon + ~4pt gap + dot group centered. Inactive icons sit
            // dead-center (no reserved dot space pulling them up).
            ZStack {
                Image(systemName: tab.symbol)
                    .font(WMType.icon(.tab))
                    .offset(y: active ? -5 : 0)
                Circle()
                    .fill(WM.Ground.ink)
                    .frame(width: 4, height: 4)
                    .opacity(active ? 1 : 0)
                    .offset(y: 11)
            }
            .frame(height: 30)                                  // icon slot stays 30pt, centered
            .foregroundStyle(active ? WM.Ground.ink : WM.Ground.inkTertiary)
            .frame(maxWidth: .infinity, minHeight: 44)          // HIG: guarantee a >=44pt tall hit region
                                                                // (the HStack's outer padding is dead space)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .wmAnimation(WMMotion.value, value: selection)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

#Preview("InkTabBar — light") {
    InkTabBarSpecimen().preferredColorScheme(.light)
}

#Preview("InkTabBar — dark") {
    InkTabBarSpecimen().preferredColorScheme(.dark)
}

private struct InkTabBarSpecimen: View {
    @State private var tab: WMTab = .today

    var body: some View {
        WM.Ground.ground
            .ignoresSafeArea()
            .safeAreaInset(edge: .bottom) {
                InkTabBar(selection: $tab)
            }
    }
}
