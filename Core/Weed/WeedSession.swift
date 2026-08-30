import Foundation
import StrapStore

/// How a session was taken. Raw values are the STABLE lowercase strings persisted in
/// `WeedSessionRow.method`, so display copy can change without a migration (the `HabitKind` pattern).
/// There is deliberately no `.unknown` / `.notRecorded` case: absence is modelled by the Optional at
/// every call site, so a nil can never be rendered as a fabricated default.
enum WeedMethod: String, CaseIterable, Identifiable {
    case flower
    case vape
    case edible
    case concentrate
    case other

    var id: String { rawValue }

    /// Display label for the editor chips and the session row (the stored key never changes; copy can).
    var label: String {
        switch self {
        case .flower:       return "Flower"
        case .vape:         return "Vape"
        case .edible:       return "Edible"
        case .concentrate:  return "Concentrate"
        case .other:        return "Other"
        }
    }
}

/// Relative strength the USER sets — explicitly NOT milligrams (the documented caffeine precedent,
/// `DoseResponsePriors.swift:29-31`: a self-reported dose the app cannot verify is an ordinal, and
/// dressing it as a measured amount would be the claim). Stored as the 1|2|3 ordinal so the ORDER is
/// the data; nothing in 009 analyses it.
enum WeedPotency: Int, CaseIterable, Identifiable {
    case light = 1
    case usual = 2
    case heavy = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .light:  return "Light"
        case .usual:  return "Usual"
        case .heavy:  return "Heavy"
        }
    }
}

/// One logged weed session — the app-side domain twin of the flat v26 `WeedSessionRow`.
///
/// `day` is the key the CHIP wrote for the tap (`Repository.anchorKey` live, the Today stepper's
/// `selectedKey` back-dated) and is NEVER re-derived from `ts`: `DayKey.local` and
/// `DayKey.logicalKey` disagree with `anchorKey` across the 00:00-04:00 window, which is exactly
/// where a post-midnight session lives, so deriving it would let a session and its own boolean land
/// on different days. `ts` is for display and ordering only.
///
/// A session is DETAIL. The merged `journal` row for "weed" stays the single truth for whether a day
/// is a weed day, which is what lets a legacy chip-only day (every weed day from Jul 22 to 009) keep
/// confounding the monitor and ranking in insights with zero sessions.
struct WeedSession: Identifiable, Equatable {
    /// Client-generated, the table's whole PK — there is deliberately no natural key, because the
    /// editor's minute-resolution DatePicker makes two sessions at the same `ts` legal.
    let id: String
    /// yyyy-MM-dd, the chip's day key (see type doc).
    var day: String
    /// Epoch seconds.
    var ts: Int
    /// False marks a DECLARED placeholder clock (a back-dated tap lands on 21:00 local), so the UI
    /// says "Time not recorded" instead of rendering a fabricated 21:00 as an observation.
    var tsExact: Bool
    /// Nil = not recorded. The one-tap chip path writes nil.
    var method: WeedMethod?
    /// Nil = not recorded.
    var potency: WeedPotency?
    /// `manualSource` for a session the user logged, `"demo"` for a seeded one.
    var source: String
    var createdAt: Int

    /// Provenance of a session the user logged themselves. The demo seed writes `"demo"` and clears
    /// itself by lane (`deleteWeedSessions(deviceId:source:)`), so the two never collide.
    static let manualSource = "manual"

    /// Whether the session carries anything the user TYPED. A bare one-tap session holds only a
    /// timestamp we can recreate, which is what lets clearing the chip stay frictionless — the
    /// confirmation dialog is owed only when clearing would discard real input.
    var hasRecordedDetail: Bool { method != nil || potency != nil }

    // MARK: Mapping

    init(id: String = UUID().uuidString, day: String, ts: Int, tsExact: Bool = true,
         method: WeedMethod? = nil, potency: WeedPotency? = nil,
         source: String = WeedSession.manualSource,
         createdAt: Int = Int(Date().timeIntervalSince1970)) {
        self.id = id; self.day = day; self.ts = ts; self.tsExact = tsExact
        self.method = method; self.potency = potency
        self.source = source; self.createdAt = createdAt
    }

    init(_ row: WeedSessionRow) {
        self.id = row.id
        self.day = row.day
        self.ts = row.ts
        self.tsExact = row.tsExact
        // An unrecognised stored method is still a RECORDED one — a future build's new case must
        // decode as `.other`, never as nil, or a downgrade would silently turn "the user told us"
        // into "not recorded". Potency has no such landing: an out-of-range ordinal carries no order
        // we can honour, so it reads as unrecorded rather than being clamped into a strength the
        // user never chose.
        self.method = row.method.map { WeedMethod(rawValue: $0) ?? .other }
        self.potency = row.potency.flatMap(WeedPotency.init(rawValue:))
        self.source = row.source
        self.createdAt = row.createdAt
    }

    /// The flat storage row. `deviceId` is always `StrapStore.weedSourceId` — ONE constant lane, so
    /// it is not carried on the domain type: the 3-lane merge `JournalStore` needs exists only
    /// because `journal` is shared with WHOOP-CSV imports and restored foreign installs, and a
    /// brand-new uuid-keyed table has no such legacy.
    var row: WeedSessionRow {
        WeedSessionRow(id: id, deviceId: StrapStore.weedSourceId, day: day, ts: ts, tsExact: tsExact,
                       method: method?.rawValue, potency: potency?.rawValue, source: source,
                       createdAt: createdAt)
    }
}
