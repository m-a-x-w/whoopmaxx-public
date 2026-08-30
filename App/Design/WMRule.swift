import SwiftUI

/// The list-row rule — a `WM.Ground.rule` hairline. THE separator primitive: in the Line language
/// (037) a hairline appears only between list rows, and every one of them is this exact shape,
/// so it lives in one place instead of being retyped (it was previously two byte-identical `RowRule`
/// structs, three per-file `hairline` vars, and ~25 bare `Rectangle().fill(WM.Ground.rule)` inlines).
///
/// It takes the full width offered and only pins its height, so it composes the same in a `VStack`,
/// an `.overlay(alignment: .bottom)`, or a `.background`.
///
/// Rules that are NOT this shape stay hand-written — the `ruleHeavy` floor under the widget's
/// ScoreColumn is a different mark.
struct WMRule: View {
    var body: some View {
        Rectangle()
            .fill(WM.Ground.rule)
            .frame(height: WM.hairline)
    }
}
