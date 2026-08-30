import SwiftUI
import StrapStore
import StrapAnalytics

/// Health Monitor detail (007 F2; 037), pushed from the Today heads-up row and from Data ›
/// Labs: the persisted composite as the hero (score + level word), one paragraph on what the level
/// means (naming the journal tags that dampened the read, when any did), the four overnight vitals
/// (RHR / HRV / Resp / Skin temp) as rows whose line shows the night against the vital's usual range,
/// and the standing not-a-diagnosis footer.
///
/// The composite score + level come from the PERSISTED `strain_score` / `strain_level` series and
/// the per-vital flags from the PERSISTED `strain_fired` bitmask (ScoreEngine is the single writer of
/// all three — the hero and the row flags can never disagree with the Today row). Only the
/// descriptive band captions and each vital's position against its range are re-derived here from the
/// published day rows.
struct HealthMonitorScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var journal: JournalStore
    /// The day key the pushing surface was showing (Today's displayed day, or Data's latest).
    let day: String
    /// The back link's label — the screen it returns to ("Today", "Data").
    let backLabel: String

    /// Metric/Imperial pref → the Skin row's °C/°F conversion, live like TodayContent's cell.
    @AppStorage(TempUnit.systemKey) private var unitSystem = "metric"

    /// The assembled model, derived in the `.task(id:)` below and never on a body pass. nil until the
    /// first derivation lands.
    @State private var model: HealthMonitorModel.Model?

    init(day: String, backLabel: String = "Today") {
        self.day = day
        self.backLabel = backLabel
    }

    /// Everything `compute` reads besides the arrays: the repository's change stamp (`days` and the
    /// three persisted strain series publish with it), the night's context tags, and the unit.
    private struct ModelKey: Equatable {
        let day: String
        let refreshSeq: Int
        let tags: Set<String>
        let imperial: Bool
    }

    var body: some View {
        // The night's CONTEXT tags — behaviors from D-1, `sick` from either day — the SAME convention
        // ScoreEngine's confounder pass applies (see `nightContextTags`), so the suppression explanation
        // names the tags that actually dampened the persisted read. Two lookups, so cheap per pass.
        let key = ModelKey(day: day, refreshSeq: repo.refreshSeq,
                           tags: ScoreEngine.nightContextTags(day: day, tagsByDay: journal.tagsByDay),
                           imperial: unitSystem == "imperial")
        // The stored model while it is this day's (a changed input keeps it on screen until the new one
        // lands); before the first derivation, resolved once inline so the push never slides in empty.
        HealthMonitorContent(model: model.flatMap { $0.day == day ? $0 : nil } ?? compute(key),
                             backLabel: backLabel)
            .toolbar(.hidden, for: .navigationBar)
            // `compute` folds each vital's calendar-padded history (twice: the verdict and the line), and
            // this screen re-renders on every Repository publish — the raw-HR watermark included — and
            // every journal edit. It runs here, once per change of what it reads.
            .task(id: key) {
                let next = compute(key)
                guard !Task.isCancelled else { return }
                model = next
            }
    }

    private func compute(_ key: ModelKey) -> HealthMonitorModel.Model {
        HealthMonitorModel.compute(day: key.day, days: repo.days,
                                   score: repo.strainScore[key.day],
                                   level: repo.strainLevel[key.day] ?? .quiet,
                                   firedMask: repo.strainFired[key.day],
                                   journalTags: key.tags,
                                   imperial: key.imperial)
    }
}

// MARK: - Model (pure)

/// Pure assembly + shared copy behind the Health Monitor surfaces (the Today heads-up row's headline
/// and this detail screen). Value-in / value-out so previews and tests drive it without a store.
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
        /// Where the night's value sits on the row's line, as a fraction of a window that is the
        /// vital's usual range padded by one range-width each side — so `usualBand` (the middle third)
        /// IS the usual range, and the dot inside it ⇔ the caption's "in range". nil for no reading;
        /// values past the window are left unclamped (the line pins them to its end).
        var position: Double? = nil
        var id: String { key }
    }

    /// The usual range's place on every vital's line: the middle third of the window `position`
    /// is measured across.
    static let usualBand: ClosedRange<Double> = (1.0 / 3)...(2.0 / 3)

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

    /// Short headline per level — the Today heads-up row and the first line of the detail's paragraph.
    static func headline(for level: StrainLevel) -> String {
        switch level {
        case .quiet:         return "Your signals look like your normal range"
        case .mild:          return "A few signals are mildly up"
        case .raised:        return "Heads-up - your body looks strained"
        case .suppressed:    return "Signals are up - likely what you logged"
        case .alreadyUnwell: return "Rest up - you logged feeling unwell"
        }
    }

    /// Level word — the detail hero's title.
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
    /// per-vital flags decode it (the SAME derivation as the persisted score, so the
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
        // `position` is measured in the stored units. The Skin row's °F conversion is a pure ×9/5
        // (a deviation has no +32), which leaves every fraction of the window unchanged.
        let vitals: [Vital] = [
            vital(key: "restingHR", label: "Resting HR", value: rhr,
                  text: rhr.map { String(format: "%.0f", $0) }, unit: "bpm", history: rhrHist,
                  populationRange: rhrPopulationRange, cfg: Baselines.restingHRCfg,
                  mask: firedMask, bit: StrainFiredMask.restingHR),
            // HRV fires on a DROP — the z is negated into illness-ward orientation.
            vital(key: "hrv", label: "HRV", value: hrv,
                  text: hrv.map { String(format: "%.0f", $0) }, unit: "ms", history: hrvHist,
                  populationRange: hrvPopulationRange, cfg: Baselines.hrvCfg,
                  mask: firedMask, bit: StrainFiredMask.hrv, negate: true),
            vital(key: "respiration", label: "Resp rate", value: resp,
                  text: resp.map { String(format: "%.1f", $0) }, unit: "rpm", history: respHist,
                  populationRange: respPopulationRange, cfg: Baselines.respCfg,
                  mask: firedMask, bit: StrainFiredMask.respiration),
            vital(key: "skinTemp", label: "Skin temp", value: skin,
                  text: skinDisp.map { String(format: "%+.1f", $0) },
                  unit: TempUnit.label(imperial: imperial), history: skinHist,
                  populationRange: skinPopulationRange, cfg: VitalBands.skinTempDeviationCfg,
                  mask: firedMask, bit: StrainFiredMask.skinTemp),
        ]

        // Only name confounders when the persisted level says they actually dampened the read.
        let suppressedBy = level == .suppressed ? confounders(in: journalTags) : []
        return Model(day: day, score: score, level: level, vitals: vitals,
                     suppressedBy: suppressedBy)
    }

    /// One vital row. The history is folded ONCE here and that state serves both the row's line and
    /// the legacy flag fallback. `VitalBands.band` folds the same history again for the verdict: the
    /// package takes a history, not a state, and restating its verdict here would be a second copy of
    /// the rule to drift. No reading ⇒ no fold at all (nothing on the line, nothing to flag).
    private static func vital(key: String, label: String, value: Double?, text: String?, unit: String,
                              history: [Double?], populationRange: ClosedRange<Double>,
                              cfg: Baselines.MetricCfg, mask: Int?, bit: Int,
                              negate: Bool = false) -> Vital {
        let state: Baselines.BaselineState? = value == nil
            ? nil : Baselines.foldHistory(history, cfg: cfg)
        return Vital(key: key, label: label, value: text, unit: unit,
                     bandText: bandText(VitalBands.band(value: value, history: history,
                                                        populationRange: populationRange, cfg: cfg)),
                     fired: fired(mask: mask, bit: bit, value: value, state: state, cfg: cfg,
                                  negate: negate),
                     position: position(value: value, state: state,
                                        populationRange: populationRange, cfg: cfg))
    }

    /// Whether a vital fired for the persisted level: decode the banked `strain_fired` bitmask
    /// when present (the engine's own derivation — the Today row and these rows share one source
    /// of truth); fall back to the local re-derivation only for days written before the mask existed.
    static func fired(mask: Int?, bit: Int, value: Double?, state: Baselines.BaselineState?,
                      cfg: Baselines.MetricCfg, negate: Bool = false) -> Bool {
        if let mask { return mask & bit != 0 }
        return fired(value: value, state: state, cfg: cfg, negate: negate)
    }

    /// LEGACY fallback (pre-`strain_fired` rows only): whether a vital moved past the engine's
    /// illness-ward firing bar (z ≥ `signalZThreshold`) against a TRUSTED personal baseline — `state`,
    /// the `Baselines.foldHistory` of the prior nights — mirroring the wiring in
    /// `ScoreEngine.healthMonitorResult` (per-signal trusted gate, HRV negated). Values outside the
    /// config's physiological bounds never fire (implausible reading, not a signal). Note this fold is
    /// over the published day rows, a DIFFERENT population than the engine's — which is exactly why the
    /// persisted mask above supersedes it.
    static func fired(value: Double?, state: Baselines.BaselineState?, cfg: Baselines.MetricCfg,
                      negate: Bool = false) -> Bool {
        guard let value, let state, cfg.minVal <= value, value <= cfg.maxVal else { return false }
        guard state.trusted else { return false }
        let z = Baselines.deviation(value, state: state).z
        return (negate ? -z : z) >= IllnessSignalEngine.signalZThreshold
    }

    /// The vital's usual range in its stored units — the range `VitalBands.band` judges "in range"
    /// against, so the row's line and its caption can never disagree:
    ///
    /// - a TRUSTED personal baseline → baseline ± `VitalBands.sigmaK` σ, with σ = `sigmaPerMAD` ×
    ///   spread exactly as `Baselines.deviation` scales z (in range ⇔ |z| ≤ sigmaK), clipped to the
    ///   config's physiological bounds (the band's outer guard);
    /// - otherwise → the population range, as the population verdict uses.
    ///
    /// `state` is the same `Baselines.foldHistory` over the same calendar-padded history the verdict
    /// folds, taken once per vital by `vital(...)`.
    static func usualRange(state: Baselines.BaselineState, populationRange: ClosedRange<Double>,
                           cfg: Baselines.MetricCfg) -> ClosedRange<Double> {
        guard state.trusted else { return populationRange }
        let reach = VitalBands.sigmaK * max(Baselines.sigmaPerMAD * state.spread, 1e-9)
        let lo = max(cfg.minVal, state.baseline - reach)
        let hi = min(cfg.maxVal, state.baseline + reach)
        return lo < hi ? lo...hi : populationRange
    }

    /// `Vital.position`: the value across a window of the usual range padded by one range-width on
    /// each side (the range is its middle third, `usualBand`). nil for no reading.
    static func position(value: Double?, state: Baselines.BaselineState?,
                         populationRange: ClosedRange<Double>, cfg: Baselines.MetricCfg) -> Double? {
        guard let value, let state else { return nil }
        let range = usualRange(state: state, populationRange: populationRange, cfg: cfg)
        let width = range.upperBound - range.lowerBound
        guard width > 0 else { return nil }
        return (value - (range.lowerBound - width)) / (3 * width)
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
///
/// Layout (037): back link → "Health monitor" over the night's date → the composite as a
/// `HeroReadout` (score, level word, how many vitals were flagged) → one paragraph (the level's
/// headline and its plain-voice explanation) → "Vitals": one row per vital, its value trailing and
/// its line beneath — a neutral band for the usual range and a dot for the night, in the bad color
/// when the engine flagged it — → the disclaimer.
struct HealthMonitorContent: View {
    let model: HealthMonitorModel.Model
    /// The back link's label — the screen it returns to.
    let backLabel: String

    @Environment(\.dismiss) private var dismiss

    init(model: HealthMonitorModel.Model, backLabel: String = "Today") {
        self.model = model
        self.backLabel = backLabel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WMBackLink(title: backLabel) { dismiss() }
                    .padding(.top, WM.Space.s)

                TabHeader("Health monitor",
                          subtitle: TodayModel.headerTitle(key: model.day, isToday: false))

                hero
                    .padding(.top, WM.Space.l + WM.Space.s)

                RuleSection("Vitals · band = usual range", topGap: WM.Space.sectionTight + WM.Space.s) {
                    vitalsList
                }

                footer
                    .padding(.top, WM.Space.sectionTight)
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }

    // MARK: Hero

    /// The composite score + level word, then the level's headline and plain-voice explanation
    /// (which, in the suppressed state, names the journal tags that dampened the read).
    private var hero: some View {
        VStack(alignment: .leading, spacing: WM.Space.l) {
            HeroReadout(value: model.score.map { String(format: "%.0f", $0) } ?? "—",
                        title: HealthMonitorModel.levelLabel(model.level),
                        subtitle: heroSubtitle,
                        color: model.score == nil ? WM.Ground.inkTertiary : WM.Ground.ink,
                        size: 96)
            VStack(alignment: .leading, spacing: WM.Space.xs) {
                Text(HealthMonitorModel.headline(for: model.level))
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(HealthMonitorModel.detail(for: model.level, suppressedBy: model.suppressedBy))
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "of 100 · 2 vitals flagged" — the scale, and how many rows below carry the engine's flag (the
    /// persisted `strain_fired` bits, the same ones that color those rows).
    private var heroSubtitle: String? {
        let flagged = model.vitals.filter(\.fired).count
        let flags: String? = flagged == 0 ? nil
            : flagged == 1 ? "1 vital flagged" : "\(flagged) vitals flagged"
        guard model.score != nil else { return flags }
        return flags.map { "of 100 · \($0)" } ?? "of 100"
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

    /// One vital: name over its band caption, the night's value trailing, and the range line.
    ///
    /// The line is two `LineScale`s on one track: a neutral band for the usual range (inkSecondary's
    /// 18% wash, never a domain or verdict color — the range is not a judgment), and the dot alone
    /// (`showsFill: false`: a bar grown from zero means nothing for a range) in the bad color when the
    /// engine flagged the vital, else secondary ink. A flagged row's caption turns bad too and says
    /// "flagged" in words, so the flag never rests on color alone.
    private func vitalRow(_ v: HealthMonitorModel.Vital) -> some View {
        let caption = v.value == nil ? "No reading this night"
            : v.fired ? "\(v.bandText) · flagged" : v.bandText
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.label)
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    Text(caption)
                        .font(WMType.caption)
                        .foregroundStyle(v.fired ? WM.Semantic.bad : WM.Ground.inkTertiary)
                }
                Spacer(minLength: WM.Space.s)
                HStack(alignment: .firstTextBaseline, spacing: WM.Space.xs) {
                    Text(v.value ?? "—")
                        .font(WMType.numeral(26))
                        .foregroundStyle(v.value == nil ? WM.Ground.inkTertiary : WM.Ground.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(v.unit)
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            ZStack {
                LineScale(value: nil, band: HealthMonitorModel.usualBand,
                          color: WM.Ground.inkSecondary, style: .row)
                LineScale(value: v.position, color: v.fired ? WM.Semantic.bad : WM.Ground.inkSecondary,
                          style: .row, showsFill: false)
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .ignore)
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
    HealthMonitorContent(model: HealthMonitorSpecimen.suppressed, backLabel: "Data")
        .preferredColorScheme(.dark)
}

#Preview("Health monitor — quiet") {
    HealthMonitorContent(model: HealthMonitorSpecimen.quiet)
        .preferredColorScheme(.light)
}

/// Deterministic preview models (no store / repo needed). Positions put the flagged vitals past
/// their range and the others inside it (the middle third).
private enum HealthMonitorSpecimen {
    static let vitals: [HealthMonitorModel.Vital] = [
        .init(key: "restingHR", label: "Resting HR", value: "58", unit: "bpm",
              bandText: "Outside your range", fired: true, position: 0.86),
        .init(key: "hrv", label: "HRV", value: "41", unit: "ms",
              bandText: "Outside your range", fired: true, position: 0.12),
        .init(key: "respiration", label: "Resp rate", value: "15.8", unit: "rpm",
              bandText: "In your range", fired: false, position: 0.58),
        .init(key: "skinTemp", label: "Skin temp", value: "+0.4", unit: "°C",
              bandText: "In your range", fired: false, position: 0.64),
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
                  bandText: "In your range", fired: false, position: 0.5)
        },
        suppressedBy: [])
}
