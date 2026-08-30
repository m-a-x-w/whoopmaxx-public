import Foundation

/// The named-sport catalogue for the workout pickers (manual add/edit + live tracking). The names are
/// DATA, not UI literals: they're persisted verbatim as the sport label and must never be localised (a
/// translated name would split one sport into two). Free-text stays allowed everywhere — this catalogue
/// is the suggestion set, not a whitelist (#519).
///
/// Ported verbatim from the original `Strand/Data/WorkoutCatalog.swift`.
enum WorkoutCatalog {

    /// One selectable activity. `name` is the verbatim stored/display label.
    struct Sport: Identifiable, Hashable {
        let name: String
        /// Types where a route makes sense → GPS hint / default on (unused in whoopmaxx MVP — no routes).
        let isDistanceSport: Bool
        /// SF Symbol drawn on the sport chip (ink, so it matches the precision-instrument chrome). Names are
        /// from the `figure.*` sports family; a sport without a dedicated glyph reuses its nearest relative.
        let icon: String
        var id: String { name }
    }

    /// Common / distance first, the rest, then the generic "Other" last.
    static let all: [Sport] = [
        Sport(name: "Running", isDistanceSport: true, icon: "figure.run"),
        Sport(name: "Walking", isDistanceSport: true, icon: "figure.walk"),
        Sport(name: "Hiking", isDistanceSport: true, icon: "figure.hiking"),
        Sport(name: "Cycling", isDistanceSport: true, icon: "figure.outdoor.cycle"),
        Sport(name: "Open-water swim", isDistanceSport: true, icon: "figure.open.water.swim"),
        Sport(name: "Rowing", isDistanceSport: true, icon: "figure.rower"),
        Sport(name: "Treadmill run", isDistanceSport: false, icon: "figure.run"),
        Sport(name: "Treadmill walk", isDistanceSport: false, icon: "figure.walk"),
        Sport(name: "Indoor cycle", isDistanceSport: false, icon: "figure.indoor.cycle"),
        Sport(name: "Pool swim", isDistanceSport: false, icon: "figure.pool.swim"),
        Sport(name: "Row machine", isDistanceSport: false, icon: "figure.rower"),
        Sport(name: "Elliptical", isDistanceSport: false, icon: "figure.elliptical"),
        Sport(name: "Strength", isDistanceSport: false, icon: "figure.strengthtraining.traditional"),
        Sport(name: "Bodybuilding", isDistanceSport: false, icon: "figure.strengthtraining.traditional"),
        Sport(name: "Weightlifting", isDistanceSport: false, icon: "figure.strengthtraining.functional"),
        Sport(name: "HIIT", isDistanceSport: false, icon: "figure.highintensity.intervaltraining"),
        Sport(name: "Yoga", isDistanceSport: false, icon: "figure.yoga"),
        Sport(name: "Pilates", isDistanceSport: false, icon: "figure.pilates"),
        Sport(name: "Boxing", isDistanceSport: false, icon: "figure.boxing"),
        Sport(name: "Basketball", isDistanceSport: false, icon: "figure.basketball"),
        Sport(name: "Soccer", isDistanceSport: false, icon: "figure.outdoor.soccer"),
        Sport(name: "Baseball", isDistanceSport: false, icon: "figure.baseball"),
        Sport(name: "Badminton", isDistanceSport: false, icon: "figure.badminton"),
        Sport(name: "Tennis", isDistanceSport: false, icon: "figure.tennis"),
        Sport(name: "Squash", isDistanceSport: false, icon: "figure.squash"),
        Sport(name: "Racquetball", isDistanceSport: false, icon: "figure.racquetball"),
        Sport(name: "Table tennis", isDistanceSport: false, icon: "figure.table.tennis"),
        Sport(name: "Volleyball", isDistanceSport: false, icon: "figure.volleyball"),
        Sport(name: "Martial arts", isDistanceSport: false, icon: "figure.martial.arts"),
        Sport(name: "Dancing", isDistanceSport: false, icon: "figure.dance"),
        Sport(name: "Golf", isDistanceSport: false, icon: "figure.golf"),
        Sport(name: "Climbing", isDistanceSport: false, icon: "figure.climbing"),
        Sport(name: "Stretching", isDistanceSport: false, icon: "figure.flexibility"),
        Sport(name: "Skiing", isDistanceSport: true, icon: "figure.skiing.downhill"),
        Sport(name: "Snowboarding", isDistanceSport: true, icon: "figure.snowboarding"),
        Sport(name: "Padel", isDistanceSport: false, icon: "figure.tennis"),
        Sport(name: "Pickleball", isDistanceSport: false, icon: "figure.pickleball"),
        Sport(name: "Bowling", isDistanceSport: false, icon: "figure.bowling"),
        Sport(name: "Other", isDistanceSport: false, icon: "figure.mixed.cardio"),
    ]

    /// The default sport for a live workout when the user starts one without picking — the generic
    /// "Other". (The auto-detector relabels detected bouts; this is only the manual-start fallback.)
    static let defaultSportName = "Other"

    /// Case-insensitive lookup of the suggestion matching a (possibly free-typed) label, or nil for an
    /// off-catalogue sport — which is still valid, just not in the suggestion set.
    static func sport(named name: String) -> Sport? {
        let q = name.trimmingCharacters(in: .whitespaces)
        return all.first { $0.name.caseInsensitiveCompare(q) == .orderedSame }
    }

    /// Catalogue filtered by a search query (empty → the whole list). Names only, case-insensitive.
    static func matching(_ query: String) -> [Sport] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
    }
}
