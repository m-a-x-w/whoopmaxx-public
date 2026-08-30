import SwiftUI
import WidgetKit
import AppIntents

/// The Log-intake widget (028): one tap per kind, straight from the Home Screen.
///
/// A DEDICATED widget, not buttons bolted onto the score widget. That one is a glance surface whose
/// whole job is Charge / Effort / Rest, and at `systemSmall` there is genuinely no room for both —
/// every button added would cost a number it exists to show. Users who want quick-log add this one.
///
/// There is no Live Activity counterpart: `WMActivityAttributes` is an ACTIVE LIVE-HR SESSION, which
/// exists for a small slice of the day and not the slice in which people eat.
@available(iOS 17.0, *)
struct WMIntakeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WMIntakeWidget", provider: IntakeQuickProvider()) { entry in
            WMIntakeWidgetView(entry: entry)
                // Honor the in-app appearance pref (mirrored into the App Group — WMAppearance), exactly
                // as the score widget does. 028 shipped this tile on the raw token, so for anyone whose
                // pref isn't "system" every adaptive token here resolved against the PHONE's scheme —
                // a papery-white Log tile sitting beside a graphite whoopmaxx tile on the same Home
                // Screen. Both halves are load-bearing: `.wmAppearance()` forces the scheme on the
                // content (ground, ink, inkTertiary), and containerBackground gets the CONCRETE ground
                // variant because it resolves outside the view environment and the override alone
                // wouldn't reach it.
                .wmAppearance()
                .containerBackground(WMAppearance.resolve(WM.Ground.ground), for: .widget)
        }
        .configurationDisplayName("Log intake")
        .description("One tap to log a meal, drink or dose.")
        // Home Screen only. The accessory families are a few points tall — a tap target there would
        // be smaller than the HIG minimum and mis-taps on a LOGGING control write false records.
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@available(iOS 17.0, *)
struct IntakeQuickEntry: TimelineEntry {
    let date: Date
    /// Entries still waiting to be drained — the widget's own optimistic count, so a tap registers
    /// under the finger instead of after the app next runs.
    let pending: Int
}

@available(iOS 17.0, *)
struct IntakeQuickProvider: TimelineProvider {
    func placeholder(in context: Context) -> IntakeQuickEntry { .init(date: Date(), pending: 0) }

    func getSnapshot(in context: Context, completion: @escaping (IntakeQuickEntry) -> Void) {
        completion(.init(date: Date(), pending: IntakeOutbox.pending().count))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IntakeQuickEntry>) -> Void) {
        let entry = IntakeQuickEntry(date: Date(), pending: IntakeOutbox.pending().count)
        // `.never`: nothing here changes on a clock. The only thing that moves this widget is a tap,
        // and the intent reloads the timeline itself — so a scheduled refresh would burn budget to
        // redraw an identical tile.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

@available(iOS 17.0, *)
struct WMIntakeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: IntakeQuickEntry

    /// Which kinds get a button. Fixed for now — the four with a response worth drawing, in the order
    /// people log them. `water` is last because it is the one that draws no tape at all.
    private var kinds: [(raw: String, label: String, symbol: String)] {
        let all = [("meal", "Meal", "fork.knife"),
                   ("caffeine", "Caffeine", "cup.and.saucer"),
                   ("alcohol", "Alcohol", "wineglass"),
                   ("water", "Water", "drop")]
        return family == .systemSmall ? Array(all.prefix(2)) : all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Log").font(.caption).textCase(.uppercase)
                    .foregroundStyle(WM.Ground.inkTertiary)
                Spacer()
                // The count is of PENDING taps, and says so — it is not "today's intake", which the
                // widget cannot know without the database it deliberately does not have.
                if entry.pending > 0 {
                    Text("\(entry.pending) waiting")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: kinds.count, by: 2)), id: \.self) { row in
                    GridRow {
                        ForEach(kinds[row..<min(row + 2, kinds.count)], id: \.raw) { k in
                            button(k)
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private func button(_ k: (raw: String, label: String, symbol: String)) -> some View {
        Button(intent: LogIntakeIntent(kind: k.raw)) {
            VStack(spacing: 2) {
                Image(systemName: k.symbol).font(.body)
                Text(k.label).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
        .tint(WM.Ground.ink)
        .accessibilityLabel("Log \(k.label)")
    }
}
