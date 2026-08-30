import Foundation

/// Minimal stand-ins for upstream app-layer helpers referenced by the verbatim-lifted core
/// (BLEManager is copied as-is by decision). Only what the call sites need.
enum AppChangelog {
    /// the original stamped decoder-replay bookkeeping with its changelog version; whoopmaxx uses the
    /// marketing version so the raw-history retro-decode still runs once per app update.
    static let currentVersion =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
}

/// BLEManager pokes these two upstream statics; carry the same contracts.
enum IntelligenceEngine {
    /// The UserDefaults flag `requestTimestampReheal` raises and `ScoreEngine.analyzeRecent` consumes.
    /// ONE constant shared by writer and reader so the two halves of the seam cannot typo apart.
    static let timestampHealKey = "intel.timestampHeal.pending"

    /// #547: a sync dropped implausible (bad-clock) records — flag the timestamp heal to re-run.
    /// `ScoreEngine.analyzeRecent` reads-and-clears this flag at the top of its next pass and treats
    /// that pass as FORCED, so the #836 idle gate cannot short-circuit the re-score (dropping records
    /// changes what a day scores from without necessarily moving the raw-HR fingerprint).
    static func requestTimestampReheal() {
        UserDefaults.standard.set(true, forKey: timestampHealKey)
    }
}

enum AppModel {
    /// the original posted a local "move reminder" notification here (#577). whoopmaxx wires wrist-alert
    /// notifications in a later wave; the sedentary detector still logs via LiveState meanwhile.
    ///
    /// Called 1:1 with the inactivity-nudge wrist buzz — `BLEManager.maybeBuzzInactivity` invokes this
    /// only on `shouldBuzz`, immediately after firing the buzz. AppRoot hooks `onInactivity` to record
    /// that buzz into `BuzzLog`: the buzz itself lives inside the verbatim-frozen BLEManager, so this
    /// pre-existing seam lets us capture it without touching BLEManager's body.
    static var onInactivity: ((Int) -> Void)?
    static func postInactivity(minutes: Int) { onInactivity?(minutes) }
}
