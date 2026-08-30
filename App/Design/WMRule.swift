import SwiftUI

/// The thin section/row rule — a `WM.Ground.rule` hairline. THE separator primitive: every list row
/// divider, section underline, and "floor" the app draws is this exact shape, so it lives in one
/// place instead of being retyped (it was previously two byte-identical `RowRule` structs, three
/// per-file `hairline` vars, and ~25 bare `Rectangle().fill(WM.Ground.rule)` inlines).
///
/// It takes the full width offered and only pins its height, so it composes the same in a `VStack`,
/// an `.overlay(alignment: .bottom)`, or a `.background`.
///
/// Rules that are NOT this shape stay hand-written — `ruleHeavy` floors (ScoreColumn, the focused
/// Data search field) and the 45%-opacity ruled-paper lanes in Night Movement are different marks.
struct WMRule: View {
    var body: some View {
        Rectangle()
            .fill(WM.Ground.rule)
            .frame(height: WM.hairline)
    }
}
