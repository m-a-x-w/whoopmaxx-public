import Foundation

/// How long raw frames are kept.
///
/// Raw is working data, not the record — there is no server and no archive, and the decoded streams
/// are what survives. Decoded rows are persisted BEFORE their raw batch is enqueued, so the oldest
/// raw is always the safest thing to drop and pruning can never lose a metric.
///
/// The byte cap is the load-bearing one. Without it an experimental capture toggle grows without
/// limit, and a strap that streams continuously will fill a phone.
enum PrunePolicy {
    /// Synced raw stays browsable for about a day.
    static let keepWindowSeconds = 24 * 3600
    /// Total raw footprint. Past it the oldest is evicted regardless of age.
    static let maxUnsyncedBytes = 50 * 1024 * 1024
}
