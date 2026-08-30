import SwiftUI

/// The app's five tabs.
enum WMTab: String, CaseIterable, Identifiable, Hashable {
    case today, rest, data, live, more

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .today: return "sun.max"
        case .rest:  return "moon"
        case .data:  return "square.grid.2x2"
        case .live:  return "waveform.path.ecg"
        case .more:  return "ellipsis"
        }
    }

    var title: String { rawValue.capitalized }
}

/// Floating pill tab bar: groundRaised capsule with a hairline border, 5 SF Symbols; active = ink
/// icon + 4pt ink dot beneath, inactive = inkTertiary. Place via
/// `.safeAreaInset(edge: .bottom) { InkTabBar(selection: $tab) }` so it floats above the home
/// indicator and content scrolls beneath it.
struct InkTabBar: View {
    @Binding var selection: WMTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WMTab.allCases) { tab in
                item(tab)
            }
        }
        .padding(.vertical, WM.Space.s)
        .padding(.horizontal, WM.Space.s)
        .background(Capsule().fill(WM.Ground.groundRaised))
        .overlay(Capsule().strokeBorder(WM.Ground.rule, lineWidth: WM.hairline))
        .padding(.horizontal, WM.Space.gutter)
        .padding(.bottom, WM.Space.xs)
    }

    private func item(_ tab: WMTab) -> some View {
        let active = tab == selection
        return Button {
            selection = tab
        } label: {
            // Icon centered in a stable slot; the dot appears only when active, and the icon nudges up
            // just enough to seat the icon+dot pair centered. Inactive icons sit dead-center (no reserved
            // dot space pulling them up).
            ZStack {
                Image(systemName: tab.symbol)
                    .font(WMType.icon(.tab))
                    .offset(y: active ? -4 : 0)
                Circle()
                    .fill(WM.Ground.ink)
                    .frame(width: 4, height: 4)
                    .opacity(active ? 1 : 0)
                    .offset(y: 9)
            }
            .frame(height: 28)                                  // icon slot stays 28pt, centered
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
