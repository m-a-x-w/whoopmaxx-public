#if os(iOS)
import SwiftUI
import WidgetKit
import AppIntents

/// The Lock Screen quick-log surfaces, parameterized by `WidgetFamily` explicitly rather than read
/// from the (get-only) `\.widgetFamily` environment — the same split `WMWidgetContent` uses, and for
/// the same reason: the extension's timeline view AND the in-app DEBUG gallery render this one
/// definition, so what an agent screenshots is what the Lock Screen draws.
///
/// Chrome only, no color. The Lock Screen renders accessory widgets in its own vibrant material and
/// flattens color anyway, so the app's domain tints would be fought for nothing — and none of the
/// three domains owns "intake" in the first place.
struct WMIntakeAccessoryContent: View {
    let family: WidgetFamily
    /// The user's standing choice: kind, the one amount field that belongs to it, and the strings.
    let preset: IntakeQuickPreset
    /// Taps still waiting to be drained, so the count moves under the finger rather than at the app's
    /// next launch. Zero draws nothing.
    var pending: Int = 0

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        default:                 rectangular
        }
    }

    /// The whole circle is the button. Symbol alone when the tap is bare — never a "—" or a "0", which
    /// would read as a recorded amount rather than an absent one.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            tapTarget {
                VStack(spacing: 0) {
                    Image(systemName: preset.symbol)
                        .font(.system(size: preset.caption.isEmpty ? 22 : 15))
                    if !preset.caption.isEmpty {
                        Text(compactAmount)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
    }

    /// Label and the standing amount in full, with the pending count where there is one.
    private var rectangular: some View {
        tapTarget {
            VStack(alignment: .leading, spacing: 1) {
                Label(preset.label, systemImage: preset.symbol)
                    .font(.headline)
                    .lineLimit(1)
                if !preset.caption.isEmpty {
                    Text(preset.caption)
                        .font(.caption)
                        .lineLimit(1)
                }
                if pending > 0 {
                    // PENDING taps, and it says so — the widget cannot know today's intake without the
                    // database it deliberately does not have.
                    Text("\(pending) waiting")
                        .font(.caption2)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The button every family shares: fills its container, so the tap target IS the widget. This is
    /// what answers 028's objection to accessory families — one action, full-size target, rather than
    /// four buttons subdivided into a space that small.
    private func tapTarget<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Button(intent: preset.logIntent) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The circular tile's amount, shortened to what fits: the bare figure for milligrams and counts
    /// (the cup/pill/glass symbol above it carries the unit), the size word for a meal.
    private var compactAmount: String {
        if let mg = preset.amountMg { return "\(mg)" }
        if let count = preset.countValue { return "\(count)" }
        return preset.caption
    }

    private var accessibilityLabel: String {
        preset.caption.isEmpty ? "Log \(preset.label)" : "Log \(preset.label), \(preset.caption)"
    }
}
#endif
