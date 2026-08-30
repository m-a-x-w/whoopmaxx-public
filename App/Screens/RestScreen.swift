import SwiftUI
import StrapStore
import StrapAnalytics

/// The Rest tab (037, "Line"): the header names the night and carries the ‹ › night stepper; then
/// the night's hours asleep as the hero numeral on its need line, the Rest score line, "Stages"
/// (hypnogram + stage columns), "Timing", and the "Night detail" row that pushes the raw-stream reads
/// (movement, why you woke, wrist orientation). Naps when there were any, "Tonight" (bedtime + wake
/// window, newest night only) and "Trend" (regularity + the 14-night duration line) close it.
struct RestScreen: View {
    @EnvironmentObject private var repo: Repository

    /// Everything the screen derives from the repository, recomputed only on a real data change (see the
    /// `.task(id:)` below). nil until the first pass lands.
    @State private var derived: Derived?

    /// The night being browsed (014), or nil for the newest — Rest's twin of Today's `dayOffset`, with
    /// `nil` carrying the same meaning `dayOffset == 0` does there. A day KEY rather than an offset
    /// because nights are sparse: stepping a calendar day back off a night lands on days the strap never
    /// recorded, and Rest has nothing to say about those. Browsing is READ-ONLY — this changes what is
    /// derived for display, never what is stored.
    @State private var selectedKey: String?

    /// Night detail is pushed from its row (037), replacing the old tap-the-hero push to Movement.
    @State private var showsNightDetail = false
    #if DEBUG
    /// `--night-detail` pushes once, not on every refresh.
    @State private var seededNightDetail = false
    #endif

    /// One pass's worth of derived state, written as ONE value so a render can never see the ledger of
    /// one night beside the hero, the flagged count or the stepper population of another.
    private struct Derived {
        let assembly: RestModel.Assembly
        /// The browse population, oldest → newest (`Assembly.slept` keys).
        let nights: [String]
        /// The rendered night as a `RestNight` — built from the Assembly's OWN selected row (014), never
        /// from a second pick, so the hero, the stages and Night detail cannot describe different nights.
        let night: RestNight?
        /// The displayed day's credited nap minutes.
        let napMin: Double
        /// How many nights in the CURRENT debt window the stager flagged (016). It resolves a main-night
        /// group per window night, which must never run on a SwiftUI frame, so it is derived here with the
        /// Assembly.
        let lowConfidenceNights: Int
        /// "Mon 28 – Tue 29" for the rendered night.
        let nightSpan: String?
    }

    var body: some View {
        Group {
            if let derived {
                content(derived)
            } else {
                // Nothing derived yet (first frame): the empty screen, not a half-derived one.
                // `loaded: false` shows the header alone rather than claiming "No sleep recorded"
                // about data we haven't read.
                RestScreenContent(loaded: false, lastNight: nil,
                                  balanceMin: 0, debtNights: 0, lowConfidenceNights: 0, history: [])
            }
        }
        // The whole derivation (a `repo.days` filter, the personal-need pass, the nap-credited
        // `SleepDebt.ledger`, the debt-window nap classification, the night's main-sleep group and its
        // decoded hypnogram) runs here and never in `body`. Repository republishes `hrWatermark` on raw-HR
        // growth WITHOUT bumping `refreshSeq` (the P5 split that keeps the workout detector off every sync
        // tick) — but an observed `@EnvironmentObject` re-renders on ANY publish, so a derivation in `body`
        // re-ran on every watermark move during a sync, for data Rest never reads. `refreshSeq` is the
        // correct gate: Repository publishes days / sleeps / restSeries / napSeries / habitualMidsleepSec
        // together with it.
        //
        // The selected night joins the id: every number here is derived AS OF that night, so moving the
        // browse has to re-run the pass. The previous derivation stays on screen while it does, which is
        // why stepping doesn't flash empty.
        .task(id: "\(repo.refreshSeq)|\(selectedKey ?? "")") {
            #if DEBUG
            // `--rest-night n` opens already browsed, so the honest states that exist only on an older
            // night can be photographed rather than reached by a dozen taps. Applied once, and only
            // while nothing is selected, so it SEEDS the browse instead of pinning it: every chevron
            // and strip tap afterwards behaves exactly as in a release build.
            if selectedKey == nil, let back = DebugFlags.restNight, back > 0 {
                let slept = repo.days.filter { $0.totalSleepMin != nil }
                if slept.count > back { selectedKey = slept[slept.count - 1 - back].day }
            }
            #endif
            let a = RestModel.assemble(days: repo.days,
                                       restSeries: repo.restSeries,
                                       sleeps: repo.sleeps,
                                       napSeries: repo.napSeries,
                                       habitualMidsleepSec: repo.habitualMidsleepSec,
                                       selectedKey: selectedKey,
                                       daysWindowFloor: repo.daysWindowFloor)
            // The whole main-night GROUP, via the shared selector — a bridged night's stage columns,
            // hypnogram and bed/wake must describe the same blocks the hero's Asleep total was summed from.
            let night = a.lastDay.map { day in
                RestNight(day: day,
                          score: repo.restSeries[day.day],
                          sessions: RestNight.sessions(for: day, in: repo.sleeps,
                                                       habitualMidsleepSec: repo.habitualMidsleepSec))
            }
            derived = Derived(
                assembly: a,
                nights: a.slept.map(\.day),
                night: night,
                napMin: a.lastDay.flatMap { repo.napSeries[$0.day] } ?? 0,
                // Over the ledger's OWN nights (the ones it actually counted), never a fresh 14-night
                // cut — the caption has to be about the balance beside it.
                lowConfidenceNights: RestNight.lowConfidenceNightCount(
                    dayKeys: a.ledger.nights.map(\.day), sleeps: repo.sleeps,
                    habitualMidsleepSec: repo.habitualMidsleepSec),
                nightSpan: RestBrowse.nightSpan(key: a.lastDay?.day))
            #if DEBUG
            // `--night-detail`: push once the first derivation lands (a cold-init push is dropped by
            // NavigationStack, and the destination needs `derived.night`).
            if DebugFlags.nightDetail, !seededNightDetail, derived?.night != nil {
                seededNightDetail = true
                showsNightDetail = true
            }
            #endif
        }
        .navigationDestination(isPresented: $showsNightDetail) {
            if let derived, let night = derived.night {
                NightDetailScreen(night: night, session: derived.assembly.lastSession,
                                  subtitle: derived.nightSpan)
            }
        }
    }

    private func content(_ d: Derived) -> some View {
        let a = d.assembly
        // The night actually ON SCREEN, not the raw selection: a stale key falls back to the newest
        // (`RestModel.selectedNight`), and the header, the two arrows and the forward-looking gate all have
        // to describe what is rendered rather than what was asked for. The population is every night in
        // the record — bounded by the DATA and not by a constant (014 decision 9), so the back arrow dies
        // on the oldest night there is and the forward one on the newest.
        let current = a.lastDay?.day
        let previous = RestBrowse.previousKey(from: current, in: d.nights)
        let next = RestBrowse.nextKey(from: current, in: d.nights)
        let isNewest = RestBrowse.isNewest(key: current, in: d.nights)
        let newest = d.nights.last
        return RestScreenContent(
            loaded: repo.loaded,
            lastNight: d.night,
            typicalBand: a.typicalBand,
            needMin: a.needMin,
            napMin: d.napMin,
            balanceMin: a.ledger.balanceMin,
            debtNights: a.ledger.nightCount,
            lowConfidenceNights: d.lowConfidenceNights,
            windowNapMin: a.windowNapMin,
            windowNapCount: a.napRows.count,
            history: a.history,
            nightTitle: RestBrowse.headerTitle(key: current, isNewest: isNewest),
            nightSpan: d.nightSpan,
            canStepBack: previous != nil,
            canStepForward: next != nil,
            onStepBack: { browse(to: previous, newest: newest) },
            onStepForward: { browse(to: next, newest: newest) },
            // The strip IS the navigation (decision 6, "tap night"): it hands back its own
            // bar's day key, which lands here unread — the strip already knows which night it drew.
            onNightTap: { browse(to: $0, newest: newest) },
            onOpenNightDetail: d.night == nil ? nil : { showsNightDetail = true },
            // The two-process bedtime — forward-looking guidance, injected so RestScreenContent stays
            // pure/previewable. `OptimalBedtimeArmed` owns the BodyClockEngine (cached per day). At the
            // NEWEST night only (014 decision 4 — the rule Today already applies with its carry gate): over
            // a night from March it would be advice about a night that is already over.
            bedtime: isNewest ? AnyView(OptimalBedtimeArmed()) : nil,
            // Recent nap rows over the debt window (007 F3), each dated — nil when the window had no naps
            // so the section vanishes entirely.
            naps: a.napRows.isEmpty ? nil : AnyView(NapSection(naps: a.napRows)),
            // The wake-window row (W9). The strap backstop can only be armed over a genuine encrypted
            // bond; the sim has none, so this honestly reads "Backup notification only". P7: the LiveState
            // observation (`connected`) and the coordinator's `backstop` live inside `WakeWindowArmed` so
            // their churn re-renders only that small subview, not the whole Rest screen. Newest night only
            // for the same reason the bedtime is (decision 4), with one more of its own: it carries an ARM
            // control, and a browsed night must not offer to schedule anything.
            wakeWindow: isNewest ? AnyView(WakeWindowArmed()) : nil,
            // The multi-night sleep-regularity reading (011 W2.1). A pure VALUE, not an injected AnyView:
            // `RestModel.assemble` already derives it off the frame path in the same pass as the ledger.
            regularity: a.regularity
        )
    }

    // MARK: - Browse (014 P2)

    /// Move the browse onto `key` — the one mutation the stepper and the strip share, so the two
    /// gestures cannot end up meaning different things.
    ///
    /// Landing on the newest night RELEASES the selection back to nil rather than pinning that key: nil is
    /// what "the newest night" means to `RestModel.assemble`, so a night that syncs overnight carries the
    /// screen forward instead of stranding it on the key that used to be the newest. The two are otherwise
    /// the same screen — `RestBrowseTests.testSelectingTheNewestReproducesTheDefault` pins that.
    ///
    /// A nil key means there was no night to step to, and is a no-op: an arrow that is disabled but somehow
    /// fires must not silently jump to the newest night. Browsing is READ-ONLY (decision 2) — this sets one
    /// piece of view state and nothing else.
    private func browse(to key: String?, newest: String?) {
        guard let key else { return }
        selectedKey = key == newest ? nil : key
    }
}

// MARK: - Browse math

/// Pure browse math behind Rest's night stepper (014 P2): which night is one step back or forward, whether
/// the screen is on the newest, and what the header calls the night it is on. Values in, values out — the
/// state lives on `RestScreen` and the tests drive these directly.
///
/// The population is NIGHTS, not calendar days. Today steps by calendar day (`TodayModel.shiftKey`) because
/// Today has something to say about every day; Rest does not — stepping a day back off a night lands on the
/// days the strap recorded no night for, and the screen would have nothing but em-dashes to show for them.
/// So these walk the record itself (`RestModel.Assembly.slept`, oldest → newest, unique by day per
/// `Repository.mergeDaily`), and a gap in it is simply skipped.
enum RestBrowse {

    /// The night one step BACK: the newest night strictly older than `key`. nil at the oldest night in the
    /// record, which is what disables the back arrow (decision 9 — bounded by the data, never a dead arrow
    /// into an empty screen).
    ///
    /// Compared by key rather than by index: `yyyy-MM-dd` sorts chronologically, so this is correct even if
    /// the selection is a key the list no longer holds.
    static func previousKey(from key: String?, in nights: [String]) -> String? {
        guard let key else { return nil }
        return nights.last { $0 < key }
    }

    /// The night one step FORWARD: the oldest night strictly newer than `key`. nil at the newest night.
    static func nextKey(from key: String?, in nights: [String]) -> String? {
        guard let key else { return nil }
        return nights.first { $0 > key }
    }

    /// Whether the night on screen is the newest one there is — the gate for everything FORWARD-LOOKING
    /// (decision 4: optimal bedtime, the wake window).
    ///
    /// It takes the RESOLVED night, never "is a key selected": a stale selection falls back to the newest
    /// night (`RestModel.selectedNight`), and gating on the selection would then hide tonight's bedtime
    /// under a screen that is in fact showing last night. An empty record answers true — nothing has been
    /// browsed away from, and a fresh install keeps the forward-looking sections it has always had.
    static func isNewest(key: String?, in nights: [String]) -> Bool {
        key == nights.last
    }

    /// The header title for the night on screen — `TodayModel.headerTitle(key:isToday:)`'s idiom in Rest's
    /// units: the relative name while it is TRUE, the night's own date ("Sat 12 Jul") once it is not.
    /// "Last night" printed over a night from March is exactly the quiet false claim this wave exists to
    /// remove.
    static func headerTitle(key: String?, isNewest: Bool) -> String {
        if isNewest { return "Last night" }
        guard let key else { return "Last night" }
        guard let date = RestFormat.date(fromDayKey: key) else { return key }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// The header's subtitle (037): the night as the two days it spans, "Mon 28 – Tue 29" — the
    /// evening before the night's key and the key's own morning (a night keyed D begins on the evening of
    /// D−1). nil when there is no key or it will not parse, which leaves the header without a subtitle
    /// rather than printing a key at the reader.
    static func nightSpan(key: String?) -> String? {
        guard let key, let morning = RestFormat.date(fromDayKey: key),
              let evening = Calendar.current.date(byAdding: .day, value: -1, to: morning) else { return nil }
        let style = Date.FormatStyle.dateTime.weekday(.abbreviated).day()
        return "\(evening.formatted(style)) \u{2013} \(morning.formatted(style))"
    }
}

/// P7: the wake-window section, isolated so its `LiveState` observation (only `connected`, for the
/// Test-buzz button) and the coordinator's `@Published backstop` re-render THIS small subview instead
/// of all of RestScreen. It reads the alarm settings + readback-verified backstop state and re-arms on Apply.
private struct WakeWindowArmed: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var alarm: SmartAlarmCoordinator
    @EnvironmentObject private var buzzLog: BuzzLog

    var body: some View {
        WakeWindowSection(settings: alarm.settings,
                          // Not `live.encryptedBond`: a bond is necessary but not sufficient. The
                          // coordinator only reports .verified once the strap has echoed the armed
                          // epoch back (GET_ALARM_TIME readback), and `.armedOnStrap` copy promises a
                          // buzz that fires with the app closed. `.confirming` is the in-between:
                          // sent, echo pending. `armState` already guards on settings.enabled.
                          strapArmed: alarm.backstop == .verified,
                          strapConfirming: alarm.backstop == .confirming,
                          onApply: { alarm.apply() },
                          canTestBuzz: live.connected,
                          onTestBuzz: {
                              alarm.testBuzz()
                              // Record the test like every other app-sent buzz — the coordinator's
                              // onBuzz sink is reserved for real wakes, so the call site logs it.
                              buzzLog.record(source: .test, label: "Test buzz")
                          })
    }
}

/// Pure render of the Rest screen — everything derived, nothing observed (previewable without a
/// live Repository). Top to bottom: header + stepper, the Asleep hero on its need line, the Rest score
/// line, "Stages", "Timing", the "Night detail" row, naps, "Tonight", "Trend".
struct RestScreenContent: View {
    let loaded: Bool
    let lastNight: RestNight?
    /// The Rest score's typical range in score points (`RestModel.Assembly.typicalBand`) — the pale band
    /// on the score line and its "typical a–b" subtitle. nil draws neither.
    var typicalBand: ClosedRange<Double>? = nil
    var needMin: Double = 480
    /// The displayed day's credited nap minutes (007 F3) — named beside the need, never drawn into it.
    var napMin: Double = 0
    /// Net `SleepDebt.ledger` balance over the trailing window (negative = debt).
    let balanceMin: Double
    /// Nights that actually contributed to the ledger (wear-gap nights skipped).
    let debtNights: Int
    /// Nights in that same window the stager kept but FLAGGED as longer than a night can be (016).
    /// 0 = an ordinary window.
    ///
    /// REQUIRED, deliberately no default, and for the reason this project has now watched three times:
    /// a defaulted honesty argument that the one production call site forgets to pass is a green build,
    /// green tests, and the feature absent from the binary. The debt line is the surface that must
    /// receive it to be honest, so the compiler checks every caller instead of a reviewer.
    let lowConfidenceNights: Int
    /// Total credited nap minutes over the debt window, and how many naps made them up — named on the
    /// debt line so prior nights' naps (which reduce the balance but have no rows on a today-only view)
    /// aren't invisible.
    var windowNapMin: Double = 0
    var windowNapCount: Int = 0
    let history: [RestHistoryStrip.Night]
    /// The header title (014 P2): "Last night" at the newest, the night's own date once you have stepped
    /// back — `RestBrowse.headerTitle`. "Last night" printed over a night from March is exactly the quiet
    /// false claim the browse removed.
    var nightTitle: String = "Last night"
    /// The header subtitle, "Mon 28 – Tue 29" (`RestBrowse.nightSpan`). Shown only over a real night.
    var nightSpan: String? = nil
    /// Whether an older / newer night exists to step to. Both default false, so a caller that knows
    /// nothing about a record renders two inert arrows rather than promising navigation it can't do.
    var canStepBack: Bool = false
    var canStepForward: Bool = false
    var onStepBack: (() -> Void)? = nil
    var onStepForward: (() -> Void)? = nil
    /// A night in the duration line was tapped (014 P2), by its own day key. nil leaves the line inert.
    var onNightTap: ((String) -> Void)? = nil
    /// Push Night detail. nil hides the row — a row that opens nothing would be a promise the screen
    /// can't keep.
    var onOpenNightDetail: (() -> Void)? = nil
    /// The "Bedtime" row under "Tonight", injected so this content stays previewable. nil when the night
    /// on screen is not the newest.
    var bedtime: AnyView? = nil
    /// The debt window's nap rows (007 F3), injected so this content stays previewable. nil when the
    /// window had no naps (the section vanishes).
    var naps: AnyView? = nil
    /// The "Wake window" row under "Tonight" (W9), injected so this content stays previewable without a
    /// live coordinator. nil when the night on screen is not the newest.
    var wakeWindow: AnyView? = nil
    /// The Sleep Regularity Index reading (011 W2.1), derived by `RestModel.assemble`. A pure value rather
    /// than an injected AnyView — it needs no Repository, so the previews drive it. nil hides it.
    var regularity: SleepRegularity.Outcome? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let lastNight {
                    hero(lastNight)
                        .padding(.top, WM.Space.sectionTight)
                    scoreLine(lastNight)
                        .padding(.top, WM.Space.sectionTight)
                    stages(lastNight)
                    timing(lastNight)
                    nightDetailRow
                } else if loaded {
                    Text("No sleep recorded")
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.inkSecondary)
                        .padding(.top, WM.Space.sectionTight)
                }
                if let naps {
                    naps
                }
                tonight
                trend
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.top, WM.Space.s)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }

    // MARK: - Header

    /// The night's name over the two days it spans, with the prev/next stepper trailing. The subtitle
    /// appears only over a real night: a record with nothing in it gets the bare title rather than a
    /// span for a night that was never recorded.
    private var header: some View {
        TabHeader(nightTitle, subtitle: lastNight == nil ? nil : nightSpan) {
            stepper(systemName: "chevron.left", label: "Previous night",
                    enabled: canStepBack) { onStepBack?() }
            stepper(systemName: "chevron.right", label: "Next night",
                    enabled: canStepForward) { onStepForward?() }
        }
    }

    /// The night stepper's button: the `.nav` chrome glyph in inkSecondary when live and dimmed when
    /// not, in a 44×44 hit region the glyph does not grow into.
    private func stepper(systemName: String, label: String, enabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(WMType.icon(.nav))
                .foregroundStyle(enabled ? WM.Ground.inkSecondary : WM.Ground.inkTertiary.opacity(0.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: - Hero

    /// Hours asleep as the 96 pt hero, bed–wake as its reading, the need line under it, and — on a night
    /// the stager kept but FLAGGED (016) — the caveat closing the block. On such a night the numeral takes
    /// the provisional treatment (secondary ink, no new colour, no icon): the flag is about how long the
    /// recording ran, which is what this numeral is read off. The caveat is the night's OWN
    /// (`RestNight.lowConfidenceCaption`), so it follows the browse and cannot caveat a different night.
    /// One combined element, so VoiceOver speaks the caveat with the numeral it qualifies.
    private func hero(_ night: RestNight) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.l) {
            HeroReadout(value: night.asleepMin.map(RestFormat.hmm) ?? "\u{2014}",
                        title: "Asleep",
                        subtitle: bedWakeSpan(night),
                        color: night.lowConfidence ? WM.Ground.inkSecondary : WM.Ground.ink,
                        size: 96)
            // `isNewest` is DERIVED from the stepper rather than passed beside it: there is a newer night to
            // step to exactly when this is not the newest one. A separate field could drift from the
            // arrows, and then the debt line's window and the navigation would tell two different stories.
            SleepNeedLine(needMin: needMin, asleepMin: night.asleepMin, napMin: napMin,
                          balanceMin: balanceMin, debtNights: debtNights,
                          windowNapMin: windowNapMin, windowNapCount: windowNapCount,
                          // The ledger's flagged nights, landing WITH the hero caveat below (016 decision
                          // 3): a hero that caveats while this line silently banks the surplus would be
                          // trusted more, not less.
                          lowConfidenceNights: lowConfidenceNights,
                          isNewest: !canStepForward)
            if let caveat = night.lowConfidenceCaption {
                Text(caveat)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "11:06 PM – 6:47 AM", or nil when either end is unknown.
    private func bedWakeSpan(_ night: RestNight) -> String? {
        guard let bed = night.bed, let wake = night.wake else { return nil }
        return "\(WMFormat.timeOfDay(bed)) \u{2013} \(WMFormat.timeOfDay(wake))"
    }

    // MARK: - Score

    /// The Rest score on its line: the dot at the score, the pale band over the 30 prior nights' IQR
    /// (`typicalBand`, derived with the typical in `RestModel.assemble`). A nil score — not scored yet —
    /// draws "—" over the bare track.
    private func scoreLine(_ night: RestNight) -> some View {
        ScoreLine(title: "Rest",
                  subtitle: typicalBand.map {
                      "typical \(Int($0.lowerBound.rounded()))\u{2013}\(Int($0.upperBound.rounded()))"
                  },
                  value: night.score.map { "\(Int($0.rounded()))" } ?? "\u{2014}",
                  fraction: night.score.map { min(max($0 / 100, 0), 1) },
                  band: typicalBand.map { ($0.lowerBound / 100)...($0.upperBound / 100) },
                  domain: .rest)
    }

    // MARK: - Stages

    /// The hypnogram over the four stage columns. Hidden when the night carries neither a timeline nor
    /// a single stage total, rather than labelling nothing.
    @ViewBuilder
    private func stages(_ night: RestNight) -> some View {
        let columns = StageColumns(deepMin: night.deepMin, remMin: night.remMin,
                                   lightMin: night.lightMin, wakeMin: night.wakeMin)
        if !night.segments.isEmpty || !columns.isEmpty {
            RuleSection("Stages") {
                VStack(alignment: .leading, spacing: WM.Space.l) {
                    if !night.segments.isEmpty {
                        StepHypnogram(segments: night.segments)
                    }
                    if !columns.isEmpty {
                        columns
                    }
                }
            }
        }
    }

    // MARK: - Timing

    /// Efficiency, bed and wake as three readouts on one row; bed and wake set the day period as a unit.
    private func timing(_ night: RestNight) -> some View {
        let efficiency = night.efficiency.map { "\(Int($0.rounded()))" }
        return RuleSection("Timing", topGap: WM.Space.sectionTight) {
            HStack(alignment: .top, spacing: WM.Space.s) {
                SignalCell(label: "Efficiency", value: efficiency ?? "\u{2014}",
                           unit: efficiency == nil ? nil : "%", valueSize: 24, fillsWidth: true)
                clockCell(label: "Bed", date: night.bed)
                clockCell(label: "Wake", date: night.wake)
            }
        }
    }

    private func clockCell(label: String, date: Date?) -> some View {
        let parts = date.map { RestFormat.clockParts($0) }
        return SignalCell(label: label, value: parts?.time ?? "\u{2014}", unit: parts?.period,
                          valueSize: 24, fillsWidth: true)
    }

    // MARK: - Night detail

    @ViewBuilder
    private var nightDetailRow: some View {
        if let onOpenNightDetail {
            WMNavRow(title: "Night detail",
                     subtitle: "Movement \u{00B7} why you woke \u{00B7} wrist orientation",
                     hint: "Opens the night's movement, awakenings and wrist orientation",
                     action: onOpenNightDetail)
                .padding(.top, WM.Space.l)
        }
    }

    // MARK: - Tonight

    /// Forward-looking rows for the newest night only: bedtime, then the wake window with its switch
    /// (and, when enabled, its controls inline below). Absent entirely on a browsed night.
    @ViewBuilder
    private var tonight: some View {
        if bedtime != nil || wakeWindow != nil {
            RuleSection("Tonight") {
                VStack(alignment: .leading, spacing: 0) {
                    if let bedtime {
                        bedtime
                    }
                    if bedtime != nil, wakeWindow != nil {
                        WMRule()
                    }
                    if let wakeWindow {
                        wakeWindow
                    }
                }
            }
        }
    }

    // MARK: - Trend

    /// The record rather than the night: Regularity on its line, then hours asleep across the last 14
    /// nights against the dashed need. Both end on the night on screen.
    @ViewBuilder
    private var trend: some View {
        if regularity != nil || history.count >= 2 {
            RuleSection("Trend") {
                VStack(alignment: .leading, spacing: WM.Space.sectionTight) {
                    if regularity != nil {
                        RegularitySection(outcome: regularity, isNewest: !canStepForward)
                    }
                    if history.count >= 2 {
                        RestHistoryStrip(nights: history, needMin: needMin, onSelect: onNightTap)
                    }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("RestScreen — light") {
    RestScreenSpecimen().preferredColorScheme(.light)
}

#Preview("RestScreen — dark") {
    RestScreenSpecimen().preferredColorScheme(.dark)
}

#Preview("RestScreen — browsed, light") {
    RestScreenSpecimen(browsed: true).preferredColorScheme(.light)
}

#Preview("RestScreen — browsed, dark") {
    RestScreenSpecimen(browsed: true).preferredColorScheme(.dark)
}

#Preview("RestScreen — empty") {
    RestScreenContent(loaded: true, lastNight: nil,
                      balanceMin: 0, debtNights: 0, lowConfidenceNights: 0, history: [])
}

#Preview("RestScreen — flagged night, light") {
    RestScreenSpecimen(flagged: true).preferredColorScheme(.light)
}

#Preview("RestScreen — flagged night, dark") {
    RestScreenSpecimen(flagged: true).preferredColorScheme(.dark)
}

private struct RestScreenSpecimen: View {
    /// Stepped back off the newest night (014 P2): the header names the night instead of calling it
    /// "Last night", both arrows are live, and "Tonight" is gone. The default specimen is the newest
    /// night, where the forward arrow is dead — a stepper that never disables is as wrong as one that
    /// never moves, so the pair of previews shows both ends.
    var browsed = false
    /// The night the stager kept but flagged (016): the Asleep numeral goes secondary, the caveat closes
    /// the hero, and the debt note names the window's one flagged night. The default specimen is a
    /// CONFIDENT night — the pair of previews shows both, so a caveat that always shows is as visible
    /// here as one that never does.
    var flagged = false

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var night: RestNight {
        // Mirrors DemoSeed's cycle shape: light→deep→light→rem→deep→light→rem→wake.
        let onset = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-45 * 60) // 23:15
        let plan: [(stage: Int, minutes: Double)] = [
            (2, 48), (3, 52), (2, 40), (1, 34), (3, 30), (2, 44), (1, 26), (0, 9)
        ]
        var t = onset
        let segments = plan.map { p -> (start: Date, end: Date, stage: Int) in
            let s = t
            t = t.addingTimeInterval(p.minutes * 60)
            return (start: s, end: t, stage: p.stage)
        }
        let asleep = plan.filter { $0.stage != 0 }.reduce(0) { $0 + $1.minutes }
        return RestNight(
            dayKey: Self.dayFmt.string(from: Date()),
            score: 58, asleepMin: asleep, efficiency: 93,
            bed: onset, wake: t, segments: segments,
            deepMin: 82, remMin: 60, lightMin: 132, wakeMin: 9,
            // 17 h 12 min of recorded stretch — deliberately unlike the 4:34 `asleep` numeral beside
            // it, which is the whole point: the caveat quotes the SPAN the cap gated on, never the
            // staged total.
            lowConfidenceSpanS: flagged ? 61_920 : nil
        )
    }

    private var history: [RestHistoryStrip.Night] {
        let cal = Calendar.current
        return (0..<14).map { i in
            let date = cal.date(byAdding: .day, value: i - 13, to: cal.startOfDay(for: Date()))!
            let minutes = 430 + 55 * sin(Double(i) / 2.2) + Double((i * 37) % 29)
            return RestHistoryStrip.Night(dayKey: Self.dayFmt.string(from: date), minutes: minutes)
        }
    }

    /// Eleven deterministic comparisons — the shape a 14-night window with one unbanked night in it
    /// produces (that night takes both of its pairs with it).
    private var regularity: SleepRegularity.Outcome {
        let cal = Calendar.current
        let agreements = [1288, 1210, 1332, 1265, 1180, 1301, 1244, 1156, 1290, 1318, 1223]
        let pairs = agreements.enumerated().map { i, a in
            // Calendar-stepped, not i × 86 400 s: a 25 h day would otherwise let two offsets land on
            // one key and collide the ForEach ids.
            let date = cal.date(byAdding: .day, value: i - 10, to: cal.startOfDay(for: Date()))!
            return SleepRegularity.Pair(dayKey: Self.dayFmt.string(from: date),
                                        agreeing: a, compared: SleepRegularity.slotsPerDay)
        }
        return .reading(SleepRegularity.Reading(
            sri: SleepRegularity.index(agreeing: agreements.reduce(0, +),
                                       compared: agreements.count * SleepRegularity.slotsPerDay),
            pairs: pairs, nightsUsable: 13, nightsConsidered: 14))
    }

    var body: some View {
        // Through the production formatters, off a key from the specimen's own strip — a preview that
        // hand-wrote its date could drift from what the screen prints.
        let key = browsed ? history.first?.dayKey : history.last?.dayKey
        let settings = SmartAlarmSettings(defaults: UserDefaults(suiteName: "wm.preview.rest")!)
        settings.enabled = true
        return NavigationStack {
            RestScreenContent(loaded: true, lastNight: night, typicalBand: 62...74,
                              napMin: 25, balanceMin: -144, debtNights: 14,
                              lowConfidenceNights: flagged ? 1 : 0, history: history,
                              nightTitle: RestBrowse.headerTitle(key: key, isNewest: !browsed),
                              nightSpan: RestBrowse.nightSpan(key: key),
                              canStepBack: true, canStepForward: browsed,
                              onOpenNightDetail: {},
                              bedtime: browsed ? nil
                                  : AnyView(OptimalBedtimeSection(recommendation: .freeSpecimen)),
                              wakeWindow: browsed ? nil
                                  : AnyView(WakeWindowSection(settings: settings, strapArmed: true,
                                                              onApply: {})),
                              regularity: regularity)
        }
    }
}
