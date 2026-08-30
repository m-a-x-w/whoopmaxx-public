import SwiftUI
import StrapStore
import StrapAnalytics

/// The Rest tab — last night first (score + duration numerals, hypnogram, stage totals,
/// need-vs-actual + debt, efficiency + timings), then the 14-night duration history.
/// Open editorial: content sits on `ground`, sections are eyebrow + rule.
struct RestScreen: View {
    @EnvironmentObject private var repo: Repository

    /// The derived read-set (see `RestModel`), recomputed only on a real data change. nil until the
    /// first pass lands.
    @State private var assembly: RestModel.Assembly?

    /// The night being browsed (014), or nil for the newest — Rest's twin of Today's `dayOffset`
    /// (`TodayScreen.swift:198`), with `nil` carrying the same meaning `dayOffset == 0` does there.
    /// A day KEY rather than an offset because nights are sparse: stepping a calendar day back off a
    /// night lands on days the strap never recorded, and Rest has nothing to say about those.
    /// Browsing is READ-ONLY — this changes what is derived for display, never what is stored.
    @State private var selectedKey: String?

    /// How many nights in the CURRENT debt window the stager flagged (016). Derived in the same
    /// `.task` as the Assembly, immediately before it, for the same reason everything else in that pass
    /// is: it resolves a main-night group per window night, which must never run on a SwiftUI frame.
    /// The two are written back to back with no suspension between them, so a render can never see the
    /// count from one night beside the ledger of another.
    ///
    /// It lives here rather than on `RestModel.Assembly` only because `RestModel` is outside this
    /// packet's files; it is a pure derivation of the same inputs and belongs beside `windowNapMin`.
    @State private var lowConfidenceNights = 0

    var body: some View {
        Group {
            if let assembly {
                content(assembly)
            } else {
                // Nothing derived yet (first frame): the empty screen, not a half-derived one.
                // `loaded: false` shows the header alone rather than claiming "No sleep recorded"
                // about data we haven't read.
                RestScreenContent(loaded: false, lastNight: nil, typicalScore: nil,
                                  balanceMin: 0, debtNights: 0, lowConfidenceNights: 0, history: [])
            }
        }
        // The whole derivation (a `repo.days` filter, the personal-need pass, the nap-credited
        // `SleepDebt.ledger`, the debt-window nap classification) used to run inline in `body`.
        // Repository republishes `hrWatermark` on raw-HR growth WITHOUT bumping `refreshSeq` (the P5
        // split that keeps the workout detector off every sync tick) — but an observed
        // `@EnvironmentObject` re-renders on ANY publish, so the pipeline re-ran on every watermark
        // move during a sync, for data Rest never reads. `refreshSeq` is the correct gate: Repository
        // publishes days / sleeps / restSeries / napSeries / habitualMidsleepSec together with it.
        //
        // The selected night joins the id (the `ArousalForensicsLoaded` idiom below): every number in
        // the Assembly is derived AS OF that night, so moving the browse has to re-run the pass. The
        // previous Assembly stays on screen while it does, which is why stepping doesn't flash empty.
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
            // Over the ledger's OWN nights (the ones it actually counted), never a fresh 14-night cut —
            // the caption has to be about the balance beside it.
            lowConfidenceNights = RestNight.lowConfidenceNightCount(
                dayKeys: a.ledger.nights.map(\.day), sleeps: repo.sleeps,
                habitualMidsleepSec: repo.habitualMidsleepSec)
            assembly = a
        }
    }

    private func content(_ a: RestModel.Assembly) -> some View {
        // The population the browse moves through: every night in the record, oldest → newest
        // (`Assembly.slept`). Bounded by the DATA and not by a constant (014 decision 9) — the back arrow
        // dies on the oldest night there is, the forward one on the newest, so neither ever steps into an
        // empty screen.
        let nights = a.slept.map(\.day)
        // The night actually ON SCREEN, not the raw selection: a stale key falls back to the newest
        // (`RestModel.selectedNight`), and the header, the two arrows and the forward-looking gate all have
        // to describe what is rendered rather than what was asked for.
        let current = a.lastDay?.day
        let previous = RestBrowse.previousKey(from: current, in: nights)
        let next = RestBrowse.nextKey(from: current, in: nights)
        let isNewest = RestBrowse.isNewest(key: current, in: nights)
        return RestScreenContent(
            loaded: repo.loaded,
            lastNight: night(a.lastDay),
            typicalScore: a.typicalScore,
            needMin: a.needMin,
            napMin: a.lastDay.flatMap { repo.napSeries[$0.day] } ?? 0,
            balanceMin: a.ledger.balanceMin,
            debtNights: a.ledger.nightCount,
            // Derived in the `.task` above, off the frame path — see the property's own note.
            lowConfidenceNights: lowConfidenceNights,
            windowNapMin: a.windowNapMin,
            windowNapCount: a.napRows.count,
            history: a.history,
            // The night stepper (014 P2), Today's control in Rest's units — same glyphs, same placement,
            // same "0 = the live default" meaning `dayOffset == 0` carries there (`TodayScreen.swift:361`).
            // The state itself stays here rather than in the content: moving the browse has to re-run the
            // whole derivation, which is the `.task(id:)` above.
            nightTitle: RestBrowse.headerTitle(key: current, isNewest: isNewest),
            canStepBack: previous != nil,
            canStepForward: next != nil,
            onStepBack: { browse(to: previous, newest: nights.last) },
            onStepForward: { browse(to: next, newest: nights.last) },
            // The strip IS the navigation (decision 6, "tap night"): it hands back its own
            // bar's day key, which lands here unread — the strip already knows which night it drew.
            onNightTap: { browse(to: $0, newest: nights.last) },
            // The wrist-orientation tape (011 W2.3) — injected so RestScreenContent stays
            // pure/previewable. `PostureLoaded` reads the night's raw gravity and clusters it ONCE per
            // day-view inside its `.task(id:)`, the same shape the forensics loader uses, so the
            // clustering never runs on a SwiftUI frame. Sits directly under the hypnogram it grids with.
            posture: AnyView(PostureLoaded(session: a.lastSession, dayKey: a.lastDay?.day)),
            // The two-process "Tonight's bedtime" cluster — forward-looking guidance, injected so
            // RestScreenContent stays pure/previewable. `OptimalBedtimeArmed` owns the BodyClockEngine
            // (cached per day) and renders ABOVE the night. At the NEWEST night only (014 decision 4 —
            // the rule Today already applies with `allowCarry: dayOffset == 0`): over a night from March
            // it would be advice about a night that is already over.
            bedtime: isNewest ? AnyView(OptimalBedtimeArmed()) : nil,
            // The "Why you woke" arousal-forensics cluster — injected so RestScreenContent stays
            // pure/previewable. `ArousalForensicsLoaded` fetches the night's streams once per day-view and
            // caches the classification off the SwiftUI frame path (see its `.task(id:)`). Sits directly
            // below "Last night".
            arousals: AnyView(ArousalForensicsLoaded(session: a.lastSession, dayKey: a.lastDay?.day)),
            // Recent nap rows over the debt window (007 F3), each dated — injected so RestScreenContent
            // stays pure/previewable; nil when the window had no naps so the section vanishes entirely.
            naps: a.napRows.isEmpty ? nil : AnyView(NapSection(naps: a.napRows)),
            // The wake-window cluster (W9) — injected so RestScreenContent stays pure/previewable. The
            // strap backstop can only be armed over a genuine encrypted bond; the sim has none, so this
            // honestly reads "Backup notification only". P7: the LiveState observation (encryptedBond)
            // lives inside `WakeWindowArmed` so the ~1 Hz live-HR churn re-renders only that small section,
            // not the whole Rest screen (hypnogram, stage totals, history). Newest night only for the same
            // reason the bedtime cluster is (decision 4), with one more of its own: it carries an ARM
            // control, and a browsed night must not offer to schedule anything.
            wakeWindow: isNewest ? AnyView(WakeWindowArmed()) : nil,
            // The multi-night sleep-regularity reading (011 W2.1). A pure VALUE, not an injected
            // AnyView: `RestModel.assemble` already derives it off the frame path in the same pass as
            // the debt ledger, so the section needs no observation of its own and both previews below
            // drive it.
            regularity: a.regularity
        )
    }

    // MARK: - Derivation off the repository

    /// The rendered night as a `RestNight` — built from the Assembly's OWN selected row (014), never
    /// from a second pick of its own, so the hero, the hypnogram and the forensics below it cannot end
    /// up describing different nights. The typical, the debt window and the strip are already derived
    /// as of the same row inside `RestModel.assemble`.
    private func night(_ day: DailyMetric?) -> RestNight? {
        guard let day else { return nil }
        // The whole main-night GROUP, via the shared selector — a bridged night's stage rows, hypnogram
        // and bed/wake must describe the same blocks the hero's Asleep total was summed from.
        return RestNight(day: day,
                         score: repo.restSeries[day.day],
                         sessions: RestNight.sessions(for: day, in: repo.sleeps,
                                                      habitualMidsleepSec: repo.habitualMidsleepSec))
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

    /// What the header calls the night on screen — Today's `headerTitle(key:isToday:)` idiom
    /// (`TodayScreen.swift:357`) in Rest's units: the relative name while it is TRUE, the night's own date
    /// once it is not. "Last night" printed over a night from March is exactly the quiet false claim this
    /// wave exists to remove.
    ///
    /// The date format is the one the header caption has always printed ("Sat 12 Jul"), so a browsed night
    /// is captioned the way this screen already captions the newest one.
    static func headerTitle(key: String?, isNewest: Bool) -> String {
        if isNewest { return "Last night" }
        guard let key else { return "Last night" }
        guard let date = RestFormat.date(fromDayKey: key) else { return key }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// P7: the wake-window section, isolated so its ~1 Hz `LiveState` observation (only `encryptedBond`,
/// the strap-armed status) re-renders THIS small subview instead of all of RestScreen. Behavior is
/// unchanged — it still reads the alarm settings + live encrypted-bond flag and re-arms on Apply.
private struct WakeWindowArmed: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var alarm: SmartAlarmCoordinator
    @EnvironmentObject private var buzzLog: BuzzLog

    var body: some View {
        WakeWindowSection(settings: alarm.settings,
                          // Not `live.encryptedBond`: a bond is necessary but not sufficient. The
                          // coordinator also knows whether BLEManager will really arm this family
                          // (5/MG needs Experimental), and `.armedOnStrap` copy promises a buzz that
                          // fires with the app closed. `armState` already guards on settings.enabled,
                          // so the extra term this carries is inert there.
                          strapArmed: alarm.isArmedOnStrap,
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

/// Loads + caches the "Why you woke" arousal forensics for the last night. It fetches the night's
/// streams and runs `ArousalForensics.classify` ONCE per day-view inside `.task(id: dayKey)` (so the
/// classification never re-runs on a SwiftUI frame), then hands the result to the pure section. Hides
/// itself entirely when there is no analyzable session.
private struct ArousalForensicsLoaded: View {
    @EnvironmentObject private var repo: Repository
    let session: CachedSleepSession?
    let dayKey: String?

    @State private var night: ArousalForensicsLoader.Night?

    var body: some View {
        Group {
            if session != nil, let night {
                // `dayKey` is what lets the section know the raw signal behind this ledger has been
                // pruned. Without it the section defaults to nil, `RawHorizon.hasAgedOut` answers
                // false for every night, and a 79-day-old night prints "Slept through — no awakenings
                // over 2 minutes" about a heart rate that no longer exists to have found any in.
                ArousalForensicsSection(arousals: night.arousals, hasSession: true,
                                        capture: night.capture, dayKey: dayKey)
            }
        }
        // Key on the data version + session identity, not just the day: the night's raw HR/skin-temp
        // streams keep backfilling AFTER the session first stages (bumping refreshSeq), and a day-key-only
        // id never re-fires, so the forensics would stay stuck on the partial first classify until midnight.
        .task(id: "\(dayKey ?? "")|\(repo.refreshSeq)|\(session?.startTs ?? 0)") {
            night = nil   // clear first so a new day/session can't briefly render the previous night's
            guard let session, dayKey != nil else { return }
            guard let store = await repo.storeHandle() else { return }
            night = await ArousalForensicsLoader.load(
                session: session,
                store: store,
                strapDeviceId: repo.deviceId,
                computedDeviceId: repo.computedDeviceId,
                family: WhoopModel.persisted.deviceFamily)
        }
    }
}

/// Loads + caches the wrist-orientation tape (011 W2.3) for the last night. It reads the night's raw
/// gravity and runs `PostureEngine` ONCE per day-view inside `.task(id:)` (so the epoch pass and the
/// clustering never re-run on a SwiftUI frame), then hands the result to the pure section. Hides itself
/// entirely when there is no session, when the gravity has been pruned (28 days,
/// `SampleRetention.swift:92-95`), or when the night never held still long enough to tell orientations
/// apart — an absent section, not an em-dash about a night that was never read.
private struct PostureLoaded: View {
    @EnvironmentObject private var repo: Repository
    let session: CachedSleepSession?
    let dayKey: String?

    /// The read's OUTCOME, not just its night: the section has to tell "the gravity is gone" from
    /// "the gravity is there and would not cluster", and only the outcome carries that.
    @State private var outcome: PostureLoader.Outcome?
    /// Whether the read has FINISHED. `night` is nil both before the read and when there is nothing to
    /// read, and the aged-out line is exactly the `night == nil` case — so without this the line would
    /// flash on every night during the async gap before its tape arrived.
    @State private var loaded = false

    var body: some View {
        Group {
            // The section is built for any real session, INCLUDING when `night` is nil — that is the
            // aged-out case, and gating on `let night` made the line it renders unreachable by
            // construction. `PostureSection` still draws nothing when the night is simply unreadable
            // inside the horizon, so a strap that recorded no gravity last night is unchanged.
            if session != nil, loaded {
                PostureSection(night: outcome?.night, hadGravity: outcome != .noSamples,
                               dayKey: dayKey)
            }
        }
        // Same id as the forensics loader, and for the same reason: the night's raw gravity keeps
        // backfilling AFTER the session first stages (bumping refreshSeq), and a day-key-only id never
        // re-fires — the tape would stay stuck on the partial first read until midnight.
        .task(id: "\(dayKey ?? "")|\(repo.refreshSeq)|\(session?.startTs ?? 0)") {
            outcome = nil   // clear first so a new day/session can't briefly render the previous night's
            loaded = false
            guard let session, dayKey != nil else { return }
            guard let store = await repo.storeHandle() else { return }
            outcome = await PostureLoader.load(session: session, store: store,
                                               strapDeviceId: repo.deviceId)
            loaded = true
        }
    }
}

/// Pure render of the Rest screen — everything derived, nothing observed (previewable without a
/// live Repository).
struct RestScreenContent: View {
    let loaded: Bool
    let lastNight: RestNight?
    let typicalScore: Double?
    var needMin: Double = 480
    /// The displayed day's credited nap minutes (007 F3) — the need line's appended dim segment.
    var napMin: Double = 0
    /// Net `SleepDebt.ledger` balance over the trailing window (negative = debt).
    let balanceMin: Double
    /// Nights that actually contributed to the ledger (wear-gap nights skipped).
    let debtNights: Int
    /// Nights in that same window the stager kept but FLAGGED as longer than a night can be (016).
    /// 0 = an ordinary window, which renders byte-identically to before this argument existed.
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
    /// What the header calls the night on screen (014 P2): "Last night" at the newest, the night's own
    /// date once you have stepped back — `RestBrowse.headerTitle`. The default keeps bare previews and the
    /// pre-first-pass empty state on the relative name.
    var nightTitle: String = "Last night"
    /// Whether an older / newer night exists to step to. Both default false, so a caller that knows
    /// nothing about a record renders two inert arrows rather than promising navigation it can't do.
    var canStepBack: Bool = false
    var canStepForward: Bool = false
    var onStepBack: (() -> Void)? = nil
    var onStepForward: (() -> Void)? = nil
    /// A night in the history strip was tapped (014 P2), by its own day key. nil leaves the strip inert,
    /// which is what the specimen previews want.
    var onNightTap: ((String) -> Void)? = nil
    /// The wrist-orientation section (011 W2.3), injected so this pure content stays previewable
    /// without a live Repository. nil in the specimen previews (`PostureSection` carries its own light
    /// and dark ones); the real screen passes the loader. Sits directly under "Last night" — the tape
    /// walks `SleepStaging.epochS`, so it grids with the hypnogram immediately above it.
    var posture: AnyView? = nil
    /// The two-process "Tonight's bedtime" section, injected so this pure content stays previewable. nil
    /// in specimen previews; the real screen passes the observed section. Sits ABOVE "Last night" —
    /// forward-looking guidance over the retrospective night.
    var bedtime: AnyView? = nil
    /// The "Why you woke" arousal-forensics section, injected so this pure content stays previewable
    /// without a live Repository. nil in the specimen previews; the real screen passes the loader. Sits
    /// directly below "Last night".
    var arousals: AnyView? = nil
    /// The displayed day's nap rows (007 F3), injected so this pure content stays previewable. nil
    /// when the day had no naps (the section vanishes). Sits below the arousal forensics —
    /// retrospective like them, ahead of the forward-looking wake window.
    var naps: AnyView? = nil
    /// The Rest wake-window section (W9), injected so this pure content stays previewable without a live
    /// coordinator. nil in the specimen previews; the real screen passes the observed section. Sits
    /// between "Last night" (the hero) and "History" (the tail).
    var wakeWindow: AnyView? = nil
    /// The Sleep Regularity Index reading (011 W2.1), derived by `RestModel.assemble`. A pure value
    /// rather than an injected AnyView — it needs no Repository, so this content view stays previewable
    /// WITH the section rather than without it. Sits with History: it is a multi-night statistic, not a
    /// property of last night. nil hides it.
    var regularity: SleepRegularity.Outcome? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let lastNight {
                    // The eyebrow NAMES the night rather than always claiming "Last night" (014 P2) —
                    // browsed back it is the date, because that label over a night from March is a
                    // statement about the data that is simply false. One string with the header's, so the
                    // two can never say different nights.
                    RuleSection(nightTitle, topGap: WM.Space.sectionTight) {
                        nightBody(lastNight)
                    }
                } else if loaded {
                    RuleSection("Last night", topGap: WM.Space.sectionTight) {
                        Text("No sleep recorded")
                            .font(WMType.body)
                            .foregroundStyle(WM.Ground.inkSecondary)
                            .padding(.vertical, WM.Space.s)
                    }
                }
                if let posture {
                    posture
                }
                if let bedtime {
                    bedtime
                }
                if let arousals {
                    arousals
                }
                if let naps {
                    naps
                }
                if let wakeWindow {
                    wakeWindow
                }
                // With History, above it: both describe the record rather than last night.
                RegularitySection(outcome: regularity, isNewest: !canStepForward)
                if history.count >= 2 {
                    RuleSection("History") {
                        RestHistoryStrip(nights: history, needMin: needMin, onSelect: onNightTap)
                    }
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.top, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }

    /// Tab name, the night on screen, and the prev/next stepper — Today's header row
    /// (`TodayScreen.swift:355`) in Rest's units. The caption slot is the one that has always held the
    /// night's date; browsing only changed what it says when the date is not the most useful name for it.
    private var header: some View {
        HStack(spacing: WM.Space.s) {
            Text("Rest")
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
            Spacer(minLength: WM.Space.m)
            // Only over a real night: a record with nothing in it gets the bare title it gets today,
            // rather than a label about a night that was never recorded.
            if lastNight != nil {
                Text(nightTitle)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            stepper(systemName: "chevron.left", label: "Previous night",
                    enabled: canStepBack) { onStepBack?() }
            stepper(systemName: "chevron.right", label: "Next night",
                    enabled: canStepForward) { onStepForward?() }
        }
    }

    /// Today's stepper button, glyph for glyph (`TodayScreen.swift:368`) — 14pt semibold chevron (the
    /// `.nav` chrome role Today's hand-written `.system(size: 14, weight: .semibold)` predates), ink when
    /// live and dimmed when not, in a 44×44 hit region the glyph does not grow into.
    private func stepper(systemName: String, label: String, enabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(WMType.icon(.nav))
                .foregroundStyle(enabled ? WM.Ground.ink : WM.Ground.inkTertiary.opacity(0.5))
                // ≥44×44 hit region (HIG); the glyph keeps its size, only the invisible box grows.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func nightBody(_ night: RestNight) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.sectionTight) {
            NavigationLink { NightMovementScreen(night: night) } label: {
                // The hero's caveat is the night's OWN (`RestNight.lowConfidenceCaption`), derived from
                // the same main-night group everything else in this block describes — so it follows the
                // browse (014) with no state of its own, and cannot caveat a different night than the
                // numerals above it.
                RestNightHero(score: night.score, asleepMin: night.asleepMin, typical: typicalScore,
                              lowConfidenceCaption: night.lowConfidenceCaption)
            }
            .buttonStyle(.plain)
            if !night.segments.isEmpty {
                StepHypnogram(segments: night.segments)
            }
            StageTotalsRows(deepMin: night.deepMin, remMin: night.remMin,
                            lightMin: night.lightMin, wakeMin: night.wakeMin)
            // `isNewest` is DERIVED from the stepper rather than passed beside it: there is a newer
            // night to step to exactly when this is not the newest one. A separate field could drift
            // from the arrows, and then the debt line's window and the navigation would tell two
            // different stories about one screen.
            SleepNeedLine(needMin: needMin, asleepMin: night.asleepMin, napMin: napMin,
                          balanceMin: balanceMin, debtNights: debtNights,
                          windowNapMin: windowNapMin, windowNapCount: windowNapCount,
                          // The ledger's flagged nights, landing WITH the hero caveat above (016
                          // decision 3): a hero that caveats while this line silently banks the surplus
                          // would be trusted more, not less.
                          lowConfidenceNights: lowConfidenceNights,
                          isNewest: !canStepForward)
            timingsRow(night)
        }
    }

    /// Efficiency + bed/wake timings as three SignalCells on one row.
    private func timingsRow(_ night: RestNight) -> some View {
        HStack(alignment: .top, spacing: WM.Space.sectionLoose) {
            SignalCell(label: "Efficiency",
                       value: night.efficiency.map { "\(Int($0.rounded()))" } ?? "—",
                       unit: night.efficiency != nil ? "%" : nil)
            SignalCell(label: "Bed",
                       value: night.bed.map { $0.formatted(.dateTime.hour().minute()) } ?? "—")
            SignalCell(label: "Wake",
                       value: night.wake.map { $0.formatted(.dateTime.hour().minute()) } ?? "—")
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
    RestScreenContent(loaded: true, lastNight: nil, typicalScore: nil,
                      balanceMin: 0, debtNights: 0, lowConfidenceNights: 0, history: [])
}

#Preview("RestScreen — flagged night, light") {
    RestScreenSpecimen(flagged: true).preferredColorScheme(.light)
}

#Preview("RestScreen — flagged night, dark") {
    RestScreenSpecimen(flagged: true).preferredColorScheme(.dark)
}

private struct RestScreenSpecimen: View {
    /// Stepped back off the newest night (014 P2): the header and the eyebrow name the night instead of
    /// calling it "Last night", and both arrows are live. The default specimen is the newest night, where
    /// the forward arrow is dead — a stepper that never disables is as wrong as one that never moves, so
    /// the pair of previews shows both ends.
    var browsed = false
    /// The night the stager kept but flagged (016): the Asleep numeral goes secondary, the caveat lands
    /// under the verdict, and the debt line names the window's one flagged night. The default specimen
    /// is a CONFIDENT night, which must stay byte-identical — the pair of previews shows both, so a
    /// caveat that always shows is as visible here as one that never does.
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
            score: 82, asleepMin: asleep, efficiency: 93,
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
        RestScreenContent(loaded: true, lastNight: night, typicalScore: 74,
                          napMin: 25, balanceMin: -144, debtNights: 14,
                          lowConfidenceNights: flagged ? 1 : 0, history: history,
                          // Through the production formatter, off a key from the specimen's own strip —
                          // a preview that hand-wrote its date could drift from what the screen prints.
                          nightTitle: RestBrowse.headerTitle(key: history.first?.dayKey,
                                                             isNewest: !browsed),
                          canStepBack: true, canStepForward: browsed,
                          regularity: regularity)
    }
}
