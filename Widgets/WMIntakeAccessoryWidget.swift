import SwiftUI
import WidgetKit
import AppIntents

/// The Lock Screen quick-log widget (031): ONE configured tap, in the strip around the clock.
///
/// 028 kept the intake widget off the accessory families, and its reasoning still stands as written —
/// "a tap target there would be smaller than the HIG minimum and mis-taps on a LOGGING control write
/// false records". That was a verdict on a FOUR-BUTTON GRID at accessory size, not on the family. This
/// widget carries a single action, so the tap target is the entire widget: the whole circle, the whole
/// rectangle. That is larger than any button on the Home Screen version, not smaller.
///
/// What it logs is the user's standing choice (`IntakeQuickConfigIntent`) rather than a fixed set,
/// because one button cannot offer four kinds. Bare is still the default: a widget configured with no
/// amount writes nils, exactly as a 028 tap does.
///
/// `accessoryInline` is deliberately absent — it renders as text beside the date and cannot host a
/// button, so it could only ever open the app, which is the context switch this whole lane exists to
/// avoid.
struct WMIntakeAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "WMIntakeAccessory",
                               intent: IntakeQuickConfigIntent.self,
                               provider: IntakeAccessoryProvider()) { entry in
            WMIntakeAccessoryView(entry: entry)
                // Clear, not the app ground: the Lock Screen renders accessory widgets in its own
                // vibrant material and flattens color anyway, so painting the papery ground here would
                // fight the system for no gain. `AccessoryWidgetBackground` supplies the circular well.
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Log intake")
        .description("One tap to log a meal, drink or dose. Choose what it logs in Edit Widget.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct IntakeAccessoryEntry: TimelineEntry {
    let date: Date
    /// The resolved configuration — kind, the amount that belongs to it, and the strings to draw.
    let preset: IntakeQuickPreset
    /// Taps still waiting to be drained (`IntakeOutbox`), so a tap registers under the finger rather
    /// than after the app next runs. Same optimistic count the 028 widget shows.
    let pending: Int
}

struct IntakeAccessoryProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> IntakeAccessoryEntry {
        IntakeAccessoryEntry(date: Date(), preset: .preview, pending: 0)
    }

    func snapshot(for configuration: IntakeQuickConfigIntent,
                  in context: Context) async -> IntakeAccessoryEntry {
        IntakeAccessoryEntry(date: Date(), preset: configuration.preset,
                             pending: IntakeOutbox.pending().count)
    }

    func timeline(for configuration: IntakeQuickConfigIntent,
                  in context: Context) async -> Timeline<IntakeAccessoryEntry> {
        let entry = IntakeAccessoryEntry(date: Date(), preset: configuration.preset,
                                         pending: IntakeOutbox.pending().count)
        // `.never` — nothing here moves on a clock. The only thing that changes this widget is a tap,
        // and `LogIntakeIntent` reloads the timeline itself.
        return Timeline(entries: [entry], policy: .never)
    }
}

/// The extension's timeline view: reads the system `\.widgetFamily` and delegates to the shared
/// `WMIntakeAccessoryContent` (which both this and the in-app DEBUG gallery render).
struct WMIntakeAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: IntakeAccessoryEntry

    var body: some View {
        WMIntakeAccessoryContent(family: family, preset: entry.preset, pending: entry.pending)
    }
}
