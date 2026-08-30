import Foundation

/// Which builds are allowed to CONSUME the strap's history queue.
///
/// The WHOOP historical offload is a DESTRUCTIVE read: each chunk is acked with
/// `HISTORICAL_DATA_RESULT` carrying a trim cursor, and the strap then discards everything up to it.
/// The strap holds exactly one such queue, so whichever client acks first destroys the backlog for
/// every other client — the official WHOOP app, and any second whoopmaxx install. That is not a
/// hypothetical here: whoopmaxx is developed on the same phone/strap pair that runs the sideloaded
/// build, so a debug build launched for ten seconds to check a layout can silently eat the night the
/// real install hadn't synced yet. Nothing in the offload path noticed, because from the strap's point
/// of view the ack was perfectly valid.
///
/// So: **only a Release build has history authority.** This is a COMPILE-TIME decision
/// (`WM_HISTORY_AUTHORITY`, set for the Release config in `project.yml`) and deliberately not a
/// runtime setting — a runtime flag is exactly the thing that gets left in the wrong state, which
/// would make the guarantee worthless. The unsigned-IPA sideload flow builds Release, so the install
/// that actually collects data is unaffected.
///
/// DEBUG builds get one escape hatch, because on-device BLE work is impossible without it: the
/// `wmDebugHistoryAuthority` default. It is compiled out of Release entirely, so it can never grant
/// authority in a shipped build, and it must be set deliberately:
///
///     xcrun simctl spawn booted defaults write com.whoopmaxx.app wmDebugHistoryAuthority -bool YES
enum BuildPolicy {

    /// DEBUG-only deliberate opt-in. Absent from Release builds.
    static let debugOverrideKey = "wmDebugHistoryAuthority"

    /// Pure form of the rule, so it is testable independently of whichever config the test bundle
    /// happens to compile under (the test target runs Debug, where the live property below is false).
    static func grantsAuthority(compiledWithAuthority: Bool, debugBuild: Bool,
                                debugOverride: Bool) -> Bool {
        if compiledWithAuthority { return true }
        return debugBuild && debugOverride
    }

    /// True when THIS build may kick a backfill and ack history chunks.
    static var hasHistoryAuthority: Bool {
        #if WM_HISTORY_AUTHORITY
        return grantsAuthority(compiledWithAuthority: true, debugBuild: false, debugOverride: false)
        #elseif DEBUG
        return grantsAuthority(compiledWithAuthority: false, debugBuild: true,
                               debugOverride: UserDefaults.standard.bool(forKey: debugOverrideKey))
        #else
        return grantsAuthority(compiledWithAuthority: false, debugBuild: false, debugOverride: false)
        #endif
    }

    /// One-line explanation for the log console, so a silent "no sync" in a dev build is legible
    /// rather than looking like a broken strap.
    static var historyAuthorityReason: String {
        #if WM_HISTORY_AUTHORITY
        return "release build"
        #elseif DEBUG
        return hasHistoryAuthority
            ? "debug build, \(debugOverrideKey) opt-in set"
            : "debug build — set the \(debugOverrideKey) default to sync from here"
        #else
        return "non-release build"
        #endif
    }
}
