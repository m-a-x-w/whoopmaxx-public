import Foundation
import StrapStore
import StrapAnalytics

/// The fold between the app's two published caches and `ActivityCostEngine` (011 W1.6): `workouts` →
/// `[sport: Set<dayKey>]`, `days` → `[dayKey: Charge]`, plus the reason the engine hands back a bare
/// `[]` — which the screen has to say out loud rather than render an empty block.
///
/// Two things live here because the vendored engine cannot own them:
///   • SPORT KEYING. Sport is free text — `WorkoutCatalog` picks, WHOOP's concatenated camelCase
///     ("TraditionalStrengthTraining"), and hand relabels of detected bouts
///     (`WorkoutRepository.relabelDetected`). Left raw, ONE sport's evidence splits across two or three
///     keys, each of which then falls under `ActivityCostEngine.minSessions` — so the sport the user
///     does most silently disappears. Keys fold through the locale-stable `WorkoutSource.editableSport`
///     (the camelCase splitter), then case + whitespace; the LABEL keeps the user's capitalisation.
///   • THE EMPTY REASON. `evaluate` returns `[]` for two different worlds: a user who trains on or
///     within a week of every scored day has no untouched baseline at all
///     (`ActivityCostEngine.swift:149`), and a user who simply has not logged four sessions of any one
///     sport yet. `Readout` keeps them apart so the block prints the true line.
///
/// Framing register (011 decision 5): descriptive, within-user, no condition name, no probability, no
/// call-to-action. Banned from every string here — thermoregulation, vasodilation, impaired, poor,
/// abnormal, apnea, insomnia, hypoxemia, arrhythmia, "consider", "you should", "talk to".
enum ActivityCostFold {

    /// One ranked sport: the engine's verdict plus the label it prints under. The engine keys on the
    /// folded, lower-cased key, which is a join key and not a thing to show anyone.
    struct SportCost: Equatable, Identifiable {
        let label: String
        let cost: ActivityCost
        var id: String { cost.sport }
    }

    /// What the workouts block has to say. The two empty cases are DIFFERENT facts about the user's
    /// data and printing the wrong one is a lie, so they never collapse into one "no data" state.
    enum Readout: Equatable {
        /// Sports that cleared `ActivityCostEngine.minSessions`, biggest mover first.
        case ranked([SportCost])
        /// Every day carrying a Charge score is a session day or sits inside a session's
        /// D+1…D+`maxLookahead` window — there is no untouched day left to measure a session against.
        case noRestDays
        /// No sport has `ActivityCostEngine.minSessions` sessions with a Charge score the next morning.
        case tooFewPairs
    }

    /// Fold the two published caches and run the engine over them.
    static func readout(workouts: [WorkoutRow], days: [DailyMetric]) -> Readout {
        let sports = sportDays(workouts)
        let recovery = recoveryByDay(days)
        guard !sports.daysByKey.isEmpty, !recovery.isEmpty else { return .tooFewPairs }
        // Checked BEFORE evaluate: a contaminated-baseline `[]` and a too-thin `[]` are the same
        // value, so the only way to tell them apart is to test the precondition ourselves.
        guard hasUntouchedDay(daysBySport: sports.daysByKey, recoveryByDay: recovery) else {
            return .noRestDays
        }
        let costs = ActivityCostEngine.evaluate(activityDaysBySport: sports.daysByKey,
                                                recoveryByDay: recovery)
        guard !costs.isEmpty else { return .tooFewPairs }
        return .ranked(costs.map { SportCost(label: sports.labels[$0.sport] ?? $0.sport, cost: $0) })
    }

    // MARK: - Fold

    /// Tagged day keys per folded sport key, plus the label each key prints under.
    struct SportDays: Equatable {
        let daysByKey: [String: Set<String>]
        let labels: [String: String]
    }

    /// `WorkoutRepository.workouts` → the engine's `activityDaysBySport`. A session is tagged on the
    /// LOGICAL day it started (`Repository.logicalDayKey`, rollover 04:00), still in the same
    /// `yyyy-MM-dd` space `days` is stored under, so the two dictionaries join exactly as before.
    /// The label is the FIRST spelling in the cache — newest-first, so it is the user's most recent
    /// capitalisation and deterministic for a given cache.
    ///
    /// It used to tag on the CALENDAR day, which broke the engine's whole premise for anything
    /// logged after midnight. The engine reads a session's cost as `Charge[D + 1]` — the next
    /// morning. A 00:32 session tagged on its calendar day therefore paired with the morning about
    /// THIRTY hours later, on the far side of a different night's sleep, while the morning it
    /// actually wrecked — the one a few hours after it — was excluded from that sport's mean
    /// entirely and could be credited to whatever else was tagged the previous day. Tagging on the
    /// logical day groups the session with the evening it belongs to, so `D + 1` is the morning its
    /// own following sleep produced. Sessions after 04:00 are unaffected: the two keys agree.
    static func sportDays(_ workouts: [WorkoutRow]) -> SportDays {
        var daysByKey: [String: Set<String>] = [:]
        var labels: [String: String] = [:]
        for row in workouts {
            let key = sportKey(row.sport)
            guard !key.isEmpty else { continue }        // a blank sport joins nothing
            let day = Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
            daysByKey[key, default: []].insert(day)
            if labels[key] == nil { labels[key] = sportLabel(row.sport) }
        }
        return SportDays(daysByKey: daysByKey, labels: labels)
    }

    /// `Repository.days` → the engine's `recoveryByDay`. A day with no Charge is simply ABSENT; the
    /// engine reads absence as "no value" and would read a zero as a Charge of 0.
    static func recoveryByDay(_ days: [DailyMetric]) -> [String: Double] {
        var out: [String: Double] = [:]
        for d in days { if let v = d.recovery { out[d.day] = v } }
        return out
    }

    // MARK: - Sport keying

    /// The evidence-joining key: camelCase split through the LOCALE-STABLE `WorkoutSource.editableSport`
    /// (so a WHOOP "TraditionalStrengthTraining" and a relabel's "Traditional Strength Training" are one
    /// sport), then lower-cased with every whitespace run collapsed (so " run " and "Run" are one too).
    static func sportKey(_ sport: String) -> String {
        WorkoutSource.editableSport(sport)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// What that key prints as — the row's own display spelling, whitespace-collapsed so a stray double
    /// space in a hand-typed sport never reaches the page.
    static func sportLabel(_ sport: String) -> String {
        WorkoutSource.displaySport(sport)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: - Baseline precondition

    /// True when at least one day carrying a Charge score sits OUTSIDE every session day AND outside
    /// every session's D+1…D+`maxLookahead` after-effect window. This is the engine's own baseline
    /// precondition (`ActivityCostEngine.swift:136-149`) restated — not to duplicate the maths, but so
    /// the screen can name the reason it got nothing back. `ScoreEngine.shiftDay` is the app-side twin
    /// of the package-internal `CorrelationEngine.shiftDay` the engine steps with, so both walk the same
    /// fixed-UTC keys and can never disagree about which days are touched.
    static func hasUntouchedDay(daysBySport: [String: Set<String>],
                                recoveryByDay: [String: Double]) -> Bool {
        var sessionDays: Set<String> = []
        for (_, days) in daysBySport { sessionDays.formUnion(days) }
        var affected = sessionDays
        for day in sessionDays {
            for k in 1...ActivityCostEngine.maxLookahead {
                if let d = ScoreEngine.shiftDay(day, by: k) { affected.insert(d) }
            }
        }
        return recoveryByDay.keys.contains { !affected.contains($0) }
    }
}
