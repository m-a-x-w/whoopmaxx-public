import SwiftUI

/// The navigation chrome primitives — back link, close button, disclosure chevron.
///
/// Chrome stays NEUTRAL INK (color = data only), and every tap target here carries its own
/// ≥44pt HIG hit region so the rule can't be forgotten at a call site. That is exactly what went wrong
/// before these existed: two of the six in-content back links had grown a 44pt frame independently and
/// the other four were still a 14pt glyph at bare text height.

// MARK: - Back link

/// The in-content back affordance used by every pushed detail screen (the nav bar is hidden app-wide,
/// so this IS the back control). Ink, no tint.
///
/// `title` names the destination — it is both the visible label and, as "Back to <title>", the
/// VoiceOver label.
struct WMBackLink: View {
    let title: String
    let action: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: WM.Space.xs) {
                Image(systemName: "chevron.left")
                    .font(WMType.icon(.nav))
                Text(title)
                    .font(WMType.body)
            }
            .foregroundStyle(WM.Ground.ink)
            .frame(minHeight: 44, alignment: .leading)   // HIG tap height for the back affordance
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to \(title)")
    }
}

// MARK: - Close button

/// The ink close (`xmark`) on full-screen covers and sheets. The glyph keeps its 16pt size; only the
/// invisible 44×44 box around it grows to the HIG target, and it is TRAILING-aligned inside that box
/// so the glyph sits on the screen's right margin rather than 14pt inboard of it.
///
/// Callers attach their own `.accessibilityLabel("Close <thing>")` — the label names the surface being
/// dismissed, which only the call site knows.
struct WMCloseButton: View {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(WMType.icon(.close))
                .foregroundStyle(WM.Ground.inkSecondary)
                .frame(width: 44, height: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Disclosure

/// The row disclosure chevron — a decorative "this pushes" marker at the trailing edge of a tappable
/// row. It carries no hit region of its own (the row owns the `contentShape`) and no accessibility
/// identity (the row's combined label already says where it goes).
struct WMDisclosure: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(WMType.icon(.disclosure))
            .foregroundStyle(WM.Ground.inkTertiary)
    }
}
