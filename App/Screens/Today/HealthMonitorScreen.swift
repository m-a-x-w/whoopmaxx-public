import SwiftUI
import StrapStore
import StrapAnalytics

/// Health Monitor detail (007 F2), pushed from the Today heads-up banner: the four overnight vitals
/// (RHR / HRV / Resp / Skin temp) with their personal band via `VitalBands.band`, a per-signal
/// "moved illness-ward" marker, the persisted composite hero, the suppression explanation when a
/// journal tag dampened the read, and the standing not-a-diagnosis footer.
///
/// The composite score + level come from the PERSISTED `strain_score` / `strain_level` series and
/// the per-vital "Flagged" markers from the PERSISTED `strain_fired` bitmask (ScoreEngine is the
/// single writer of all three — the hero and the row markers can never disagree with the banner).
/// Only the descriptive band CAPTIONS are re-derived here from the published day rows.
struct HealthMonitorScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var journal: JournalStore
    /// The day key the banner was showing (Today's displayed day).
    let day: String

    /// Metric/Imperial pref → the Skin row's °C/°F conversion, live like TodayContent's cell.
    @AppStorage(TempUnit.systemKey) private var unitSystem = "metric"

    var body: some View {
        HealthMonitorContent(model: HealthMonitorModel.compute(
            day: day, days: repo.days,
            score: repo.strainScore[day],
            level: repo.strainLevel[day] ?? .quiet,
            firedMask: repo.strainFired[day],
            // The night's CONTEXT tags — behaviors from D-1, `sick` from either day — the SAME
            // convention ScoreEngine's confounder pass applies (see `nightContextTags`), so the
            // suppression explanation names the tags that actually dampened the persisted read.
            journalTags: ScoreEngine.nightContextTags(day: day, tagsByDay: journal.tagsByDay),
            imperial: unitSystem == "imperial"))
            .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Model (pure)

/// Pure assembly + shared copy behind the Health Monitor surfaces (the Today banner headline and
/// this detail screen). Value-in / value-out so previews and tests drive it without a store.
enum HealthMonitorModel {

    /// One vital row of the detail screen.
    struct Vital: Identifiable, Equatable {
        /// Engine signal key ("restingHR" / "hrv" / "respiration" / "skinTemp").
        let key: String
        let label: String
        /// Rendered current-night value ("52", "+0.4"), or nil for no data (row shows "—").
        let value: String?
        let unit: String
        /// Personal/population banding caption ("In your range" / "Outside typical range" / …).
        let bandText: String
        /// True when the signal cleared the engine's illness-ward firing bar (z ≥ 2, HRV negated).
        let fired: Bool
        var id: String { key }
    }

    struct Model: Equatable {
        let day: String
        /// Persisted 0–100 composite, nil when the day was never evaluated.
        let score: Double?
        let level: StrainLevel
        let vitals: [Vital]
        /// Present-confounder phrases when a journal tag dampened the read ("alcohol", "travel").
        let suppressedBy: [String]
    }

    // MARK: Population fallback bands (cold-start / stale baseline)
    //
    // Deliberately generous typical-adult ranges — the personal ±2σ band takes over the moment the
    // baseline is trusted (`Baselines.minNightsTrust` nights), and `Baselines.MetricCfg`'s physiological
    // bounds stay the absolute outer guard inside `VitalBands.band` either way.

    static let rhrPopulationRange: ClosedRange<Double> = 40...85     // bpm
    static let hrvPopulationRange: ClosedRange<Double> = 20...120    // ms
    static let respPopulationRange: ClosedRange<Double> = 8...22     // rpm
    /// Skin temp rows carry a ±°C DEVIATION vs the personal baseline (on-device pipeline) — near
    /// zero is normal, so the population band is a deviation band too.
    static let skinPopulationRange: ClosedRange<Double> = -1.0...1.0 // ±°C

    // MARK: Copy (echoes the engine's shipped strings)

    /// Short headline per level — the Today banner line and the detail hero caption.
    static func headline(for level: StrainLevel) -> String {
        switch level {
        case .quiet:         return "Your signals look like your normal range"
        case .mild:          return "A few signals are mildly up"
        case .raised:        return "Heads-up - your body looks strained"
        case .suppressed:    return "Signals are up - likely what you logged"
        case .alreadyUnwell: return "Rest up - you logged feeling unwell"
        }
    }

    /// Level word for the hero overline.
    static func levelLabel(_ level: StrainLevel) -> String {
        switch level {
        case .quiet:         return "Quiet"
        case .mild:          return "Mild"
        case .raised:        return "Raised"
        case .suppressed:    return "Explained"
        case .alreadyUnwell: return "Rest up"
        }
    }

    /// Longer detail line per level. The suppressed state names exactly which journal tags dampened
    /// the score (the engine multiplied the composite by its `confounderDampen` and downgraded).
    static func detail(for level: StrainLevel, suppressedBy: [String]) -> String {
        switch level {
        case .quiet:
            return "Nothing notable - your overnight vitals sit inside your normal range."
        case .mild:
            return "Nothing alarming - worth a calmer day."
        case .raised:
            return "Multiple signals moved together away from your baseline overnight, with no "
                + "logged behavior to explain them. Consider taking it easy today."
        case .suppressed:
            let reason = joinReasons(suppressedBy.isEmpty ? ["a logged behavior"] : suppressedBy)
            return "Some signals are up, but you logged \(reason) - likely that, not illness. "
                + "The score is dampened accordingly."
        case .alreadyUnwell:
            return "You logged feeling sick, so this reads as a reminder to rest - never a scare."
        }
    }

    /// The journal confounders present on a day, phrased exactly as the engine's `suppressedBy`
    /// list would phrase them (order fixed to the engine's).
    ///
    /// This is a hand-maintained TWIN of `IllnessSignalEngine.evaluate`'s literal list — re-derived
    /// because `suppressedBy` is never persisted (the scoring loop banks only `strain_score` /
    /// `strain_level` / `strain_fired`). It drifts silently: a tag the engine suppresses on but this
    /// list misses renders the "a logged behavior" fallback above instead of naming it.
    /// `testConfounderListsAgreeWithEngine` runs both lists over every confounder tag and pins them.
    static func confounders(in tags: Set<String>) -> [String] {
        var out: [String] = []
        if tags.contains(JournalTag.alcohol.rawValue) { out.append("alcohol") }
        if tags.contains(JournalTag.stress.rawValue) { out.append("stress") }
        if tags.contains(JournalTag.sauna.rawValue) { out.append("sauna") }
        if tags.contains(JournalTag.weed.rawValue) { out.append("weed") }
        if tags.contains(JournalTag.travel.rawValue) { out.append("travel") }
        return out
    }

    /// Natural-language join ("alcohol", "alcohol and stress", "a, b and c") — twin of the
    /// engine's internal `joinReasons` (not public there).
    static func joinReasons(_ reasons: [String]) -> String {
        switch reasons.count {
        case 0: return "something"
        case 1: return reasons[0]
        case 2: return "\(reasons[0]) and \(reasons[1])"
        default: return reasons.dropLast().joined(separator: ", ") + " and \(reasons.last!)"
        }
    }

    // MARK: Assembly

    /// Build the full detail model for one day from the published caches. `firedMask` is the
    /// persisted `strain_fired` bitmask ScoreEngine banked next to the level — when present the
    /// per-vital "Flagged" markers decode it (the SAME derivation as the persisted score, so the
    /// hero and the rows can never disagree); when absent (a day written before the mask existed)
    /// they fall back to the local re-derivation.
    static func compute(day: String, days: [DailyMetric], score: Double?, level: StrainLevel,
                        firedMask: Int? = nil,
                        journalTags: Set<String>, imperial: Bool = false) -> Model {
        let row = days.last { $0.day == day }
        // History STRICTLY before the displayed day, calendar-padded so the baseline's staleness
        // logic sees real wear gaps (VitalBands doc) — the displayed night must not sit inside the
        // band it's judged against.
        let prior = days.filter { $0.day < day }

        let rhr = row?.restingHr.map(Double.init)
        let rhrHist = VitalBands.calendarSeries(prior.map { (day: $0.day, value: $0.restingHr.map(Double.init)) })
        let hrv = row?.avgHrv
        let hrvHist = VitalBands.calendarSeries(prior.map { (day: $0.day, value: $0.avgHrv) })
        let resp = row?.respRateBpm
        let respHist = VitalBands.calendarSeries(prior.map { (day: $0.day, value: $0.respRateBpm) })
        // Skin temp: the published rows carry the ±°C deviation (skinTempDevC), so band and fire on
        // the DEVIATION config, not the absolute-°C `skin_temp` config.
        let skin = row?.skinTempDevC
        let skinHist = VitalBands.calendarSeries(prior.map { (day: $0.day, value: $0.skinTempDevC) })

        let skinDisp = skin.map { TempUnit.delta($0, imperial: imperial) }
        let vitals: [Vital] = [
            Vital(key: "restingHR", label: "Resting HR",
                  value: rhr.map { String(format: "%.0f", $0) }, unit: "bpm",
                  bandText: bandText(VitalBands.band(value: rhr, history: rhrHist,
                                                     populationRange: rhrPopulationRange,
                                                     cfg: Baselines.restingHRCfg)),
                  fired: fired(mask: firedMask, bit: StrainFiredMask.restingHR,
                               value: rhr, history: rhrHist, cfg: Baselines.restingHRCfg)),
            Vital(key: "hrv", label: "HRV",
                  value: hrv.map { String(format: "%.0f", $0) }, unit: "ms",
                  bandText: bandText(VitalBands.band(value: hrv, history: hrvHist,
                                                     populationRange: hrvPopulationRange,
                                                     cfg: Baselines.hrvCfg)),
                  // HRV fires on a DROP — the z is negated into illness-ward orientation.
                  fired: fired(mask: firedMask, bit: StrainFiredMask.hrv,
                               value: hrv, history: hrvHist, cfg: Baselines.hrvCfg, negate: true)),
            Vital(key: "respiration", label: "Resp rate",
                  value: resp.map { String(format: "%.1f", $0) }, unit: "rpm",
                  bandText: bandText(VitalBands.band(value: resp, history: respHist,
                                                     populationRange: respPopulationRange,
                                                     cfg: Baselines.respCfg)),
                  fired: fired(mask: firedMask, bit: StrainFiredMask.respiration,
                               value: resp, history: respHist, cfg: Baselines.respCfg)),
            Vital(key: "skinTemp", label: "Skin temp",
                  value: skinDisp.map { String(format: "%+.1f", $0) },
                  unit: TempUnit.label(imperial: imperial),
                  bandText: bandText(VitalBands.band(value: skin, history: skinHist,
                                                     populationRange: skinPopulationRange,
                                                     cfg: VitalBands.skinTempDeviationCfg)),
                  fired: fired(mask: firedMask, bit: StrainFiredMask.skinTemp,
                               value: skin, history: skinHist,
                               cfg: VitalBands.skinTempDeviationCfg)),
        ]

        // Only name confounders when the persisted level says they actually dampened the read.
        let suppressedBy = level == .suppressed ? confounders(in: journalTags) : []
        return Model(day: day, score: score, level: level, vitals: vitals,
                     suppressedBy: suppressedBy)
    }

    /// Whether a vital fired for the persisted level: decode the banked `strain_fired` bitmask
    /// when present (the engine's own derivation — banner and rows share one source of truth);
    /// fall back to the local re-derivation only for days written before the mask existed.
    static func fired(mask: Int?, bit: Int, value: Double?, history: [Double?], cfg: Baselines.MetricCfg,
                      negate: Bool = false) -> Bool {
        if let mask { return mask & bit != 0 }
        return fired(value: value, history: history, cfg: cfg, negate: negate)
    }

    /// LEGACY fallback (pre-`strain_fired` rows only): whether a vital moved past the engine's
    /// illness-ward firing bar (z ≥ `signalZThreshold`) against a TRUSTED personal baseline folded
    /// from the prior nights — mirroring the wiring in `ScoreEngine.healthMonitorResult`
    /// (per-signal trusted gate, HRV negated). Values outside the config's physiological bounds
    /// never fire (implausible reading, not a signal). Note this fold is over the published day
    /// rows, a DIFFERENT population than the engine's — which is exactly why the persisted mask
    /// above supersedes it.
    static func fired(value: Double?, history: [Double?], cfg: Baselines.MetricCfg,
                      negate: Bool = false) -> Bool {
        guard let value, cfg.minVal <= value, value <= cfg.maxVal else { return false }
        let state = Baselines.foldHistory(history, cfg: cfg)
        guard state.trusted else { return false }
        let z = Baselines.deviation(value, state: state).z
        return (negate ? -z : z) >= IllnessSignalEngine.signalZThreshold
    }

    /// Band → row caption. The basis distinction keeps the copy honest: "your range" only once the
    /// personal baseline is trusted; the population fallback says "typical" instead.
    static func bandText(_ r: VitalBands.Result) -> String {
        switch r.band {
        case .noData:
            return "No reading this night"
        case .inRange:
            return r.basis == .personal ? "In your range" : "In typical range"
        case .outOfRange:
            return r.basis == .personal ? "Outside your range" : "Outside typical range"
        }
    }
}

// MARK: - View (pure)

/// The detail body over a plain model, previewable without a store.
struct HealthMonitorContent: View {
    let model: HealthMonitorModel.Model

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backLink
                    .padding(.top, WM.Space.m)

                header
                    .padding(.top, WM.Space.sectionTight)

                hero
                    .padding(.top, WM.Space.section)

                RuleSection("Vitals") {
                    vitalsList
                }

                footer
                    .padding(.top, WM.Space.section)
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }

    // MARK: Header

    /// Ink back affordance (chrome stays neutral — no tint). Pushed from Today.
    private var backLink: some View {
        WMBackLink(title: "Today") { dismiss() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("Health monitor")
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
            Text(TodayModel.headerTitle(key: model.day, isToday: false))
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
        }
    }

    // MARK: Hero

    /// Composite score + level word, then the level's plain-voice explanation (which, in the
    /// suppressed state, names the journal tags that dampened the read).
    private var hero: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.s) {
                Text(model.score.map { String(format: "%.0f", $0) } ?? "—")
                    .font(WMType.display(64))
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("/ 100")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                Spacer(minLength: WM.Space.s)
                VStack(alignment: .trailing, spacing: WM.Space.xs) {
                    if model.level >= .mild {
                        // Semantic warn dot — a status, never an accent (color = data only).
                        Circle()
                            .fill(WM.Semantic.warn)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(HealthMonitorModel.levelLabel(model.level)).wmOverline()
                }
            }
            Text(HealthMonitorModel.headline(for: model.level))
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Text(HealthMonitorModel.detail(for: model.level, suppressedBy: model.suppressedBy))
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Vitals

    private var vitalsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.vitals) { v in
                vitalRow(v)
                if v.id != model.vitals.last?.id {
                    WMRule()
                }
            }
        }
    }

    /// One vital: label, the night's value, its personal/population band caption, and — when the
    /// signal cleared the engine's illness-ward bar — a warn-dot "Flagged" marker.
    private func vitalRow(_ v: HealthMonitorModel.Vital) -> some View {
        HStack(alignment: .center, spacing: WM.Space.m) {
            VStack(alignment: .leading, spacing: WM.Space.xs) {
                Text(v.label).wmOverline()
                HStack(alignment: .firstTextBaseline, spacing: WM.Space.xs) {
                    Text(v.value ?? "—")
                        .font(WMType.numeral(28))
                        .foregroundStyle(WM.Ground.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(v.unit)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
                Text(v.value == nil ? "No reading this night" : v.bandText)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            Spacer(minLength: WM.Space.s)
            if v.fired {
                HStack(spacing: WM.Space.xs) {
                    Circle()
                        .fill(WM.Semantic.warn)
                        .frame(width: 6, height: 6)
                    Text("Flagged")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkSecondary)
                }
            }
        }
        .padding(.vertical, WM.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(v.label): \(v.value ?? "no reading") \(v.unit), \(v.bandText)"
            + (v.fired ? ", flagged" : ""))
    }

    // MARK: Footer

    private var footer: some View {
        Text("Wellness information only. \(IllnessSignalEngine.disclaimerTail) whoopmaxx is not a "
            + "medical device and never names a condition.")
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Previews

#Preview("Health monitor — raised") {
    HealthMonitorContent(model: HealthMonitorSpecimen.raised)
        .preferredColorScheme(.light)
}

#Preview("Health monitor — suppressed, dark") {
    HealthMonitorContent(model: HealthMonitorSpecimen.suppressed)
        .preferredColorScheme(.dark)
}

#Preview("Health monitor — quiet") {
    HealthMonitorContent(model: HealthMonitorSpecimen.quiet)
        .preferredColorScheme(.light)
}

/// Deterministic preview models (no store / repo needed).
private enum HealthMonitorSpecimen {
    static let vitals: [HealthMonitorModel.Vital] = [
        .init(key: "restingHR", label: "Resting HR", value: "58", unit: "bpm",
              bandText: "Outside your range", fired: true),
        .init(key: "hrv", label: "HRV", value: "41", unit: "ms",
              bandText: "Outside your range", fired: true),
        .init(key: "respiration", label: "Resp rate", value: "15.8", unit: "rpm",
              bandText: "In your range", fired: false),
        .init(key: "skinTemp", label: "Skin temp", value: "+0.4", unit: "°C",
              bandText: "In your range", fired: false),
    ]
    static let raised = HealthMonitorModel.Model(
        day: "2026-07-15", score: 62, level: .raised, vitals: vitals, suppressedBy: [])
    static let suppressed = HealthMonitorModel.Model(
        day: "2026-07-15", score: 28, level: .suppressed, vitals: vitals,
        suppressedBy: ["alcohol"])
    static let quiet = HealthMonitorModel.Model(
        day: "2026-07-15", score: 4, level: .quiet,
        vitals: vitals.map {
            .init(key: $0.key, label: $0.label, value: $0.value, unit: $0.unit,
                  bandText: "In your range", fired: false)
        },
        suppressedBy: [])
}
