import SwiftUI
import StrapStore
import StrapAnalytics

/// The Today tab (037, "Line"): the header (weekday over the date and its day stepper; the strap
/// chip and the Settings control trailing) → the pipeline caption (problems only) → the Charge hero on
/// its line → Effort and Rest as score lines → the health-monitor row (when the engine flagged the day)
/// → "Signals" (HRV / RHR / Resp / Skin temp with semantic deltas) → "Your day" (the day strip: the
/// night's sleep, the day's workouts, HR intensity as neutral shading, logged intake as dots, and
/// "now" — each drawn only where the day actually holds one) → the detected-workout suggestion →
/// "Last workout". The Charge hero pushes the Charge detail.
///
/// Habits and Intake are not here: they are the Log tab's (037).
struct TodayScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var workoutRepo: WorkoutRepository
    /// Read for ONE number: the HRmax the timeline's HR-intensity scale is anchored at
    /// (`hrIntensitySource`). `ProfileStore` publishes only when the user edits their profile, so
    /// observing it here costs the body nothing at runtime.
    ///
    /// That sentence is the BAR every `@EnvironmentObject` on this screen has to clear. `ScoreEngine`
    /// once sat here for a single lookup that only the pushed Charge detail consumed, while publishing
    /// twice per scoring pass, and each publish invalidated the app's largest view tree; that lookup
    /// lives in `ChargeDetailHost` below. The same rule is why `LiveState` (the strap chip, the sync
    /// caption) and `IntakeStore` (the strip's intake dots) are observed by small child views, never
    /// here.
    @EnvironmentObject private var profile: ProfileStore
    @State private var showsChargeDetail = false
    @State private var selectedWorkout: WorkoutRef?
    @State private var monitorDay: MonitorDayRef?
    @State private var showsWorkouts = false

    var body: some View {
        // No NavigationStack here: the shell (`AppShell.stack`) already wraps every tab in one, so the
        // destinations below push onto THAT stack — matching Data/Live, which also attach their
        // `.navigationDestination` directly. A second nested stack swallowed cold-init state seeds.
        TodayContent(days: repo.days, restSeries: repo.restSeries, sleeps: repo.sleeps,
                     workouts: workoutRepo.workouts, hrIntensity: hrIntensitySource,
                     refreshSeq: repo.refreshSeq,
                     lastWorkout: workoutRepo.lastWorkout, showsAutoWorkout: true, loaded: repo.loaded,
                     showsSyncStatus: true,
                     showsStrapChip: true,
                     showsIntakeEntries: true,
                     onChargeTap: { showsChargeDetail = true },
                     onWorkoutTap: { selectedWorkout = WorkoutRef(row: $0) },
                     onAllWorkoutsTap: { showsWorkouts = true },
                     strainLevel: repo.strainLevel,
                     onStrainTap: { monitorDay = MonitorDayRef(day: $0) },
                     effortCoverage: repo.effortCoverage)
            .navigationDestination(isPresented: $showsChargeDetail) {
                ChargeDetailHost(days: repo.days)
            }
            .navigationDestination(item: $selectedWorkout) { ref in
                WorkoutDetailScreen(row: ref.row, backLabel: "Today")
            }
            .navigationDestination(item: $monitorDay) { ref in
                HealthMonitorScreen(day: ref.day)
            }
            .navigationDestination(isPresented: $showsWorkouts) {
                WorkoutsListScreen(backLabel: "Today")
            }
            .tint(WM.Ground.ink)
            #if DEBUG
            // `--charge-detail`: push the detail AFTER first render (a cold-init path seed is dropped by
            // NavigationStack) — screenshot/UI work without tapping through. `--demo-drivers` is read
            // by `ChargeDetailHost` once the push lands.
            .task {
                if DebugFlags.chargeDetail {
                    showsChargeDetail = true
                }
            }
            #endif
    }

    /// The timeline's HR-intensity layer, wired to the store (015 P1). `hrBuckets` is an EXISTING
    /// downsampled read (decision 6 — no new engine, no new read); it runs inside `TimelineLoaded`'s
    /// `.task(id:)`, once per day-view, never on a SwiftUI frame.
    ///
    /// The stamp is the raw-HR WATERMARK rather than `refreshSeq`, for the reason `AutoWorkoutRow`
    /// gives one screen over: raw HR grows without moving a score, and a score moves without raw HR
    /// growing. Only the first of those changes this layer.
    ///
    /// Both ends of the scale are resolved HERE, once, and NEITHER is read from the day being drawn —
    /// see `TodayTimeline.hrIntensity` for why that is the whole point. HRmax is the profile's
    /// (`ProfileStore.hrMax`: the user's override, else Tanaka); resting is the freshest resting HR in
    /// the record, which is the same anchor `WorkoutRepository.autoDetectCandidates` takes, falling
    /// back to the detectors' own `defaultRestingHR` so a record with no scored night still has a scale.
    private var hrIntensitySource: TodayHRIntensity {
        let watermark = repo.hrWatermark
        let restingBpm = repo.days.last(where: { $0.restingHr != nil })?.restingHr
            ?? AutoWorkoutDetector.defaultRestingHR
        let hrMaxBpm = profile.hrMax
        return TodayHRIntensity(stamp: "\(watermark.count)|\(watermark.maxTs)") { dayStart, dayEnd in
            let buckets = await repo.hrBuckets(from: Int(dayStart.timeIntervalSince1970),
                                               to: Int(dayEnd.timeIntervalSince1970),
                                               bucketSeconds: TodayTimeline.hrBucketSeconds)
            return TodayTimeline.hrIntensity(buckets, dayStart: dayStart, dayEnd: dayEnd,
                                             restingBpm: restingBpm, hrMaxBpm: hrMaxBpm)
        }
    }
}

// MARK: - Charge detail host

/// The Charge detail's ONE dependency on `ScoreEngine`, scoped to the screen that actually reads it.
///
/// It used to be an `@EnvironmentObject` on `TodayScreen` itself, standing there for a single lookup
/// (`results.first(where:)?.drivers`) that nothing but this destination consumed — Today's own score
/// lines read their scores off `Repository.days`, never off the engine. `ScoreEngine` is a plain
/// `ObservableObject` that publishes `computing = true` / `computing = false` around every pass, and
/// it does so BEFORE the #836 fingerprint gate can decide the pass had nothing to do, so a fully
/// short-circuited tick still invalidated the app's largest view tree — `TodayContent` is not
/// `Equatable` (it carries closures), so each publish re-rendered the whole Today body. Two
/// whole-body passes to answer a question nobody on Today was asking.
///
/// Same fix and the same reason as `TodaySyncCaption` further down (see its note): scope the
/// observation to the view that needs it. `navigationDestination` does not build its content until
/// the push happens, so while Today is merely on screen this observer does not exist at all — and
/// once pushed, a publish re-renders these rows rather than the tab behind them.
private struct ChargeDetailHost: View {
    /// Merged daily rows, handed down rather than re-read: `TodayScreen` already observes the
    /// repository, and the destination closure re-runs when `days` moves, so the detail stays live.
    let days: [DailyMetric]
    @EnvironmentObject private var scores: ScoreEngine

    var body: some View {
        ChargeDetailScreen(days: days, drivers: drivers)
    }

    /// The driver list for the newest scored day — matched by day key so the rows always explain
    /// the same night the detail headline shows.
    private var drivers: [ChargeDriver] {
        #if DEBUG
        if DebugFlags.demoDrivers {
            return ChargeDriverDemo.rows
        }
        #endif
        // Clamp to the resolved anchor day (#547 future-day guard): a recovery-bearing row keyed for
        // TOMORROW (tz-ahead import / clock skew, admitted by the +1-day read window) must not become the
        // "last scored" day, or the drivers would describe a future row (or fail to match → empty) instead
        // of the today hero the detail was pushed from — matching ChargeDetailScreen's clamp, which
        // resolves the same `Repository.anchorKey(days:)` over the same array.
        let anchorKey = Repository.anchorKey(days: days)
        guard let lastScored = days.last(where: { $0.recovery != nil && $0.day <= anchorKey }) else { return [] }
        return scores.results.first(where: { $0.day == lastScored.day })?.drivers ?? []
    }
}

/// The screen body over plain data, so previews (and later tests) drive it without a Repository.
/// Selected-day state lives here: `dayOffset` counts days back from the resolved "today" row and is
/// clamped to today on the forward side.
struct TodayContent: View {
    let days: [DailyMetric]
    let restSeries: [String: Double]
    let sleeps: [CachedSleepSession]
    /// Every banked workout, newest first (`WorkoutRepository.workouts`) — the timeline's workout band
    /// filters this to the day on screen and clips each session to it. REQUIRED, deliberately no
    /// default: see `hrIntensity` for why a `= []` here would be a layer nobody can see.
    let workouts: [WorkoutRow]
    /// The timeline's HR-intensity layer, injected as a SOURCE rather than a value — the read is
    /// `async` and covers the day `dayOffset` selects, which only this view knows.
    ///
    /// REQUIRED, deliberately no default. A `= .none` here is exactly the shape that ships a dead
    /// layer: the build is green, the unit tests are green, and the shading does not exist in the
    /// binary because the one production call site never passed it. That has now happened twice in
    /// this app (see `ArousalForensicsSection.dayKey`), and the compiler is the only thing that
    /// reliably catches it.
    let hrIntensity: TodayHRIntensity
    /// `Repository.refreshSeq`: bumped exactly when `days`, `restSeries`, `effortCoverage`,
    /// `strainLevel` and `loaded` republish together, so it is the cheap stamp the day derivation
    /// re-runs on (see `derived`). Previews pass a constant, since their data never changes.
    ///
    /// REQUIRED, deliberately no default, for `hrIntensity`'s reason: a caller that forgot it would
    /// freeze the scores at their first derivation, and only the compiler reliably catches that.
    let refreshSeq: Int
    /// The newest workout, threaded from `WorkoutRepository` so the last-workout row reads the shared
    /// cache (W7).
    var lastWorkout: WorkoutRow? = nil
    /// Host the opt-in `AutoWorkoutRow` (needs the live Repository + WorkoutRepository env — off in
    /// previews).
    var showsAutoWorkout: Bool = false
    /// Whether the repository has finished its first load — gates the Signals empty-state copy so a
    /// still-loading screen shows the four cells rather than flashing the "no data yet" line.
    var loaded: Bool = true
    /// Host the pipeline caption under the header (012 P2) — env-driven (`LiveState`), off in bare
    /// previews. A Bool rather than a threaded string on purpose: `LiveState` publishes at packet rate,
    /// and threading its verdict through here would re-render the WHOLE Today body on every live beat.
    /// The gate stays cheap and the observation stays inside `TodaySyncCaption`.
    var showsSyncStatus: Bool = false
    /// Host the header's strap chip — env-driven (`LiveState`), off in bare previews. A Bool for the
    /// `showsSyncStatus` reason: the battery reading is observed inside `TodayStrapChip`, never here.
    var showsStrapChip: Bool = false
    /// Draw the displayed day's logged intake as dots over the day strip — env-driven (`IntakeStore`'s
    /// in-memory event cache, observed inside `TodayIntakeTimeline`), off in bare previews.
    var showsIntakeEntries: Bool = false
    var onChargeTap: (() -> Void)? = nil
    var onWorkoutTap: ((WorkoutRow) -> Void)? = nil
    /// "All workouts" beside the Last workout label; nil hides the action.
    var onAllWorkoutsTap: (() -> Void)? = nil
    /// Health monitor (007 F2): decoded `strain_level` per day key, threaded from the repo — drives
    /// the heads-up row between the score lines and Signals (visible at `.mild` and up).
    var strainLevel: [String: StrainLevel] = [:]
    /// The heads-up row was tapped — the wrapper pushes `HealthMonitorScreen` for the day key.
    var onStrainTap: ((String) -> Void)? = nil
    /// Waking-window capture coverage per day key (`Repository.effortCoverage`). Marks an Effort score
    /// that was ACCUMULATED over materially incomplete data and keeps such days out of the Effort
    /// baseline and band. Default empty ⇒ nothing is flagged, so previews and pure callers are unchanged.
    var effortCoverage: [String: Double] = [:]

    /// Days back from the anchor day (0 = today).
    @State private var dayOffset = 0

    /// Everything the screen derives from the day arrays, recomputed only when `DerivationKey` moves
    /// (see the `.task(id:)` in `body`). nil until the first derivation lands.
    @State private var derived: Derived?

    /// The header's settings button presents the shell's sheet (inert outside a shell).
    @Environment(\.appActions) private var appActions

    /// Metric/Imperial pref → the Skin cell's °C/°F unit + deviation conversion. @AppStorage so the cell
    /// re-renders live the moment Units changes in Settings.
    @AppStorage(TempUnit.systemKey) private var unitSystem = "metric"

    var body: some View {
        let now = Date()
        let isToday = dayOffset == 0
        // The row "today" resolves to (the #304/#144 resolver), stepped back by the local offset. This
        // stays in `body`, and it is cheap (the anchor sits at the newest end of `days`): it reads the
        // CLOCK, so the 04:00 rollover can move it on a render no data change caused, and the
        // derivation's task id has to see that happen.
        let anchorKey = Repository.anchorKey(days: days, now: now)
        let selectedKey = isToday
            ? anchorKey
            : (TodayModel.shiftKey(anchorKey, by: -dayOffset) ?? anchorKey)
        let stamp = DerivationKey(refreshSeq: refreshSeq, key: selectedKey, isToday: isToday,
                                  loaded: loaded)
        // The screen renders the derived day. Only before the very first derivation has landed is it
        // resolved inline, so the tab opens on real numbers rather than an empty frame; every later pass
        // reads the stored value, and a step keeps the previous day on screen until its own lands.
        let d = derived ?? Self.derive(days: days, restSeries: restSeries,
                                       effortCoverage: effortCoverage, key: selectedKey,
                                       isToday: isToday, loaded: loaded)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(selectedKey: d.key, isToday: d.isToday, canStepBack: d.canStepBack)

                // The pipeline's ONE answer (012 P2), and only when it is worth reporting: a
                // caught-up strap says nothing, so a user whose strap is working never sees this row
                // at all. It is a CAPTION, not a banner — no icon, no color, no tap target. The
                // actionable states (Bluetooth off, a strap that needs a restart) are worded by the
                // ladder itself, and Live is where the controls for them live.
                if showsSyncStatus {
                    TodaySyncCaption()
                }

                TodayScores(charge: d.charge, effort: d.effort, rest: d.rest,
                            chargeBand: d.bands.charge, effortBand: d.bands.effort,
                            restBand: d.bands.rest,
                            chargeTappable: d.chargeTappable, onChargeTap: onChargeTap)
                    .padding(.top, WM.Space.sectionTight)

                // Health monitor heads-up (007 F2): only when the engine judged the displayed day
                // mild or louder. One row — the warn dot is the sole color (a status, never a wash
                // panel); copy echoes the engine's shipped strings. Tap pushes the detail.
                if let strain = strainLevel[d.key], strain >= .mild {
                    strainBanner(level: strain, day: d.key)
                        .padding(.top, WM.Space.sectionTight)
                }

                RuleSection("Signals") {
                    signals(d)
                }

                RuleSection("Your day") {
                    timeline(selectedKey: d.key, now: d.isToday ? now : nil)
                }

                // Opt-in "Looks like a workout?" suggestion (gated on the Settings toggle + a
                // candidate); it draws its own "Detected" section.
                if showsAutoWorkout {
                    AutoWorkoutRow()
                }

                // Last-workout row, if any — pushes the detail.
                if d.isToday, let last = lastWorkout {
                    RuleSection("Last workout",
                                action: onAllWorkoutsTap.map { (title: "All workouts", handler: $0) }) {
                        lastWorkoutRow(last)
                    }
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.top, WM.Space.s)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
        // The day's whole derivation (the carry resolver, the three typical bands, the calibrating fold,
        // the four trailing means) runs here and never in `body`. `TodayScreen` re-renders on EVERY
        // Repository publish, the raw-HR watermark included, and `refreshSeq` is the gate that moves only
        // when the arrays this reads did (the `RestScreen` idiom). The selected day joins the key, so a
        // step re-derives; the previous day stays on screen, whole, until it does.
        .task(id: stamp) {
            let next = Self.derive(days: days, restSeries: restSeries,
                                   effortCoverage: effortCoverage, key: stamp.key,
                                   isToday: stamp.isToday, loaded: stamp.loaded)
            // A superseded pass (the day stepped again before this one ran) is stale by definition.
            guard !Task.isCancelled else { return }
            derived = next
        }
    }

    // MARK: - Derivation

    /// What the day derivation depends on beyond the arrays themselves: the repository's change stamp,
    /// the day, the carry gate, and the load state the calibrating note and the Signals empty state
    /// read. Four scalars, so comparing them is the whole per-render cost of Today's numbers.
    private struct DerivationKey: Equatable {
        let refreshSeq: Int
        let key: String
        let isToday: Bool
        let loaded: Bool
    }

    /// One derivation's worth of day state, written as ONE value (`RestScreen.Derived`'s rule) so a
    /// render can never put one day's scores beside another day's bands, signals or header.
    private struct Derived {
        /// The day this describes, and whether it was the anchor day. The screen renders THESE rather
        /// than the stepper's live selection, which is what keeps a step from pairing the new day's
        /// header with the old day's numbers while its derivation is in flight.
        let key: String
        let isToday: Bool
        /// The `loaded` this was derived under, for the Signals empty state: read live, a first load
        /// would flash "appear after your first synced night" beside the empty arrays it replaced.
        let loaded: Bool
        /// The day's own row, and the vitals-fallback row (anchor day only) that fills what it lacks.
        let row: DailyMetric?
        let vitalsRow: DailyMetric?
        let charge: ScoreTrio.Entry
        let effort: ScoreTrio.Entry
        let rest: ScoreTrio.Entry
        let bands: TodayModel.ScoreBands
        let chargeTappable: Bool
        /// Each Signals cell's "vs typical" mean, in stored units (the Skin cell converts at render).
        let hrvMean: Double?
        let rhrMean: Double?
        let respMean: Double?
        let skinMean: Double?
        /// Whether any vital was ever measured — a first run, as opposed to a sync gap.
        let everMeasured: Bool
        /// Whether ANY earlier data exists to step back to (daily row or Rest score).
        let canStepBack: Bool
    }

    /// Resolve everything Today shows for `key` from the in-memory arrays. Called from the derivation
    /// task (and once inline before the first one lands), never on an ordinary body pass.
    private static func derive(days: [DailyMetric], restSeries: [String: Double],
                               effortCoverage: [String: Double], key: String, isToday: Bool,
                               loaded: Bool) -> Derived {
        let row = days.last { $0.day == key }

        // Anchor-day carry (#911 / the v8 rollover-blank fix): today's row is still forming
        // until last night syncs and scores, and an empty hero under today's date reads as broken. On
        // the anchor day only, Charge / Rest carry the freshest strictly-prior scored values and
        // the signals fall back per-field to the last vitals-bearing day. Effort never carries —
        // it accumulates from midnight, and yesterday's total shown as today would lie. A carried
        // value's baseline is computed before its SOURCE day, never before the anchor: the carried
        // sample must not sit inside its own mean (fabricated "near typical" readings / zero deltas).
        //
        // Those rules live in ONE place — `WidgetDayResolver.fields` — shared with the widget / watch /
        // Live-Activity glance, so the two surfaces cannot drift apart (#977 shipped exactly that drift
        // when the sequence was written out twice). `allowCarry` is the browsed-history gate: stepping
        // back off the anchor day turns Charge, Rest and the vitals fallback dark together.
        let f = WidgetDayResolver.fields(days: days, restSeries: restSeries,
                                         effortCoverage: effortCoverage,
                                         key: key, allowCarry: isToday)
        // The pale typical band on each line: the 25th…75th percentile of the SAME window each
        // baseline above is taken from (carry source days and the low-coverage exclusion included),
        // resolved here beside it, from the arrays already in hand.
        let bands = TodayModel.scoreBands(days: days, restSeries: restSeries,
                                          effortCoverage: effortCoverage,
                                          key: key, fields: f)
        // The Charge hero is tappable ONLY on the anchor day AND only when it actually shows a value
        // (today's own recovery or a fresh carry). ChargeDetailScreen describes the NEWEST scored day, so
        // letting a browsed past hero — or a deliberately-blanked "—" (a >2-day-stale carry the resolver
        // withholds) — push it would open a detail that contradicts the number the user tapped.
        let chargeTappable = isToday && (row?.recovery != nil || f.chargeCarriedFrom != nil)

        // A blank Charge says HOW FAR ALONG the seed is, not merely that it is calibrating (015 P2).
        // Computed only when there IS no number: a scored or carried hero captions itself, and
        // short-circuiting here keeps the fold off every normal day's derivation.
        let chargeNote: String? = f.charge == nil
            ? TodayCalibration.note(days: days, through: key, loaded: loaded,
                                    offsetSec: TimeZone.current.secondsFromGMT())
            : nil

        // The three scores as `ScoreTrio.Entry` — the SAME honest states the trio was fed (carried
        // source day, partial capture, calibrating progress), so the lines inherit every one of them
        // and the caption composition (`calibratingCaption`) stays the one the tests pin.
        let charge = ScoreTrio.Entry(score: f.charge.map(Double.init),
                                     baseline: f.chargeBaseline.map(Double.init),
                                     carriedFrom: f.chargeCarriedFrom.map(TodayModel.shortDayLabel),
                                     calibratingNote: chargeNote)
        // Effort still shows its real number on a partial day — it is a FLOOR, not a fabrication — but
        // the line renders provisional and captions "partial capture", so a 12-hour hole can no longer
        // read as a genuine rest day. `calibratingNote: nil` on Effort and Rest, deliberately: the note
        // describes the HRV baseline seeding that suppresses CHARGE specifically; a nil Effort or Rest
        // means the day has no data yet, which is a different state with no "n of 4" to report.
        let effort = ScoreTrio.Entry(score: f.effort.map(Double.init),
                                     baseline: f.effortBaseline.map(Double.init),
                                     lowCoverage: f.effortLowCoverage,
                                     calibratingNote: nil)
        let rest = ScoreTrio.Entry(score: f.rest.map(Double.init),
                                   baseline: f.restBaseline.map(Double.init),
                                   carriedFrom: f.restCarriedFrom.map(TodayModel.shortDayLabel),
                                   calibratingNote: nil)

        // P5/P7: slice the strictly-prior rows ONCE per derivation; every trailing mean below derives
        // from this single slice instead of re-filtering the full `days` array per field.
        //
        // Today-first per field; the vitals-fallback row (anchor day only) fills what today hasn't
        // measured yet, and each field's mean is windowed before its SOURCE day, so a carried value is
        // never a sample inside the baseline it's compared against. Skin temp never carries (parity with
        // the original — a deviation is only meaningful the night it was measured).
        let prior = days.filter { $0.day < key }
        let fallbackKey = f.vitalsRow?.day ?? key
        let hrvMean = priorMean(in: prior, selectedKey: key,
                                before: row?.avgHrv != nil ? key : fallbackKey, \.avgHrv)
        let rhrMean = priorMean(in: prior, selectedKey: key,
                                before: row?.restingHr != nil ? key : fallbackKey) {
            $0.restingHr.map(Double.init)
        }
        let respMean = priorMean(in: prior, selectedKey: key,
                                 before: row?.respRateBpm != nil ? key : fallbackKey, \.respRateBpm)
        let skinMean = priorMean(in: prior, selectedKey: key, before: key, \.skinTempDevC)

        return Derived(
            key: key, isToday: isToday, loaded: loaded,
            row: row, vitalsRow: f.vitalsRow,
            charge: charge, effort: effort, rest: rest,
            bands: bands, chargeTappable: chargeTappable,
            hrvMean: hrvMean, rhrMean: rhrMean, respMean: respMean, skinMean: skinMean,
            everMeasured: days.contains {
                $0.avgHrv != nil || $0.restingHr != nil || $0.respRateBpm != nil
            },
            canStepBack: days.contains { $0.day < key } || restSeries.keys.contains { $0 < key })
    }

    // MARK: - Header

    /// The tab header in `TabHeader`'s metrics (title role over a label subtitle, 64pt, trailing
    /// controls in inkSecondary), composed here because the DATE line carries the day stepper:
    /// `TabHeader` takes its subtitle as a string, and its trailing slot cannot also hold two more
    /// 44pt steppers beside the chip and the settings button without squeezing a weekday title off
    /// the row.
    ///
    /// The title always names the displayed day ("Tuesday"), browsed or not; VoiceOver hears "Today"
    /// first on the anchor day, since the visible title no longer says it.
    private func header(selectedKey: String, isToday: Bool, canStepBack: Bool) -> some View {
        let weekday = TodayModel.weekdayTitle(key: selectedKey)
        let date = TodayModel.dateSubtitle(key: selectedKey)
        let spokenTitle: String = isToday ? "Today, \(weekday), \(date)" : "\(weekday), \(date)"
        return HStack(alignment: .center, spacing: WM.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(weekday)
                    .font(WMType.title)
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(spokenTitle)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 0) {
                    Text(date)
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .accessibilityHidden(true)
                    stepper(systemName: "chevron.left", label: "Previous day",
                            enabled: canStepBack) { dayOffset += 1 }
                    stepper(systemName: "chevron.right", label: "Next day",
                            enabled: dayOffset > 0) { dayOffset -= 1 }
                }
            }
            Spacer(minLength: WM.Space.s)
            HStack(spacing: WM.Space.s) {
                if showsStrapChip {
                    TodayStrapChip()
                }
                WMIconButton(systemName: "slider.horizontal.3", label: "Settings") {
                    appActions.openSettings()
                }
            }
        }
        .frame(minHeight: 64)
    }

    /// One day-stepper chevron on the date line. The glyph is sized to sit with 13pt text, but the
    /// hit region stays the HIG 44×44: the negative vertical padding lets the square overhang the
    /// line (into the title above and the gap below — neither holds a control) instead of pushing
    /// the date 14pt away from the title it belongs to.
    private func stepper(systemName: String, label: String, enabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(WMType.icon(.disclosure))
                .foregroundStyle(enabled ? WM.Ground.inkSecondary : WM.Ground.inkTertiary.opacity(0.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.vertical, -14)
        .accessibilityLabel(label)
    }

    // MARK: - Signals

    /// The four vitals over the derived day. Today-first per field; the vitals-fallback row (anchor day
    /// only) fills what today hasn't measured yet. Skin temp never carries. Each cell's "vs typical"
    /// mean was windowed in `derive`, before the field's SOURCE day.
    @ViewBuilder
    private func signals(_ d: Derived) -> some View {
        let hrv = d.row?.avgHrv ?? d.vitalsRow?.avgHrv
        let rhr = d.row?.restingHr ?? d.vitalsRow?.restingHr
        let resp = d.row?.respRateBpm ?? d.vitalsRow?.respRateBpm
        let skin = d.row?.skinTempDevC

        // Fresh / strap-less install: no vital has ever been measured. Show one plain-voice line
        // instead of four bare em-dashes (mirrors the Data/Rest empty copy). Only once the repo has
        // loaded — a still-loading screen keeps the cells rather than flashing this.
        //
        // `everMeasured` is what distinguishes a genuine first run from a SYNC GAP. Now that the vitals
        // carry is capped at `carryFreshnessDays` (it used to reach back the whole 120-day window), an
        // established wearer who simply hasn't synced for three days has nil cells too — and telling them
        // "Signals appear after your first synced night" would be plainly false. They get four honest
        // em-dashes instead, matching the score lines directly above.
        if d.loaded, !d.everMeasured, hrv == nil, rhr == nil, resp == nil, skin == nil {
            Text("Signals appear after your first synced night.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: WM.Space.m) {
            cell(label: "HRV", unit: "ms",
                 value: hrv.map { String(format: "%.0f", $0) },
                 delta: TodayModel.signalDelta(current: hrv, mean: d.hrvMean,
                                               rule: .upGood, decimals: 0))
            cell(label: "RHR", unit: "bpm",
                 value: rhr.map(String.init),
                 delta: TodayModel.signalDelta(current: rhr.map(Double.init),
                                               mean: d.rhrMean, rule: .downGood, decimals: 0))
            cell(label: "Resp", unit: "rpm",
                 value: resp.map { String(format: "%.1f", $0) },
                 delta: TodayModel.signalDelta(current: resp, mean: d.respMean,
                                               rule: .nearZeroGood(warn: 1.0, bad: 2.0),
                                               decimals: 1))
            // Skin temp never carries and only banks on a full history offload (and needs a personal
            // baseline before a deviation is meaningful), so it's routinely absent for a day. Hide the
            // cell entirely until there's a real reading rather than pinning a permanent em-dash — the
            // three vitals then spread across the row. It reappears the moment skin temp is populated.
            if skin != nil {
                // Skin temp is a ±°C DEVIATION vs the personal baseline — convert the shown value, the
                // mean it's compared against, AND the near-zero band thresholds by the delta rule (×9/5,
                // no +32) so imperial reads the same physical move in °F with an unchanged verdict.
                let imperial = unitSystem == "imperial"
                let skinDisp = skin.map { TempUnit.delta($0, imperial: imperial) }
                let skinMeanDisp = d.skinMean.map { TempUnit.delta($0, imperial: imperial) }
                cell(label: "Skin", unit: TempUnit.label(imperial: imperial),
                     value: skinDisp.map { String(format: "%+.1f", $0) },
                     delta: TodayModel.signalDelta(current: skinDisp, mean: skinMeanDisp,
                                                   rule: .nearZeroGood(warn: TempUnit.delta(0.3, imperial: imperial),
                                                                       bad: TempUnit.delta(0.6, imperial: imperial)),
                                                   decimals: 1, suffix: "°"))
            }
            }
        }
    }

    private func cell(label: String, unit: String, value: String?, delta: WMDelta?) -> some View {
        SignalCell(label: label, value: value ?? "—", unit: unit,
                   delta: value == nil ? nil : delta, fillsWidth: true)
    }

    /// Trailing 30-day mean of a daily field strictly before `cutoff`, derived from the pre-sliced
    /// `prior` (rows before the selected day) so the full `days` array is filtered ONCE per derivation
    /// (P5/P7). Every `cutoff` here is ≤ `selectedKey`, so a carried field just narrows `prior` further
    /// — the population, and thus the mean, is byte-identical to filtering `days` directly.
    private static func priorMean(in prior: [DailyMetric], selectedKey: String,
                                  before cutoff: String, _ value: (DailyMetric) -> Double?) -> Double? {
        let rows = cutoff == selectedKey ? prior : prior.filter { $0.day < cutoff }
        // `typicalMean`, not `mean`: this feeds every Signals cell's ▲/▼ delta and the Skin verdict, all
        // of which are presented as "vs typical". Bare `mean` called one prior night a 30-day typical.
        return TodayModel.typicalMean(Array(rows.compactMap(value).suffix(30)))
    }

    // MARK: - Timeline

    /// "Your day": the displayed day as the Line day strip. `now` is the ink "now" dot — today only;
    /// a browsed day is over, and a dot on it would mark a moment that is not on it.
    @ViewBuilder
    private func timeline(selectedKey: String, now: Date?) -> some View {
        if let dayStart = TodayModel.date(fromKey: selectedKey),
           let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) {
            let spans = TodayModel.sleepSpans(sleeps, dayKey: selectedKey,
                                              dayStart: dayStart, dayEnd: dayEnd)
            // The BROWSED day's workouts, clipped to it — the same window the sleep spans and the HR
            // read below take, so all three layers describe the day the header names rather than today.
            let bouts = TodayTimeline.workoutSpans(workouts, dayStart: dayStart, dayEnd: dayEnd)
            // The TimelineStrip is accessibilityHidden (decorative track), so without a spoken equivalent a
            // VoiceOver user finds NOTHING under the "Your day" heading on a normal synced day. Summarize
            // the sleep span(s) and the day's workouts as the section's a11y label. The HR shading is left
            // out: it is a continuous texture rather than a set of events, so it has no honest one-sentence
            // equivalent, and the Effort line above already states the day's load as a number. The intake
            // dots are left out too: they are the Log tab's list drawn small, and Log reads them out.
            let sleepPhrase = spans.isEmpty
                ? "No sleep banked for this day."
                : "Asleep " + spanPhrase(spans)
            let a11ySummary = bouts.isEmpty
                ? sleepPhrase
                : sleepPhrase + ". Workouts " + spanPhrase(bouts)
            VStack(alignment: .leading, spacing: WM.Space.s) {
                // The strip's layers, each drawn only where the day actually holds one (decision 1): no
                // workout ⇒ no band, no HR ⇒ no shading, no exact-clock intake ⇒ no dots, never a flat
                // zero row. Stress ticks stay unfed on purpose — they need the DaytimeStress number that
                // was parked by decision, so feeding them here would ship exactly what was declined.
                if showsIntakeEntries {
                    TodayIntakeTimeline(dayKey: selectedKey, dayStart: dayStart, dayEnd: dayEnd,
                                        sleep: spans, workouts: bouts, hrIntensity: hrIntensity,
                                        now: now)
                } else {
                    TimelineLoaded(dayKey: selectedKey, dayStart: dayStart, dayEnd: dayEnd,
                                   sleep: spans, workouts: bouts, hrIntensity: hrIntensity,
                                   entries: [], now: now)
                }
                if spans.isEmpty {
                    Text("No sleep banked for this day.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11ySummary)
        }
    }

    /// The spoken form of a span list for the timeline's a11y label ("11:15 PM to 7:00 AM, …").
    private func spanPhrase(_ spans: [(start: Date, end: Date)]) -> String {
        spans.map {
            "\($0.start.formatted(date: .omitted, time: .shortened)) to "
                + "\($0.end.formatted(date: .omitted, time: .shortened))"
        }.joined(separator: ", ")
    }

    // MARK: - Health monitor row (007 F2)

    /// The heads-up row between the score lines and Signals: warn dot + the engine's headline over
    /// the standing disclaimer, a chevron pushing the Health Monitor detail. Row metrics are
    /// `WMNavRow`'s (56pt with a subtitle); the leading dot is why it is not one.
    private func strainBanner(level: StrainLevel, day: String) -> some View {
        Button { onStrainTap?(day) } label: {
            HStack(spacing: WM.Space.m) {
                Circle()
                    .fill(WM.Semantic.warn)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(HealthMonitorModel.headline(for: level))
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(IllnessSignalEngine.disclaimerTail)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: WM.Space.s)
                WMDisclosure()
            }
            .padding(.vertical, WM.Space.s)
            .frame(minHeight: WM.Space.row + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Health monitor: \(HealthMonitorModel.headline(for: level))")
        .accessibilityHint("Opens the health monitor for this day")
    }

    // MARK: - Last workout

    /// One row: sport (17 semibold) over "Yesterday · 18:05 · 52 min", the session's Effort as a
    /// numeral in the Effort color, and a chevron. Tapping pushes the workout detail in Today's stack.
    private func lastWorkoutRow(_ row: WorkoutRow) -> some View {
        let sport = WorkoutSource.displaySport(row.sport)
        let day = WorkoutFormat.relativeDay(row.startTs)
        let time = WorkoutFormat.time(row.startTs)
        let duration = WorkoutFormat.duration(row)
        let effort = WorkoutFormat.strainText(row.strain)
        let spoken: String = "\(sport), \(day), \(time), \(duration)" + (effort.map { ", Effort \($0)" } ?? "")
        return Button { onWorkoutTap?(row) } label: {
            HStack(spacing: WM.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sport)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(WM.Ground.ink)
                        .lineLimit(1)
                    Text("\(day) · \(time) · \(duration)")
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: WM.Space.s)
                if let effort {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(effort)
                            .font(WMType.numeral(28))
                            .foregroundStyle(WM.Domain.effort.color)
                        Text("Effort")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                    }
                }
                WMDisclosure()
            }
            .frame(minHeight: WM.Space.row + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens the workout")
    }
}

// MARK: - Header strap chip

/// The header's `StrapChip`, observing `LiveState` on its own so the strap's packet-rate publishes
/// re-render this chip and nothing else (the `TodaySyncCaption` idiom).
///
/// "Paired" is settled on EVIDENCE, like `SyncStatus`'s "never paired" rung: a live link, a bond, or
/// the persisted peripheral pin (`AppRoot.pairedPeripheralKey`) — written when a strap connects,
/// cleared by Forget. `bonded` alone is false at launch and while the strap is out of range, and
/// "No strap" on a strap that is merely on the charger would be the wrong answer.
private struct TodayStrapChip: View {
    @EnvironmentObject private var live: LiveState
    @Environment(\.appActions) private var appActions
    @AppStorage(AppRoot.pairedPeripheralKey) private var pinnedPeripheral: String?

    var body: some View {
        StrapChip(batteryPct: live.batteryPct.map { Int($0.rounded()) },
                  connected: live.connected,
                  paired: live.connected || live.bonded || pinnedPeripheral != nil,
                  action: { appActions.openStrapHealth() })
    }
}

// MARK: - Timeline layers (015 P1)

/// The day strip with the displayed day's logged intake drawn as dots above the rail — `IntakeStore`
/// observed HERE, so a log re-renders the strip and not the whole Today body. The events are the
/// store's in-memory 120-day cache (`events(on:)`), the same cache Log's list reads: no store read.
private struct TodayIntakeTimeline: View {
    let dayKey: String
    let dayStart: Date
    let dayEnd: Date
    let sleep: [(start: Date, end: Date)]
    let workouts: [(start: Date, end: Date)]
    let hrIntensity: TodayHRIntensity
    let now: Date?

    @EnvironmentObject private var intake: IntakeStore

    var body: some View {
        TimelineLoaded(dayKey: dayKey, dayStart: dayStart, dayEnd: dayEnd, sleep: sleep,
                       workouts: workouts, hrIntensity: hrIntensity,
                       entries: Self.entries(intake.events(on: dayKey), dayStart: dayStart, dayEnd: dayEnd),
                       now: now)
    }

    /// The day's intake as strip dots: water in Rest's iris, everything else in Charge's ember.
    ///
    /// Only EXACT clocks inside the day's window are drawn. A back-dated log's placeholder noon is a
    /// declared guess (`IntakeEvent.tsExact`), and a dot is a claim about WHEN; and an event keyed to
    /// this day but stamped after midnight (the pre-04:00 anchor window) lies off this strip, where
    /// clamping it to the edge would draw it at a time it did not happen.
    static func entries(_ events: [IntakeEvent], dayStart: Date,
                        dayEnd: Date) -> [(date: Date, color: Color)] {
        events.compactMap { event -> (date: Date, color: Color)? in
            guard event.tsExact else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(event.ts))
            guard date >= dayStart, date < dayEnd else { return nil }
            return (date: date,
                    color: event.kind == .water ? WM.Domain.rest.color : WM.Domain.charge.color)
        }
    }
}

// MARK: - Scores

/// Today's three scores in the Line language (037): the Charge hero on its `.hero` line, then
/// Effort and Rest as `ScoreLine`s. Its own view so the Honesty gallery renders the SAME composition
/// Today does — every calibrating / carried / partial state included — rather than a look-alike.
struct TodayScores: View {
    let charge: ScoreTrio.Entry
    let effort: ScoreTrio.Entry
    let rest: ScoreTrio.Entry
    /// Each score's typical band on its own 0–100 scale; nil until `minBaselineSamples` is met.
    var chargeBand: ClosedRange<Double>? = nil
    var effortBand: ClosedRange<Double>? = nil
    var restBand: ClosedRange<Double>? = nil
    /// Charge pushes its detail only under `TodayContent`'s gating rule.
    var chargeTappable: Bool = false
    var onChargeTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chargeHero(charge, band: chargeBand, tappable: chargeTappable)
            // Effort and Rest stay inert: only Charge has a detail to push, and the shell exposes
            // no action to switch tabs from here.
            VStack(alignment: .leading, spacing: WM.Space.m + WM.Space.s) {
                scoreLine("Effort", effort, band: effortBand, domain: .effort)
                scoreLine("Rest", rest, band: restBand, domain: .rest)
            }
            .padding(.top, WM.Space.sectionTight + WM.Space.s)
        }
    }

    /// The Charge hero: the day's one big number on its line, the band the user's typical range.
    /// Tappable into the Charge detail only under `chargeTappable`'s rule; otherwise a plain element.
    @ViewBuilder
    private func chargeHero(_ entry: ScoreTrio.Entry, band: ClosedRange<Double>?,
                            tappable: Bool) -> some View {
        let hero = VStack(alignment: .leading, spacing: WM.Space.l) {
            HeroReadout(value: Self.numeral(entry), title: "Charge",
                        subtitle: Self.caption(entry, band: band, readsBand: true),
                        color: Self.numeralColor(entry), size: 104)
            LineScale(value: entry.score.map { $0 / 100 }, band: Self.fraction(band),
                      color: Self.lineColor(.charge, entry), style: .hero)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken("Charge", entry, band: band))

        if tappable, let onChargeTap {
            Button(action: onChargeTap) {
                hero.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows what shaped it")
        } else {
            hero
        }
    }

    /// Effort / Rest as a `ScoreLine`. The subtitle carries only an honesty state (carried, partial
    /// capture, calibrating) — the band reading stays on the line, where the Line boards put it.
    private func scoreLine(_ name: String, _ entry: ScoreTrio.Entry, band: ClosedRange<Double>?,
                           domain: WM.Domain) -> some View {
        ScoreLine(title: name, subtitle: Self.caption(entry, band: band, readsBand: false),
                  value: Self.numeral(entry), fraction: entry.score.map { $0 / 100 },
                  band: Self.fraction(band), domain: domain,
                  provisional: entry.carriedFrom != nil || entry.lowCoverage)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(name, entry, band: band))
    }

    private static func numeral(_ e: ScoreTrio.Entry) -> String {
        e.score.map { String(Int($0.rounded())) } ?? "—"
    }

    /// A carried or partial score is provisional — someone else's day, or only part of this one — so
    /// its numeral drops to secondary ink and its line to half strength, as the trio's dimmed column
    /// did. A blank one is tertiary.
    private static func numeralColor(_ e: ScoreTrio.Entry) -> Color {
        guard e.score != nil else { return WM.Ground.inkTertiary }
        return (e.carriedFrom != nil || e.lowCoverage) ? WM.Ground.inkSecondary : WM.Ground.ink
    }

    private static func lineColor(_ domain: WM.Domain, _ e: ScoreTrio.Entry) -> Color {
        (e.carriedFrom != nil || e.lowCoverage) ? domain.color.opacity(0.5) : domain.color
    }

    /// A 0–100 band as the line's 0…1 fractions.
    private static func fraction(_ band: ClosedRange<Double>?) -> ClosedRange<Double>? {
        band.map { ($0.lowerBound / 100)...($0.upperBound / 100) }
    }

    /// The line's one caption, in `ScoreTrio`'s precedence (the states are mutually exclusive):
    /// carried → blank ("calibrating", sharpened by the Charge note via `calibratingCaption`) →
    /// partial capture → (hero only) the reading against its band. nil when there is nothing honest
    /// to add — no band yet under `minBaselineSamples`, exactly where the trio drew no tick.
    private static func caption(_ e: ScoreTrio.Entry, band: ClosedRange<Double>?,
                                readsBand: Bool) -> String? {
        if let src = e.carriedFrom { return "carried · \(src)" }
        guard let score = e.score else { return e.calibratingCaption }
        if e.lowCoverage { return "partial capture" }
        guard readsBand, let band else { return nil }
        return TodayModel.bandCaption(value: Int(score.rounded()), band: band)
    }

    /// The spoken reading. The dimmed line and numeral that mark a provisional score are invisible to
    /// VoiceOver, so the carried / partial states are said out loud, as the trio's columns said them.
    private static func spoken(_ name: String, _ e: ScoreTrio.Entry,
                               band: ClosedRange<Double>?) -> String {
        guard let score = e.score else {
            return "\(name), calibrating" + (e.calibratingNote.map { ", \($0)" } ?? "")
        }
        var s = "\(name) \(Int(score.rounded()))"
        if let src = e.carriedFrom { s += ", provisional, carried from \(src)" }
        if e.lowCoverage { s += ", partial capture" }
        if let band {
            let lo = Int(band.lowerBound.rounded()), hi = Int(band.upperBound.rounded())
            s += lo == hi ? ", typical \(lo)" : ", typical \(lo) to \(hi)"
        }
        return s
    }

}

/// The day's TimelineStrip plus the async HR-intensity read that feeds it — a view of its own so the
/// `.task(id:)` sits next to the `@State` it fills, and so the read never happens on a SwiftUI frame
/// (decision 6; the `ArousalForensicsLoaded` / `ThisMorningWakeLoader` idiom).
///
/// Every stored value here is Sendable, the loader closure included, so the `.task` captures nothing
/// that has to cross an isolation boundary unsafely.
private struct TimelineLoaded: View {
    /// The day on screen. Part of the task id: stepping the stepper must re-read.
    let dayKey: String
    let dayStart: Date
    let dayEnd: Date
    let sleep: [(start: Date, end: Date)]
    let workouts: [(start: Date, end: Date)]
    let hrIntensity: TodayHRIntensity
    /// Logged moments as dots above the rail (empty ⇒ the strip reserves no room for them).
    let entries: [(date: Date, color: Color)]
    /// The ink "now" dot; nil for a day that is not today.
    let now: Date?

    /// The selected day's shading. Empty until the read lands — and empty is equally the honest END
    /// state for a day the strap recorded no HR on, which the strip draws as no shading at all.
    @State private var shading: [Double] = []

    var body: some View {
        TimelineStrip(dayStart: dayStart, dayEnd: dayEnd, sleep: sleep,
                      hrIntensity: shading, workouts: workouts, entries: entries, now: now)
            // Cleared first for the reason `ArousalForensicsLoaded` clears first: stepping to another
            // day must not shade it, even for one frame, with the day before's heart rate.
            .task(id: "\(dayKey)|\(hrIntensity.stamp)") {
                shading = []
                shading = await hrIntensity.load(dayStart, dayEnd)
            }
    }
}

/// The Today timeline's HR-intensity layer as an injected SOURCE: the read is `async` and covers the
/// day the stepper selects, so the parent cannot pre-compute a value to hand down.
///
/// Two fields because the loader needs both halves to behave: WHAT to read, and WHEN what it read
/// stopped being true.
struct TodayHRIntensity: Sendable {
    /// Re-read whenever this changes. Production passes the repository's raw-HR watermark, so the
    /// layer reloads when raw HR actually GREW and not on every score/sleep republish.
    let stamp: String
    /// Normalized 0–1 per bucket across `[dayStart, dayEnd)` — see `TodayTimeline.hrIntensity` for
    /// what the 0–1 means. Empty for a day the strap recorded no HR on.
    let load: @Sendable (_ dayStart: Date, _ dayEnd: Date) async -> [Double]

    /// A day with nothing to shade — every preview that is not about this layer, and the honest
    /// answer for a caller that has no store behind it.
    static let none = TodayHRIntensity(stamp: "none") { _, _ in [] }

    /// A fixed layer, for the previews that ARE about it. The stamp carries the count so two
    /// different fixed layers can't be mistaken for the same read.
    static func fixed(_ values: [Double]) -> TodayHRIntensity {
        TodayHRIntensity(stamp: "fixed-\(values.count)") { _, _ in values }
    }
}

/// Pure derivations for the Today timeline's workout and HR-intensity layers (015 P1). Value-in /
/// value-out and nonisolated, the `TodayModel` contract, so previews and tests drive them without a
/// Repository.
enum TodayTimeline {
    /// Bucket width for the HR-intensity layer: 15 minutes, i.e. 96 buckets across a normal day
    /// (92 or 100 across a DST one — the count always follows the day's real length). Fine enough
    /// that an hour-long session reads as a distinct band, coarse enough that one day's read is
    /// ~96 SQL-aggregated rows.
    static let hrBucketSeconds = 900

    /// The value a bucket that WAS recorded but sits at or below resting is floored to.
    ///
    /// It exists so "measured, and quiet" and "not measured at all" are not the same picture:
    /// `TimelineStrip` skips a zero bucket entirely, so without the floor a night spent at resting
    /// HR would be drawn exactly like an afternoon the strap was in a drawer. Deliberately tiny —
    /// the visible weight comes from the strip's own base wash, not from this number, which
    /// only has to be positive.
    static let measuredFloor = 0.001

    /// The workout spans that intersect `[dayStart, dayEnd)`, each CLIPPED to it, oldest first.
    ///
    /// A session that ran across midnight contributes only the part that fell on this day: the band
    /// is a picture of the day, so the other half is drawn on the day it happened. A session that
    /// misses the day entirely contributes nothing — no band, rather than a zero-width mark.
    static func workoutSpans(_ workouts: [WorkoutRow], dayStart: Date,
                             dayEnd: Date) -> [(start: Date, end: Date)] {
        let lo = dayStart.timeIntervalSince1970, hi = dayEnd.timeIntervalSince1970
        return workouts.compactMap { w -> (start: Date, end: Date)? in
            let start = max(TimeInterval(w.startTs), lo)
            let end = min(TimeInterval(w.endTs), hi)
            guard end > start else { return nil }
            return (start: Date(timeIntervalSince1970: start),
                    end: Date(timeIntervalSince1970: end))
        }
        .sorted { $0.start < $1.start }
    }

    /// The day's HR as one 0–1 value per `hrBucketSeconds` bucket across `[dayStart, dayEnd)`.
    ///
    /// WHAT THE 0–1 MEANS, and it means the same thing on every day: **fraction of heart-rate
    /// reserve** — 0 at the wearer's resting heart rate, 1 at their HRmax, clamped at both ends.
    /// Half-shaded is 50 %HRR today, yesterday, and last March.
    ///
    /// WHY NOT the day's own maximum, which is the obvious normalization and is wrong. Scaled to its
    /// own peak, a day whose hardest moment was the walk to the bus shades exactly as dark as a day
    /// with an interval session in it, and stepping the day stepper back silently re-scales the whole
    /// strip under the reader. A layer that means something different every day is worse than no
    /// layer. Both anchors here are therefore day-INDEPENDENT: the caller resolves HRmax from the
    /// profile and resting from the record as a whole, never from the day being drawn.
    ///
    /// ABSENCE. A bucket the strap recorded nothing in stays 0, and `TimelineStrip` draws nothing
    /// there — an off-wrist afternoon is a gap, not a measured calm. A day with no HR at all yields
    /// `[]`, not a row of zeros that would read as a flat measured floor. And a bucket that WAS
    /// recorded but sits at or below resting is floored at `measuredFloor` so it still draws
    /// faintly, because it is a reading and the gap beside it is not.
    ///
    /// No reserve to divide by (`hrMaxBpm <= restingBpm` — an override typed below resting) yields
    /// `[]`: there is no scale, so there is no honest shading.
    static func hrIntensity(_ buckets: [HRBucket], dayStart: Date, dayEnd: Date,
                            restingBpm: Int, hrMaxBpm: Int) -> [Double] {
        let spanSec = Int(dayEnd.timeIntervalSince(dayStart).rounded())
        guard spanSec > 0, hrMaxBpm > restingBpm else { return [] }
        let reserve = Double(hrMaxBpm - restingBpm)
        let count = Int((Double(spanSec) / Double(hrBucketSeconds)).rounded(.up))
        let lo = Int(dayStart.timeIntervalSince1970.rounded())

        var out = [Double](repeating: 0, count: count)
        var measured = false
        for bucket in buckets {
            // `hrBuckets` keys each bucket by its ABSOLUTE floor(ts/width)·width, so in a zone whose
            // local midnight is not a whole number of buckets the first key can sit fractionally
            // before `dayStart` while still overlapping the day's first bucket — that one lands in
            // slot 0. Anything a whole bucket or more outside the window is another day's heart rate
            // and is dropped, which is the day stepper's whole point.
            let offset = bucket.ts - lo
            guard offset > -hrBucketSeconds, offset < spanSec else { continue }
            let i = min(count - 1, max(0, offset / hrBucketSeconds))
            let fraction = (bucket.bpm - Double(restingBpm)) / reserve
            out[i] = max(out[i], max(measuredFloor, min(1, fraction)))
            measured = true
        }
        return measured ? out : []
    }
}

// MARK: - Calibrating progress (015 P2)

/// The progress note on a blank Charge hero: how far along the HRV seed is, rather than the bare
/// "calibrating" a blank Charge has shown since it shipped.
///
/// THE NUMBER IS THE ENGINE'S OWN (decision 2), never a second count of nights. It is
/// `BaselineState.nValid` off `Baselines.foldHistory` — the same fold, the same `hrvCfg`, the same
/// recalibration epoch (`baselineEpoch` left nil so it reads the same UserDefaults key) and the same
/// `offsetSec` that `ScoreEngine`'s own gate runs (`ScoreEngine.swift:693-695`), and the package states
/// outright that the two folds have "identical iteration, epoch handling and `offsetSec` semantics …
/// so the two can never disagree about which nights count" (`Baselines.foldPrefixUsable`). A
/// `days.filter { $0.avgHrv != nil }.count` would have been the second counter the decision forbids:
/// it counts a physiologically impossible 300 ms night that the fold rejects, and the caption would
/// then claim a night the suppressed score does not have.
enum TodayCalibration {

    /// The note for a blank Charge on `selectedKey`, or nil to leave the bare "calibrating" (the hero
    /// captions `ScoreTrio.Entry.calibratingCaption`, which renders "calibrating · <note>" or the bare
    /// word).
    ///
    /// AS OF THE DAY ON SCREEN, not as of today: the fold runs over the rows up to and including
    /// `selectedKey`, so stepping the day stepper back reports the count that day actually had behind
    /// it — the 014 lesson, and the same as-of-day question `foldPrefixUsable` answers for the score.
    ///
    /// nil while `loaded` is false. `days` is empty until the first refresh lands, and "0 of 4 nights"
    /// would then be a measurement of nothing — a flat zero standing in for "not read yet". Once
    /// loaded, an empty record genuinely IS zero banked nights and says so.
    ///
    /// nil once `nValid` reaches `minNightsSeed` — which is exactly `BaselineStatus.calibrating`
    /// (`computeStatus` reaches its calibrating branch iff `nValid < minNightsSeed`, the stale branch
    /// requiring `nValid >= minNightsSeed`). Deliberately NOT `!state.usable`: a long-seeded baseline
    /// that has gone `.stale` is un-usable too, and gating on that would caption a returning wearer's
    /// blank hero "60 of 4 nights".
    ///
    /// WHAT IT FOLDS. `days` is the published 120-day merged daily cache; the engine's gate folds the
    /// whole persisted record (`ScoreEngine.chargeSeedSequence`). For every user this caption is for
    /// the two sets are the same rows — a baseline under `minNightsSeed` has by definition fewer than
    /// four banked nights, and the cache is also exactly the range the day stepper can reach. The one
    /// case where they part is a wearer holding a valid night OLDER than the cache window and still
    /// under the seed, where this understates by that night; it can never overstate past the gate,
    /// because a count at or above the seed prints nothing at all.
    static func note(days: [DailyMetric], through selectedKey: String, loaded: Bool,
                     offsetSec: Int) -> String? {
        guard loaded else { return nil }
        let history = days.filter { $0.day <= selectedKey }.sorted { $0.day < $1.day }
        let state = Baselines.foldHistory(history.map { $0.avgHrv }, dayKeys: history.map { $0.day },
                                          cfg: Baselines.hrvCfg, offsetSec: offsetSec)
        guard state.nValid < Baselines.minNightsSeed else { return nil }
        return "\(state.nValid) of \(Baselines.minNightsSeed) nights"
    }
}

// MARK: - Pipeline caption (012 P2)

/// Today's one line about whether data is getting in — `SyncStatus`, the single ladder, rendered on
/// the app's most protected surface.
///
/// Env-driven rather than threaded through `TodayContent`, and for a specific reason: `LiveState`
/// publishes on every packet, so an `@EnvironmentObject` on `TodayScreen` would re-render the whole
/// Today body at beat rate. Scoping the observation to this one row keeps the churn to one `Text`.
private struct TodaySyncCaption: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        // Resolved ONCE (012 P2's trap), passed down as a value — `TodaySyncCaptionContent` never
        // calls `resolve` itself, and never derives a second opinion about the same pipeline.
        TodaySyncCaptionContent(status: SyncStatus.resolve(
            radio: live.radio,
            bonded: live.bonded,
            backfilling: live.backfilling,
            strapNeedsReboot: live.strapNeedsReboot,
            historySyncExperimental: live.historySyncExperimental,
            frontierUnix: live.persistedFrontierUnix,
            frontierLoaded: live.frontierLoaded,
            now: Date().timeIntervalSince1970))
    }
}

/// The caption over a plain resolved state, so both previews drive it without a `LiveState` (the
/// TodayScreen / TodayContent split). A label-role line in secondary ink under the header: legible,
/// but still a caption — no icon, no color, no tap target.
///
/// Draws NOTHING unless the state is worth reporting (012 decision 5 — the `CaptureQuality.caption`
/// rule: a working pipeline saying so unprompted is noise). The gate is `isProblem`, not "has a line":
/// an offload in progress has plenty to say and is the pipeline WORKING, so gating on the line would
/// flash a caption onto Today every time the strap connected. Live is where progress belongs.
/// Internal, not private, so `HonestyGallery` can render the REAL caption rather than re-type its
/// font and colour — a gallery that reimplements what it is proving proves nothing.
struct TodaySyncCaptionContent: View {
    let status: SyncStatus.State

    var body: some View {
        if status.isProblem, let line = status.line {
            Text(line)
                .font(WMType.label)
                .foregroundStyle(WM.Ground.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, WM.Space.xs)
        }
    }
}

/// Identifiable day-key wrapper for the Health Monitor `navigationDestination(item:)` push
/// (mirrors `WorkoutRef` — a bare String can't drive an item destination).
private struct MonitorDayRef: Identifiable, Hashable {
    let day: String
    var id: String { day }
}

// MARK: - Previews

#Preview("Today — light") {
    let d = TodaySpecimen.data
    TodayContent(days: d.days, restSeries: d.rest, sleeps: d.sleeps,
                 workouts: TodaySpecimen.workouts,
                 hrIntensity: .fixed(TodaySpecimen.hrIntensity), refreshSeq: 0,
                 lastWorkout: TodaySpecimen.workouts.last)
        .preferredColorScheme(.light)
}

#Preview("Today — dark") {
    let d = TodaySpecimen.data
    TodayContent(days: d.days, restSeries: d.rest, sleeps: d.sleeps,
                 workouts: TodaySpecimen.workouts,
                 hrIntensity: .fixed(TodaySpecimen.hrIntensity), refreshSeq: 0,
                 lastWorkout: TodaySpecimen.workouts.last)
        .preferredColorScheme(.dark)
}

// The timeline with only the layers a bare day HOLDS: sleep, and nothing else. The gap where the
// other two would be IS the state — no workout band, no shading, no grey bar at zero.
#Preview("Today — timeline, no workout or HR") {
    let d = TodaySpecimen.data
    TodayContent(days: d.days, restSeries: d.rest, sleeps: d.sleeps,
                 workouts: [], hrIntensity: .none, refreshSeq: 0)
        .preferredColorScheme(.light)
}

// Today's own row not yet scored: Charge and Rest carry yesterday's values at half strength with a
// "carried · <day>" caption, and Effort (which never carries) reads "—".
#Preview("Today — carried Charge") {
    TodayContent(days: TodaySpecimen.carried.days, restSeries: TodaySpecimen.carried.rest,
                 sleeps: TodaySpecimen.data.sleeps, workouts: [], hrIntensity: .none,
                 refreshSeq: 0)
        .preferredColorScheme(.light)
}

#Preview("Today — calibrating") {
    TodayContent(days: [], restSeries: [:], sleeps: [], workouts: [], hrIntensity: .none,
                 refreshSeq: 0)
        .preferredColorScheme(.light)
}

// The cold-start Charge PART-WAY through its seed (015 P2): two of the four nights the gate wants, so
// the blank hero captions "calibrating · 2 of 4 nights" rather than a bare "calibrating". Effort and
// Rest stay bare on purpose — nothing knows how far along THEY are, and inventing a denominator for
// them would be a number the data does not support.
#Preview("Today — calibrating, 2 of 4 nights") {
    TodayContent(days: TodaySpecimen.coldStart, restSeries: [:], sleeps: [],
                 workouts: [], hrIntensity: .none, refreshSeq: 0)
        .preferredColorScheme(.light)
}

#Preview("Today — calibrating, 2 of 4 nights, dark") {
    TodayContent(days: TodaySpecimen.coldStart, restSeries: [:], sleeps: [],
                 workouts: [], hrIntensity: .none, refreshSeq: 0)
        .preferredColorScheme(.dark)
}

#Preview("Today — sync caption, light") {
    TodaySyncCaptionSpecimen().preferredColorScheme(.light)
}

#Preview("Today — sync caption, dark") {
    TodaySyncCaptionSpecimen().preferredColorScheme(.dark)
}

#Preview("Today — health monitor row") {
    let d = TodaySpecimen.data
    TodayContent(days: d.days, restSeries: d.rest, sleeps: d.sleeps,
                 workouts: [], hrIntensity: .none, refreshSeq: 0,
                 strainLevel: [TodayModel.key(from: Date()): .raised])
        .preferredColorScheme(.light)
}

/// Every rung the caption can print, followed by the two it must print as NOTHING — an offload in
/// progress and a caught-up strap leave blank space at the bottom here, and that gap IS the feature.
private struct TodaySyncCaptionSpecimen: View {
    private let states: [SyncStatus.State] = [
        .radio(LiveState.RadioState.poweredOff.problem ?? ""),
        .strapStuck(SyncStatus.strapRebootLine),
        .neverSynced,
        .behind("2d 4h"),
        .liveOnly,
        .notPaired,
        .offloading("3d"),
        .caughtUp
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                TodaySyncCaptionContent(status: state)
            }
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WM.Ground.ground)
    }
}

/// Deterministic 30-day preview dataset (no Repository / store needed).
private enum TodaySpecimen {

    /// Two sessions on the anchor day so the light/dark previews carry the timeline's workout band:
    /// a morning lift and an evening run. The run is the "Last workout" row, Effort included.
    static let workouts: [WorkoutRow] = {
        let day0 = Calendar.current.startOfDay(for: Date())
        func row(startHour: Double, minutes: Int, sport: String, strain: Double) -> WorkoutRow {
            let start = Int(day0.timeIntervalSince1970) + Int(startHour * 3600)
            return WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: sport,
                              source: "manual", durationS: Double(minutes * 60), energyKcal: nil,
                              avgHr: nil, maxHr: nil, strain: strain, distanceM: nil,
                              zonesJSON: nil, notes: nil)
        }
        return [row(startHour: 7.5, minutes: 45, sport: "Lifting", strain: 31),
                row(startHour: 18, minutes: 55, sport: "Running", strain: 44)]
    }()

    /// 15-minute HR-intensity buckets across the anchor day, in the units the layer really carries
    /// (fraction of HR reserve — see `TodayTimeline.hrIntensity`). Both halves of its contract are on
    /// screen: shading everywhere HR was recorded, and a blank 13:00–15:00 where the strap was off,
    /// which must read as nothing rather than as a measured calm.
    static let hrIntensity: [Double] = (0..<96).map { i -> Double in
        let hour = Double(i) / 4
        switch hour {
        case ..<7: return 0.05            // asleep
        case 7.5..<8.25: return 0.55      // the morning lift
        case 13..<15: return 0            // off wrist — absent, and it has to LOOK absent
        case 18..<18.92: return 0.78      // the evening run
        default: return 0.18
        }
    }

    /// A fresh install part-way through the Charge seed: the two nights before the anchor day, each
    /// carrying real HRV and no recovery. Two of `Baselines.minNightsSeed`, so the Charge hero is
    /// genuinely blank and the note has a real count to print.
    static let coldStart: [DailyMetric] = {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (1...2).reversed().map { back in
            let key = TodayModel.key(from: cal.date(byAdding: .day, value: -back, to: today)!)
            return DailyMetric(
                day: key, totalSleepMin: 430, efficiency: 91,
                deepMin: 78, remMin: 96, lightMin: 236, disturbances: 6,
                restingHr: 53, avgHrv: back == 1 ? 68.0 : 74.0,
                recovery: nil, strain: nil, exerciseCount: 0,
                spo2Pct: nil, skinTempDevC: nil, respRateBpm: 14.2)
        }
    }()

    /// `data` the morning before last night has scored: the anchor row keeps its vitals but has no
    /// recovery or strain yet, and its Rest score is missing — so Charge and Rest carry yesterday's.
    static let carried: (days: [DailyMetric], rest: [String: Double]) = {
        var days = data.days
        var rest = data.rest
        if var last = days.popLast() {
            rest[last.day] = nil
            last.recovery = nil
            last.strain = nil
            days.append(last)
        }
        return (days, rest)
    }()

    static let data: (days: [DailyMetric], rest: [String: Double], sleeps: [CachedSleepSession]) = {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var days: [DailyMetric] = []
        var rest: [String: Double] = [:]
        var sleeps: [CachedSleepSession] = []

        for i in 0..<30 {
            let date = cal.date(byAdding: .day, value: i - 29, to: today)!
            let key = TodayModel.key(from: date)
            let wave = sin(Double(i) / 3.5)
            let hrv = 74 + 12 * wave + Double((i * 7) % 5)
            let rhr = 52 - Int((2 * wave).rounded())
            days.append(DailyMetric(
                day: key, totalSleepMin: 420 + 30 * wave, efficiency: 90 + 3 * wave,
                deepMin: 80, remMin: 100, lightMin: 240, disturbances: 5 + (i % 4),
                restingHr: rhr, avgHrv: hrv,
                recovery: min(max(60 + 22 * wave + Double((i * 13) % 9), 0), 100),
                strain: min(max(30 + 25 * sin(Double(i) / 2.2), 0), 100),
                exerciseCount: i % 3 == 0 ? 1 : 0,
                spo2Pct: 96.5, skinTempDevC: 0.2 * wave, respRateBpm: 14.3 + 0.5 * wave))
            rest[key] = min(max(76 + 12 * wave, 0), 100)

            let onset = Int(date.timeIntervalSince1970) - 45 * 60  // 23:15 the prior evening
            sleeps.append(CachedSleepSession(
                startTs: onset, endTs: onset + Int((465 + 30 * wave) * 60),
                efficiency: 90 + 3 * wave, restingHr: rhr, avgHrv: hrv, stagesJSON: nil))
        }
        return (days, rest, sleeps)
    }()
}
