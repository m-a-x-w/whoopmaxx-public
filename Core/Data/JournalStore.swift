import Foundation
import Combine
import StrapStore

/// The fixed whoopmaxx journal tag set — boolean day tags logged from Today's Journal chip row.
/// Question strings persist as these STABLE snake_case keys (display labels are app-side only and
/// free to change), deliberately aligned with `IllnessSignalEngine.Context`'s confounders
/// (alcohol / stress / sauna / travelPhaseJump) so the health monitor can read them without a
/// mapping table.
enum JournalTag: String, CaseIterable, Identifiable {
    case alcohol
    /// Caffeine after ~14:00 — late enough to plausibly touch the night.
    case caffeineLate = "caffeine_late"
    case lateMeal = "late_meal"
    case stress
    case sauna
    case travel
    case sick
    case weed

    var id: String { rawValue }

    /// Display label for chips / insight rows (the stored key never changes; copy can).
    var label: String {
        switch self {
        case .alcohol:         return "Alcohol"
        case .caffeineLate:    return "Late caffeine"
        case .lateMeal:        return "Late meal"
        case .stress:          return "Stress"
        case .sauna:           return "Sauna"
        case .travel:          return "Travel"
        case .sick:            return "Sick"
        case .weed:            return "Weed"
        }
    }

    /// Display label for ANY stored question key: the fixed tags map to their labels; an imported
    /// question (a restored backup's own journal keys) is humanized from its key so it can
    /// still rank in the insights list.
    static func displayLabel(forQuestion question: String) -> String {
        if let tag = JournalTag(rawValue: question) { return tag.label }
        let words = question
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        guard let first = words.first else { return question }
        return String(first).uppercased() + words.dropFirst()
    }
}

/// Small @MainActor facade over the store's `journal` table (which has existed since v8 — no
/// migration): merged-lane reads and native tag writes.
///
/// LANES: native whoopmaxx answers persist under `nativeSourceId` ("wm-journal") — their own source
/// id, so they can never collide with rows a backup restore carries (BackupImport adopts the whole
/// sqlite, so an imported backup's own logging-card rows arrive under the "imported-journal" id, and
/// rows a WHOOP-export CSV import wrote there arrive under the strap id "my-whoop"). Reads MERGE all
/// three lanes; the native answer wins per (day, question), the imported rows fill next, the
/// WHOOP-CSV strap-lane rows fill last. Clearing a tag is an explicit
/// `answeredYes = false` upsert under the native lane — NOT a delete — so the clear keeps winning
/// the merge instead of resurfacing an identical imported YES.
@MainActor
final class JournalStore: ObservableObject {
    /// Source id native whoopmaxx journal answers write under (own lane; see type doc).
    static let nativeSourceId = "wm-journal"
    /// The lane a restored backup's own journal answers live under (kept verbatim by the
    /// whole-file BackupImport restore). Merged on read; native (`nativeSourceId`) wins.
    static let importedSourceId = "imported-journal"

    /// Days the published chip cache spans (matches the Repository dashboard window).
    ///
    /// Not private: this is the FLOOR the Journal day stepper stops at. `tagsByDay` is only ever
    /// populated for `[now-readWindowDays, now+1d]`, so a day outside the window has no cache entry
    /// and every chip on it would render OFF — not "not logged", just never read. The screen has to
    /// know where the cache ends to refuse to walk past it, so the number lives here (one source of
    /// truth) rather than being duplicated as a literal in the view.
    static let readWindowDays = 120

    /// Per day key, the set of question keys answered YES (merged lanes, native wins) — what the
    /// Today chip row renders. Published so the chips re-render the moment a toggle lands.
    @Published private(set) var tagsByDay: [String: Set<String>] = [:]

    private let repo: Repository
    private let scores: ScoreEngine
    /// The app-level data-changed seam, injected by `AppRoot` (`dataDidChange(.derivedRows)`). Called
    /// after a tag write's forced rescore INSTEAD of refreshing the repository here, so the write path
    /// picks up everything a changed Charge / Rest owes — the dashboard cache AND the widget snapshot.
    /// Defaults to a no-op so the facade stays constructible without an AppRoot (tests).
    var onChanged: () async -> Void = {}

    init(repo: Repository, scores: ScoreEngine) {
        self.repo = repo
        self.scores = scores
    }

    // MARK: - Reads

    /// Re-read the trailing-window chip cache from the store (merged lanes). Diff-guarded so an
    /// unchanged pass publishes nothing.
    func refresh() async {
        let now = Date()
        let from = Repository.localDayKey(now.addingTimeInterval(-Double(Self.readWindowDays) * 86_400))
        let to = Repository.localDayKey(now.addingTimeInterval(86_400))
        var map: [String: Set<String>] = [:]
        for e in await mergedEntries(from: from, to: to) where e.answeredYes {
            map[e.day, default: []].insert(e.question)
        }
        if tagsByDay != map { tagsByDay = map }
    }

    /// Every merged journal answer for one day (native wins per question). Downstream consumers
    /// (the health monitor's confounder assembly) read a day's context through this.
    func entries(for day: String) async -> [JournalEntry] {
        await mergedEntries(from: day, to: day)
    }

    /// Per question key, the set of day keys it was answered YES on over `[from, to]` — the
    /// behaviors × days input `BehaviorInsights`/`EffectRanker` rank over. Merged lanes, so
    /// imported behaviors participate in insights alongside the native tags.
    func tagDays(from: String, to: String) async -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for e in await mergedEntries(from: from, to: to) where e.answeredYes {
            out[e.question, default: []].insert(e.day)
        }
        return out
    }

    private func mergedEntries(from: String, to: String) async -> [JournalEntry] {
        guard let store = await repo.storeHandle() else { return [] }
        // Third (lowest-precedence) lane: journal rows a WHOOP-export CSV import wrote upstream
        // under the STRAP deviceId ("my-whoop"), carried verbatim by a backup restore. Without
        // this lane a migrating user's imported behavior days silently vanish from the chips,
        // insights and confounders even though the rows sit in the same table.
        let strap = (try? await store.journalEntries(deviceId: repo.deviceId,
                                                     from: from, to: to)) ?? []
        let imported = (try? await store.journalEntries(deviceId: Self.importedSourceId,
                                                        from: from, to: to)) ?? []
        let native = (try? await store.journalEntries(deviceId: Self.nativeSourceId,
                                                      from: from, to: to)) ?? []
        return Self.merged(strap: strap, imported: imported, native: native)
    }

    /// Pure merged-lane read: the native answer wins per (day, question); the imported rows
    /// fill next; the WHOOP-CSV strap-lane rows fill last (lowest precedence). Sorted
    /// (day, question) ascending, matching the store's read order.
    nonisolated static func merged(strap: [JournalEntry] = [], imported: [JournalEntry],
                                   native: [JournalEntry]) -> [JournalEntry] {
        var byKey: [String: JournalEntry] = [:]
        for e in strap { byKey[e.day + "|" + e.question] = e }    // WHOOP-CSV lane fills first…
        for e in imported { byKey[e.day + "|" + e.question] = e } // …the imported rows over it…
        for e in native { byKey[e.day + "|" + e.question] = e }   // …whoopmaxx native wins
        return byKey.values.sorted { ($0.day, $0.question) < ($1.day, $1.question) }
    }

    // MARK: - Writes

    /// Toggle a tag for a day. Writes under the native lane, then re-runs the FORCED rescore —
    /// journal edits must re-evaluate the health-monitor confounders, and the #836 HR watermark
    /// would otherwise skip the pass when no new raw HR landed — and hands off to `onChanged`, the
    /// app's one data-change seam, which refreshes the dashboard cache and republishes the glance.
    /// The chip cache updates optimistically first so the tap renders instantly.
    func set(tag: JournalTag, on: Bool, day: String) async {
        var tags = tagsByDay[day] ?? []
        if on { tags.insert(tag.rawValue) } else { tags.remove(tag.rawValue) }
        tagsByDay[day] = tags

        guard let store = await repo.storeHandle() else { return }
        // An OFF is an explicit answeredYes=false under the native lane (see type doc — never a
        // delete, which would resurface an identical imported YES on the next merged read).
        _ = try? await store.upsertJournal(
            [JournalEntry(day: day, question: tag.rawValue, answeredYes: on, notes: nil)],
            deviceId: Self.nativeSourceId)
        await refresh()
        // The night a tag contexts is D+1, and the ordinary pass reaches only the trailing 21 days —
        // a back-dated toggle would otherwise leave that night evaluated without its confounder.
        await scores.analyzeRecent(maxDays: Self.rescoreReach(editedDay: day, now: Date()), force: true)
        await onChanged()
    }

    // MARK: - Rescore reach

    /// How many days back the forced rescore after a tag write must scan.
    ///
    /// `analyzeRecent`'s ordinary window is the trailing 21 days, which is right for a live tap and
    /// silently wrong for a BACK-DATED one: the night a tag contexts is D+1 (`ScoreEngine.
    /// nightContextTags`), so toggling a tag 40 days back would re-evaluate only the last three
    /// weeks and leave that night scored as if nothing had been logged. Widen to cover the edited day
    /// itself — `+2` because the scan's day offsets are 0-based (reaching D needs `daysBack(D) + 1`)
    /// plus one day of slack for a timezone move between the write and the pass.
    ///
    /// Never NARROWS (floor 21, the pass's own default) and never exceeds
    /// `SampleRetention.hardCapDays` (56) — the outermost horizon at which the raw samples a day is
    /// re-derived from can still exist, so scanning past it is pure cost for days that are skipped
    /// anyway for want of HR.
    nonisolated static func rescoreReach(editedDay day: String, now: Date) -> Int {
        min(SampleRetention.hardCapDays, max(21, daysBack(day, now: now) + 2))
    }

    /// Calendar days from `day` back to `now` — 0 for today, 1 for yesterday, negative for a
    /// future-dated key (the Today stepper cannot reach one, but a restored backup's bad-clock row
    /// can). `now` resolves through `Repository.localDayKey`, not the logical #144 key, because the
    /// LOCAL calendar is what the rescore's own scan steps back from. The difference between the two
    /// day KEYS is then taken in a fixed UTC calendar (the `ScoreEngine.shiftDay` idiom): both keys
    /// are already calendar dates, so the count is exact and immune to the 23/25-hour DST days a
    /// fixed-86_400 s subtraction gets wrong by one. An unparseable key returns 0, leaving the reach
    /// at its ordinary floor rather than widening on garbage.
    nonisolated static func daysBack(_ day: String, now: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let from = Self.utcMidnight(day, cal),
              let to = Self.utcMidnight(Repository.localDayKey(now), cal),
              let delta = cal.dateComponents([.day], from: from, to: to).day else { return 0 }
        return delta
    }

    /// "yyyy-MM-dd" → that date in a FIXED UTC calendar. Same parse and same validity checks as
    /// `ScoreEngine.shiftDay`, so the two agree on which keys are junk.
    private nonisolated static func utcMidnight(_ day: String, _ cal: Calendar) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1 else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        return cal.date(from: comps)
    }
}
