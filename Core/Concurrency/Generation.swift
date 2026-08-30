import Foundation

/// A monotonic stale-drop stamp for the "newest caller wins" async refresh every store-backed read
/// model in this app runs.
///
/// The shape is always the same: CLAIM a generation synchronously at entry (before the awaits), then
/// re-CHECK it after them and bail when a newer call has claimed a higher one. `.task(id:)` starts a new
/// refresh on every id bump WITHOUT waiting for the prior one to finish, and those bodies do several
/// sequential store awaits — so without the stamp an older-started call finishing AFTER a newer one
/// clobbers the fresher caches (each publish is only value-diff-guarded, so older != newer passes and
/// overwrites).
///
/// Main-actor by design: claim and check are the two halves of one decision, and actor isolation is what
/// makes the claim atomic — two refreshes can never read-then-bump across each other.
///
/// Wrapping add (`&+=`) so a long-lived model can't trap on overflow; the counter only ever has to
/// distinguish CONCURRENT refreshes, and 2^63 of those never coexist.
@MainActor
struct Generation {
    private var n = 0

    /// Claim the newest generation. Call this synchronously at the top of the refresh, before its first
    /// await: the last-invoked refresh then holds the highest gen and reads the freshest data.
    mutating func claim() -> Int {
        n &+= 1
        return n
    }

    /// True when `g` is still the newest claim — nothing newer started while the caller awaited. An
    /// older body sees false and drops its now-stale result instead of publishing it.
    func isCurrent(_ g: Int) -> Bool { g == n }
}
