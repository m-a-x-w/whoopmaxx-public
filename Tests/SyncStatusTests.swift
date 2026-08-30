import XCTest
@testable import whoopmaxx

/// Precedence pins for `SyncStatus.resolve` — the one ladder every surface reads (012 P1).
///
/// The point of a ladder is ORDER, not the individual verdicts: with Bluetooth off, a three-day-old
/// frontier and the stuck-strap watchdog all true at once the app must say exactly ONE thing, and it
/// must be the radio — everything under it is a consequence of the dead radio, so naming any of those
/// instead is misattribution. Most of these tests are therefore written as conflicts, with several
/// rungs true at the same time, rather than one input at a time.
final class SyncStatusTests: XCTestCase {

    /// A fixed "now" so every gap below is exact — no wall clock in these tests.
    private let now: TimeInterval = 1_700_000_000

    /// The healthy baseline — radio fine, bonded, idle, not experimental — so each test perturbs only
    /// the axes it is about. `frontierUnix` has no default: every case states its own frontier.
    private func resolve(radio: LiveState.RadioState = .poweredOn,
                         bonded: Bool = true,
                         backfilling: Bool = false,
                         strapNeedsReboot: Bool = false,
                         historySyncExperimental: Bool = false,
                         frontierUnix: TimeInterval?,
                         frontierLoaded: Bool = true) -> SyncStatus.State {
        SyncStatus.resolve(radio: radio,
                           bonded: bonded,
                           backfilling: backfilling,
                           strapNeedsReboot: strapNeedsReboot,
                           historySyncExperimental: historySyncExperimental,
                           frontierUnix: frontierUnix,
                           frontierLoaded: frontierLoaded,
                           now: now)
    }

    // MARK: - The radio outranks the strap (decision 3)

    /// Bluetooth off + a three-day-old frontier + the stuck-strap flag: the answer is the radio, and
    /// the two strap states it outranks must not surface at all.
    func testRadioOutranksTheStrapStatesBelowIt() {
        let status = resolve(radio: .poweredOff,
                             strapNeedsReboot: true,
                             frontierUnix: now - 3 * 86_400)
        XCTAssertEqual(status, .radio(LiveState.RadioState.poweredOff.problem!),
                       "a dead radio explains the frozen frontier — blaming the strap is misattribution")
    }

    /// The radio's copy is carried verbatim, never re-authored here: the app already owns the only
    /// wording that names the actual fault and its recovery route.
    func testRadioCopyIsCarriedNotRewritten() {
        for state in [LiveState.RadioState.poweredOff, .unauthorized, .unsupported] {
            XCTAssertEqual(resolve(radio: state, frontierUnix: now).line, state.problem)
        }
    }

    /// `.unknown` (not yet reported / transiently resetting) has no problem copy, so it must NOT mask
    /// the strap state under it. The gate is `problem != nil`, not `radio == .poweredOn` — a device
    /// churning `.resetting` would otherwise hide a real three-day gap behind a blank radio state.
    func testTransientRadioStateDoesNotHijackTheLadder() {
        XCTAssertEqual(resolve(radio: .unknown, frontierUnix: now - 3 * 86_400), .behind("3d"))
    }

    // MARK: - The named trap: no strap is not a stale sync

    /// A fresh install has a nil frontier, which `SyncGap` reads as `.firstSync`. That is only a sync
    /// verdict once there is something to sync FROM — unpaired, it is the absence of a strap.
    func testFreshInstallReadsNotPairedNotNeverSynced() {
        XCTAssertEqual(resolve(bonded: false, frontierUnix: nil), .notPaired)
    }

    /// THE CASE THIS WHOLE WAVE EXISTS FOR, and the one a `guard bonded` hides.
    ///
    /// `LiveState.bonded` is false at process start until the strap reconnects, and stays false while
    /// the strap is out of range or flat. So the user who left their strap on the charger for three
    /// days opens the app UNBONDED with a real three-day-old frontier. Answering "No strap paired."
    /// there would suppress precisely the state this ladder was built to report — and keep suppressing
    /// it for as long as the strap stayed off.
    ///
    /// A persisted frontier is proof a strap paired and synced: the store cannot hold a sample that
    /// never arrived. So it stands in for the live link, and the frontier verdict runs.
    func testAnUnbondedStrapWithRealHistoryStillReportsHowFarBehindItIs() {
        XCTAssertEqual(resolve(bonded: false, frontierUnix: now - 3 * 86_400), .behind("3d"))
    }

    /// Bonded with nothing persisted IS the sync verdict — paired, waiting for the first sample.
    func testBondedWithNoFrontierIsNeverSynced() {
        XCTAssertEqual(resolve(frontierUnix: nil), .neverSynced)
    }

    // MARK: - An offload in progress outranks the gap it is closing

    /// Mid-offload the store is still three days behind, but that gap is being fixed as we read it —
    /// reporting it as an idle backlog would be wrong about the direction of travel.
    func testOffloadingOutranksAStaleFrontier() {
        XCTAssertEqual(resolve(backfilling: true, frontierUnix: now - 3 * 86_400), .offloading("3d"))
    }

    /// With nothing persisted yet, or a gap already inside the caught-up floor, there is no honest
    /// numeral to print — the state carries nil rather than a fabricated "0m behind".
    func testOffloadingCarriesNilWhenThereIsNoHonestNumeral() {
        XCTAssertEqual(resolve(backfilling: true, frontierUnix: nil), .offloading(nil))
        XCTAssertEqual(resolve(backfilling: true, frontierUnix: now), .offloading(nil))
        XCTAssertEqual(SyncStatus.State.offloading(nil).line, "Syncing…")
    }

    /// A 5/MG mid-offload: data really is arriving, so the experimental-history caption would be
    /// wrong right now.
    func testOffloadingOutranksLiveOnly() {
        XCTAssertEqual(resolve(backfilling: true,
                               historySyncExperimental: true,
                               frontierUnix: now - 3 * 86_400),
                       .offloading("3d"))
    }

    // MARK: - Explanations outrank the symptoms they cause

    /// #580: the frontier really is days behind on a 5/MG that streams bpm and hands over no history —
    /// but "3d old" reads as "wait a bit longer", and waiting is not what fixes this one.
    func testLiveOnlyOutranksTheFrontierVerdict() {
        XCTAssertEqual(resolve(historySyncExperimental: true, frontierUnix: now - 3 * 86_400),
                       .liveOnly)
    }

    /// The stuck-strap watchdog beats both the offload and the frontier: it fires precisely because
    /// data exists that the link will not move, so neither "syncing" nor "3d old" is the story.
    func testStuckStrapOutranksTheOffloadAndTheFrontier() {
        XCTAssertEqual(resolve(backfilling: true,
                               strapNeedsReboot: true,
                               frontierUnix: now - 3 * 86_400),
                       .strapStuck(SyncStatus.strapRebootLine))
    }

    // MARK: - The frontier verdict is SyncGap's, not a second opinion

    /// The NUMERAL is always SyncGap's, at both floors — the ladder must never format a duration
    /// itself, or Today and the sync-progress row would spell the same gap two ways.
    ///
    /// The THRESHOLD differs by rung, and deliberately so: `.offloading` keeps SyncGap's 5-minute floor
    /// (mid-offload the frontier is re-read per chunk, so five minutes of lag is a real backlog), while
    /// the idle verdict answers to `idleBehindFloor` — see that constant. This asserts both halves, so
    /// collapsing them back onto one floor fails here.
    func testTheNumeralIsSyncGapsAtBothFloors() {
        let syncGapFloor = SyncGap.caughtUpFloor
        // Mid-offload: SyncGap's floor, and its formatting.
        XCTAssertEqual(resolve(backfilling: true, frontierUnix: now - (syncGapFloor - 1)),
                       .offloading(nil))
        XCTAssertEqual(resolve(backfilling: true, frontierUnix: now - syncGapFloor),
                       .offloading(SyncGap.compact(seconds: syncGapFloor)))
        // Idle: the same formatter, at the idle floor.
        XCTAssertEqual(resolve(frontierUnix: now - SyncStatus.idleBehindFloor),
                       .behind(SyncGap.compact(seconds: SyncStatus.idleBehindFloor)))
    }

    /// A strap whose clock drifted ahead of the phone must read as caught up — never a negative gap,
    /// and never a numeral counted the wrong way.
    func testFrontierAheadOfNowReadsCaughtUpNeverNegative() {
        XCTAssertEqual(resolve(frontierUnix: now + 3_600), .caughtUp)
    }

    /// The idle-and-behind state this wave exists for, with the gap formatted by `SyncGap.compact`.
    func testIdleAndBehindCarriesTheCompactGap() {
        XCTAssertEqual(resolve(frontierUnix: now - (2 * 86_400 + 4 * 3_600)), .behind("2d 4h"))
    }

    // MARK: - Copy: one line per state, owned by the type

    /// A caught-up strap says nothing at all — decision 5. Anything else here puts a permanent caption
    /// on Today for every user whose strap is working.
    func testCaughtUpSaysNothing() {
        XCTAssertNil(SyncStatus.State.caughtUp.line)
        XCTAssertFalse(SyncStatus.State.caughtUp.isProblem)
    }

    /// Both surfaces render these strings, so they live on the type and are pinned here — a reword on
    /// one screen is the drift this prevents.
    func testEachStateOwnsItsLine() {
        XCTAssertEqual(SyncStatus.State.neverSynced.line, "Paired, but no data has arrived yet.")
        XCTAssertEqual(SyncStatus.State.offloading("3d").line, "Syncing… 3d behind.")
        XCTAssertEqual(SyncStatus.State.behind("2d 4h").line, "Last synced data is 2d 4h old.")
        XCTAssertEqual(SyncStatus.State.notPaired.line, "No strap paired.")
        XCTAssertEqual(SyncStatus.State.liveOnly.line,
                       "Live heart rate only — this strap's history sync is experimental, so scores "
                           + "may not fill in.")
    }

    /// An offload is the pipeline WORKING, so it must not trip Today's caption gate even though it has
    /// something to say — otherwise a caption flashes onto Today every time the strap connects.
    func testAnOffloadInProgressIsNotAProblem() {
        XCTAssertFalse(SyncStatus.State.offloading("3d").isProblem)
        XCTAssertNotNil(SyncStatus.State.offloading("3d").line)
    }

    // MARK: - The caption gate the surfaces render through (012 P2)

    /// Every case, written out by hand: the enum carries associated values so it cannot be
    /// `CaseIterable`, and `offloading` appears twice because its two payloads are two different
    /// renderings. A rung added later and left out of this list is caught by the counts below.
    private let everyState: [SyncStatus.State] = [
        .radio(LiveState.RadioState.poweredOff.problem!),
        .strapStuck(SyncStatus.strapRebootLine),
        .neverSynced,
        .offloading("3d"),
        .offloading(nil),
        .behind("2d 4h"),
        .liveOnly,
        .caughtUp,
        .notPaired
    ]

    /// Today renders `if status.isProblem, let line = status.line` — so a state that claims a problem
    /// and hands back nothing to print would put a BLANK caption row under the date header, on the
    /// app's most protected surface, with no way for the user to tell it apart from a layout bug. The
    /// count is asserted first so the loop can never pass vacuously.
    func testEveryStateThatClaimsAProblemHasSomethingToSay() {
        let reporting = everyState.filter(\.isProblem)
        XCTAssertEqual(reporting.count, 6,
                       "radio · strapStuck · neverSynced · behind · liveOnly · notPaired trip the gate")
        for state in reporting {
            XCTAssertFalse(state.line?.isEmpty ?? true,
                           "\(state) trips Today's caption gate, so it owes the gate a line to print")
        }
    }

    /// The other half of the gate: `caughtUp` is the ONLY state allowed to stay silent. If any rung
    /// that describes a real fault lost its line, Today would render nothing for it and the fault would
    /// go back to being invisible — which is the entire defect this wave exists to fix.
    func testCaughtUpIsTheOnlySilentState() {
        XCTAssertEqual(everyState.filter { $0.line == nil }, [.caughtUp])
    }

    // MARK: - The disabled Reconnect gate (012 decision 4)

    /// Live keeps the Reconnect button visible and disables it on `radio.problem != nil`, because
    /// `BLEManager.connect()` no-ops unless the radio is powered on. That gate is only honest while the
    /// ladder blames the radio on the SAME predicate: a disabled control has to have its reason printed
    /// beneath it, and the reason is the `.radio` line.
    ///
    /// Asserted as a biconditional over every radio state. Re-gating `resolve` on `radio == .poweredOn`
    /// — the tempting simplification — breaks it at `.unknown`: the ladder would blame the radio (with
    /// no copy to show for it) while the button stayed live.
    func testTheLadderBlamesTheRadioExactlyWhenReconnectGoesDisabled() {
        for radio in [LiveState.RadioState.unknown, .poweredOn, .poweredOff, .unauthorized, .unsupported] {
            let blamesRadio: Bool
            if case .radio = resolve(radio: radio, frontierUnix: now) { blamesRadio = true }
            else { blamesRadio = false }
            XCTAssertEqual(blamesRadio, radio.problem != nil,
                           "\(radio): Reconnect's disabled gate and the ladder's top rung must agree")
        }
    }

    // MARK: - The idle verdict answers to the offload cadence, not to SyncGap's floor

    /// A HEALTHY connected strap must never caption Today (012 decision 5), and the frontier is what
    /// makes that hard: `persistedFrontierUnix` is a snapshot that only advances when something re-reads
    /// it, while `now` runs continuously. Inheriting `SyncGap.caughtUpFloor` (5 min) made `.behind` the
    /// steady state for most of every 15-minute sync cycle — "Last synced data is 7m old" at a strap
    /// whose store held a sample from seconds ago.
    func testAnOrdinarySyncCycleNeverReadsAsBehind() {
        // Anywhere inside a normal cycle — well past SyncGap's 5-minute floor.
        XCTAssertEqual(resolve(frontierUnix: now - 7 * 60), .caughtUp)
        XCTAssertEqual(resolve(frontierUnix: now - 14 * 60), .caughtUp)
        // Even a cycle running late, up to the floor itself.
        XCTAssertEqual(resolve(frontierUnix: now - (SyncStatus.idleBehindFloor - 60)), .caughtUp)
    }

    /// …and past it, the pipeline really is behind and says so, with SyncGap's numeral.
    func testPastTheIdleFloorItReportsTheGap() {
        XCTAssertEqual(resolve(frontierUnix: now - SyncStatus.idleBehindFloor), .behind("30m"))
        XCTAssertEqual(resolve(frontierUnix: now - 3 * 86_400), .behind("3d"))
    }

    /// The floor is DERIVED from the offload cadence, not written as a literal — so changing the
    /// cadence moves it, and a future change to either breaks this rather than the caption.
    func testTheIdleFloorTracksTheOffloadCadence() {
        XCTAssertEqual(SyncStatus.idleBehindFloor,
                       2 * TimeInterval(BLEManager.backfillIntervalSeconds))
        XCTAssertGreaterThan(SyncStatus.idleBehindFloor, SyncGap.caughtUpFloor,
                             "the idle verdict must be strictly laxer than the mid-offload row's")
    }

    /// A mid-offload gap keeps SyncGap's own floor: there the frontier is re-read per chunk, so five
    /// minutes of lag genuinely is a backlog. The idle floor must not leak into `.offloading`.
    func testTheOffloadingRungKeepsSyncGapsFloor() {
        XCTAssertEqual(resolve(backfilling: true, frontierUnix: now - 7 * 60), .offloading("7m"))
    }

    // MARK: - "Not read yet" is not a finding about the user

    /// The frontier read is an async store query, so on the opening frames of every launch it has not
    /// landed and `persistedFrontierUnix` is nil. Treating that nil as "nothing has ever been persisted"
    /// turned the app's own startup latency into a claim about the user: "No strap paired." on Today,
    /// for everyone, every launch. Silence until we have actually looked.
    func testABeforeTheFirstReadTheLadderSaysNothing() {
        XCTAssertEqual(resolve(bonded: false, frontierUnix: nil, frontierLoaded: false), .caughtUp)
        XCTAssertNil(SyncStatus.State.caughtUp.line)
        // And it is quiet even where a rung below WOULD have fired.
        XCTAssertEqual(resolve(frontierUnix: nil, frontierLoaded: false), .caughtUp)
    }

    /// Once the read HAS landed, a nil frontier is a real answer again and the ladder speaks.
    func testAfterTheReadLandsANilFrontierIsAFinding() {
        XCTAssertEqual(resolve(bonded: false, frontierUnix: nil, frontierLoaded: true), .notPaired)
        XCTAssertEqual(resolve(frontierUnix: nil, frontierLoaded: true), .neverSynced)
    }

    /// A radio problem is independent of the store, so it must NOT wait on the frontier read — a user
    /// with Bluetooth off should be told immediately, not after a query that explains nothing.
    func testARadioProblemDoesNotWaitOnTheFrontierRead() {
        XCTAssertEqual(resolve(radio: .poweredOff, frontierUnix: nil, frontierLoaded: false),
                       .radio(LiveState.RadioState.poweredOff.problem!))
    }
}
