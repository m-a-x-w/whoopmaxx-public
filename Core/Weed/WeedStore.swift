import Foundation
import Combine
import StrapStore

/// `@MainActor` facade over the v26 `weedSession` table (009 Weed) — the additive DETAIL behind the
/// journal's per-day weed boolean.
///
/// INVARIANT, the one this type exists to keep: **a day is a weed day iff its merged `journal` row
/// for "weed" is `answeredYes`.** Sessions never DEFINE weed days; they add detail to days that
/// already are. So `weedDays` reads the journal cache and never `sessionsByDay`, nothing in the
/// confounder or insights path reads this table at all (both keep reading the same boolean they have
/// since Jul 22), and a legacy chip-only day keeps confounding the monitor and ranking in insights
/// with zero sessions. Nothing migrates. No double count is possible either: `JournalStore.tagDays`
/// returns day SETS, so a day with four sessions contributes exactly one day, same as a day with none.
///
/// Shape follows `HabitsStore` (trailing-day window, `storeHandle()` guard, `try?`-to-empty,
/// diff-guarded publishes, optimistic cache mutation then reload) — except that the window itself is
/// NOT this store's to pick; see `readWindowDays`. With `JournalStore` COUPLING: every boolean
/// write goes through `journal.set`, the app's one journal writer, never a bare `upsertJournal`.
/// That single call carries the native-lane upsert, `journal.refresh()` (so the Today chip and
/// `JournalScreen`'s `.onChange(of:)` both fire), the forced `analyzeRecent` at the back-dated reach,
/// and `onChanged` → `dataDidChange(.derivedRows)`. `AppRoot.refreshCaches` does NOT refresh
/// `JournalStore`, so routing through it is what keeps the chip from going stale.
@MainActor
final class WeedStore: ObservableObject {
    /// Days the published session cache spans — DERIVED from `JournalStore.readWindowDays`, never a
    /// second copy of it.
    ///
    /// They are ONE number because this store compares its two caches against each other day for
    /// day. `sessionsByDay` spans THIS window (the `weedSession` table); `weedDays` spans the JOURNAL
    /// window (`journal.tagsByDay`, bounded by `JournalStore.readWindowDays`); and both `project` and
    /// `repair` ask "does this day's boolean agree with its session count?" across the pair. A day
    /// that falls inside one span and outside the other answers that question out of an absence that
    /// was never READ — the very thing this app refuses to treat as a measurement — so drift breaks
    /// in either direction:
    ///
    /// - WIDER here than the journal's: a session day past the journal edge is permanently missing
    ///   from `weedDays`, so `repair` reads it as an unraised boolean on EVERY launch and can never
    ///   converge — raising a boolean cannot pull its day into a cache whose window excludes it.
    ///   Each launch then pays a batch `upsertJournal` plus one forced `analyzeRecent`,
    ///   `journal.refresh()` and `dataDidChange(.derivedRows)`, for a day that was already correct.
    /// - NARROWER here: the Journal day stepper stops at `JournalStore.readWindowDays - 1` and its
    ///   weed chip routes through `setDay` (`JournalScreen`), so the user can back-date past this
    ///   window. The row IS written; `reload()` then rebuilds from the shorter window and drops it,
    ///   `project` sees zero sessions against a false boolean and correctly writes nothing — the chip
    ///   snaps straight back OFF, the session is orphaned with no boolean, and `repair` cannot see it
    ///   either. That is exactly the unbounded-stepper bug `canStepBack` was added to close, one
    ///   table over.
    ///
    /// The value still lands on the Repository dashboard window's 120 — that is where `JournalStore`
    /// takes it from, and that parenthetical is what this comment used to say. It was the wrong
    /// reason: the dashboard does not BIND this window, the journal cache does. Widening the weed
    /// session cache means widening `JournalStore`'s, in that order.
    private static let readWindowDays = JournalStore.readWindowDays

    /// Local clock hour a BACK-DATED tap's placeholder timestamp lands on — the middle of the evening
    /// window this behavior sits in. Always paired with `tsExact = false`; see `stamp`.
    /// `nonisolated`: read by the nonisolated `stamp` below (an immutable `Int`).
    nonisolated static let placeholderHour = 21

    /// Sessions per day key, oldest first within a day (the store's own `ts ASC, id ASC` order).
    /// A day absent here has no sessions — which says nothing about whether it is a weed day.
    @Published private(set) var sessionsByDay: [String: [WeedSession]] = [:]
    /// The newest session by `ts` REGARDLESS of window, so "days since last" can say "120+" instead
    /// of nothing when the last one predates the `readWindowDays` cache — absence, never a fabricated
    /// zero. (The floor the screen SPEAKS is `WeedScreen.historyWindowDays`, its own read range; this
    /// property's job is only to make sure a session older than any window is still known to exist.)
    @Published private(set) var latestSession: WeedSession?
    /// Whether anything has ever been logged, for telling an empty state from a real one. Reads the
    /// BOOLEAN too: a legacy chip-only user has never written a session and must still not be told
    /// "Nothing logged yet" (`WeedProjectionTests` pins that case).
    ///
    /// COMPUTED, not a stored `@Published`. It was stored and assigned only inside `reload()` — and
    /// both write paths run `reload()` BEFORE `project()`, so on the pass that clears the last weed
    /// day the flag was computed while the journal boolean was still true, then `project()` lowered
    /// the boolean with nothing left to recompute it. Since `weed.refresh()` runs exactly once, at
    /// launch, and the `scenePhase` handler never re-enters this store, the stale `true` survived
    /// until a cold start — and `WeedScreen` rendered its populated hero branch over empty data
    /// instead of the empty state. Deriving it removes the window entirely, the way the sibling
    /// `IntakeStore.everLogged` already does.
    ///
    /// Both inputs are observable from the views that read this (`WeedScreen` holds `journal` as well
    /// as `weed`), so the recompute happens on the same publish that moves the underlying data.
    var everLogged: Bool { latestSession != nil || !weedDays.isEmpty }

    private let repo: Repository
    private let journal: JournalStore

    init(repo: Repository, journal: JournalStore) {
        self.repo = repo
        self.journal = journal
    }

    // MARK: - Reads

    /// The day keys that ARE weed days — straight off the journal cache, the single truth. A legacy
    /// chip-only day is in here with zero sessions; a day with four sessions is in here exactly once.
    /// Deliberately NOT derived from `sessionsByDay`: that would make sessions define weed days and
    /// break every consumer that already reads the boolean.
    var weedDays: Set<String> {
        Set(journal.tagsByDay.filter { $0.value.contains(JournalTag.weed.rawValue) }.keys)
    }

    /// The sessions logged on one day, oldest first (empty for a legacy chip-only day).
    func sessions(on day: String) -> [WeedSession] { sessionsByDay[day] ?? [] }

    /// Whether clearing `day` should ask first: only when a session there carries something the USER
    /// typed (see `WeedSession.hasRecordedDetail`), so the one-tap path stays frictionless.
    func needsClearConfirmation(on day: String) -> Bool {
        sessions(on: day).contains { $0.hasRecordedDetail }
    }

    /// Re-read the session cache and heal any day whose boolean fell behind its sessions.
    ///
    /// MUST run strictly AFTER `journal.refresh()` in the launch `.task`: the repair compares session
    /// days against `journal.tagsByDay`, and an empty tag cache would make every session day read as
    /// missing and cost one pointless forced rescore.
    func refresh() async {
        await reload()
        await repair()
    }

    /// Pure re-read of the trailing-window sessions + the newest-ever session. Diff-guarded, so an
    /// unchanged pass publishes nothing.
    private func reload() async {
        guard let store = await repo.storeHandle() else { return }
        let now = Date()
        let from = Repository.localDayKey(now.addingTimeInterval(-Double(Self.readWindowDays) * 86_400))
        let to = Repository.localDayKey(now.addingTimeInterval(86_400))
        let rows = (try? await store.weedSessions(deviceId: StrapStore.weedSourceId,
                                                  from: from, to: to)) ?? []
        let newestRow = (try? await store.latestWeedSession(deviceId: StrapStore.weedSourceId)) ?? nil

        var map: [String: [WeedSession]] = [:]
        for r in rows { map[r.day, default: []].append(WeedSession(r)) }   // read order is already ts, id
        if sessionsByDay != map { sessionsByDay = map }
        let newest = newestRow.map { WeedSession($0) }
        if latestSession != newest { latestSession = newest }
    }

    // MARK: - Writes

    /// The Today chip. ON inserts one bare session (method/potency nil) and projects the boolean;
    /// OFF deletes that day's sessions and projects it back off.
    func setDay(_ day: String, on: Bool) async {
        if on {
            let clock = Self.stamp(day: day, anchorKey: Repository.anchorKey(days: repo.days),
                                   now: Date())
            let session = WeedSession(day: day, ts: clock.ts, tsExact: clock.exact)
            cacheUpsert(session)
            guard let store = await repo.storeHandle() else { return }
            _ = try? await store.upsertWeedSessions([session.row])
        } else {
            sessionsByDay[day] = nil
            guard let store = await repo.storeHandle() else { return }
            // Sessions FIRST, boolean second (`project` below). A crash between the two leaves
            // "boolean true, zero sessions" — a legacy-shaped day, which is consistent — and never
            // "boolean false, orphan sessions", which `repair` would silently re-raise on the next
            // launch, resurrecting a day the user just cleared.
            _ = try? await store.deleteWeedSessions(deviceId: StrapStore.weedSourceId, day: day)
        }
        await reload()
        await project(day: day)
    }

    /// Log a session the editor built. Same upsert as `update` — a new session simply carries a fresh
    /// `id` — kept as its own name so the sheet's create and edit paths read as what they are.
    func add(_ session: WeedSession) async { await upsert(session) }

    /// Save an edited session (keyed by `id`, so it updates in place).
    func update(_ session: WeedSession) async { await upsert(session) }

    /// Remove one session. `day` is passed rather than looked up so the projection still happens when
    /// the cache has already been mutated past it.
    func delete(id: String, day: String) async {
        cacheRemove(id: id, day: day)
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteWeedSession(deviceId: StrapStore.weedSourceId, id: id)
        await reload()
        await project(day: day)
    }

    private func upsert(_ session: WeedSession) async {
        // The editor's DatePicker can move a session to another DAY. The day it LEFT may now be
        // empty and owes a false projection, so both keys are projected — each is a separate day's
        // truth and neither can be inferred from the other.
        let previousDay = sessionsByDay.first { $0.value.contains { s in s.id == session.id } }?.key
        if let previousDay, previousDay != session.day { cacheRemove(id: session.id, day: previousDay) }
        cacheUpsert(session)
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.upsertWeedSessions([session.row])
        await reload()
        await project(day: session.day)
        if let previousDay, previousDay != session.day { await project(day: previousDay) }
    }

    // MARK: - Projection

    /// Write `day`'s boolean when — and only when — it disagrees with the sessions now on it.
    ///
    /// The "only when it differs" gate is what keeps a second session on an already-logged day from
    /// costing a redundant forced rescore: `journal.set` runs a full `analyzeRecent` every call.
    private func project(day: String) async {
        guard let next = Self.projection(sessionCount: sessions(on: day).count,
                                         current: weedDays.contains(day)) else { return }
        await journal.set(tag: .weed, on: next, day: day)
    }

    /// Raise the boolean on any session day that reads false — the launch heal.
    ///
    /// Only ever RAISES. The reverse is deliberately absent: a weed day with zero sessions is a
    /// legacy chip-only day, which is consistent and must never be cleared. The one path that can
    /// produce a session with no boolean is disclosed in the plan — a 009 backup opened by a pre-009
    /// build, which owns the boolean and knows nothing about the table.
    private func repair() async {
        let missing = Self.missingBooleanDays(sessionDays: Array(sessionsByDay.keys),
                                              weedDays: weedDays)
        guard let oldest = missing.first else { return }
        // ONE rescore, never k. Every day but the OLDEST lands directly under the native lane in one
        // upsert; the oldest then goes through `journal.set`, whose forced pass reaches back from the
        // day it edits (`JournalStore.rescoreReach`) and so already covers the whole batch. Calling
        // `journal.set` k times would run k full forced passes at launch.
        let batch = missing.dropFirst().map {
            JournalEntry(day: $0, question: JournalTag.weed.rawValue, answeredYes: true, notes: nil)
        }
        if !batch.isEmpty, let store = await repo.storeHandle() {
            _ = try? await store.upsertJournal(batch, deviceId: JournalStore.nativeSourceId)
        }
        await journal.set(tag: .weed, on: true, day: oldest)
    }

    // MARK: - Pure rules

    /// The boolean `day` should carry given how many sessions it now has, or nil when it already
    /// carries it (nil means WRITE NOTHING — no upsert, no `journal.refresh`, no forced rescore).
    nonisolated static func projection(sessionCount: Int, current: Bool) -> Bool? {
        let next = sessionCount > 0
        return next == current ? nil : next
    }

    /// Session days whose journal boolean reads false — what `repair` raises, ascending.
    nonisolated static func missingBooleanDays(sessionDays: [String],
                                               weedDays: Set<String>) -> [String] {
        Set(sessionDays).subtracting(weedDays).sorted()
    }

    /// The `(ts, exact)` a ONE-TAP chip log carries.
    ///
    /// A live tap on the anchor day is a real observation: `now`, exact. A BACK-DATED tap is not — we
    /// know the day and nothing about the clock — so it lands on a DECLARED placeholder
    /// (`placeholderHour` local) with `exact = false`, which is what makes the UI say "Time not
    /// recorded" instead of rendering a fabricated 21:00 as an observation.
    ///
    /// A key with no local midnight falls back to `now`, still declared inexact. That is not only the
    /// junk-key case: in the handful of zones whose DST springs forward AT midnight (Havana, Cairo,
    /// Beirut, Azores — one day a year each) `DayKey.date(from:)` returns nil for a perfectly valid
    /// key. Harmless, because `day` is stored verbatim either way — the session lands on the key the
    /// chip wrote regardless of what its clock ends up saying, and an inexact clock is never rendered.
    nonisolated static func stamp(day: String, anchorKey: String, now: Date) -> (ts: Int, exact: Bool) {
        if day == anchorKey { return (Int(now.timeIntervalSince1970), true) }
        guard let midnight = DayKey.date(from: day) else {
            return (Int(now.timeIntervalSince1970), false)
        }
        let placeholder = Calendar.current.date(bySettingHour: placeholderHour, minute: 0, second: 0,
                                                of: midnight)
            ?? midnight.addingTimeInterval(Double(placeholderHour) * 3_600)
        return (Int(placeholder.timeIntervalSince1970), false)
    }

    // MARK: - Cache

    /// Optimistic insert/replace, keeping the day in the store's own `(ts, id)` order so the row list
    /// doesn't jump when the reload lands.
    private func cacheUpsert(_ session: WeedSession) {
        var list = sessionsByDay[session.day] ?? []
        list.removeAll { $0.id == session.id }
        list.append(session)
        list.sort { ($0.ts, $0.id) < ($1.ts, $1.id) }
        sessionsByDay[session.day] = list
    }

    private func cacheRemove(id: String, day: String) {
        var list = sessionsByDay[day] ?? []
        list.removeAll { $0.id == id }
        // A day with no sessions is ABSENT, not an empty array — `sessionsByDay[day] != nil` is what
        // the Today section gates its "Weed" block on.
        sessionsByDay[day] = list.isEmpty ? nil : list
    }
}
