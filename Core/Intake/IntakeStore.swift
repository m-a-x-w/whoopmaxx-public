import Foundation
import Combine
import StrapStore

/// `@MainActor` facade over the v27 `ingestionEvent` table (024 Intake) — the timestamped log of
/// what was eaten and drunk, and the source of every response tape.
///
/// **The invariant that shapes this type: projection RAISES ONLY.**
///
/// `WeedStore` may lower its boolean, because in 009 the chip and the sessions are two halves of one
/// feature — the chip going off IS the user deleting the day. Here they are not. `alcohol` and
/// `caffeine_late` are pre-existing `JournalTag`s the user taps directly on Today (the kept corpus
/// contains exactly such a tap), and nothing distinguishes "Intake raised this" from "the user
/// tapped this". A lowering projection would therefore let this feature silently un-set a chip its
/// user set — so it does not lower, and clearing a chip stays where it has always been: the chip.
///
/// The consequence is deliberate and is a legal state: a day may carry `alcohol` with zero events.
/// That is the same shape 009 calls a legacy chip-only day (`WeedSessionStore.swift:9-13`) and it
/// reads the same way — the day IS an alcohol day, with no detail recorded. The reverse never
/// happens silently either: an event whose tag is missing gets it raised at launch by `repair`.
///
/// Shape follows `WeedStore` (120-day window, `storeHandle()` guard, `try?`-to-empty, diff-guarded
/// publishes, optimistic cache mutation then reload) with the same `JournalStore` COUPLING: every
/// boolean write goes through `journal.set`, the app's one journal writer, never a bare
/// `upsertJournal`. That single call carries the native-lane upsert, `journal.refresh()`, the forced
/// `analyzeRecent` at the back-dated reach, and `onChanged` → `dataDidChange(.derivedRows)`.
@MainActor
final class IntakeStore: ObservableObject {
    /// Days the published event cache spans (matches the Repository dashboard window).
    private static let readWindowDays = 120

    /// Local clock hour a BACK-DATED log's placeholder timestamp lands on. Always paired with
    /// `tsExact = false`, which is also what suppresses the response tape — a window drawn around a
    /// placeholder would be drawing around a guess. `nonisolated`: read by the nonisolated `stamp`.
    nonisolated static let placeholderHour = 12

    /// Events per day key, oldest first within a day (the store's own `ts ASC, id ASC` order).
    /// A day absent here has no logged events — which says nothing about what was consumed.
    @Published private(set) var eventsByDay: [String: [IntakeEvent]] = [:]
    /// The newest event by `ts` REGARDLESS of window, so an empty 120-day cache can still tell
    /// "never logged anything" from "last logged before the window" — absence, never a fake zero.
    @Published private(set) var latestEvent: IntakeEvent?

    private let repo: Repository
    private let journal: JournalStore

    init(repo: Repository, journal: JournalStore) {
        self.repo = repo
        self.journal = journal
    }

    // MARK: - Reads

    /// The events logged on one day, oldest first.
    func events(on day: String) -> [IntakeEvent] { eventsByDay[day] ?? [] }

    /// Whether anything has ever been logged, for telling an empty state from a real one. Unlike
    /// weed's `everLogged` this reads the EVENTS only and never the journal booleans: a tapped
    /// `alcohol` chip is not an intake log, and saying "you have logged before" on the strength of
    /// one would be claiming a record that does not exist.
    var everLogged: Bool { latestEvent != nil }

    /// Re-read the event cache and raise any tag that fell behind its events.
    ///
    /// MUST run strictly AFTER `journal.refresh()` in the launch `.task`: `repair` compares owed
    /// tags against `journal.tagsByDay`, and an empty tag cache would make every one read as
    /// missing and cost one pointless forced rescore.
    func refresh() async {
        await reload()
        await repair()
    }

    /// Pure re-read of the trailing-window events + the newest-ever event. Diff-guarded, so an
    /// unchanged pass publishes nothing.
    private func reload() async {
        guard let store = await repo.storeHandle() else { return }
        let now = Date()
        let from = Repository.localDayKey(now.addingTimeInterval(-Double(Self.readWindowDays) * 86_400))
        let to = Repository.localDayKey(now.addingTimeInterval(86_400))
        let rows = (try? await store.ingestionEvents(deviceId: StrapStore.intakeSourceId,
                                                     from: from, to: to)) ?? []
        let newestRow = (try? await store.latestIngestionEvent(deviceId: StrapStore.intakeSourceId)) ?? nil

        var map: [String: [IntakeEvent]] = [:]
        for r in rows { map[r.day, default: []].append(IntakeEvent(r)) }   // read order is already ts, id
        if eventsByDay != map { eventsByDay = map }
        let newest = newestRow.map { IntakeEvent($0) }
        if latestEvent != newest { latestEvent = newest }
    }

    // MARK: - Writes

    /// Log an event the editor built. Same upsert as `update` — a new event simply carries a fresh
    /// `id` — kept as its own name so the sheet's create and edit paths read as what they are.
    func add(_ event: IntakeEvent) async { await upsert(event) }

    /// Save an edited event (keyed by `id`, so it updates in place).
    func update(_ event: IntakeEvent) async { await upsert(event) }

    /// Remove one event. `day` is passed rather than looked up so the cache can already have been
    /// mutated past it.
    ///
    /// Deliberately does NOT project: removing an event never lowers a tag (see the type doc), and
    /// there is nothing to raise. A deleted drink leaves the `alcohol` chip standing for the user to
    /// clear if they want to.
    func delete(id: String, day: String) async {
        cacheRemove(id: id, day: day)
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteIngestionEvent(deviceId: StrapStore.intakeSourceId, id: id)
        await reload()
    }

    private func upsert(_ event: IntakeEvent) async {
        // The editor's picker can move an event to another DAY. Unlike weed there is nothing owed to
        // the day it LEFT — that day's tag is not lowered by the departure — so only the destination
        // is projected. The stale cache entry still has to go, or the row renders on both days.
        let previousDay = eventsByDay.first { $0.value.contains { e in e.id == event.id } }?.key
        if let previousDay, previousDay != event.day { cacheRemove(id: event.id, day: previousDay) }
        cacheUpsert(event)
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.upsertIngestionEvents([event.row])
        await reload()
        await project(event)
    }

    // MARK: - Outbox drain

    /// Pull everything the Home Screen widget logged into the store (028).
    ///
    /// **Routed through `add`, deliberately, and never a bare `upsertIngestionEvents`.** `add` is the
    /// one path that carries the raise-only journal projection; a drain that wrote straight to the
    /// store would bypass it and silently reintroduce the class of defect 025 fixed — an event whose
    /// tag never gets raised, or worse a heal that later argues with the user about it.
    ///
    /// Idempotent by construction: every entry carries a client uuid, `add` upserts `ON CONFLICT(id)`,
    /// and only the ids actually consumed are cleared. A crash mid-drain re-runs harmlessly; a tap
    /// landing while the drain is in flight survives to the next pass because nothing is cleared
    /// wholesale.
    ///
    /// A pending entry whose kind this build does not recognise is LEFT IN THE OUTBOX rather than
    /// dropped — a newer build wrote it, and an older one deleting it would destroy a real log.
    @discardableResult
    func drainOutbox() async -> Int {
        let entries = IntakeOutbox.pending()
        guard !entries.isEmpty else { return 0 }

        var consumed: Set<String> = []
        for e in entries {
            guard let kind = IntakeKind(rawValue: e.kind) else { continue }   // newer build's — keep
            // The day key is resolved HERE, not in the widget: `anchorKey` needs `repo.days`,
            // which the extension has no access to.
            //
            // IT MUST BE RESOLVED AT THE TAP'S INSTANT, NOT THE DRAIN'S. This originally called
            // `anchorKey(days:)` with its default `now: Date()` — the DRAIN clock — so a tap made at
            // 19:30 and drained after the next 04:00 rollover was filed on the FOLLOWING day: the row
            // printed the tap's own clock under tomorrow's heading, and `project()` raised `alcohol`
            // on a day the user had not drunk, which feeds the health-monitor confounders and shifts
            // the confounded night by one (`nightContextTags` reads D-1). The widget exists so the
            // app is NOT opened, so "tap tonight, open tomorrow" is the ordinary path, not an edge.
            let tapInstant = Date(timeIntervalSince1970: TimeInterval(e.ts))
            let day = Repository.anchorKey(days: repo.days, now: tapInstant)
            // A widget tap reads the real clock at the moment of the tap, so it IS an exact
            // observation — unlike a back-dated log, which is what `stamp` exists to mark inexact.
            let event = IntakeEvent(id: e.id,
                                    day: day,
                                    ts: e.ts,
                                    tsExact: true,
                                    kind: kind,
                                    countValue: e.countValue,
                                    sizeOrdinal: e.sizeOrdinal.flatMap(MealSize.init(rawValue:)),
                                    variant: e.variant.flatMap(IntakeVariant.init(rawValue:)),
                                    amountMg: e.amountMg,
                                    source: IntakeOutbox.source,
                                    createdAt: e.ts)
            await add(event)
            consumed.insert(e.id)
        }
        IntakeOutbox.clear(ids: consumed)
        return consumed.count
    }

    // MARK: - Projection

    /// Raise the tag this event owes, if it owes one and the day does not already carry it.
    ///
    /// Runs on WRITE only, and deliberately does NOT consult the user's cleared answers: logging a
    /// drink is a fresh, deliberate act, so it raises `alcohol` even on a day the user had previously
    /// turned off. That is the opposite of `repair`'s rule below, and the difference is the point —
    /// one is the user doing something now, the other is the app deciding something at launch.
    ///
    /// The "only when it is missing" gate is what keeps a second drink on an already-tagged day from
    /// costing a redundant forced rescore: `journal.set` runs a full `analyzeRecent` every call.
    private func project(_ event: IntakeEvent) async {
        guard let tag = event.kind?.journalTag(at: event.ts) else { return }
        guard !(journal.tagsByDay[event.day]?.contains(tag.rawValue) ?? false) else { return }
        await journal.set(tag: tag, on: true, day: event.day)
    }

    /// Raise every tag the cached events owe and the journal does not carry — the launch heal.
    ///
    /// **NEVER OVERRIDES AN ANSWER THE USER GAVE.** `journal.tagsByDay` holds only the YES answers
    /// (`JournalStore.refresh` filters `where e.answeredYes`), so a day the user explicitly CLEARED
    /// is indistinguishable there from a day nobody ever answered — and a heal built on that
    /// difference re-raised the tag on every launch, silently overwriting the NO and burning a forced
    /// rescore each time. The chip could not be turned off while the event existed.
    ///
    /// The fix reads the native lane directly, where a clear is stored as an explicit
    /// `answeredYes = false` (never a delete — `JournalStore`'s type doc), and skips those pairs. So
    /// the invariant this type claims actually holds: clearing a chip stays the chip's business, and
    /// a deleted drink leaves the chip standing for the user to clear.
    ///
    /// What remains healed is the case the heal is FOR: an event whose tag was never answered at all
    /// — the mirror of 009's, a 024 backup opened by a pre-024 build, which owns the booleans and
    /// knows nothing about this table.
    private func repair() async {
        let owed = Self.missingTagDays(eventsByDay: eventsByDay,
                                       tagsByDay: journal.tagsByDay,
                                       clearedByUser: await clearedNativeAnswers())
        guard !owed.isEmpty else { return }
        // ONE rescore, never k. Every (day, tag) but the OLDEST lands directly under the native lane
        // in a single upsert; the oldest then goes through `journal.set`, whose forced pass reaches
        // back from the day it edits (`JournalStore.rescoreReach`) and so already covers the batch.
        // Calling `journal.set` k times would run k full forced passes at launch.
        let batch = owed.dropFirst().map {
            JournalEntry(day: $0.day, question: $0.tag.rawValue, answeredYes: true, notes: nil)
        }
        if !batch.isEmpty, let store = await repo.storeHandle() {
            _ = try? await store.upsertJournal(batch, deviceId: JournalStore.nativeSourceId)
        }
        let oldest = owed[0]
        await journal.set(tag: oldest.tag, on: true, day: oldest.day)
    }

    // MARK: - Pure rules

    /// The `(day, question)` pairs the user has explicitly answered NO under the native lane — what
    /// `repair` must leave alone. Read straight from the store rather than from `journal.tagsByDay`,
    /// which cannot express a NO at all (it holds only the YES set).
    ///
    /// Native lane ONLY. An imported or WHOOP-CSV `false` is not this user's answer on this install,
    /// and the native lane is the one `journal.set` writes to and the one that wins the merge.
    private func clearedNativeAnswers() async -> Set<String> {
        guard let store = await repo.storeHandle() else { return [] }
        let now = Date()
        let from = Repository.localDayKey(now.addingTimeInterval(-Double(Self.readWindowDays) * 86_400))
        let to = Repository.localDayKey(now.addingTimeInterval(86_400))
        let rows = (try? await store.journalEntries(deviceId: JournalStore.nativeSourceId,
                                                    from: from, to: to)) ?? []
        return Set(rows.filter { !$0.answeredYes }.map { $0.day + "|" + $0.question })
    }

    /// Every (day, tag) the events owe that the journal does not already carry AND the user has not
    /// explicitly cleared, ascending by day then tag so the order is total and the batch's "oldest"
    /// is well-defined.
    ///
    /// Pure and `nonisolated` so the boundary cases — a caffeine event either side of 14:00, a
    /// post-midnight drink on the previous day's key, a day the user turned back off — are testable
    /// without a store or a clock move.
    nonisolated static func missingTagDays(
        eventsByDay: [String: [IntakeEvent]],
        tagsByDay: [String: Set<String>],
        clearedByUser: Set<String> = [],
        calendar: Calendar = .current
    ) -> [(day: String, tag: JournalTag)] {
        var owed: Set<String> = []          // "day|tagRaw", deduped across many events on one day
        for (day, events) in eventsByDay {
            for e in events {
                guard let tag = e.kind?.journalTag(at: e.ts, calendar: calendar) else { continue }
                guard !(tagsByDay[day]?.contains(tag.rawValue) ?? false) else { continue }
                // The user said no. The heal exists for tags nobody ever answered, not to argue.
                guard !clearedByUser.contains(day + "|" + tag.rawValue) else { continue }
                owed.insert(day + "|" + tag.rawValue)
            }
        }
        return owed.sorted().compactMap { key in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let tag = JournalTag(rawValue: parts[1]) else { return nil }
            return (day: parts[0], tag: tag)
        }
    }

    /// The `(ts, exact)` a ONE-TAP log carries.
    ///
    /// A live log on the anchor day is a real observation: `now`, exact. A BACK-DATED one is not — we
    /// know the day and nothing about the clock — so it lands on a DECLARED placeholder
    /// (`placeholderHour` local) with `exact = false`. That flag does double duty here: it makes the
    /// row say "Time not recorded", and it suppresses the response tape, because a 3-hour window
    /// drawn from a fabricated noon would be arithmetic over a guess presented as a measurement.
    ///
    /// A key with no local midnight falls back to `now`, still declared inexact — the junk-key case,
    /// and also the handful of zones whose DST springs forward AT midnight (Havana, Cairo, Beirut,
    /// Azores, one day a year each) where `DayKey.date(from:)` returns nil for a valid key. Harmless:
    /// `day` is stored verbatim either way, so the event lands on the key the caller wrote.
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

    /// Optimistic insert/replace, keeping the day in the store's own `(ts, id)` order so the row
    /// list doesn't jump when the reload lands.
    private func cacheUpsert(_ event: IntakeEvent) {
        var list = eventsByDay[event.day] ?? []
        list.removeAll { $0.id == event.id }
        list.append(event)
        list.sort { ($0.ts, $0.id) < ($1.ts, $1.id) }
        eventsByDay[event.day] = list
    }

    private func cacheRemove(id: String, day: String) {
        var list = eventsByDay[day] ?? []
        list.removeAll { $0.id == id }
        // A day with no events is ABSENT, not an empty array — `eventsByDay[day] != nil` is what the
        // Today section gates its "Intake" block on.
        eventsByDay[day] = list.isEmpty ? nil : list
    }
}
