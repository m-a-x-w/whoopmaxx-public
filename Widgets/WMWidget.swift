import WidgetKit
import SwiftUI
import AppIntents

/// Timeline entry backed by the latest `WidgetSnapshot` the app published into the App Group, plus the
/// user's standing choice of which single reading the Lock Screen accessory families show.
struct WMEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    /// From `GlanceWidgetConfigIntent`. Carried on the ENTRY rather than read from the configuration at
    /// render time because the view is shared with the in-app DEBUG gallery, which has no intent host —
    /// the same reason `WMWidgetContent` takes its family explicitly instead of reading the environment.
    let reading: GlanceReading
}

/// `AppIntentTimelineProvider`, not `TimelineProvider`: the configuration is delivered to each callback,
/// which is the only way the Lock Screen families can honour a per-widget choice.
struct WMProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WMEntry {
        WMEntry(date: Date(), snapshot: .placeholder, reading: .charge)
    }

    func snapshot(for configuration: GlanceWidgetConfigIntent, in context: Context) async -> WMEntry {
        // `.empty`, never `.placeholder`: this is a REAL render on the user's home screen once the widget
        // is added. Falling back to the gallery sample showed invented vitals as measurement.
        WMEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? .empty, reading: configuration.reading)
    }

    func timeline(for configuration: GlanceWidgetConfigIntent,
                  in context: Context) async -> Timeline<WMEntry> {
        let snap = WidgetSnapshot.load() ?? .empty      // see snapshot(for:in:) — never the gallery sample
        // Refresh roughly every 15 minutes; the app also forces a reload whenever it publishes fresh data
        // (WidgetCenter.reloadAllTimelines at its small set of publish points).
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(900)
        let entry = WMEntry(date: Date(), snapshot: snap, reading: configuration.reading)
        return Timeline(entries: [entry], policy: .after(next))
    }
}

/// The extension's timeline view: reads the system `\.widgetFamily` and delegates to the shared
/// `WMWidgetContent` (which both this and the in-app gallery render).
struct WMWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WMEntry

    var body: some View {
        WMWidgetContent(family: family, snap: entry.snapshot, reading: entry.reading)
    }
}

/// The glance widget: Charge / Effort / Rest and the live strip on the Home Screen, and ONE configured
/// reading on the Lock Screen.
///
/// **WHY IT BECAME CONFIGURABLE, AND WHY ONLY THE ACCESSORIES CHANGED.** `systemSmall` and
/// `systemMedium` have room for the whole picture, so nothing there is worth asking about. The accessory
/// families fit one number, and that number was hardwired to Charge — a user whose interest is Rest
/// could not put Rest beside their clock at all. `GlanceWidgetConfigIntent` reuses 032's `GlanceReading`
/// rather than declaring a parallel enum of the same five values; see that file for the argument.
///
/// **THE MIGRATION IS THE DELICATE PART.** `StaticConfiguration` → `AppIntentConfiguration` keeps the
/// SAME `kind` ("WMWidget") on purpose: changing it would orphan every widget the user has already
/// placed, and they would have to re-add it. Under the same kind the system re-renders the existing
/// placements with a default-initialised configuration, which is exactly why the intent's `reading`
/// parameter defaults to `.charge`. An already-placed Lock Screen widget therefore keeps drawing the
/// number it drew before the update; a default of anything else would silently repurpose it, which is a
/// regression no matter how good the new reading is.
struct WMWidget: Widget {
    let kind = "WMWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: GlanceWidgetConfigIntent.self,
                               provider: WMProvider()) { entry in
            WMWidgetEntryView(entry: entry)
                // Honor the in-app appearance pref (mirrored into the App Group — WMAppearance): force the
                // scheme on the content, and hand containerBackground the CONCRETE ground variant (it
                // resolves outside the view environment, so the override alone wouldn't reach it).
                //
                // This is the HOME SCREEN treatment and it stays as it was. The Lock Screen composites
                // accessory widgets through its own vibrant material, which flattens both the forced
                // scheme and the papery ground — so nothing here fights the system there, it simply has
                // no effect, and the accessory layouts are built to look right in that material.
                .wmAppearance()
                .containerBackground(WMAppearance.resolve(WM.Ground.ground), for: .widget)
        }
        .configurationDisplayName("whoopmaxx")
        .description("Charge, Effort, Rest, live heart rate and strap battery at a glance. "
                     + "On the Lock Screen, choose which one it shows in Edit Widget.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
    }
}
