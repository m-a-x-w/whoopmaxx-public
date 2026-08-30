import Foundation
import SwiftUI   // only for the row types this hands back (`NapSection.Nap`, `RestHistoryStrip.Night`)
import StrapStore
import StrapAnalytics

/// Pure derivations behind the Rest screen: the slept-days slice, the night on screen, personal sleep
/// need, the nap-credited sleep-debt ledger, that night's detected session, the debt window's nap rows,
/// the typical the hero verdict compares against, and the 14-night duration strip.
/// Value-in / value-out (no Repository, no observation) so the screen can run the whole pass ONCE
/// per real data change off the SwiftUI frame path — see `RestScreen`'s `.task(id:)`.
///
/// 014: every derivation here is AS OF the night being browsed. Which night that is arrives as one
/// `selectedKey` and is resolved ONCE (`selectedNight(for:in:)`); nothing below re-picks a night, so
/// the hero, the debt, the typical, the strip and the regularity cannot describe different nights.
enum RestModel {

    /// Everything `RestScreen` derives from the repository in a single pass.
    struct Assembly {
        /// `days` filtered to rows that carry a night total — the WHOLE record, oldest → newest. This is
        /// the population a browse moves through (the oldest night there is to step back to, the newest
        /// to step forward to); every derivation below reads only the part of it up to `lastDay`.
        let slept: [DailyMetric]
        /// Personal sleep need, in minutes, over the record up to the night on screen.
        let needMin: Double
        /// The nap-credited sleep-debt ledger over the trailing window ENDING on that night.
        let ledger: SleepDebtLedger
        /// The night the screen renders: the browsed one, or the most recent slept day when nothing is
        /// selected (and when a selected key no longer has a row). nil only when nothing was ever slept.
        let lastDay: DailyMetric?
        /// That night's detected session, for the "Why you woke" forensics.
        let lastSession: CachedSleepSession?
        /// Naps across the debt window as dated rows, newest first.
        let napRows: [NapSection.Nap]
        /// Total credited nap minutes across that same window.
        let windowNapMin: Double
        /// The multi-night Sleep Regularity Index reading (011 W2.1); nil when the window holds no
        /// usable night, which hides the section rather than captioning nights that were never banked.
        let regularity: SleepRegularity.Outcome?
        /// 30-day typical Rest score EXCLUDING the night on screen — the 30 nights BEFORE it, which is
        /// what the hero verdict compares that night against. nil under `TodayModel.minBaselineSamples`.
        let typicalScore: Double?
        /// The 14-night duration strip, ending on the night on screen.
        let history: [RestHistoryStrip.Night]
    }

    /// The night a browse resolves to: the row for `key`, or the newest slept night when nothing is
    /// selected — AND when `key` has no row of its own. A selection can go stale (its night re-scored
    /// away, its row aged out of the published cache, a key restored from a backup that no longer
    /// matches), and falling back beats rendering a screen with nothing on it.
    static func selectedNight(for key: String?, in slept: [DailyMetric]) -> DailyMetric? {
        guard let key else { return slept.last }
        return slept.last { $0.day == key } ?? slept.last
    }

    /// Build the whole Assembly from the repository's published Rest read-set.
    ///
    /// - Parameter selectedKey: the night to render (`yyyy-MM-dd`), or nil for the newest — the screen's
    ///   default, and byte-identical to what every caller got before 014.
    ///
    /// - Note: `restSeries` is threaded in with the other lanes so the full read-set arrives through
    ///   one call (and any caller sees the same snapshot). `typicalScore` reads it; the per-night score
    ///   lookup for the hero itself stays on the screen, which already observes the series.
    static func assemble(days: [DailyMetric],
                         restSeries: [String: Double],
                         sleeps: [CachedSleepSession],
                         napSeries: [String: Double],
                         habitualMidsleepSec: Int?,
                         selectedKey: String? = nil,
                         daysWindowFloor: String?) -> Assembly {
        // P6: derive the slept-days slice ONCE per body pass and thread it into every derivation
        // (last night, typical, debt, history) — each of these used to re-run the full `repo.days`
        // filter, so a single body pass filtered the whole array ~5×.
        let slept = days.filter { $0.totalSleepMin != nil }
        // The night the screen renders, resolved ONCE (014). Everything below is derived AS OF it:
        // browsing is read-only (decision 2), but it must not be retrospective either — a night in March
        // measured against the record that came after it is a comparison that could not have existed on
        // that night, and it would read as that night's own verdict. So the record is cut here, once, and
        // every window below reads the cut slices rather than `days`/`slept`.
        //
        // `repo.days` is unique-by-day and oldest → newest (`Repository.mergeDaily`), so each slice ends
        // exactly ON the selected night. At the newest night the cut changes nothing: the only rows past
        // the newest slept night are rows with no night total, and both `personalNeedHours` and
        // `SleepDebt.ledger` already skip those.
        let lastDay = selectedNight(for: selectedKey, in: slept)
        let daysUpTo = lastDay.map { n in days.filter { $0.day <= n.day } } ?? days
        let sleptUpTo = lastDay.map { n in slept.filter { $0.day <= n.day } } ?? slept
        let needMin = ScoreEngine.personalNeedHours(days: daysUpTo) * 60
        // Nap credit (007 F3): read the AUTHORITATIVE `nap_min` series ScoreEngine persisted. It is
        // classified with the SAME learned `habitualMidsleepSec` main-night pick that produced each day's
        // `totalSleepMin`, so adding it to the night total never double-counts (a locally recomputed
        // cold-start classification could pick a DIFFERENT main night than the scored total and credit a
        // session already inside it — wrong debt for day-sleepers / shift workers). Absent day = 0.
        let ledger = SleepDebt.ledger(
            series: daysUpTo.map { d in
                (day: d.day, totalSleepMin: d.totalSleepMin.map { $0 + (napSeries[d.day] ?? 0) })
            },
            needHours: needMin / 60.0)
        // The rendered night's detected session (for the "Why you woke" forensics), resolved the same way
        // the hero does — injected into the loader below so RestScreenContent stays pure/previewable.
        // The SUBSTANTIAL fragment of the main-night group, not the latest-onset one. Tier-1 bridging has
        // no duration floor, so a 20-minute morning re-doze after an out-of-bed gap joins the group and
        // would be the last by start time — handing the forensics a window with nothing in it, which
        // renders "Slept through — no awakenings over 2 minutes" under a hero reading 7h30. Taking the
        // longest span keeps the arousal ledger over the real night while still resolving the group
        // through the shared selector.
        let lastSession = lastDay.flatMap {
            RestNight.sessions(for: $0, in: sleeps, habitualMidsleepSec: habitualMidsleepSec)
                .max { ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs) }
        }
        // Naps across the DEBT WINDOW (the exact nights `ledger` counted), as dated rows newest-first PLUS
        // a summary for the debt line. Rest used to render only the displayed day's naps, so prior nights'
        // naps reduced the 14-night balance with no visible row (Rest can't navigate to a nap's own day) —
        // now every credited nap is listed with its date. Classified with the SAME learned
        // `habitualMidsleepSec` main-night pick that produced each day's `napSeries` credit (Repository
        // publishes it), so rows can't disagree with the credit; nil (cold-start, <14 nights) matches
        // ScoreEngine. Minutes for the note come from the authoritative `napSeries` (matches the balance).
        var napRows: [NapSection.Nap] = []
        var windowNapMin = 0.0
        for night in ledger.nights {
            let credited = napSeries[night.day] ?? 0
            guard credited > 0 else { continue }
            windowNapMin += credited
            let dayNaps = NapCredit.naps(for: night.day, sleeps: sleeps,
                                         habitualMidsleepSec: habitualMidsleepSec)
            napRows += NapSection.rows(from: dayNaps)
        }
        napRows.sort { $0.startTs > $1.startTs }   // newest nap first
        // Sleep regularity (011 W2.1): a MULTI-NIGHT statistic, so it is derived HERE in the same
        // single pass as the debt ledger rather than in a View — the 1440-slot-per-day walk must never
        // run on a SwiftUI frame. It ends on `lastDay`, the night the screen renders — the BROWSED one
        // once a night is selected — so "Regularity" and the hero above it describe the same stretch of
        // record. `days` is passed whole rather than cut: `analyze` walks only up to `endKey`, so later
        // rows never enter the span. `sleeps` is passed whole (naps included): the index is over
        // sleep/wake STATE, not over the main-night group.
        //
        // 014's own plan claimed the 14-night window "reaches back from there, which the cache holds"
        // — true for the newest night, false for the oldest thirteen browsable ones, whose windows run
        // off the published cache's floor. `recordFloor` is what lets `analyze` tell "the record starts
        // here" from "the cache does": the oldest cached day is the record's own start ONLY when the
        // window did not clip it, i.e. when it is strictly newer than the day the window was read from.
        // The record starts where the cache starts ONLY when the cache did not clip it: the oldest row
        // must be strictly newer than the day the window was read from.
        let reachesRecordStart = daysWindowFloor.map { floor in (days.first?.day).map { $0 > floor } ?? false } ?? false
        let regularity = SleepRegularity.analyze(days: days, sleeps: sleeps, endKey: lastDay?.day,
                                                 daysReachRecordStart: reachesRecordStart)
        // The typical the hero verdict compares this night against: the 30 nights BEFORE it, never the
        // 30 ending today (014 decision 3) — `sleptUpTo` already ends on the rendered night, so dropping
        // its last row is exactly "the nights before this one". `typicalMean`'s floor stays: a night
        // early in the record legitimately has no typical, and "above your typical" is precisely the
        // claim `minBaselineSamples` exists to withhold.
        let typicalScore = TodayModel.typicalMean(
            Array(sleptUpTo.dropLast().suffix(30).compactMap { restSeries[$0.day] }))
        // The 14-night duration strip, ending on the rendered night for the same reason the ledger does.
        // `SparkHistory` dots and labels its LAST value and draws the typical band from the values it is
        // handed, so a strip running past the selected night would label another night's duration under
        // this night's hero and band it against nights that, from here, have not happened.
        let history = sleptUpTo.suffix(14).map {
            RestHistoryStrip.Night(dayKey: $0.day, minutes: $0.totalSleepMin ?? 0)
        }

        return Assembly(slept: slept, needMin: needMin, ledger: ledger,
                        lastDay: lastDay, lastSession: lastSession,
                        napRows: napRows, windowNapMin: windowNapMin,
                        regularity: regularity, typicalScore: typicalScore,
                        history: history)
    }
}
