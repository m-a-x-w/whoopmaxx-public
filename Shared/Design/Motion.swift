import SwiftUI

/// Instrument-calm motion: needle-like value changes, quiet transitions, no decoration.
enum WMMotion {
    /// For numeral / bar / fill value changes — snappy, needle-like.
    static let value: Animation = .interactiveSpring(response: 0.3, dampingFraction: 0.8)

    /// For appear / selection transitions.
    static let transition: Animation = .easeOut(duration: 0.25)

    /// Resolve an animation against Reduce Motion: nil (no animation) when reduced.
    static func resolved(_ base: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}

/// `.animation(_:value:)` that respects Reduce Motion automatically.
struct WMAnimatedModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(WMMotion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// Animate changes of `value` with a WM motion curve, honoring Reduce Motion.
    func wmAnimation(_ animation: Animation = WMMotion.value, value: some Equatable) -> some View {
        modifier(WMAnimatedModifier(animation: animation, value: value))
    }
}
