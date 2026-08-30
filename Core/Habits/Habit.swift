import Foundation
import StrapStore

/// LEGACY storage labels for a habit. Raw values are the STABLE snake_case strings persisted in
/// `HabitDef.kind` — old definitions must keep decoding, so the cases stay. Every habit is now
/// manually logged (strap auto-verification was removed); new habits always save as `.manual`,
/// and a non-manual kind only survives as a display-name fallback for unnamed legacy habits.
enum HabitKind: String, CaseIterable, Identifiable, Equatable {
    case sleepBy = "sleep_by"
    case wakeBy = "wake_by"
    case sleepDuration = "sleep_duration"
    case train
    case nap
    case windDown = "wind_down"
    case manual

    var id: String { rawValue }

    /// Legacy label fallback: an unnamed old habit still reads as its kind's name.
    var displayName: String {
        switch self {
        case .sleepBy:        return "Sleep by"
        case .wakeBy:         return "Wake by"
        case .sleepDuration:  return "Sleep duration"
        case .train:          return "Train today"
        case .nap:            return "Nap today"
        case .windDown:       return "Wind down"
        case .manual:         return "Custom"
        }
    }
}

/// How often a habit is scheduled — decides when a miss counts and what the adherence denominator is.
enum HabitCadence: Equatable {
    /// Every day.
    case daily
    /// N times per week; any day is eligible, the week's rate is done/N.
    case weekly(Int)
    /// Specific weekdays, as a bitmask over `Calendar` weekday (bit i set = weekday i, 1=Sun … 7=Sat).
    case weekdays(Int)
    /// No schedule, no rate — loggable but never a miss.
    case anytime

    /// Decompose into the flat (cadence, cadenceN, weekdaysMask) storage triple.
    var stored: (cadence: String, n: Int?, mask: Int?) {
        switch self {
        case .daily:               return ("daily", nil, nil)
        case let .weekly(n):       return ("weekly", n, nil)
        case let .weekdays(mask):  return ("weekdays", nil, mask)
        case .anytime:             return ("anytime", nil, nil)
        }
    }

    static func from(cadence: String, n: Int?, mask: Int?) -> HabitCadence {
        switch cadence {
        case "weekly":   return .weekly(n ?? 1)
        case "weekdays": return .weekdays(mask ?? 0)
        case "anytime":  return .anytime
        default:         return .daily
        }
    }
}

/// A wrist-buzz window (minutes-since-midnight). The app fires a buzz once/day at the window start
/// on the first live+worn tick inside it (008 — HR-picked timing within the window is deferred).
struct HabitBuzzWindow: Equatable {
    var start: Int
    var end: Int
}

/// The app-side domain habit. Maps to/from the flat `HabitDef` storage struct.
struct Habit: Identifiable, Equatable {
    let id: String
    var name: String
    var kind: HabitKind
    var cadence: HabitCadence
    /// sleep_by / wake_by: target clock time as minutes-since-midnight. sleep_duration: target minutes.
    var targetMinutes: Int?
    var buzz: HabitBuzzWindow?
    var pinned: Bool
    var sortOrder: Int
    var archived: Bool
    var createdAt: Int

    /// Effective display name: a custom habit uses its typed name; a measurable habit falls back to
    /// its kind's name when unnamed.
    var displayName: String { name.isEmpty ? kind.displayName : name }

    // MARK: Mapping

    init(id: String, name: String, kind: HabitKind, cadence: HabitCadence, targetMinutes: Int? = nil,
         buzz: HabitBuzzWindow? = nil, pinned: Bool = true, sortOrder: Int = 0,
         archived: Bool = false, createdAt: Int) {
        self.id = id; self.name = name; self.kind = kind; self.cadence = cadence
        self.targetMinutes = targetMinutes; self.buzz = buzz; self.pinned = pinned
        self.sortOrder = sortOrder; self.archived = archived; self.createdAt = createdAt
    }

    init(_ def: HabitDef) {
        self.id = def.id
        self.name = def.name
        self.kind = HabitKind(rawValue: def.kind) ?? .manual
        self.cadence = HabitCadence.from(cadence: def.cadence, n: def.cadenceN, mask: def.weekdaysMask)
        self.targetMinutes = def.targetMinutes
        self.buzz = (def.buzzEnabled && def.buzzWindowStart != nil && def.buzzWindowEnd != nil)
            ? HabitBuzzWindow(start: def.buzzWindowStart!, end: def.buzzWindowEnd!) : nil
        self.pinned = def.pinned
        self.sortOrder = def.sortOrder
        self.archived = def.archived
        self.createdAt = def.createdAt
    }

    var def: HabitDef {
        let c = cadence.stored
        return HabitDef(id: id, name: name, kind: kind.rawValue, cadence: c.cadence,
                        cadenceN: c.n, weekdaysMask: c.mask, targetMinutes: targetMinutes,
                        buzzEnabled: buzz != nil, buzzWindowStart: buzz?.start,
                        buzzWindowEnd: buzz?.end, pinned: pinned, sortOrder: sortOrder,
                        archived: archived, createdAt: createdAt)
    }
}
