import Foundation
import AppIntents
import WidgetKit
import StrapStore
import StrapAnalytics

/// The day-derived glance fields, resolved the SAME way the Today screen resolves them so the widget and
/// the app never disagree about a value. Pure (value-in / value-out) so the carry rules are unit-tested.
struct WidgetDayFields: Equatable {
    var charge: Int?
    var effort: Int?
    var hrv: Int?
    var restingHr: Int?
    var rest: Int?
    var chargeBaseline: Int?
    var effortBaseline: Int?
    var restBaseline: Int?
    /// The SOURCE day key of a carried Charge — nil when the resolved day's own row is scored, or when
    /// `allowCarry` is off. Today renders it as the column's "carried · Tue" caption and gates the
    /// Charge detail push on it (a blanked carry is not tappable).
    ///
    /// AMENDED IN 032 — this used to read "the glance surfaces ignore it", and the RENDERED ones still
    /// do: the widget shows a number, not its provenance. But the publish path no longer drops it. It
    /// is forwarded into `GlanceCarry` so the read-side App Intent can name the source day out loud,
    /// because a spoken answer has nowhere to put a caption and "Charge 62" for a two-day-old value is
    /// the #977 lie in a different medium.
    var chargeCarriedFrom: String?
    /// The source day key of a carried Rest score — same contract as `chargeCarriedFrom`, including the
    /// 032 forward into `GlanceCarry`.
    var restCarriedFrom: String?
    /// The vitals-fallback row behind `hrv` / `restingHr` when the resolved day's own row hasn't measured
    /// them. Surfaced as the ROW (not just the two Ints) because Today's Signals section also reads its
    /// `respRateBpm` and windows each signal's baseline strictly before THIS row's day.
    /// (`DailyMetric` is `Equatable`, so the synthesized conformance above survives.)
    var vitalsRow: DailyMetric?
    /// True when this day's waking-window capture coverage is below `ScoreConfidence.effortSolidCoverage`,
    /// i.e. its Effort was ACCUMULATED over materially incomplete data. `effort` still carries the number —
    /// it is real, just a floor rather than a measurement — and the UI renders the column as partial.
    var effortLowCoverage: Bool = false
}

enum WidgetDayResolver {
    /// The day key an always-today surface describes: the resolved-today row's day (`resolveToday` honors
    /// the #304 pre-04:00 window and the #144 local-nap carve-out), falling back to the logical key when
    /// no row exists yet. All baselines/carry are keyed off THAT day, never the carried anchor's day, so
    /// the 00:00–04:00 rollover doesn't misclassify.
    ///
    /// Nonisolated: value-in / value-out over `DayKey`, so any actor can call it.
    static func todayKey(days: [DailyMetric], now: Date) -> String {
        Repository.anchorKey(days: days, now: now)
    }

    /// THE one implementation of the Today carry rules. Both the Today screen and every off-dashboard
    /// glance (widget publish, watch snapshot, Live Activity) resolve a day through this, so they cannot
    /// disagree about a value — #977 shipped exactly that drift when the rules lived in two places.
    ///
    /// - **Charge carry** — `key`'s own row when scored, else `TodayModel.carriedChargeRow` (the 2-day
    ///   freshness cap + `< key` future-date guard). NOT the uncapped `Repository.widgetAnchor` (whose
    ///   contract is "freshest prior scored row, no age limit", and which also backs the watch snapshot /
    ///   Live Activity): without the cap a glance pins a week-old recovery as today's Charge while the app
    ///   shows "—" — the #977 "stale value pinned as today" bug.
    /// - **HRV / RHR carry** — own row first, else `TodayModel.vitalsFallbackRow` (recovery-INDEPENDENT:
    ///   a night with vitals but no recovery is a valid source), NOT the recovery-gated charge anchor,
    ///   which can skip a fresher vitals-only night.
    /// - **Effort NEVER carries** — read strictly from `key`'s own row's strain, `nil` when that day isn't
    ///   scored yet. Carrying yesterday's full-day strain as today's Effort would lie.
    /// - **Rest** — `key`'s own `sleep_performance`, else `TodayModel.carriedRest` (the same 2-day
    ///   freshness cap + `< key` future-date guard), never an uncapped tail.
    /// - A CARRIED value's baseline is windowed strictly before its SOURCE day, never before `key` — else
    ///   the carried value sits inside its own mean and fabricates an "at typical" tick (the W6 bug used
    ///   `before: todayKey`). The source day is `key` (when it scored) or the capped carried day.
    ///
    /// `allowCarry` is the browsed-history gate: the Today screen passes `false` for any day the user
    /// stepped BACK to, where painting a past day with a NEWER day's numbers would be a lie. All three
    /// carries — Charge, Rest, vitals — go dark together. Always-today surfaces pass `true`.
    ///
    /// Nonisolated: value-in / value-out over the static resolvers, so any actor can call it.
    static func fields(days: [DailyMetric], restSeries: [String: Double],
                       effortCoverage: [String: Double] = [:],
                       key: String, allowCarry: Bool) -> WidgetDayFields {
        let row = days.last { $0.day == key }
        // A day whose waking-window capture coverage fell below the bar. `effortCoverage` carries a point
        // only for days that were GRADED, so an absent key means "unknown" and is never treated as low —
        // which is what keeps today's live, still-accumulating Effort out of this.
        func lowCoverage(_ day: String) -> Bool {
            guard let c = effortCoverage[day] else { return false }
            return c < ScoreConfidence.effortSolidCoverage
        }

        let carriedCharge = allowCarry && row?.recovery == nil
            ? TodayModel.carriedChargeRow(days: days, before: key) : nil
        let chargeValue = row?.recovery ?? carriedCharge?.recovery
        let chargeBaselineKey = carriedCharge?.day ?? key

        let carriedRest = allowCarry && restSeries[key] == nil
            ? TodayModel.carriedRest(restSeries: restSeries, before: key) : nil
        let restValue = restSeries[key] ?? carriedRest?.value
        let restBaselineKey = carriedRest?.day ?? key

        let vitalsRow = allowCarry ? TodayModel.vitalsFallbackRow(days: days, before: key) : nil
        let hrv = row?.avgHrv ?? vitalsRow?.avgHrv
        let restingHr = row?.restingHr ?? vitalsRow?.restingHr

        func i(_ d: Double?) -> Int? { d.map { Int($0.rounded()) } }
        return WidgetDayFields(
            charge: i(chargeValue),
            effort: i(row?.strain),
            hrv: i(hrv),
            restingHr: restingHr,
            rest: i(restValue),
            chargeBaseline: i(TodayModel.priorMean(days: days, before: chargeBaselineKey) { $0.recovery }),
            // BASELINE POLLUTION GUARD: a low-coverage day's Effort is a FLOOR, not a measurement, so
            // folding it into the prior mean drags every other day's "typical" tick down. Measured on the
            // real 18 days: including 07-15 and 07-26 moved the Effort baseline 45.97 → 43.87, a 2.10-point
            // shift on EVERY day's column (−2.75 on 07-16 specifically). Excluding them is a single
            // predicate and fixes all days at once. Charge and Rest are unaffected — neither accumulates.
            effortBaseline: i(TodayModel.priorMean(days: days, before: key) {
                lowCoverage($0.day) ? nil : $0.strain
            }),
            restBaseline: i(TodayModel.priorRestMean(restSeries: restSeries, before: restBaselineKey)),
            chargeCarriedFrom: carriedCharge?.day,
            restCarriedFrom: carriedRest?.day,
            vitalsRow: vitalsRow,
            effortLowCoverage: lowCoverage(key))
    }

    /// The always-today entry point: resolve the day for `now` and read it with carry ON. Every
    /// off-dashboard glance comes through here; the Today screen calls `fields(days:restSeries:key:
    /// allowCarry:)` directly so a browsed past day can turn the carries off.
    static func fields(days: [DailyMetric], restSeries: [String: Double],
                       effortCoverage: [String: Double] = [:], now: Date) -> WidgetDayFields {
        fields(days: days, restSeries: restSeries, effortCoverage: effortCoverage,
               key: todayKey(days: days, now: now), allowCarry: true)
    }
}

extension WidgetSnapshot {
    /// Build a glance snapshot from live app state and publish it into the shared App Group, then ask
    /// WidgetKit to refresh. Called from a deliberately SMALL budget of publish points: every
    /// `AppRoot.dataDidChange` scope (launch / post-sync debounce / journal write / 15-min analyze tick)
    /// plus scenePhase `.active` — NOT off the live-HR stream (WidgetKit would coalesce/ignore those and
    /// burn budget; the home widget's bpm is a "recent glance", staleness shown via `updated`.
    /// Per-second HR is the Live Activity's job).
    @MainActor
    static func publish(from root: AppRoot) {
        // ONE `now` for the whole publish. It resolves the anchor day, it stamps `updated`, and the
        // provenance record below keys off that same stamp to prove the two records describe the SAME
        // publish. Two separate `Date()` calls (what this was) can straddle a second boundary, which
        // would make an honest provenance record look like it belonged to some other publish and push
        // every carried answer into the "day unknown" branch.
        let now = Date()
        // `effortCoverage` threaded here too, not just on Today: the snapshot publishes `effortBaseline`,
        // and a glance whose Effort tick sat 2.10 points below the app's would be exactly the #977-class
        // drift this shared resolver exists to prevent.
        let f = WidgetDayResolver.fields(days: root.repo.days, restSeries: root.repo.restSeries,
                                         effortCoverage: root.repo.effortCoverage, now: now)
        let snap = WidgetSnapshot(
            recovery: f.charge,
            bpm: root.bpm ?? root.live.heartRate,
            batteryPct: root.live.batteryPct.map { Int($0.rounded()) },
            bonded: root.live.bonded,
            updated: now,
            effort: f.effort,
            rest: f.rest,
            hrv: f.hrv,
            restingHr: f.restingHr,
            chargeBaseline: f.chargeBaseline,
            effortBaseline: f.effortBaseline,
            restBaseline: f.restBaseline)
        // Perf2: load the previous snapshot BEFORE overwriting it, always save the fresh one (so `updated`
        // stays current), then only ask WidgetKit to reload when a glance VALUE actually changed — an
        // unconditional reload on every publish point (the 15-min background tick especially) can exhaust
        // WidgetKit's background-refresh budget on stale data.
        let previous = WidgetSnapshot.load()
        snap.save()
        // 032: the spoken-answer provenance sidecar. `chargeCarriedFrom` / `restCarriedFrom` were
        // computed here already and then dropped on the floor, because no glance surface draws them —
        // which is fine for a widget (Today's dim fill and "carried · Tue" caption carry the meaning)
        // and not fine for `GlanceReadingIntent`, whose answer is a sentence with nowhere to put a
        // caption. Mapped through `TodayModel.shortDayLabel`, the SAME function that renders Today's
        // caption, so the app and the voice answer cannot name a day differently. See `GlanceCarry` for
        // why this is a sibling record rather than two more fields on the snapshot.
        //
        // Written on EVERY publish — before the reload gate below returns early, and even when both
        // fields are nil. A missing record means "provenance unknown" to the reader, so skipping the
        // write on a nothing-carried publish would make an honest own-day score answer as unconfirmed.
        // Cost is one small JSON encode + `UserDefaults` set per publish point (launch / post-sync
        // debounce / journal write / 15-min tick / scenePhase active); nothing per render, per frame or
        // per packet, and it deliberately does NOT touch the WidgetKit reload budget.
        GlanceCarry(updated: now,
                    chargeCarriedFrom: f.chargeCarriedFrom.map(TodayModel.shortDayLabel),
                    restCarriedFrom: f.restCarriedFrom.map(TodayModel.shortDayLabel)).save()
        if let previous, previous.sameValues(as: snap) { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// The app's ONE App Shortcuts declaration — the Siri phrases that reach `GlanceReadingIntent`.
///
/// **WHY IT LIVES IN THE APP TARGET AND NOT BESIDE THE INTENT.** An app gets exactly one
/// `AppShortcutsProvider`. `Shared/` is compiled into BOTH binaries (project.yml), so a provider
/// declared next to the intent in `Shared/Contract/` would be two providers — one in the app, one in
/// the widget extension — publishing the same phrase set twice. The intent itself still belongs in
/// `Shared/`, because that is what lets the EXTENSION run `perform()` without waking the app; a
/// provider is metadata only and never runs anything, so hosting it here costs nothing at invocation
/// time.
///
/// **ONE PARAMETERIZED ENTRY, NOT FIVE.** The system expands `\(\.$reading)` over `GlanceReading`'s
/// cases, so "what's my Charge", "what's my Rest" and the rest all resolve without declaring a shortcut
/// each. Nothing else is declared here: `LogIntakeIntent` stays out on purpose — a spoken "log a
/// coffee" would need its own disambiguation for amount and form, and a phrase that silently logs the
/// widget's standing configuration is a write the user did not see. The write lane's surfaces are
/// buttons, where what a tap logs is on screen before it is tapped.
///
/// Every phrase carries `\(.applicationName)` because App Shortcuts require it.
struct WMAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GlanceReadingIntent(),
            phrases: [
                "What's my \(\.$reading) in \(.applicationName)",
                "\(.applicationName) \(\.$reading)"
            ],
            shortTitle: "Get reading",
            systemImageName: "bolt.heart")
    }
}
