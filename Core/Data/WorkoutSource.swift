import Foundation
import StrapStore

/// Origin of a workout row, classified from its stored `source` column. The read model
/// (`WorkoutRow`) carries no `deviceId`, so the row's origin has to be recovered from `source`.
/// Stored values today:
///   - "whoop"        — imported WHOOP session
///   - "apple_health" / "apple-health" — Apple Health import
///   - "manual"       — WorkoutSessionController.endWorkout (live session) AND the retro add/edit sheet
///   - "my-whoop-computed"— ScoreEngine detected bouts (source == the computed deviceId, i.e. it ends
///                       in "-computed"). These are re-derived every analyzeRecent run.
///
/// Classification order matters: "-computed" is checked BEFORE "whoop" because the computed id
/// "my-whoop-computed" also contains the substring "whoop".
///
/// Ported+pruned from the original `Strand/Data/WorkoutSource.swift` for whoopmaxx W7: the Test-Centre
/// `.workouts` trace helpers (`traceSportKey`, `sourceLabel`, `dedupCrossSourceTrace`) and the
/// `import StrapAnalytics` they needed are STRIPPED — whoopmaxx surfaces strap-detected + manual
/// workouts only, with no diagnostic trace lane.
enum WorkoutSource: Equatable {
    case whoop, apple, detected, manual, lifting, activityFile

    /// Canonical Apple Health source id written by new imports. Early rows used the underscore
    /// spelling, so reads must accept both — see `isAppleHealth`.
    static let appleHealthSource = "apple-health"
    private static let legacyAppleHealthSource = "apple_health"

    static func classify(_ source: String) -> WorkoutSource {
        let s = source.lowercased()
        if s.hasSuffix("-computed") { return .detected }   // BEFORE whoop: "my-whoop-computed" contains "whoop"
        if s == "manual" { return .manual }
        if s == "lifting" { return .lifting }          // imported Hevy / Liftosaur strength session
        if s == "activity-file" { return .activityFile } // imported GPX / TCX / FIT activity file
        if isAppleHealth(s) { return .apple }          // both spellings → Apple Health
        if s.contains("whoop") { return .whoop }
        return .apple
    }

    /// True for an Apple Health workout row regardless of which spelling it was stored under — the
    /// canonical `apple-health` or the legacy `apple_health`. Case-insensitive.
    static func isAppleHealth(_ source: String) -> Bool {
        let s = source.lowercased()
        return s == appleHealthSource || s == legacyAppleHealthSource
    }

    /// Sport-cell text. The detector stores the machine token "detected"; show it as a neutral
    /// "Activity" (we don't claim a sport we didn't actually classify). WHOOP sport names arrive as
    /// concatenated camelCase (e.g. "TraditionalStrengthTraining") and truncate badly — split them on
    /// the lower→Upper boundary so they read "Traditional Strength Training". Spaced labels pass through.
    static func displaySport(_ sport: String) -> String {
        if sport == "detected" { return String(localized: "Activity") }
        return splitCamelCase(sport)
    }

    /// The camelCase splitter shared by the display and KEY paths. Deliberately NOT localized: the key
    /// path below must be locale-stable.
    private static func splitCamelCase(_ sport: String) -> String {
        if sport.isEmpty || sport.contains(" ") { return sport }
        var out = ""
        var prev: Character?
        for ch in sport {
            if let p = prev, ch.isUppercase, !p.isUppercase { out.append(" ") }
            out.append(ch)
            prev = ch
        }
        return out
    }

    /// The locale-stable editable form: what an edit field should SEED so a save round-trips a stable
    /// token ("Activity", never a translated word that would split cross-source dedup per language).
    static func editableSport(_ sport: String) -> String {
        sport == "detected" ? "Activity" : splitCamelCase(sport)
    }

    // MARK: - Dismissed detected bouts (durable across re-detection)
    //
    // The engine wipes + re-derives "detected" rows every run, so deleting a detected row from the
    // table would only hide it until the next analyzeRecent recreates the same (startTs, sport) PK.
    // The durable "this isn't a workout" record is a list of dismissed time spans persisted in
    // UserDefaults. A detected row overlapping any dismissed span stays hidden. (#107)

    /// UserDefaults key holding the dismissed spans as "startTs:endTs" strings.
    static let dismissedDefaultsKey = "workouts.dismissedDetected"

    /// Parse "startTs:endTs" spans (UserDefaults string array). Malformed / non-positive-width entries
    /// are dropped so a corrupt value can never hide everything.
    static func parseDismissedSpans(_ raw: [String]) -> [(start: Int, end: Int)] {
        raw.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (a, b)
        }
    }

    /// The "startTs:endTs" token persisted for a dismissed row.
    static func dismissedToken(for row: WorkoutRow) -> String { "\(row.startTs):\(row.endTs)" }

    /// Read-time filter: a DETECTED row overlapping any dismissed span is hidden. Imported / manual rows
    /// are never auto-hidden (the user deletes those outright). Half-open overlap test.
    static func isDismissed(_ row: WorkoutRow, spans: [(start: Int, end: Int)]) -> Bool {
        classify(row.source) == .detected
            && spans.contains { row.startTs < $0.end && $0.start < row.endTs }
    }

    // MARK: - Cross-source dedup (#687)
    //
    // The SAME activity can land twice: once live/tracked under the strap (rich — HR trace, strain,
    // zones), and once imported from Apple Health for the same window (thin — usually just duration +
    // calories). They sit under different sources, so the list shows both. Collapse a pair that is
    // clearly the same bout (overlapping window + same sport) to a single richer entry.

    /// Normalised sport key for cross-source matching. Folds the WHOOP camelCase token and a
    /// human-readable import label to the same key, case- and space-insensitive.
    static func sportKey(_ sport: String) -> String {
        editableSport(sport).lowercased().filter { !$0.isWhitespace }
    }

    /// How many "rich" captured signals a row carries — the tiebreak for which duplicate to keep.
    static func richness(_ row: WorkoutRow) -> Int {
        var n = 0
        if row.avgHr != nil { n += 1 }
        if row.maxHr != nil { n += 1 }
        if row.strain != nil { n += 1 }
        if let z = row.zonesJSON, !z.isEmpty { n += 1 }
        if let d = row.distanceM, d > 0 { n += 1 }
        if let k = row.energyKcal, k > 0 { n += 1 }
        return n
    }

    /// True when two rows are the SAME activity from different sources: same normalised sport AND their
    /// time windows overlap by more than half of the shorter session.
    static func sameActivity(_ a: WorkoutRow, _ b: WorkoutRow) -> Bool {
        guard sportKey(a.sport) == sportKey(b.sport) else { return false }
        let overlap = min(a.endTs, b.endTs) - max(a.startTs, b.startTs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(a.endTs - a.startTs, b.endTs - b.startTs))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    /// Of two same-activity rows, the one to KEEP. Prefer the richer; on a tie prefer the strap-native
    /// source over a thin import; final tie → the longer session, then `a` (stable).
    static func preferred(_ a: WorkoutRow, _ b: WorkoutRow) -> WorkoutRow {
        let ra = richness(a), rb = richness(b)
        if ra != rb { return ra > rb ? a : b }
        let ia = classify(a.source) == .apple, ib = classify(b.source) == .apple
        if ia != ib { return ia ? b : a }   // keep the non-import on a richness tie
        let da = a.endTs - a.startTs, db = b.endTs - b.startTs
        if da != db { return da > db ? a : b }
        return a
    }

    // MARK: - Detected-vs-real overlap collapse (#975)
    //
    // The engine derives a "detected" bout from raw HR and DROPS it when it overlaps a real logged
    // session, but only on the next analyze pass. Between a live/manual session ending and that pass,
    // BOTH the manual row AND the detected shadow of the same bout show. This read-time guard mirrors
    // the engine's own rule so the list never shows the transient duplicate.

    /// True when `detected` is a redundant shadow of `real` (a non-detected session): their windows
    /// overlap by more than half of the shorter session.
    static func detectedShadowsReal(_ detected: WorkoutRow, _ real: WorkoutRow) -> Bool {
        let overlap = min(detected.endTs, real.endTs) - max(detected.startTs, real.startTs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(detected.endTs - detected.startTs, real.endTs - real.startTs))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    /// Drop every DETECTED row whose window shadows a REAL (non-detected) session in the same list, so
    /// the live/manual session and its detected twin never both show. Order-stable.
    static func dropDetectedShadows(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        let reals = rows.filter { classify($0.source) != .detected }
        guard !reals.isEmpty else { return rows }
        return rows.filter { row in
            guard classify(row.source) == .detected else { return true }
            return !reals.contains { detectedShadowsReal(row, $0) }
        }
    }

    /// Collapse cross-source duplicates of the same activity, keeping the richer row of each pair.
    /// Order-stable; single-source lists pass through unchanged. A detected bout that shadows a real
    /// logged session is dropped FIRST so the transient live+detected duplicate never shows.
    static func dedupCrossSource(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        var kept: [WorkoutRow] = []
        let input = dropDetectedShadows(rows)
        kept.reserveCapacity(input.count)
        outer: for row in input {
            for i in kept.indices where sameActivity(kept[i], row) {
                kept[i] = preferred(kept[i], row)
                continue outer
            }
            kept.append(row)
        }
        return kept
    }

    // MARK: - Building / preserving rows

    /// Carry the captured fields the add/edit sheet does NOT expose (maxHr, strain, distanceM,
    /// zonesJSON, notes) over from the row being edited. No-op for a fresh add (`old == nil`).
    static func preservingCaptured(_ row: WorkoutRow, from old: WorkoutRow?) -> WorkoutRow {
        guard let old else { return row }
        return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                          source: row.source, durationS: row.durationS,
                          energyKcal: row.energyKcal, avgHr: row.avgHr,
                          maxHr: old.maxHr, strain: old.strain, distanceM: old.distanceM,
                          zonesJSON: old.zonesJSON, notes: old.notes)
    }

    /// Build a retroactive manual workout (source "manual", persisted under the strap deviceId by the
    /// caller). Returns nil when the input can't make an honest row. strain/zones stay nil: with no
    /// captured HR window an APPROXIMATE strain is never fabricated.
    static func buildManualRow(start: Date, durationMin: Int, sport: String,
                               avgHr: Int?, energyKcal: Double?, now: Date = Date()) -> WorkoutRow? {
        guard durationMin > 0, durationMin <= 24 * 60 else { return nil }
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, start <= now else { return nil }
        if let hr = avgHr, !(25...250).contains(hr) { return nil }
        if let k = energyKcal, k < 0 || k > 20_000 { return nil }
        let s = Int(start.timeIntervalSince1970)
        guard s > 0 else { return nil }
        return WorkoutRow(startTs: s, endTs: s + durationMin * 60, sport: trimmed, source: "manual",
                          durationS: Double(durationMin) * 60, energyKcal: energyKcal,
                          avgHr: avgHr, maxHr: nil, strain: nil, distanceM: nil,
                          zonesJSON: nil, notes: nil)
    }
}

// MARK: - Filter predicate (#64)
//
// The Workouts list filters beyond the time range: a SPORT filter, a SOURCE filter, and a free-text
// SEARCH over the displayed sport name. All three are pure and compose. Kept for parity + tests; MVP
// wires no facet UI.

/// One workout-list filter state. `sport` is a displayed-sport key (`WorkoutSource.displaySport`), nil
/// = all sports. `sourceClass` is the origin class, nil = all sources. `search` is a free-text query.
struct WorkoutFilter: Equatable {
    var sport: String?
    var sourceClass: WorkoutSource?
    var search: String

    init(sport: String? = nil, sourceClass: WorkoutSource? = nil, search: String = "") {
        self.sport = sport
        self.sourceClass = sourceClass
        self.search = search
    }

    /// True when no facet is active — the caller can skip the walk and keep the input verbatim.
    var isActive: Bool {
        sport != nil || sourceClass != nil
            || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Does one row pass every active facet? Sport matches on the DISPLAYED name; source matches on
    /// `classify`; search is a case-insensitive substring of the displayed sport.
    func matches(_ row: WorkoutRow) -> Bool {
        if let sport, WorkoutSource.displaySport(row.sport) != sport { return false }
        if let sourceClass, WorkoutSource.classify(row.source) != sourceClass { return false }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty,
           WorkoutSource.displaySport(row.sport).range(of: q, options: .caseInsensitive) == nil {
            return false
        }
        return true
    }

    /// Apply the filter to a windowed list, preserving order. A no-op when nothing is active.
    func apply(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        guard isActive else { return rows }
        return rows.filter(matches)
    }
}

// MARK: - Merge (#64)
//
// Merge two-or-more overlapping / adjacent MANUAL or DETECTED sessions into one, keeping the richer
// captured signals. Imported history is NEVER merged. Pure + deterministic; MVP ports the math for
// tests but wires no merge UI (spec cut line).

enum WorkoutMerge {

    /// Only MANUAL and DETECTED rows can be merged (imported history stays read-only).
    static func isMergeable(_ row: WorkoutRow) -> Bool {
        switch WorkoutSource.classify(row.source) {
        case .manual, .detected: return true
        case .whoop, .apple, .lifting, .activityFile: return false
        }
    }

    /// True when a set of selected rows can be merged: two or more, and every one is mergeable.
    static func canMerge(_ rows: [WorkoutRow]) -> Bool {
        rows.count >= 2 && rows.allSatisfy(isMergeable)
    }

    /// The sport the merge should carry: the most-frequent non-"detected" sport across the inputs (ties
    /// broken by first appearance), or nil when every input is a bare detected bout.
    static func resolvedSport(_ rows: [WorkoutRow]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for r in rows where r.sport != "detected" {
            let s = r.sport
            if counts[s] == nil { order.append(s) }
            counts[s, default: 0] += 1
        }
        guard !order.isEmpty else { return nil }
        return order.max(by: { (counts[$0] ?? 0, order.firstIndex(of: $1) ?? 0)
                                < (counts[$1] ?? 0, order.firstIndex(of: $0) ?? 0) })
    }

    /// Merge the given rows into one manual row. Math: startTs = min, endTs = max; durationS = SUM;
    /// energyKcal = SUM (nil when none); avgHr = duration-weighted mean; maxHr = max; distanceM = SUM;
    /// strain = nil (rescored later); zonesJSON = nil; notes = joined. Returns nil for < 2 rows.
    static func merge(_ rows: [WorkoutRow], sport: String? = nil) -> WorkoutRow? {
        guard rows.count >= 2 else { return nil }
        let start = rows.map(\.startTs).min() ?? rows[0].startTs
        let end = rows.map(\.endTs).max() ?? rows[0].endTs

        let durationS = rows.reduce(0.0) { $0 + ($1.durationS ?? Double(max(0, $1.endTs - $1.startTs))) }

        let kcals = rows.compactMap(\.energyKcal)
        let energyKcal = kcals.isEmpty ? nil : kcals.reduce(0, +)
        let dists = rows.compactMap(\.distanceM)
        let distanceM = dists.isEmpty ? nil : dists.reduce(0, +)

        var hrWeight = 0.0, hrSum = 0.0
        for r in rows {
            guard let hr = r.avgHr else { continue }
            let w = r.durationS ?? Double(max(1, r.endTs - r.startTs))
            hrWeight += w
            hrSum += Double(hr) * w
        }
        let avgHr = hrWeight > 0 ? Int((hrSum / hrWeight).rounded()) : nil
        let maxHr = rows.compactMap(\.maxHr).max()

        let notes = rows.compactMap { $0.notes?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let mergedNotes = notes.isEmpty ? nil : notes.joined(separator: " · ")

        let mergedSport = sport ?? resolvedSport(rows) ?? "Activity"

        return WorkoutRow(startTs: start, endTs: end, sport: mergedSport, source: "manual",
                          durationS: durationS, energyKcal: energyKcal, avgHr: avgHr, maxHr: maxHr,
                          strain: nil, distanceM: distanceM, zonesJSON: nil, notes: mergedNotes)
    }
}
