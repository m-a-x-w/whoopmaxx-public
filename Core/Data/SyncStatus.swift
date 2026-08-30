import Foundation

/// The ONE answer to "is data getting in?" — the whole pipeline resolved into a single state.
///
/// EXISTS BECAUSE THE APP ALREADY KNEW AND NEVER SAID IT. `LiveState.RadioState.problem` carries
/// honest, actionable copy for a dead radio and had exactly one reader — the pair sheet a paired user
/// never opens again. `strapNeedsReboot` and `historySyncExperimental` were `@Published` with zero
/// readers. And `SyncGap`, the only honest "2d 4h behind" in the app, was rendered only while
/// `backfilling`, i.e. visible only while data was already arriving. The state a user actually lives in
/// — strap on the charger for three days, nothing syncing — had no representation anywhere.
///
/// ONE LADDER, ONE ANSWER (012 decision 1). Every surface resolves through `resolve` and chooses only
/// how much of the result to show. Two screens deriving their own opinion of "are we synced" is the
/// contradiction this app repeatedly designs against.
///
/// PURE, AND TAKES `now` (012 decision 2) — no `LiveState` reference, no BLE seam, no `Date()` inside.
/// The `SyncGap` / `SignalQuality` idiom, and what makes the precedence testable without a strap.
///
/// INVENTS NOTHING (012 decision 6). The gap is `SyncGap`'s, the radio copy is `RadioState`'s. This is
/// a ladder plus one line of copy per rung — it is not an estimator, and it measures nothing new.
enum SyncStatus {

    /// The pipeline's mutually exclusive states. Declaration order is the 012 spec's; the PRECEDENCE
    /// order — which one wins when several are true at once — is `resolve`'s, and is the whole point.
    enum State: Equatable {
        /// The BLUETOOTH RADIO is the subject. Outranks everything below it: a dead radio explains
        /// every strap symptom under it, so naming one of those instead is misattribution (012
        /// decision 3). Carries `LiveState.RadioState.problem` verbatim — the app already owns the
        /// right words and they must not be rewritten here.
        case radio(String)
        /// The stuck-strap watchdog fired (`LiveState.strapNeedsReboot`, set by `checkStrapLiveness`):
        /// the strap reports records newer than our frontier while our frontier has not advanced for
        /// the detector window. Data exists that the link will not move, and waiting longer will not
        /// fix it — which is exactly what the generic frontier verdict below ("3d old") would imply,
        /// so this specific, actionable state outranks it. Case name is the 012 spec's.
        case strapStuck(String)
        /// Bonded, but no sample has EVER landed — `SyncGap.Reading.firstSync` for a paired strap.
        case neverSynced
        /// History is being handed over right now. Carries the compact gap, or nil while that is
        /// unknown (nothing persisted yet) or already inside the caught-up floor.
        case offloading(String?)
        /// Idle, and the store trails the wall clock by this much. THE state this wave exists for:
        /// before it, an idle strap days behind said nothing anywhere in the app.
        case behind(String)
        /// #580: a connected WHOOP 5/MG streams live bpm fine while its firmware hands over no history
        /// offload. The frontier really is falling behind, but that is the symptom — this is the only
        /// explanation such an owner would ever get for live bpm with no scores behind it.
        case liveOnly
        /// Up to date. The state with nothing to say.
        case caughtUp
        /// No strap bonded at all. Not a sync fault — the absence of a strap.
        case notPaired

        /// The one line each state owns, so both surfaces render identical words.
        ///
        /// nil ONLY for `.caughtUp`: a strap that is up to date has nothing to report, and saying so
        /// unprompted would be noise (012 decision 5 — the `CaptureQuality.caption` rule).
        var line: String? {
            switch self {
            case .radio(let copy):       return copy
            case .strapStuck(let copy):  return copy
            case .neverSynced:           return "Paired, but no data has arrived yet."
            case .offloading(let gap):
                guard let gap else { return "Syncing…" }
                return "Syncing… \(gap) behind."
            case .behind(let gap):       return "Last synced data is \(gap) old."
            case .liveOnly:
                return "Live heart rate only — this strap's history sync is experimental, so scores "
                    + "may not fill in."
            case .caughtUp:              return nil
            case .notPaired:             return "No strap paired."
            }
        }

        /// Whether the pipeline is in a state worth reporting on a surface the user opened for another
        /// reason. Today's caption gates on this (012 decision 5).
        ///
        /// `.offloading` has a line but is NOT a problem: a sync in progress is the pipeline working,
        /// and gating on "has a line" instead would flash a caption onto Today every time the strap
        /// connected. `.caughtUp` has neither.
        var isProblem: Bool {
            switch self {
            case .caughtUp, .offloading:
                return false
            case .radio, .strapStuck, .neverSynced, .behind, .liveOnly, .notPaired:
                return true
            }
        }
    }

    /// The `.strapStuck` line.
    ///
    /// Unlike `.radio`, the app owns NO copy for the stuck-strap watchdog — `strapNeedsReboot` shipped
    /// `@Published` with zero readers and no sentence anywhere — so it is authored once here and
    /// carried in the case, rather than written twice at two call sites. States what was actually
    /// observed (the strap holds records we do not) and the one recovery `checkStrapLiveness`'s own
    /// comment names; no invented mechanics for how to restart a strap.
    static let strapRebootLine = "The strap has newer data than the app but isn't handing it over. "
        + "Restarting the strap usually clears this."

    /// How far behind the IDLE pipeline must be before `.behind` is worth saying.
    ///
    /// Deliberately NOT `SyncGap.caughtUpFloor` (5 min). That floor belongs to the mid-offload progress
    /// row, where a per-chunk re-read keeps the frontier seconds old, so 5 minutes of lag there really
    /// is a backlog. Idle is the opposite situation: `persistedFrontierUnix` is a SNAPSHOT that only
    /// moves when something re-reads it, while `now` runs continuously — so the measured gap grows in
    /// real time on a perfectly healthy pipeline. With the periodic offload floor at
    /// `BLEManager.backfillIntervalSeconds` (900 s), a 5-minute threshold made `.behind` the steady
    /// state for most of every sync cycle: Today captioning "Last synced data is 7m old" at a connected
    /// strap whose store held a sample from seconds ago. That is decision 5 inverted — the caption
    /// firing for exactly the user who should never see it.
    ///
    /// Two offload intervals, so a cycle running late still clears it, and comfortably above the
    /// 15-minute `.idleTick` that now re-reads the frontier. Derived FROM the cadence rather than
    /// written as a literal, so changing the cadence moves this with it.
    static let idleBehindFloor: TimeInterval = 2 * TimeInterval(BLEManager.backfillIntervalSeconds)

    /// Resolve the whole pipeline to one state, highest precedence first.
    ///
    /// The order, and why each rung sits where it does:
    /// 1. `radio` — a dead radio explains everything under it (012 decision 3).
    /// 2. `strapStuck` — a specific, actionable strap fault beats the generic frontier verdict.
    /// 3. `notPaired` — see THE TRAP below.
    /// 4. `offloading` — data is arriving right now, which outranks the stale frontier it is in the
    ///    middle of fixing.
    /// 5. `liveOnly` — the explanation outranks the symptom it causes.
    /// 6. the frontier verdict, resolved THROUGH `SyncGap.reading`: the 5-minute caught-up floor, the
    ///    ahead-of-now clamp and the compact formatting are all its, deliberately not re-derived here.
    ///    A second floor would let this ladder and the sync-progress row disagree about one instant.
    ///
    /// THE TRAP, both halves: `SyncGap.Reading.firstSync` means "no persisted sample has ever landed".
    /// For a bonded strap that is `.neverSynced`; for a strap that was never paired it is not a sync
    /// problem at all, it is the absence of a strap. So the pairing question is settled before the
    /// frontier verdict, or a fresh install greets the user with a sync that has fallen behind.
    ///
    /// But it is settled on EVIDENCE, not on `bonded` alone. `LiveState.bonded` is false at process
    /// start until the strap reconnects or CoreBluetooth restoration returns the peripheral, and it
    /// stays false while the strap is out of range or flat — so `guard bonded` would answer "No strap
    /// paired." to precisely the user this ladder was built for, the one whose strap has been on the
    /// charger for three days. A persisted frontier is proof a strap paired and synced (the store
    /// cannot hold a sample that never arrived), so it stands in for the live link.
    ///
    /// - Parameters:
    ///   - radio: `LiveState.radio` — gated on its `problem` copy, not on `== .poweredOn`, so the
    ///     transient `.unknown`/resetting state stays quiet instead of masking the strap state below.
    ///   - bonded: `LiveState.bonded`.
    ///   - backfilling: `LiveState.backfilling` — a history offload is running.
    ///   - strapNeedsReboot: `LiveState.strapNeedsReboot` — the stuck-strap watchdog's verdict.
    ///   - historySyncExperimental: `LiveState.historySyncExperimental` — #580, live bpm, no history.
    ///   - frontierUnix: `LiveState.persistedFrontierUnix` — newest PERSISTED sample, nil when none.
    ///   - frontierLoaded: `LiveState.frontierLoaded` — whether that read has HAPPENED yet.
    ///   - now: wall clock, passed in so this stays pure.
    static func resolve(radio: LiveState.RadioState,
                        bonded: Bool,
                        backfilling: Bool,
                        strapNeedsReboot: Bool,
                        historySyncExperimental: Bool,
                        frontierUnix: TimeInterval?,
                        frontierLoaded: Bool,
                        now: TimeInterval) -> State {
        if let problem = radio.problem { return .radio(problem) }
        if strapNeedsReboot { return .strapStuck(strapRebootLine) }
        // "Never paired" is decided on EVIDENCE, not on the live link. `LiveState.bonded` is false at
        // process start until the strap reconnects or CoreBluetooth restoration hands the peripheral
        // back (`BLEManager.swift:3187`) — so keying `.notPaired` on `bonded` alone would greet the
        // user who left their strap on the charger for three days with "No strap paired.", and would
        // keep saying it for as long as the strap stayed out of range or flat. That is the exact state
        // this ladder exists to report, so it must not be the one state it hides.
        //
        // A persisted frontier is proof a strap was paired and did sync: the store cannot hold a sample
        // that never arrived. So an unbonded strap with a frontier falls through to the frontier verdict
        // and correctly reads "Last synced data is 3d old"; only an unbonded strap with NO frontier has
        // genuinely never delivered anything, and that is the honest `.notPaired`.
        // Everything below reads the frontier, and until the store has actually been asked, a nil
        // frontier means "we have not looked", not "nothing is there". Reporting on it before the read
        // lands turns the app's own startup latency into a claim about the user — "No strap paired." on
        // the opening frames of every launch. Silence until we know.
        guard frontierLoaded else { return .caughtUp }
        guard bonded || frontierUnix != nil else { return .notPaired }

        let reading = SyncGap.reading(frontierUnix: frontierUnix, now: now)
        if backfilling {
            // Only `.behind` carries a numeral; first-sync and sub-floor gaps are an honest nil rather
            // than a fabricated "0m behind" while chunks are landing.
            guard case .behind(let gap) = reading else { return .offloading(nil) }
            return .offloading(gap)
        }
        if historySyncExperimental { return .liveOnly }

        switch reading {
        case .firstSync:       return .neverSynced
        case .caughtUp:        return .caughtUp
        // The idle verdict answers to `idleBehindFloor`, not to `SyncGap`'s mid-offload floor — see
        // that constant for why. The NUMERAL is still SyncGap's, so the two surfaces never format one
        // gap two ways; only the threshold for saying anything at all differs.
        case .behind where now - (frontierUnix ?? now) < idleBehindFloor:
            return .caughtUp
        case .behind(let gap): return .behind(gap)
        }
    }
}
