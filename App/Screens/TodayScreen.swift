import SwiftUI
import StrapStore
import StrapAnalytics

/// The Today tab: date header with prev/next day steppers (clamped to today) →
/// ScoreTrio hero (Charge / Effort / Rest vs their 30-day typicals) → SIGNALS (HRV / RHR / Resp /
/// Skin temp with semantic deltas) → TODAY (the day as a TimelineStrip: the night's sleep, the
/// workouts that fell on the day, and HR intensity as neutral shading — each layer drawn only where
/// the day actually holds one). Charge column pushes the Charge detail.
struct TodayScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var workoutRepo: WorkoutRepository
    /// Read for ONE number: the HRmax the timeline's HR-intensity scale is anchored at
    /// (`hrIntensitySource`). `ProfileStore` publishes only when the user edits their profile, so
    /// observing it here costs the body nothing at runtime.
    ///
    /// That sentence is the BAR every `@EnvironmentObject` on this screen has to clear, and three
    /// of them no longer did. `ScoreEngine` sat here for a single lookup that only the pushed Charge
    /// detail consumed, while publishing twice per scoring pass; `JournalStore` and `WeedStore` sat
    /// here feeding arguments 029 had already stopped rendering. Each publish invalidated the app's
    /// largest view tree. The Charge lookup moved into `ChargeDetailHost` below; the journal/weed
    /// wiring went with the sections it fed (see the 029/030 note in `TodayContent.body`).
    @EnvironmentObject private var profile: ProfileStore
    @State private var showsChargeDetail = false
    @State private var showsHabitsDetail = false
    @State private var selectedWorkout: WorkoutRef?
    @State private var monitorDay: MonitorDayRef?
    @State private var showsIntakeDetail = false
    /// The intake event being edited, or a nil-event ref for a fresh log (024). Reuses
    /// `IntakeEditorRef` — the Intake screen presents the same sheet from its own "+".
    @State private var editingIntake: IntakeEditorRef?

    var body: some View {
        // No NavigationStack here: the shell (`AppShell.stack`) already wraps every tab in one, so the
        // destinations below push onto THAT stack — matching Data/Live, which also attach their
        // `.navigationDestination` directly. A second nested stack swallowed cold-init state seeds.
        TodayContent(days: repo.days, restSeries: repo.restSeries, sleeps: repo.sleeps,
                     workouts: workoutRepo.workouts, hrIntensity: hrIntensitySource,
                     lastWorkout: workoutRepo.lastWorkout, showsAutoWorkout: true, loaded: repo.loaded,
                     showsSyncStatus: true,
                     onChargeTap: { showsChargeDetail = true },
                     onWorkoutTap: { selectedWorkout = WorkoutRef(row: $0) },
                     strainLevel: repo.strainLevel,
                     onStrainTap: { monitorDay = MonitorDayRef(day: $0) },
                     effortCoverage: repo.effortCoverage,
                     showsHabits: true,
                     onHabitsDetailTap: { showsHabitsDetail = true },
                     showsIntake: true,
                     onIntakeDetailTap: { showsIntakeDetail = true },
                     onIntakeEventTap: { day, event in
                         editingIntake = IntakeEditorRef(day: day, event: event)
                     })
            .navigationDestination(isPresented: $showsChargeDetail) {
                ChargeDetailHost(days: repo.days)
            }
            .navigationDestination(isPresented: $showsHabitsDetail) {
                HabitsDetailScreen()
            }
            .navigationDestination(item: $selectedWorkout) { ref in
                WorkoutDetailScreen(row: ref.row, backLabel: "Today")
            }
            .navigationDestination(item: $monitorDay) { ref in
                HealthMonitorScreen(day: ref.day)
            }
            .navigationDestination(isPresented: $showsIntakeDetail) {
                IntakeScreen(backLabel: "Today")
            }
            .sheet(item: $editingIntake) { ref in
                IntakeEventSheet(editing: ref.event, day: ref.day)
            }
            .tint(WM.Ground.ink)
            #if DEBUG
            // 030: the `--weed` seed used to sit in the task below, behind a `showsWeedDetail` @State
            // and a `#if DEBUG` `.navigationDestination` pushing `WeedScreen(backLabel: "Today")`.
            // Both are gone from this file. 029 took the Weed section off Today and the wiring pass
            // above removed the rest of its plumbing, which left that route as the only weed
            // reference on a screen that says nothing about weed — a screenshot photographing a push
            // no user can perform, from a screen no user reaches it from, under a back label naming
            // the wrong origin. The seed now lives on `JournalScreen`, beside the production row that
            // pushes the same screen, so the route an agent photographs is the route a user walks.
            // `--weed` still works on its own: see `DebugFlags.tab` / `DebugFlags.journal` for how it
            // reaches More and pushes Journal first.
            //
            // `--charge-detail` / `--intake` / `--intake-response`: push the detail AFTER first render
            // (a cold-init path seed is dropped by NavigationStack) — screenshot/UI work without
            // tapping through.
            .task {
                if DebugFlags.chargeDetail {
                    showsChargeDetail = true
                }
                if DebugFlags.intake || DebugFlags.intakeResponse {
                    showsIntakeDetail = true
                }
            }
            #endif
    }

    /// The timeline's HR-intensity layer, wired to the store (015 P1). `hrBuckets` is an EXISTING
    /// downsampled read (decision 6 — no new engine, no new read); it runs inside `TodayContent`'s
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
/// (`results.first(where:)?.drivers`) that nothing but this destination consumed — Today's own trio
/// reads its scores off `Repository.days`, never off the engine. `ScoreEngine` is a plain
/// `ObservableObject` that publishes `computing = true` / `computing = false` around every pass, and
/// it does so BEFORE the #836 fingerprint gate can decide the pass had nothing to do, so a fully
/// short-circuited tick still invalidated the app's largest view tree — `TodayContent` is not
/// `Equatable` (it carries closures), and each rebuild re-slices the 120-row prior array and re-folds
/// four trailing means. Two whole-body passes to answer a question nobody on Today was asking.
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
        // of the today column the detail was pushed from — matching ChargeDetailScreen's clamp, which
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
    /// The newest workout, threaded from `WorkoutRepository` so the last-workout row reads the shared
    /// cache (W7).
    var lastWorkout: WorkoutRow? = nil
    /// Host the opt-in `AutoWorkoutRow` (needs the live Repository + WorkoutRepository env — off in
    /// previews).
    var showsAutoWorkout: Bool = false
    /// Whether the repository has finished its first load — gates the Signals empty-state copy so a
    /// still-loading screen shows the four cells rather than flashing the "no data yet" line.
    var loaded: Bool = true
    /// Host the pipeline caption under the date header (012 P2) — env-driven (`LiveState`), off in bare
    /// previews. A Bool rather than a threaded string on purpose: `LiveState` publishes at packet rate,
    /// and threading its verdict through here would re-render the WHOLE Today body on every live beat.
    /// The gate stays cheap and the observation stays inside `TodaySyncCaption`.
    var showsSyncStatus: Bool = false
    var onChargeTap: (() -> Void)? = nil
    var onWorkoutTap: ((WorkoutRow) -> Void)? = nil
    /// Health monitor (007 F2): decoded `strain_level` per day key, threaded from the repo — drives
    /// the heads-up banner between the score trio and Signals (visible at `.mild` and up).
    var strainLevel: [String: StrainLevel] = [:]
    /// The heads-up banner was tapped — the wrapper pushes `HealthMonitorScreen` for the day key.
    var onStrainTap: ((String) -> Void)? = nil
    /// Waking-window capture coverage per day key (`Repository.effortCoverage`). Marks an Effort score
    /// that was ACCUMULATED over materially incomplete data and keeps such days out of the Effort
    /// baseline. Default empty ⇒ nothing is flagged, so previews and pure callers are unchanged.
    var effortCoverage: [String: Double] = [:]
    /// Host the Habits section (008) — env-driven (`HabitsStore`), off in bare previews.
    var showsHabits: Bool = false
    /// The Habits section's "Manage" chevron — the wrapper pushes `HabitsDetailScreen`.
    var onHabitsDetailTap: (() -> Void)? = nil
    /// Host the Intake section (024) — env-driven (`IntakeStore`), off in bare previews. There is no
    /// per-day gate to go with it: unlike Weed this section mounts on every day, because it carries
    /// the only affordance for logging the first entry.
    var showsIntake: Bool = false
    /// The Intake section's chevron — the wrapper pushes `IntakeScreen`.
    var onIntakeDetailTap: (() -> Void)? = nil
    /// An event row (or the log row) was tapped: (day key, the event to edit — nil to create).
    var onIntakeEventTap: ((String, IntakeEvent?) -> Void)? = nil

    /// Days back from the anchor day (0 = today).
    @State private var dayOffset = 0

    /// Metric/Imperial pref → the Skin cell's °C/°F unit + deviation conversion. @AppStorage so the cell
    /// re-renders live the moment Units changes on More.
    @AppStorage(TempUnit.systemKey) private var unitSystem = "metric"

    var body: some View {
        let now = Date()
        // The row "today" resolves to (the #304/#144 resolver), stepped back by the local offset.
        let anchorKey = Repository.anchorKey(days: days, now: now)
        let selectedKey = dayOffset == 0
            ? anchorKey
            : (TodayModel.shiftKey(anchorKey, by: -dayOffset) ?? anchorKey)
        let row = days.last { $0.day == selectedKey }

        // Anchor-day carry (#911 / the v8 rollover-blank fix): today's row is still forming
        // until last night syncs and scores, and an empty trio under "Today" reads as broken. On
        // the anchor day only, Charge / Rest carry the freshest strictly-prior scored values and
        // the signals fall back per-field to the last vitals-bearing day. Effort never carries —
        // it accumulates from midnight, and yesterday's total shown as today would lie. A carried
        // value's baseline is computed before its SOURCE day, never before the anchor: the carried
        // sample must not sit inside its own mean (fabricated "at typical" ticks / zero deltas).
        //
        // Those rules live in ONE place — `WidgetDayResolver.fields` — shared with the widget / watch /
        // Live-Activity glance, so the two surfaces cannot drift apart (#977 shipped exactly that drift
        // when the sequence was written out twice). `allowCarry` is the browsed-history gate: stepping
        // back off the anchor day turns Charge, Rest and the vitals fallback dark together.
        let f = WidgetDayResolver.fields(days: days, restSeries: restSeries,
                                         effortCoverage: effortCoverage,
                                         key: selectedKey, allowCarry: dayOffset == 0)
        // The Charge column is tappable ONLY on the anchor day AND only when it actually shows a value
        // (today's own recovery or a fresh carry). ChargeDetailScreen describes the NEWEST scored day, so
        // letting a browsed past column — or a deliberately-blanked "—" (a >2-day-stale carry the trio
        // withholds) — push it would open a detail that contradicts the column the user tapped.
        let chargeTappable = dayOffset == 0 && (row?.recovery != nil || f.chargeCarriedFrom != nil)

        // A blank Charge column says HOW FAR ALONG the seed is, not merely that it is calibrating
        // (015 P2). Computed only when there IS no number: a scored or carried column captions itself,
        // and short-circuiting here keeps the fold off every normal day's body pass.
        let chargeNote: String? = f.charge == nil
            ? TodayCalibration.note(days: days, through: selectedKey, loaded: loaded,
                                    offsetSec: TimeZone.current.secondsFromGMT())
            : nil

        // P5/P7: slice the strictly-prior rows ONCE per body pass; every trailing-mean below derives
        // from this single slice instead of re-filtering the full `days` array per field.
        let prior = days.filter { $0.day < selectedKey }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The date header and the pipeline caption share a Group for the same reason Signals and
                // the load windows do below — the stack is at ViewBuilder's ten-child ceiling, and a
                // Group is layout-transparent inside a VStack, so nothing about the spacing moves.
                Group {
                    header(selectedKey: selectedKey)

                    // The pipeline's ONE answer (012 P2), and only when it is worth reporting: a
                    // caught-up strap says nothing, so a user whose strap is working never sees this row
                    // at all. It is a CAPTION, not a banner — no icon, no color, no tap target. The
                    // actionable states (Bluetooth off, a strap that needs a restart) are worded by the
                    // ladder itself, and Live is where the controls for them live.
                    if showsSyncStatus {
                        TodaySyncCaption()
                    }
                }

                // Scores + baselines read straight off the shared resolver (see `f` above) — the trio and
                // the widget therefore render the same numbers by construction.
                ScoreTrio(charge: .init(score: f.charge.map(Double.init),
                                        baseline: f.chargeBaseline.map(Double.init),
                                        carriedFrom: f.chargeCarriedFrom.map(TodayModel.shortDayLabel),
                                        calibratingNote: chargeNote),
                          // Effort still shows its real number on a partial day — it is a FLOOR, not a
                          // fabrication — but the column renders provisional and captions "partial
                          // capture", so a 12-hour hole can no longer read as a genuine rest day.
                          // `calibratingNote: nil` on both, deliberately. The note describes the HRV
                          // baseline seeding that suppresses CHARGE specifically (see the field's own
                          // doc); a nil Effort or Rest means the day has no data yet, which is a
                          // different state with no "n of 4" to report.
                          effort: .init(score: f.effort.map(Double.init),
                                        baseline: f.effortBaseline.map(Double.init),
                                        lowCoverage: f.effortLowCoverage,
                                        calibratingNote: nil),
                          rest: .init(score: f.rest.map(Double.init),
                                      baseline: f.restBaseline.map(Double.init),
                                      carriedFrom: f.restCarriedFrom.map(TodayModel.shortDayLabel),
                                      calibratingNote: nil),
                          // Only Charge pushes a detail, and only when it's today AND showing a value —
                          // Effort/Rest and browsed/blank Charge stay inert (no dead buttons, no contradiction).
                          onTap: { _ in if chargeTappable { onChargeTap?() } },
                          tappable: chargeTappable ? [.charge] : [])
                    .padding(.top, WM.Space.sectionTight)

                // Health monitor heads-up (007 F2): only when the engine judged the displayed day
                // mild or louder. One editorial row — warn dot is the sole color (a status, never
                // a wash panel); copy echoes the engine's shipped strings. Tap pushes the detail.
                if let strain = strainLevel[selectedKey], strain >= .mild {
                    strainBanner(level: strain, day: selectedKey)
                        .padding(.top, WM.Space.sectionTight)
                }

                RuleSection("Signals") {
                    signals(row: row, vitalsRow: f.vitalsRow, selectedKey: selectedKey,
                            prior: prior)
                }

                RuleSection("Today") {
                    timeline(selectedKey: selectedKey)
                }

                // Habits (008): current-period rows for the DISPLAYED day + the manage push. Env-driven
                // (HabitsStore) since each verdict derives from the sleep/workout/nap lanes.
                if showsHabits {
                    RuleSection("Habits") {
                        HabitsTodaySection(selectedKey: selectedKey, onOpenDetail: onHabitsDetailTap)
                    }
                }

                // 029: the Journal section moved to More. Today had grown to seven sections, and the
                // chips needed a day stepper of their own anyway — which More's pushed screen now
                // carries. Weed's chip (and its clear-confirmation) travelled with it, and Weed's own
                // page is reachable from the Journal screen unconditionally now.
                //
                // 030: the WIRING followed, late. 029 removed the two sections but left both features
                // plumbed at every other point — eight `TodayContent` arguments the body no longer
                // read, four chip/section builders with no call site, and destinations nothing could
                // reach. That was not merely untidy: `TodayScreen` went on holding `JournalStore` and
                // `WeedStore` as `@EnvironmentObject`s purely to feed those dead arguments, so every
                // tag toggle and every session write re-rendered this whole body, and one of the
                // arguments rebuilt a `Set` of the weed day keys on each pass for a value nobody read.
                // Unlike the Intake block below — whose only entry point was here, which is why its
                // loss was a real defect — nothing became unreachable: Journal opens from More and
                // Weed from Journal, and the clear-confirmation moved to `JournalScreen` intact.

                // Intake (024): the DISPLAYED day's logged meals / caffeine / alcohol / water + the
                // detail push. NOT gated on the day already carrying something, unlike the Weed
                // section that used to sit here: weed's chip created the first session, intake has
                // no chip, so a section that appeared only once an event existed would offer no way
                // to log the first one. 030 restored this block — b1028cc deleted it as collateral
                // while removing Weed, and `showsIntake` stayed wired at both ends, so it built
                // green with the whole feature unreachable from Today.
                if showsIntake {
                    RuleSection("Intake") {
                        IntakeTodaySection(selectedKey: selectedKey,
                                           onEditEvent: { onIntakeEventTap?(selectedKey, $0) },
                                           onOpenDetail: onIntakeDetailTap)
                    }
                }

                // Opt-in "Looks like a workout?" suggestion (gated on the More toggle + a candidate).
                if showsAutoWorkout {
                    AutoWorkoutRow()
                }

                // Last-workout row, if any — pushes the detail.
                if dayOffset == 0, let last = lastWorkout {
                    RuleSection("Last workout") {
                        lastWorkoutRow(last)
                    }
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.top, WM.Space.m)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }

    // MARK: - Header

    @ViewBuilder
    private func header(selectedKey: String) -> some View {
        HStack(spacing: WM.Space.s) {
            Text(TodayModel.headerTitle(key: selectedKey, isToday: dayOffset == 0))
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
            Spacer(minLength: WM.Space.m)
            stepper(systemName: "chevron.left", label: "Previous day",
                    enabled: hasPriorData(before: selectedKey)) { dayOffset += 1 }
            stepper(systemName: "chevron.right", label: "Next day",
                    enabled: dayOffset > 0) { dayOffset -= 1 }
        }
    }

    private func stepper(systemName: String, label: String, enabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? WM.Ground.ink : WM.Ground.inkTertiary.opacity(0.5))
                // ≥44×44 hit region (HIG); the glyph keeps its size, only the invisible box grows.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// Whether ANY earlier data exists to step back to (daily row or Rest score).
    private func hasPriorData(before key: String) -> Bool {
        days.contains { $0.day < key } || restSeries.keys.contains { $0 < key }
    }

    // MARK: - Signals

    @ViewBuilder
    private func signals(row: DailyMetric?, vitalsRow: DailyMetric?, selectedKey: String,
                         prior: [DailyMetric]) -> some View {
        // Today-first per field; `vitalsRow` (anchor day only) fills what today hasn't measured
        // yet. Skin temp never carries (parity with the original — a deviation is only meaningful the night it
        // was measured). Each field's mean is windowed before its SOURCE day, so a carried value is
        // never a sample inside the baseline it's compared against.
        let hrv = row?.avgHrv ?? vitalsRow?.avgHrv
        let rhr = row?.restingHr ?? vitalsRow?.restingHr
        let resp = row?.respRateBpm ?? vitalsRow?.respRateBpm
        let skin = row?.skinTempDevC

        let fallbackKey = vitalsRow?.day ?? selectedKey
        let hrvMean = priorMean(in: prior, selectedKey: selectedKey,
                                before: row?.avgHrv != nil ? selectedKey : fallbackKey, \.avgHrv)
        let rhrMean = priorMean(in: prior, selectedKey: selectedKey,
                                before: row?.restingHr != nil ? selectedKey : fallbackKey) {
            $0.restingHr.map(Double.init)
        }
        let respMean = priorMean(in: prior, selectedKey: selectedKey,
                                 before: row?.respRateBpm != nil ? selectedKey : fallbackKey, \.respRateBpm)
        let skinMean = priorMean(in: prior, selectedKey: selectedKey,
                                 before: selectedKey, \.skinTempDevC)

        // Fresh / strap-less install: no vital has ever been measured. Show one plain-voice line
        // instead of four bare em-dashes (mirrors the Data/Rest empty copy). Only once the repo has
        // loaded — a still-loading screen keeps the cells rather than flashing this.
        //
        // `everMeasured` is what distinguishes a genuine first run from a SYNC GAP. Now that the vitals
        // carry is capped at `carryFreshnessDays` (it used to reach back the whole 120-day window), an
        // established wearer who simply hasn't synced for three days has nil cells too — and telling them
        // "Signals appear after your first synced night" would be plainly false. They get four honest
        // em-dashes instead, matching the score trio directly above.
        let everMeasured = days.contains {
            $0.avgHrv != nil || $0.restingHr != nil || $0.respRateBpm != nil
        }
        if loaded, !everMeasured, hrv == nil, rhr == nil, resp == nil, skin == nil {
            Text("Signals appear after your first synced night.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: WM.Space.m) {
            cell(label: "HRV", unit: "ms",
                 value: hrv.map { String(format: "%.0f", $0) },
                 delta: TodayModel.signalDelta(current: hrv, mean: hrvMean,
                                               rule: .upGood, decimals: 0))
            cell(label: "RHR", unit: "bpm",
                 value: rhr.map(String.init),
                 delta: TodayModel.signalDelta(current: rhr.map(Double.init),
                                               mean: rhrMean, rule: .downGood, decimals: 0))
            cell(label: "Resp", unit: "rpm",
                 value: resp.map { String(format: "%.1f", $0) },
                 delta: TodayModel.signalDelta(current: resp, mean: respMean,
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
                let skinMeanDisp = skinMean.map { TempUnit.delta($0, imperial: imperial) }
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
    /// `prior` (rows before the selected day) so the full `days` array is filtered ONCE per body pass
    /// (P5/P7). Every `cutoff` here is ≤ `selectedKey`, so a carried field just narrows `prior` further
    /// — the population, and thus the mean, is byte-identical to filtering `days` directly.
    private func priorMean(in prior: [DailyMetric], selectedKey: String,
                           before cutoff: String, _ value: (DailyMetric) -> Double?) -> Double? {
        let rows = cutoff == selectedKey ? prior : prior.filter { $0.day < cutoff }
        // `typicalMean`, not `mean`: this feeds every Signals cell's ▲/▼ delta and the Skin verdict, all
        // of which are presented as "vs typical". Bare `mean` called one prior night a 30-day typical.
        return TodayModel.typicalMean(Array(rows.compactMap(value).suffix(30)))
    }

    // MARK: - Timeline

    @ViewBuilder
    private func timeline(selectedKey: String) -> some View {
        if let dayStart = TodayModel.date(fromKey: selectedKey),
           let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) {
            let spans = TodayModel.sleepSpans(sleeps, dayKey: selectedKey,
                                              dayStart: dayStart, dayEnd: dayEnd)
            // The BROWSED day's workouts, clipped to it — the same window the sleep spans and the HR
            // read below take, so all three layers describe the day the header names rather than today.
            let bouts = TodayTimeline.workoutSpans(workouts, dayStart: dayStart, dayEnd: dayEnd)
            // The TimelineStrip is accessibilityHidden (decorative track), so without a spoken equivalent a
            // VoiceOver user finds NOTHING under the "Today" heading on a normal synced day. Summarize the
            // sleep span(s) and the day's workouts as the section's a11y label. The HR shading is left out:
            // it is a continuous texture rather than a set of events, so it has no honest one-sentence
            // equivalent, and the Effort column above already states the day's load as a number.
            let sleepPhrase = spans.isEmpty
                ? "No sleep banked for this day."
                : "Asleep " + spanPhrase(spans)
            let a11ySummary = bouts.isEmpty
                ? sleepPhrase
                : sleepPhrase + ". Workouts " + spanPhrase(bouts)
            VStack(alignment: .leading, spacing: WM.Space.s) {
                // Three of the strip's four layers, each drawn only where the day actually holds one
                // (decision 1): no workout ⇒ no band, no HR ⇒ no shading, never a flat zero row. The
                // fourth (stress ticks) stays unfed on purpose — it needs the DaytimeStress number that
                // was parked by decision, so feeding it here would ship exactly what was declined.
                TimelineLoaded(dayKey: selectedKey, dayStart: dayStart, dayEnd: dayEnd,
                               sleep: spans, workouts: bouts, hrIntensity: hrIntensity)
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

    // MARK: - Health monitor banner (007 F2)

    /// The heads-up row between the score trio and Signals: warn dot + the engine's headline +
    /// the standing disclaimer, chevron pushing the Health Monitor detail.
    private func strainBanner(level: StrainLevel, day: String) -> some View {
        Button { onStrainTap?(day) } label: {
            HStack(spacing: WM.Space.m) {
                Circle()
                    .fill(WM.Semantic.warn)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: WM.Space.xs) {
                    Text(HealthMonitorModel.headline(for: level))
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    Text(IllnessSignalEngine.disclaimerTail)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
                Spacer(minLength: WM.Space.s)
                WMDisclosure()
            }
            .contentShape(Rectangle())
            .padding(.vertical, WM.Space.xs)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Health monitor: \(HealthMonitorModel.headline(for: level))")
    }

    // MARK: - Last workout

    /// One editorial row: sport + when/duration on the left, a strain read in Effort on the right.
    /// Tapping pushes the workout detail in Today's NavigationStack.
    private func lastWorkoutRow(_ row: WorkoutRow) -> some View {
        Button { onWorkoutTap?(row) } label: {
            HStack(spacing: WM.Space.m) {
                VStack(alignment: .leading, spacing: WM.Space.xs) {
                    Text(WorkoutSource.displaySport(row.sport))
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    Text("\(WorkoutFormat.relativeDay(row.startTs)) · \(WorkoutFormat.duration(row))")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
                Spacer(minLength: WM.Space.s)
                if let strain = WorkoutFormat.strainText(row.strain) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(strain)
                            .font(WMType.numeral(26))
                            .foregroundStyle(WM.Domain.effort.color)
                        Text("EFFORT").wmOverline()
                    }
                }
                WMDisclosure()
            }
            .contentShape(Rectangle())
            .padding(.vertical, WM.Space.xs)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Timeline layers (015 P1)

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

    /// The selected day's shading. Empty until the read lands — and empty is equally the honest END
    /// state for a day the strap recorded no HR on, which the strip draws as no shading at all.
    @State private var shading: [Double] = []

    var body: some View {
        TimelineStrip(dayStart: dayStart, dayEnd: dayEnd, sleep: sleep,
                      hrIntensity: shading, workouts: workouts)
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
    /// the visible weight comes from the strip's own 0.04 base wash, not from this number, which
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

/// The caption under a blank Charge column: how far along the HRV seed is, rather than the bare
/// "calibrating" the column has shown since it shipped.
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

    /// The note for a blank Charge column on `selectedKey`, or nil to leave `ScoreTrio`'s shipped bare
    /// "calibrating" (it renders `calibratingNote ?? "calibrating"`).
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
    /// blank column "60 of 4 nights".
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
/// Env-driven (the `HabitsTodaySection` idiom) rather than threaded through
/// `TodayContent`, and for a specific reason: `LiveState` publishes on every packet, so an
/// `@EnvironmentObject` on `TodayScreen` would re-render the whole trio-signals-timeline body at beat
/// rate. Scoping the observation to this one row keeps the churn to one `Text`.
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
/// TodayScreen / TodayContent split).
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
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
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

// 030: `WeedEditRef` and `WeedClearRef` lived here to drive Today's weed editor sheet and its
// clear-confirmation. Both went with the wiring above: `WeedScreen` carries its own editor ref, and
// the confirmation is `JournalWeedClearRef` on `JournalScreen`, where the chip that needs it now is.

// MARK: - Chip flow layout

/// Minimal wrapping flow for the journal tag chips: rows fill left→right and wrap at the proposed
/// width (SwiftUI ships no flow container). Row height follows the tallest chip in the row.
/// 029: internal, not private — the journal chips moved to `JournalScreen` and still need it.
/// 030: which makes `JournalScreen` its ONLY caller — this file declares it and no longer uses it.
struct ChipFlow: Layout {
    var spacing: CGFloat = WM.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let frames = layout(subviews: subviews, width: bounds.width).frames
        for (i, sub) in subviews.enumerated() {
            sub.place(at: CGPoint(x: bounds.minX + frames[i].minX, y: bounds.minY + frames[i].minY),
                      proposal: ProposedViewSize(frames[i].size))
        }
    }

    private func layout(subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x + size.width)
            x += size.width + spacing
        }
        return (frames, CGSize(width: maxX, height: y + rowHeight))
    }
}

// MARK: - Previews

#Preview("Today — light") {
    let d = TodaySpecimen.data
    TodayContent(days: d.days, restSeries: d.rest, sleeps: d.sleeps,
                 workouts: TodaySpecimen.workouts,
                 hrIntensity: .fixed(TodaySpecimen.hrIntensity))
        .preferredColorScheme(.light)
}

#Preview("Today — dark") {
    let d = TodaySpecimen.data
    TodayContent(days: d.days, restSeries: d.rest, sleeps: d.sleeps,
                 workouts: TodaySpecimen.workouts,
                 hrIntensity: .fixed(TodaySpecimen.hrIntensity))
        .preferredColorScheme(.dark)
}

// The timeline with only the layers a bare day HOLDS: sleep, and nothing else. The gap where the
// other two would be IS the state — no workout band, no shading, no grey bar at zero.
#Preview("Today — timeline, no workout or HR") {
    let d = TodaySpecimen.data
    TodayContent(days: d.days, restSeries: d.rest, sleeps: d.sleeps,
                 workouts: [], hrIntensity: .none)
        .preferredColorScheme(.light)
}

#Preview("Today — calibrating") {
    TodayContent(days: [], restSeries: [:], sleeps: [], workouts: [], hrIntensity: .none)
        .preferredColorScheme(.light)
}

// The cold-start Charge column PART-WAY through its seed (015 P2): two of the four nights the gate
// wants, so the blank column captions "2 of 4 nights" rather than a bare "calibrating". Effort and
// Rest stay bare on purpose — nothing knows how far along THEY are, and inventing a denominator for
// them would be a number the data does not support.
#Preview("Today — calibrating, 2 of 4 nights") {
    TodayContent(days: TodaySpecimen.coldStart, restSeries: [:], sleeps: [],
                 workouts: [], hrIntensity: .none)
        .preferredColorScheme(.light)
}

#Preview("Today — calibrating, 2 of 4 nights, dark") {
    TodayContent(days: TodaySpecimen.coldStart, restSeries: [:], sleeps: [],
                 workouts: [], hrIntensity: .none)
        .preferredColorScheme(.dark)
}

// 030: `#Preview("Today — journal")` is gone. It had been rendering nothing since 029 moved the
// section off this screen — a preview whose subject does not exist is worse than no preview, because
// it reads as coverage. `JournalScreen` owns the chips and their previews now.

#Preview("Today — sync caption, light") {
    TodaySyncCaptionSpecimen().preferredColorScheme(.light)
}

#Preview("Today — sync caption, dark") {
    TodaySyncCaptionSpecimen().preferredColorScheme(.dark)
}

#Preview("Today — health monitor banner") {
    let d = TodaySpecimen.data
    TodayContent(days: d.days, restSeries: d.rest, sleeps: d.sleeps,
                 workouts: [], hrIntensity: .none,
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
    /// a morning lift and an evening run.
    static let workouts: [WorkoutRow] = {
        let day0 = Calendar.current.startOfDay(for: Date())
        func row(startHour: Double, minutes: Int, sport: String) -> WorkoutRow {
            let start = Int(day0.timeIntervalSince1970) + Int(startHour * 3600)
            return WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: sport,
                              source: "manual", durationS: Double(minutes * 60), energyKcal: nil,
                              avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                              zonesJSON: nil, notes: nil)
        }
        return [row(startHour: 7.5, minutes: 45, sport: "Lifting"),
                row(startHour: 18, minutes: 55, sport: "Running")]
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
    /// carrying real HRV and no recovery. Two of `Baselines.minNightsSeed`, so the trio's Charge column
    /// is genuinely blank and the note has a real count to print.
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
