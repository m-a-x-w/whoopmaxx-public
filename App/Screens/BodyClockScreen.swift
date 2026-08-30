import SwiftUI
import StrapAnalytics

/// body clock — the immersive readout launched from More → Body Clock (a full-screen cover, mirroring
/// Breathe). Two sections on the open-editorial ground:
///   • Body-clock readout: thermal midnight (the body-clock temperature minimum), the owl/lark lean vs the
///     user's own schedule, plus confidence + an honest "hard to read right now" cold-start.
///   • Jet-lag planner: a destination time-zone picker → a signed circadian shift → the CircadianEngine's
///     day-by-day light + sleep-timing plan.
///
/// Circadian phase / jet-lag are NOT one of the three score domains, so everything renders in NEUTRAL INK
/// (no fabricated domain color). Both themes first-class. The `BodyClockEngine` compute is cached + shared
/// with the Rest "Tonight's bedtime" section, so opening this screen costs no extra work when it's warm.
struct BodyClockScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var alarmSettings: SmartAlarmSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = BodyClockEngine()

    /// The chosen destination time-zone identifier; nil = no trip picked yet.
    @State private var destinationTZ: String? = nil

    var body: some View {
        ZStack {
            WM.Ground.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    BodyClockReadoutSection(phase: engine.readout?.phase,
                                            heatDump: engine.readout?.heatDump,
                                            loaded: engine.readout != nil)
                    // Only plan against a LEARNED schedule. The `?? 23.0 / ?? 7.0` fallback presented a
                    // population default as "your habitual schedule" and built a personalised day-by-day
                    // shift plan on top of it — a fabrication for anyone who had not yet banked enough
                    // nights for the engine to learn one.
                    JetLagPlannerSection(destinationTZ: $destinationTZ,
                                         sleepHour: engine.readout?.habitualSleepHour,
                                         wakeHour: engine.readout?.habitualWakeHour)
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
            }
        }
        .task(id: taskKey) {
            await engine.refresh(repo: repo, wakeTargetHour: wakeTargetHour)
        }
    }

    private var wakeTargetHour: Double? {
        alarmSettings.enabled ? Double(alarmSettings.latestMin) / 60.0 : nil
    }
    private var taskKey: String {
        "\(repo.refreshSeq)|\(alarmSettings.enabled ? alarmSettings.latestMin : -1)"
    }

    // MARK: - Header (title + ink close)

    private var header: some View {
        WMCoverHeader(title: "Body Clock", closeLabel: "Close body clock") { dismiss() }
    }
}

// MARK: - Body-clock readout (pure)

/// The thermal-midnight + owl/lark readout. Pure over the phase estimate so it previews without an engine.
/// Neutral ink throughout — circadian phase is not a score domain.
struct BodyClockReadoutSection: View {
    let phase: CircadianEngine.PhaseEstimate?
    /// Last night's onset heat dump (011 W2.2). nil = the engine hasn't reported yet; the reading's own
    /// refusals live inside the value, not in this optional.
    var heatDump: ThermalSleepSignature.HeatDump? = nil
    var loaded: Bool = true

    var body: some View {
        RuleSection("Body clock", topGap: WM.Space.section) {
            if let phase, phase.confidence != .unreadable {
                populated(phase)
            } else {
                unreadable(phase)
            }
        }
    }

    private func populated(_ p: CircadianEngine.PhaseEstimate) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            // Three cells now, so the gap steps down from `sectionLoose` — the row still has to fit an
            // iPhone gutter-to-gutter at the default type size.
            HStack(alignment: .top, spacing: WM.Space.sectionTight) {
                VStack(alignment: .leading, spacing: WM.Space.xs) {
                    Text("Thermal midnight").wmOverline()
                    Text(BodyClockFormat.clockLabel(p.tempMinHour))
                        .font(WMType.numeral(40))
                        .foregroundStyle(WM.Ground.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                leanCell(p)
                if let heatDump { heatDumpCell(heatDump) }
                Spacer(minLength: 0)
            }
            Text(p.note)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your body-clock low point — roughly the middle of your biological night, when core temperature bottoms out. \(confidenceTail(p.confidence))")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let heatDump { heatDumpProse(heatDump) }
        }
    }

    private func leanCell(_ p: CircadianEngine.PhaseEstimate) -> some View {
        let mins = Int(p.offsetVsScheduleMinutes.rounded())
        let magnitude = abs(mins)
        let value: String
        let unit: String?
        if magnitude <= 20 { value = "Aligned"; unit = nil }
        else { value = "\(mins > 0 ? "+" : "−")\(magnitude)"; unit = "min" }
        return VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text("Lean").wmOverline()
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.xs) {
                Text(value)
                    .font(WMType.numeral(magnitude <= 20 ? 22 : 28))
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let unit {
                    Text(unit).font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            Text(leanWord(mins))
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
        }
        .accessibilityElement(children: .combine)
        // Fold the signed magnitude into the label (spelled out — U+2212 isn't spoken and "min" reads as an
        // abbreviation), else VoiceOver hears only "Lean night-owl" and loses the +42 min the layout shows.
        .accessibilityLabel(magnitude <= 20
            ? "Lean, aligned, on schedule"
            : "Lean, \(mins > 0 ? "plus" : "minus") \(magnitude) minutes, \(leanWord(mins))")
    }

    private func leanWord(_ mins: Int) -> String {
        if mins > 20 { return "night-owl" }
        if mins < -20 { return "morning-lark" }
        return "on schedule"
    }

    // MARK: - Heat dump (011 W2.2)

    /// The third readout cell. It leads with the SETTLE DURATION and never prints a temperature: the
    /// WHOOP 4.0 raw→°C slope is provisional (`Streams.swift:82-85`), so the amplitude only ever leaves
    /// the engine as a within-user ranking. Neutral ink like its two siblings.
    private func heatDumpCell(_ d: ThermalSleepSignature.HeatDump) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text("Heat dump").wmOverline()
            Text(d.settleMinutes.map { WMFormat.duration(seconds: $0 * 60, style: .compact) } ?? "—")
                .font(WMType.numeral(22))
                .foregroundStyle(WM.Ground.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(Self.heatDumpWord(d))
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
        }
        .accessibilityElement(children: .combine)
        // The compact "1h 40m" isn't spoken as a duration, so VoiceOver gets the spelled form plus the
        // full comparison clause — the same information the cell + prose carry between them.
        .accessibilityLabel("Heat dump. " + Self.heatDumpSentence(d))
    }

    /// The sentence + the framing line under the readout. The framing line is fixed copy: it says what
    /// the reading is, and what it is not.
    private func heatDumpProse(_ d: ThermalSleepSignature.HeatDump) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            WMRule()
            Text(Self.heatDumpSentence(d))
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.heatDumpFraming)
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, WM.Space.xs)
    }

    /// The one-or-two-word caption under the numeral — the Lean cell's "night-owl" slot. Static and
    /// internal so `ThermalSleepSignatureTests` can pin the framing register on the strings themselves.
    static func heatDumpWord(_ d: ThermalSleepSignature.HeatDump) -> String {
        guard let steepness = d.steepness else { return "not yet ranked" }
        switch steepness {
        case .steeper: return "steeper"
        case .typical: return "typical"
        case .shallower: return "shallower"
        case .unreadable: return "unreadable"
        }
    }

    /// The prose line. Every branch names only what was measured: a duration, or the fact that the start
    /// of the night didn't read. Static + internal for the same reason as `heatDumpWord`.
    static func heatDumpSentence(_ d: ThermalSleepSignature.HeatDump) -> String {
        guard let minutes = d.settleMinutes else {
            return "The start of last night didn't read clearly enough to measure the drop."
        }
        let span = WMFormat.duration(seconds: minutes * 60, style: .spelled)
        guard let steepness = d.steepness else {
            return "Your skin released heat over the first \(span) last night. There aren't enough "
                + "readable nights behind it yet to set that against your own."
        }
        switch steepness {
        case .steeper:
            return "Your skin released heat over the first \(span) last night — a steeper drop than your recent nights."
        case .shallower:
            return "Your skin released heat over the first \(span) last night — a shallower drop than your recent nights."
        case .typical:
            return "Your skin released heat over the first \(span) last night — in line with your recent nights."
        case .unreadable:
            return "The start of last night didn't read clearly enough to measure the drop."
        }
    }

    /// Fixed framing line (011 decision 5): descriptive, within-user, no condition name, no probability,
    /// no call-to-action.
    static let heatDumpFraming =
        "The temperature drop at the start of the night is part of how the body settles into sleep. "
        + "This is a descriptive reading of your own pattern, not a measurement of health."

    private func confidenceTail(_ c: CircadianEngine.PhaseConfidence) -> String {
        switch c {
        case .solid: return "A steady read."
        case .wide: return "Still a wide estimate — keep wearing it to sharpen it."
        case .unreadable: return ""
        }
    }

    private func unreadable(_ p: CircadianEngine.PhaseEstimate?) -> some View {
        Text(loaded
             ? (p?.note ?? "Your rhythm is hard to read right now - keep wearing it for a clearer picture.")
             : "Reading your body clock…")
            .font(WMType.body)
            .foregroundStyle(WM.Ground.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, WM.Space.xs)
            .accessibilityLabel("Body clock hard to read right now")
    }
}

// MARK: - Jet-lag planner (pure over the picked destination + schedule)

/// The destination-time-zone → shift → day-by-day light & sleep plan. Pure over the bound selection + the
/// habitual schedule; the CircadianEngine builds the plan. Neutral ink.
struct JetLagPlannerSection: View {
    @Binding var destinationTZ: String?
    /// The LEARNED habitual sleep/wake hours, or nil until the engine has enough nights to know them.
    /// Nil is not a reason to invent a schedule — see `plan`.
    let sleepHour: Double?
    let wakeHour: Double?

    var body: some View {
        RuleSection("Jet-lag plan", topGap: WM.Space.section) {
            VStack(alignment: .leading, spacing: WM.Space.m) {
                destinationRow
                if let plan = plan {
                    if plan.direction == .none {
                        Text(plan.note)
                            .font(WMType.body)
                            .foregroundStyle(WM.Ground.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        summary(plan)
                        ForEach(plan.days, id: \.dayIndex) { day in
                            WMRule()
                            dayRow(day)
                        }
                        Text(plan.note)
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, WM.Space.xs)
                    }
                } else if sleepHour == nil || wakeHour == nil {
                    Text("Your body clock isn't learned yet — wear the strap for a few nights and a "
                         + "jet-lag plan can be built from your own sleep timing.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Pick where you're heading and I'll map a light + sleep-timing plan to bring your body clock along.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Destination picker

    private var destinationRow: some View {
        HStack {
            Text("Destination")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Spacer()
            Picker("Destination", selection: pickerBinding) {
                Text("Choose…").tag("")
                ForEach(BodyClockFormat.destinations, id: \.id) { dst in
                    Text(dst.label).tag(dst.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(WM.Ground.ink)
            .accessibilityLabel("Destination time zone")
        }
    }

    private var pickerBinding: Binding<String> {
        Binding(get: { destinationTZ ?? "" },
                set: { destinationTZ = $0.isEmpty ? nil : $0 })
    }

    // MARK: Plan derivation (pure)

    private var plan: CircadianEngine.JetLagPlan? {
        // No learned schedule → no plan. The shift plan is expressed entirely in terms of the user's own
        // sleep and wake hours, so building one from a population default (23:00/07:00) produces a
        // confident, personalised-looking day-by-day schedule for a body clock nobody has measured.
        guard let sleepHour, let wakeHour else { return nil }
        guard let id = destinationTZ, let dest = TimeZone(identifier: id) else { return nil }
        let now = Date()
        let home = TimeZone.current.secondsFromGMT(for: now)
        let there = dest.secondsFromGMT(for: now)
        let shift = TimeZoneShift.shiftHours(homeOffsetSeconds: home, destOffsetSeconds: there)
        return CircadianEngine.planShift(shiftHours: shift, currentSleepHour: sleepHour,
                                         currentWakeHour: wakeHour)
    }

    private func summary(_ plan: CircadianEngine.JetLagPlan) -> some View {
        HStack(alignment: .top, spacing: WM.Space.sectionLoose) {
            SignalCell(label: "Direction",
                       value: plan.direction == .advance ? "Earlier" : "Later")
            SignalCell(label: "Shift",
                       value: String(format: "%.1f", plan.totalShiftHours), unit: "h")
            SignalCell(label: "Days", value: "\(plan.estimatedDays)")
        }
    }

    private func dayRow(_ day: CircadianEngine.DayPlan) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Day \(day.dayIndex)").wmOverline()
                Spacer()
                Text("Sleep \(BodyClockFormat.clockLabel(day.targetSleepHour)) · Wake \(BodyClockFormat.clockLabel(day.targetWakeHour))")
                    .font(WMType.label)
                    .foregroundStyle(WM.Ground.ink)
            }
            HStack(spacing: WM.Space.l) {
                labelled("Bright light",
                         "\(BodyClockFormat.clockLabel(day.brightLightStartHour))–\(BodyClockFormat.clockLabel(day.brightLightEndHour))")
                labelled("Dim from", BodyClockFormat.clockLabel(day.dimFromHour))
            }
            Text(day.guidance)
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, WM.Space.xs)
        .accessibilityElement(children: .combine)
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).wmOverline()
            Text(value).font(WMType.caption).foregroundStyle(WM.Ground.inkSecondary)
        }
    }

}

// MARK: - Formatting + destination catalogue

enum BodyClockFormat {
    /// Locale-aware HH:mm for a clock hour in [0, 24).
    static func clockLabel(_ hour: Double) -> String { WMFormat.clockLabel(hour) }

    struct Destination: Identifiable {
        let id: String        // TimeZone identifier
        let city: String
        var label: String {
            guard let tz = TimeZone(identifier: id) else { return city }
            let off = Double(tz.secondsFromGMT(for: Date())) / 3600.0
            let sign = off >= 0 ? "+" : "−"
            let mag = abs(off)
            let hh = Int(mag)
            let mm = Int((mag - Double(hh)) * 60)
            let offText = mm == 0 ? "\(sign)\(hh)" : String(format: "%@%d:%02d", sign, hh, mm)
            return "\(city) (UTC\(offText))"
        }
    }

    /// A curated spread of destinations across the globe for the planner picker.
    static let destinations: [Destination] = [
        .init(id: "Pacific/Honolulu", city: "Honolulu"),
        .init(id: "America/Los_Angeles", city: "Los Angeles"),
        .init(id: "America/Denver", city: "Denver"),
        .init(id: "America/Chicago", city: "Chicago"),
        .init(id: "America/New_York", city: "New York"),
        .init(id: "America/Sao_Paulo", city: "São Paulo"),
        .init(id: "Europe/London", city: "London"),
        .init(id: "Europe/Paris", city: "Paris"),
        .init(id: "Europe/Athens", city: "Athens"),
        .init(id: "Asia/Dubai", city: "Dubai"),
        .init(id: "Asia/Kolkata", city: "Mumbai"),
        .init(id: "Asia/Bangkok", city: "Bangkok"),
        .init(id: "Asia/Singapore", city: "Singapore"),
        .init(id: "Asia/Tokyo", city: "Tokyo"),
        .init(id: "Australia/Sydney", city: "Sydney"),
        .init(id: "Pacific/Auckland", city: "Auckland"),
    ]
}

// MARK: - Previews

#Preview("Body Clock — readout, light") {
    BodyClockSpecimen(phase: .solidSpecimen, heatDump: .steeperSpecimen,
                      destination: "Asia/Tokyo").preferredColorScheme(.light)
}

#Preview("Body Clock — readout, dark") {
    BodyClockSpecimen(phase: .solidSpecimen, heatDump: .steeperSpecimen,
                      destination: "America/Los_Angeles").preferredColorScheme(.dark)
}

#Preview("Body Clock — heat dump unreadable, light") {
    BodyClockSpecimen(phase: .solidSpecimen, heatDump: .unreadableSpecimen,
                      destination: nil).preferredColorScheme(.light)
}

#Preview("Body Clock — heat dump unreadable, dark") {
    BodyClockSpecimen(phase: .solidSpecimen, heatDump: .unreadableSpecimen,
                      destination: nil).preferredColorScheme(.dark)
}

#Preview("Body Clock — unreadable, light") {
    BodyClockSpecimen(phase: nil, heatDump: nil, destination: nil).preferredColorScheme(.light)
}

private struct BodyClockSpecimen: View {
    let phase: CircadianEngine.PhaseEstimate?
    let heatDump: ThermalSleepSignature.HeatDump?
    @State var destination: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BodyClockReadoutSection(phase: phase, heatDump: heatDump)
                JetLagPlannerSection(destinationTZ: $destination, sleepHour: 23.0, wakeHour: 7.0)
            }
            .padding(.horizontal, WM.Space.gutter)
        }
        .background(WM.Ground.ground)
    }
}

extension ThermalSleepSignature.HeatDump {
    /// A ranked night for previews / specimens (no live engine).
    static let steeperSpecimen = ThermalSleepSignature.HeatDump(
        settleMinutes: 100, steepness: .steeper, comparedNights: 6)
    /// The honest refusal: the start of the night wouldn't read, so there is no duration to print.
    static let unreadableSpecimen = ThermalSleepSignature.HeatDump(
        settleMinutes: nil, steepness: .unreadable, comparedNights: 0)
}

extension CircadianEngine.PhaseEstimate {
    /// Synthetic solid phase estimate for previews / specimens (no live engine).
    static let solidSpecimen = CircadianEngine.PhaseEstimate(
        tempMinHour: 4.5, acrophaseHours: 16.5, offsetVsScheduleMinutes: 42,
        confidence: .solid, note: "Your body clock looks later (a night-owl lean).")
}
