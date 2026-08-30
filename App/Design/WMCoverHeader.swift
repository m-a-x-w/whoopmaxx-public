import SwiftUI

/// The top bar of a full-screen cover / sheet (037): a `TabHeader` — the 64pt row with the 28 bold
/// `WMType.title` over an optional one-line subtitle on the leading side — with `WMCloseButton` (an
/// inkSecondary `xmark` sized by `WMType.icon(.close)`) as its trailing control. A cover's title
/// therefore sits exactly where a tab's does, and the 64pt row is the whole gap under the status bar
/// (or a sheet's grabber): there is no extra top padding.
///
/// One shape for all of them. Before this the same HStack was retyped per screen and the comments had
/// started to chain ("mirroring Breathe's top bar" → "mirroring Body Clock's top bar" → "mirroring Buzz
/// history's top bar"), which is the tell that a primitive was missing.
///
/// `accessory` is an optional view dropped before the close — Buzz history's low-key "Clear" and Signal
/// Lab's Physical · Raw units toggle. Every cover and sheet with a close uses this row (Breathe and
/// Signal Lab included); `WMCloseButton` on its own is only its trailing control.
struct WMCoverHeader<Accessory: View>: View {
    let title: String
    /// One line under the title (Strap health's "Bonded · streaming · firmware 41.16.3"); nil for none.
    let subtitle: String?
    /// VoiceOver label for the close ("Close body clock").
    let closeLabel: String
    let onClose: () -> Void
    let accessory: Accessory

    init(title: String, subtitle: String? = nil, closeLabel: String, onClose: @escaping () -> Void,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.closeLabel = closeLabel
        self.onClose = onClose
        self.accessory = accessory()
    }

    var body: some View {
        TabHeader(title, subtitle: subtitle) {
            accessory
            WMCloseButton(action: onClose)
                .accessibilityLabel(closeLabel)
        }
    }
}

extension WMCoverHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, closeLabel: String, onClose: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, closeLabel: closeLabel, onClose: onClose) { EmptyView() }
    }
}

#Preview("WMCoverHeader — light") {
    WMCoverHeaderSpecimen().preferredColorScheme(.light)
}

#Preview("WMCoverHeader — dark") {
    WMCoverHeaderSpecimen().preferredColorScheme(.dark)
}

private struct WMCoverHeaderSpecimen: View {
    var body: some View {
        VStack(spacing: WM.Space.l) {
            WMCoverHeader(title: "Diagnostics", closeLabel: "Close diagnostics") {}
            WMCoverHeader(title: "WHOOP 4.0", subtitle: "Bonded · streaming · firmware 41.16.3",
                          closeLabel: "Close strap health") {}
            WMCoverHeader(title: "Buzz history", closeLabel: "Close buzz history") {} accessory: {
                Text("Clear")
                    .font(WMType.label)
                    .foregroundStyle(WM.Ground.inkSecondary)
            }
        }
        .padding(.horizontal, WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
