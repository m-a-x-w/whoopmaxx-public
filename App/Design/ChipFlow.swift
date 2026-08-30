import SwiftUI

/// Minimal wrapping flow for chips (the journal day tags on Log): rows fill left→right and wrap at
/// the proposed width (SwiftUI ships no flow container). Row height follows the tallest chip in the row.
/// Lives in the design system since 037 — it used to sit in `TodayScreen.swift`, which no longer uses it.
struct ChipFlow: Layout {
    var spacing: CGFloat = WM.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let frames = layout(subviews: subviews, width: bounds.width).frames
        for (i, sub) in subviews.enumerated() {
            sub.place(at: CGPoint(x: bounds.minX + frames[i].minX, y: bounds.minY + frames[i].minY),
                      proposal: ProposedViewSize(frames[i].size))
        }
    }

    private func layout(subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x + size.width)
            x += size.width + spacing
        }
        return (frames, CGSize(width: maxX, height: y + rowHeight))
    }
}
