import Foundation
import StrapStore

/// Stable, Hashable navigation identity for a `WorkoutRow` (which is neither Identifiable nor Hashable),
/// keyed by its natural key so a push survives a refresh that rebuilds the row.
struct WorkoutRef: Identifiable, Hashable {
    let row: WorkoutRow
    var id: String { "\(row.source)|\(row.startTs)|\(row.sport)" }
    static func == (l: WorkoutRef, r: WorkoutRef) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Presentation helpers shared by the list / detail / Today rows.
enum WorkoutFormat {
    static func durationSeconds(_ row: WorkoutRow) -> Int {
        Int(row.durationS ?? Double(max(0, row.endTs - row.startTs)))
    }

    /// "58 min" / "1 h 12 min" / "1 h" — the SPELLED style; the gap rows' "2h 35m" is a different
    /// shipped spelling, so this must not be collapsed into it.
    static func duration(seconds: Int) -> String {
        WMFormat.duration(seconds: seconds, style: .spelled)
    }

    static func duration(_ row: WorkoutRow) -> String { duration(seconds: durationSeconds(row)) }

    /// "Today" / "Yesterday" / "Jun 23" for a workout's start.
    static func relativeDay(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let cal = Calendar.current
        if cal.isDateInToday(d) { return String(localized: "Today") }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday") }
        return dayFmt.string(from: d)
    }

    /// "14:05".
    static func time(_ ts: Int) -> String { timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }

    /// "Wednesday, Jun 23 · 14:05".
    static func longDateTime(_ ts: Int) -> String {
        longFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Strain as a rounded Effort integer, or nil.
    static func strainText(_ strain: Double?) -> String? { strain.map { String(Int($0.rounded())) } }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("MMM d"); return f
    }()
    private static let longFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEE MMM d  HH:mm"); return f
    }()
}
