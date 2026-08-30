#if DEBUG
import SwiftUI
import StrapStore
import StrapAnalytics

/// DEBUG-only render proof for every REFUSAL the app can make — Today and Data, then Rest and its Night
/// detail. Reachable via `--honesty-gallery` (see `AppShell`).
///
/// WHY THIS EXISTS. Nine waves added honest-refusal states to Rest — the aged-out lines past the
/// 28-day raw horizon, the low-confidence caveat, the capture-quality caption, the browsed copy, the
/// clipped-window silence — and almost none of them could be looked at. Each needs a night the
/// simulator can only reach by tapping a chevron a dozen times, and even browsed there
/// (`--rest-night`) they sit below the Last-night hero, which `simctl` cannot scroll past. Meanwhile
/// `DemoSeed` banks raw HR/gravity for exactly ONE night, so the two aged-out branches never render on
/// seeded data at all. The states this project works hardest to get right were the only ones nobody
/// had ever seen.
///
/// This is the `WakeWindowGallery` idiom, for the same reason it gives: the real sections, the real
/// tokens, side by side, above the fold, in both themes.
///
/// It also answers a question a code review cannot: whether the caveats READ well together. They were
/// written by different waves weeks apart, and "say nothing when there is nothing to say" is a rule
/// that erodes by accumulation rather than by any single edit. Seeing them stacked is the only way to
/// tell — and a state that cannot co-occur in the seed can still be put next to its neighbours here.
///
/// NOT a substitute for the unit tests: these are fixed fixtures, so this proves how a state LOOKS,
/// never that the app enters it. The tests own reachability.
///
/// Where a refusal is a COMPONENT it is rendered as one, at its own tokens. Where it is a string the
/// app builds and hands to a shared view (the SpO2 capability note, the stale Data row's date, the
/// no-comparable-window caption), the string itself is shown and labelled as copy — the point there is
/// the wording, and re-typing the surrounding view would prove nothing about it.
struct HonestyGallery: View {

    /// A day comfortably past the raw horizon, and one comfortably inside it.
    private var agedOutKey: String { key(daysAgo: SampleRetention.retentionDays + 7) }
    private var freshKey: String { key(daysAgo: 1) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WM.Space.section) {
                Text("Honesty gallery")
                    .font(WMType.title)
                    .foregroundStyle(WM.Ground.ink)
                    .padding(.top, WM.Space.gutter)

                Text("Every refusal the app can make, on fixed fixtures.")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.inkSecondary)

                // ── Today: the pipeline ladder, and the hero and score lines in their honest states.
                Text("Today · sync status, every reportable state").wmOverline()
                VStack(alignment: .leading, spacing: WM.Space.m) {
                    ForEach(Array(syncStates.enumerated()), id: \.offset) { _, state in
                        TodaySyncCaptionContent(status: state)
                    }
                }

                Text("Today · caught up (says nothing, deliberately)").wmOverline()
                TodaySyncCaptionContent(status: .caughtUp)

                Text("Today · scores before the baseline is seeded").wmOverline()
                TodayScores(charge: .init(score: nil, baseline: nil,
                                          calibratingNote: "2 of \(Baselines.minNightsSeed) nights"),
                            effort: .init(score: 47, baseline: 55, calibratingNote: nil),
                            rest: .init(score: nil, baseline: nil, calibratingNote: nil))

                Text("Today · a carried Charge and a partial-capture Effort").wmOverline()
                TodayScores(charge: .init(score: 61, baseline: 55, carriedFrom: "Mon", calibratingNote: nil),
                            effort: .init(score: 22, baseline: 40, lowCoverage: true, calibratingNote: nil),
                            rest: .init(score: 70, baseline: 68, calibratingNote: nil),
                            chargeBand: 48...62, effortBand: 30...52, restBand: 62...74)

                // ── Data: refusals that are copy rather than components.
                Text("Data · copy-only refusals").wmOverline()
                VStack(alignment: .leading, spacing: WM.Space.m) {
                    copyLine("SpO2 capability note",
                             MetricCatalog.all.first { $0.key == "spo2" }?.note)
                    copyLine("Data row, measured 4 days before the list's freshest point",
                             WallFreshness.caption(unit: "ms", measured: daysAgo(6),
                                                   freshest: daysAgo(2)))
                    copyLine("Data row, current (stays bare)",
                             WallFreshness.caption(unit: "ms", measured: daysAgo(2),
                                                   freshest: daysAgo(2)))
                    copyLine("Metric detail, no comparable previous window",
                             PeriodDeltaReadout.make(current: [60, 61], previous: nil,
                                                     windowDays: 90).caption)
                }

                // ── Night detail, in its on-screen order: past the raw horizon each of its three sections
                // has nothing left to read, and on an old night all three render one above the other —
                // so they are stacked here too, where a repeated opening would show.
                Text("Movement · past the raw horizon").wmOverline()
                NightMovementContent(tape: nil, loaded: true, dayKey: agedOutKey)

                Text("Movement · inside the horizon, nothing recorded").wmOverline()
                NightMovementContent(tape: nil, loaded: true, dayKey: freshKey)

                Text("Arousals · past the raw horizon").wmOverline()
                ArousalForensicsSection(arousals: [], hasSession: true, capture: nil,
                                        dayKey: agedOutKey)

                Text("Arousals · inside the horizon, genuinely quiet").wmOverline()
                ArousalForensicsSection(arousals: [], hasSession: true, capture: nil,
                                        dayKey: freshKey)

                Text("Arousals · with a capture caption").wmOverline()
                ArousalForensicsSection(arousals: [], hasSession: true,
                                        capture: CaptureQuality(hrPerMinute: 0.4,
                                                                gravityCoverage: 0.44),
                                        dayKey: freshKey)

                Text("Wrist orientation · past the horizon, nothing banked").wmOverline()
                PostureSection(night: nil, hadGravity: false, dayKey: agedOutKey)

                Text("Wrist orientation · past the horizon, banked but unclusterable").wmOverline()
                Text("Renders nothing — the gravity is on disk, so \"no longer stored\" would be false.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                PostureSection(night: nil, hadGravity: true, dayKey: agedOutKey)

                // ── The Rest hero's caveat on a flagged night, one sentence per cause.
                Text("Rest hero · flagged night caveats").wmOverline()
                VStack(alignment: .leading, spacing: WM.Space.m) {
                    copyLine("Kept, longer than a night can be (17 h 12 min recorded)",
                             RestNight.lowConfidenceCaption(spanS: 61_920))
                    copyLine("Kept, with unmeasured minutes inside an ordinary-length night",
                             RestNight.lowConfidenceCaption(spanS: 6 * 3600 + 45 * 60))
                }

                // ── Regularity: the same outcome, worded for the newest night and for a browsed one.
                Text("Regularity · calibrating, newest night").wmOverline()
                RegularitySection(outcome: .calibrating(pairs: 3,
                                                        needed: SleepRegularity.minimumPairs),
                                  isNewest: true)

                Text("Regularity · calibrating, browsed").wmOverline()
                RegularitySection(outcome: .calibrating(pairs: 3,
                                                        needed: SleepRegularity.minimumPairs),
                                  isNewest: false)

                Text("Regularity · window clipped by the cache").wmOverline()
                Text("Renders nothing — the missing nights exist, we simply were not given them.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                RegularitySection(outcome: nil, isNewest: false)

                // ── The debt line, both tenses, with and without a flagged night in the window.
                Text("Debt · newest night").wmOverline()
                SleepNeedLine(asleepMin: 432, balanceMin: -144, debtNights: 14,
                              lowConfidenceNights: 0, isNewest: true)

                Text("Debt · browsed").wmOverline()
                SleepNeedLine(asleepMin: 432, balanceMin: -144, debtNights: 14,
                              lowConfidenceNights: 0, isNewest: false)

                Text("Debt · a flagged night inside the window").wmOverline()
                SleepNeedLine(asleepMin: 580, balanceMin: 342, debtNights: 14,
                              lowConfidenceNights: 1, isNewest: true)
            }

            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground.ignoresSafeArea())
    }

    /// Every state the sync ladder will actually report. `.caughtUp` is shown separately, because its
    /// whole point is that it renders nothing.
    private var syncStates: [SyncStatus.State] {
        [.radio(LiveState.RadioState.poweredOff.problem ?? ""),
         .strapStuck(SyncStatus.strapRebootLine),
         .neverSynced,
         .offloading("3d"),
         .behind("3d"),
         .liveOnly,
         .notPaired]
    }

    /// A refusal that lives as COPY rather than as a component — labelled as such, so nobody reads this
    /// block as a render proof of a view.
    @ViewBuilder
    private func copyLine(_ label: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
            Text(text ?? "(nil — nothing rendered)")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func daysAgo(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n,
                              to: Calendar.current.startOfDay(for: Date()))!
    }

    private func key(daysAgo: Int) -> String {
        let cal = Calendar.current
        return DayKey.local(cal.date(byAdding: .day, value: -daysAgo,
                                     to: cal.startOfDay(for: Date()))!)
    }
}

#Preview("Honesty gallery — light") {
    HonestyGallery().preferredColorScheme(.light)
}

#Preview("Honesty gallery — dark") {
    HonestyGallery().preferredColorScheme(.dark)
}
#endif
