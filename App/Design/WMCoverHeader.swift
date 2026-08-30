import SwiftUI

/// The top bar of a full-screen cover / sheet: screen title on the left, ink close on the right,
/// baseline-aligned, with the standard `WM.Space.m` top gap.
///
/// One shape for all of them. Before this the same HStack was retyped per screen and the comments had
/// started to chain ("mirroring Breathe's top bar" → "mirroring Body Clock's top bar" → "mirroring Buzz
/// history's top bar"), which is the tell that a primitive was missing.
///
/// `accessory` is an optional view dropped between the spacer and the close — Buzz history's low-key
/// "Clear" is the only current user. Covers with NO title (Breathe, Signal Lab) use `WMCloseButton`
/// directly instead; their close floats over the content rather than sitting in a title row.
struct WMCoverHeader<Accessory: View>: View {
    let title: String
    /// VoiceOver label for the close ("Close body clock").
    let closeLabel: String
    let onClose: () -> Void
    let accessory: Accessory

    init(title: String, closeLabel: String, onClose: @escaping () -> Void,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.closeLabel = closeLabel
        self.onClose = onClose
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
            Spacer()
            accessory
            WMCloseButton(action: onClose)
                .accessibilityLabel(closeLabel)
        }
        .padding(.top, WM.Space.m)
    }
}

extension WMCoverHeader where Accessory == EmptyView {
    init(title: String, closeLabel: String, onClose: @escaping () -> Void) {
        self.init(title: title, closeLabel: closeLabel, onClose: onClose) { EmptyView() }
    }
}
