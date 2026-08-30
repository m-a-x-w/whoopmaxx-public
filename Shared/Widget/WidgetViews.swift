// The whole file is iOS-only now, not just the Live Activity banner at the bottom: `GlanceReading` and
// `GlanceAccessory` live behind the same `#if os(iOS)` every AppIntents-bearing contract file carries
// (`GlanceIntents`, `IntakeQuickConfig`), and `WMWidgetContent` reads both. Every target in this project
// is iOS — app, widget extension and tests — so the guard costs nothing; it just keeps this file from
// being the one that breaks first if that ever stops being true. Same arrangement `IntakeAccessoryViews`
// has had since 031.
#if os(iOS)
import SwiftUI
import WidgetKit

/// The widget's rendered content, parameterized by `WidgetFamily` explicitly (rather than read from the
/// `\.widgetFamily` environment, which is get-only and can't be forced). That lets BOTH the extension's
/// timeline view AND the in-app DEBUG widget gallery render the exact same surfaces — the gallery just
/// passes each family by hand. Precision instrument on paper: ink chrome, color = the domain scores only.
struct WMWidgetContent: View {
    let family: WidgetFamily
    let snap: WidgetSnapshot
    /// Which single reading the Lock Screen accessory families show — the user's standing choice
    /// (`GlanceWidgetConfigIntent`), threaded down from the timeline entry.
    ///
    /// Ignored by `systemSmall` / `systemMedium`, which have room for the whole picture and so have
    /// nothing to choose; see the intent's doc for why the Edit sheet cannot hide the row from them.
    ///
    /// **DEFAULTED, and it has to stay defaulted.** It is declared last so the synthesised memberwise
    /// initialiser still accepts `WMWidgetContent(family:snap:)` — the in-app DEBUG gallery
    /// (`App/Screens/Debug/WidgetGallery.swift`) constructs every family that way, and that gallery is
    /// how these surfaces get screenshotted without fighting the simulator's widget-placement flow.
    /// `.charge` is the same default the intent carries, so the two cannot disagree about what an
    /// unconfigured widget shows.
    var reading: GlanceReading = .charge

    var body: some View {
        switch family {
        case .accessoryCircular:    accessoryCircular
        case .accessoryInline:      Text(inlineText)
        case .accessoryRectangular: rectangular
        case .systemMedium:         medium
        default:                    small
        }
    }

    /// The chosen reading resolved against this snapshot — strings, symbol and (when the reading has a
    /// scale AND a value) a 0…1 fill. All three accessory families read from this one resolution, so
    /// they cannot disagree about whether a reading was recorded.
    private var accessory: GlanceAccessory {
        GlanceAccessory.make(reading: reading, snapshot: snap)
    }

    // MARK: - System small — Charge hero + bar motif

    private var small: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            // No "as of" on small — too narrow; the bonded dot is the only chrome that fits cleanly.
            headerRow(title: "Charge", showStaleness: false)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.xs) {
                Text(numeral(snap.recovery))
                    .font(WMType.display(54))
                    .foregroundStyle(WM.Ground.ink)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(baselineCaption(snap.chargeBaseline))
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            ScoreBar(score: snap.recovery, baseline: snap.chargeBaseline, domain: .charge)
                .frame(height: 6)
            if snap.isEmpty {
                Text(emptyNote)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            footerStrip(compact: true)
        }
        .padding(WM.Space.l)
    }

    // MARK: - System medium — ScoreTrio + live strip

    private var medium: some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            headerRow(title: "whoopmaxx", showStaleness: true)
            // `calibratingNote: nil` on purpose: the widget renders a published SNAPSHOT and cannot see
            // the baseline state behind it, so it has no progress to report. A bare "calibrating" is
            // the honest read here — not an omission.
            ScoreTrio(charge: .init(score: dbl(snap.recovery), baseline: dbl(snap.chargeBaseline),
                                    calibratingNote: nil),
                      effort: .init(score: dbl(snap.effort), baseline: dbl(snap.effortBaseline),
                                    calibratingNote: nil),
                      rest: .init(score: dbl(snap.rest), baseline: dbl(snap.restBaseline),
                                  calibratingNote: nil),
                      height: 58)
            if snap.isEmpty {
                Text(emptyNote)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            footerStrip(compact: false)
        }
        .padding(WM.Space.m)
    }

    // MARK: - Lock-screen accessories
    //
    // All three draw the ONE reading the user configured (`reading`), and all three treat a missing
    // value the same way: the reading's NAME, and nothing shaped like a figure. No ring at zero, no
    // em-dash sitting where a number goes. `GlanceAccessory` is what makes that consistent — it hands
    // back a nil `value` / nil `gauge` rather than a sentinel, so there is no zero to reach for.
    //
    // Colour is left as it was: the domain tint on a score's ring, the battery's low-level warning on
    // battery. The Lock Screen composites accessories through its own vibrant material and flattens
    // that anyway, so the tint is not fighting the system there — it is what the in-app gallery and
    // StandBy render, and dropping it would change Charge's existing appearance for no gain.

    /// Three states, deliberately distinct rather than one layout with a fallback string.
    ///
    /// 1. **Scaled and present** — the accessory gauge, exactly as Charge has always drawn.
    /// 2. **Present but unscaled** (heart rate) — the figure in the well, no ring: there is no maximum
    ///    in this codebase to make a bpm a proportion OF, and a ring would assert one.
    /// 3. **Absent** — the symbol and the ring label, no well-filling arc and no digits at all. This is
    ///    the fix for the live bug: `Gauge(value: Double(recovery ?? 0))` drew a correctly-proportioned
    ///    ring at zero for the whole first night of a fresh install, visually identical to a real and
    ///    terrible score, on a strap that had never reported.
    private var accessoryCircular: some View {
        let a = accessory
        // A ZStack rather than a Group so the three branches share ONE accessibility container: a Group
        // applies its modifiers to each child, which would make the two-line wells below announce their
        // label twice.
        return ZStack {
            if let fill = a.gauge, let compact = a.compact {
                Gauge(value: fill, in: 0...1) {
                    Text(a.abbreviation)
                } currentValueLabel: {
                    Text(compact)
                }
                .gaugeStyle(.accessoryCircular)
                .tint(accessoryTint)
            } else if let compact = a.compact {
                accessoryWell {
                    Text(compact)
                        .font(.system(size: 22, weight: .regular))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(a.abbreviation).font(.system(size: 10, weight: .medium))
                }
            } else {
                accessoryWell {
                    Image(systemName: a.symbol).font(.system(size: 17))
                    Text(a.abbreviation).font(.system(size: 10, weight: .medium))
                }
            }
        }
        // Spoken explicitly, because the default reading of an absent tile would be its two loose
        // labels. VoiceOver must never be handed a gauge whose value is a stand-in for "unrecorded".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLine)
    }

    /// The circular well the two non-gauge states share. `AccessoryWidgetBackground` is the system's
    /// own tinted disc — the same one the 031 intake tile sits on — so an absent reading still occupies
    /// its slot on the Lock Screen rather than appearing as a hole.
    private func accessoryWell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) { content() }
        }
    }

    /// Headline is the chosen reading; the caption below carries whatever else was actually measured.
    ///
    /// The headline drops to the bare name when the reading is absent ("Charge", not "Charge —") and
    /// the caption says so in words, so the absence is stated once and never mimed by punctuation.
    private var rectangular: some View {
        let a = accessory
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: a.symbol)
                Text(a.value.map { "\(a.shortLabel) \($0)" } ?? a.shortLabel).font(.headline)
            }
            if !secondaryLine.isEmpty {
                Text(secondaryLine).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The rectangular caption, in priority order: an install that has never published says so; an
    /// absent headline says THAT; otherwise the other readings that carry a measurement (absent ones
    /// are omitted, never dashed — see `GlanceAccessory.context`). Empty means draw no second line at
    /// all, which is the honest look for a snapshot holding exactly one number.
    private var secondaryLine: String {
        if snap.isEmpty { return emptyNote }
        if accessory.isAbsent { return "Not recorded yet" }
        return GlanceAccessory.context(for: reading, snapshot: snap).joined(separator: " · ")
    }

    /// Text beside the clock. Leads with the chosen reading and appends live heart rate as context —
    /// unless heart rate IS the chosen reading, in which case repeating it would be the whole line
    /// twice.
    ///
    /// A never-published install still reads "whoopmaxx" rather than "Charge not recorded": inline has
    /// no room to distinguish "the strap hasn't reported this" from "the app has never run", and of the
    /// two the app name is the one that does not accuse the strap.
    private var inlineText: String {
        guard !snap.isEmpty else { return "whoopmaxx" }
        let a = accessory
        var parts = [a.value.map { "\(a.shortLabel) \($0)" } ?? "\(a.shortLabel) not recorded"]
        if reading != .heartRate, let bpm = snap.bpm { parts.append("\(bpm) bpm") }
        return parts.joined(separator: " · ")
    }

    /// One spoken line for the chosen reading — the full name, so "Strap battery 84%" rather than
    /// "BATT 84". Absence is spoken as absence.
    private var accessibilityLine: String {
        let a = accessory
        guard let value = a.value else { return "\(a.label) not recorded" }
        return "\(a.label) \(value)"
    }

    /// The gauge tint for the chosen reading. Domain colour for the three scores (colour = data);
    /// battery borrows the footer strip's low-level warning, which is the same status signal drawn in
    /// a different place. Heart rate never reaches here — it has no gauge — but the switch stays total
    /// so adding a scale to it later cannot leave an untinted arc behind.
    private var accessoryTint: Color {
        switch reading {
        case .charge:    return WM.Domain.charge.color
        case .effort:    return WM.Domain.effort.color
        case .rest:      return WM.Domain.rest.color
        case .heartRate: return WM.Ground.ink
        case .battery:   return batteryTint(snap.batteryPct)
        }
    }

    // MARK: - Shared pieces

    /// Overline title + a bonded dot + (when it fits) the "as of {time}" staleness stamp — absolute short
    /// time, so it reads exact and never drifts between widget refreshes. `title` is single-line so a
    /// wider word ("whoopmaxx") never wraps.
    private func headerRow(title: String, showStaleness: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WM.Space.s) {
            Text(title).wmOverline().lineLimit(1).fixedSize()
            if showStaleness { Spacer(minLength: WM.Space.s) } else { Spacer(minLength: 0) }
            Circle()
                .fill(snap.bonded ? WM.Semantic.good : WM.Ground.inkTertiary)
                .frame(width: 6, height: 6)
            if showStaleness {
                Text("as of \(snap.updated.formatted(date: .omitted, time: .shortened))")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Live/last HR + strap battery, quiet caption weight. `compact` (small widget) drops the "bpm" word
    /// so the two stats never truncate in the narrow square.
    private func footerStrip(compact: Bool) -> some View {
        HStack(spacing: WM.Space.m) {
            Label(snap.bpm.map { compact ? "\($0)" : "\($0) bpm" } ?? "—", systemImage: "waveform.path.ecg")
                .lineLimit(1)
            Spacer(minLength: 0)
            Label(snap.batteryPct.map { "\($0)%" } ?? "—",
                  systemImage: GlanceAccessory.batterySymbol(snap.batteryPct))
                .foregroundStyle(batteryTint(snap.batteryPct))
                .lineLimit(1)
        }
        .font(WMType.caption)
        .foregroundStyle(WM.Ground.inkSecondary)
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Formatting helpers

    private func numeral(_ v: Int?) -> String { v.map(String.init) ?? "—" }
    private func dbl(_ v: Int?) -> Double? { v.map(Double.init) }
    private func baselineCaption(_ baseline: Int?) -> String { baseline.map { "typ \($0)" } ?? "" }

    // The level→glyph mapping (and the "unknown is NOT half" rule it enforces) moved to
    // `GlanceAccessory.batterySymbol` when battery became a choosable accessory reading: the footer
    // strip and the configured accessory have to draw the same glyph for the same percentage, and a
    // second copy here is a second copy that can drift back to a half-full unknown.

    /// Honest one-liner for a snapshot that carries no measurement, so a never-published widget reads as
    /// "not set up" rather than as a broken extension showing em-dashes under a fresh timestamp.
    private var emptyNote: String { "Open whoopmaxx to set up" }

    /// Battery tint only warns when low (design: color = data / status, never decoration).
    private func batteryTint(_ pct: Int?) -> Color {
        switch pct ?? 100 {
        case ..<15: return WM.Semantic.bad
        case ..<35: return WM.Semantic.warn
        default:    return WM.Ground.inkSecondary
        }
    }
}

/// The Live Activity's Lock-Screen banner, factored out so the extension's `ActivityConfiguration` AND
/// the in-app DEBUG gallery render the same layout (the Dynamic Island can only be built by the system,
/// so it stays in the extension). The huge live bpm alongside the Charge / Effort pair.
struct WMLiveActivityBanner: View {
    let state: WMActivityAttributes.ContentState
    var title: String = "Live HR"

    var body: some View {
        HStack(spacing: WM.Space.l) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(WM.Domain.effort.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).wmOverline()
                HStack(alignment: .firstTextBaseline, spacing: WM.Space.xs) {
                    Text(state.bpm.map(String.init) ?? "—")
                        .font(WMType.display(30))
                        .foregroundStyle(WM.Ground.ink)
                    Text("bpm").font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            Spacer()
            HStack(spacing: WM.Space.l) {
                if let c = state.charge { bannerStat("Charge", "\(c)", .charge) }
                if let e = state.effort { bannerStat("Effort", "\(e)", .effort) }
            }
        }
        .padding(WM.Space.l)
    }

    private func bannerStat(_ label: String, _ value: String, _ domain: WM.Domain) -> some View {
        VStack(alignment: .center, spacing: 2) {
            Text(label).wmOverline()
            Text(value).font(WMType.numeral(20)).foregroundStyle(domain.color)
        }
        .fixedSize()
    }
}
#endif
