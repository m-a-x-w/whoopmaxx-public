import Foundation

/// The App Group outbox that carries a Home Screen tap into the app's database (028).
///
/// **WHY AN OUTBOX AND NOT A DIRECT WRITE.** The store is not in the App Group — it is a ~350 MB GRDB
/// `DatabasePool` in the app's own container — so the widget process physically cannot write an
/// intake event. Moving it there was considered and rejected: cross-process SQLite on
/// iOS means an extension can be suspended mid-transaction holding a lock, and it would also mean
/// weakening the data-protection class on a health database and reworking the restore path. The
/// outbox buys the same user-visible behaviour — tap, it's logged — for a fraction of that risk.
///
/// The cost is that an entry reaches `ingestionEvent` on the app's next launch or foreground rather
/// than instantly. That is nearly invisible for a LOGGING feature, because the widget renders its own
/// count straight from here, so the tap registers immediately either way.
///
/// Compiled into BOTH targets (the `Shared/` tree already is), so the intent and the drain read one
/// definition rather than a pair that can drift.
public enum IntakeOutbox {

    /// One tap, waiting to be drained.
    ///
    /// Carries a client-generated `id` because that id is what makes the drain IDEMPOTENT: the store
    /// upserts `ON CONFLICT(id) DO UPDATE`, so a double-fire, a re-drain, or a crash part-way through
    /// all converge on exactly one row. Every amount field is optional and nil means NOT RECORDED —
    /// the same convention the domain model uses, so a bare tap stays honestly bare.
    public struct Pending: Codable, Equatable, Sendable {
        public let id: String
        /// `IntakeKind` raw value. Kept as a String so this contract does not drag the app's domain
        /// enum into the widget target, and so a kind added by a later build survives the round trip.
        public let kind: String
        public let ts: Int
        public let variant: String?
        public let countValue: Int?
        public let sizeOrdinal: Int?
        public let amountMg: Int?

        public init(id: String = UUID().uuidString, kind: String, ts: Int,
                    variant: String? = nil, countValue: Int? = nil,
                    sizeOrdinal: Int? = nil, amountMg: Int? = nil) {
            self.id = id; self.kind = kind; self.ts = ts
            self.variant = variant; self.countValue = countValue
            self.sizeOrdinal = sizeOrdinal; self.amountMg = amountMg
        }
    }

    public static let storageKey = "wm.intake.outbox"

    /// Provenance stamped on every event this path produces.
    ///
    /// A widget tap can carry an amount the user configured once in `Edit Widget`. That is genuinely
    /// the user's input — a standing declaration, not an app-invented default, which is the
    /// distinction 024 decision 7 turns on. But it is declared IN ADVANCE, so on the day you tap it
    /// for a different coffee it is confidently wrong. Stamping the lane keeps a configured amount
    /// separable from one typed in the moment, so no later dose work can mistake it for a
    /// measurement taken at the time.
    public static let source = "widget"

    /// Hard ceiling on pending entries.
    ///
    /// Bounded because an outbox that only grows is a bug waiting for a user who adds the widget and
    /// never opens the app. Deliberately NOT an age expiry: a meal you logged is a fact whether or
    /// not the app happened to open, and quietly deleting it because it aged out would discard a true
    /// record. When the cap bites it drops the OLDEST — dropping the newest would throw away the tap
    /// the user just made, which is the worst thing a logging feature can do.
    public static let maxPending = 500

    /// Count of entries dropped to the cap, ever. Surfaced rather than swallowed, so a user whose
    /// taps went missing can be told rather than left to wonder.
    public static let droppedKey = "wm.intake.outbox.dropped"

    // MARK: - Access

    /// The shared defaults, or nil when the App Group is not provisioned on this target.
    ///
    /// NOTE the failure mode this cannot see: with the entitlement missing, `UserDefaults(suiteName:)`
    /// returns a NON-SHARED store rather than nil, so writes appear to succeed and are invisible to
    /// the other process. `WidgetSnapshot.isGroupProvisioned` is the check that catches it, because it
    /// interrogates the container instead — the intent paths refuse to log rather than drop a tap into
    /// a store nobody reads.
    static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.suiteName) }

    /// Everything waiting, oldest first.
    public static func pending() -> [Pending] {
        guard let defaults, let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }

    /// Append one tap. Returns false only when the App Group is unreachable.
    ///
    /// Read-modify-write under the shared suite. Two processes racing here could in principle lose an
    /// entry, which is why the widget is the only writer: the app never appends, it only drains.
    @discardableResult
    public static func append(_ entry: Pending) -> Bool {
        guard let defaults else { return false }
        var all = pending()
        all.append(entry)
        if all.count > maxPending {
            let dropped = all.count - maxPending
            all.removeFirst(dropped)                       // oldest out, never the newest
            defaults.set(defaults.integer(forKey: droppedKey) + dropped, forKey: droppedKey)
        }
        guard let data = try? JSONEncoder().encode(all) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    /// Remove exactly the ids that were consumed.
    ///
    /// Never clears wholesale: a tap landing while the drain is in flight would be deleted without
    /// ever having been written to the store. Removing by id leaves it for the next pass.
    public static func clear(ids: Set<String>) {
        guard let defaults, !ids.isEmpty else { return }
        let remaining = pending().filter { !ids.contains($0.id) }
        guard let data = try? JSONEncoder().encode(remaining) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Entries dropped to the cap since install, for the app to surface.
    public static func droppedCount() -> Int { defaults?.integer(forKey: droppedKey) ?? 0 }

    // MARK: - Pure rules

    /// What `append` would keep, given the current contents. Pure so the cap's oldest-first rule is
    /// testable without touching a real `UserDefaults` suite.
    public static func capped(_ all: [Pending], max: Int = maxPending) -> (kept: [Pending], dropped: Int) {
        guard all.count > max else { return (all, 0) }
        let dropped = all.count - max
        return (Array(all.dropFirst(dropped)), dropped)
    }
}
