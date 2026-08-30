import XCTest
@testable import whoopmaxx

/// Pins the SleepStagingV2-by-default flip.
///
/// Three things have to agree or the app stages one way and says another: the engine's read
/// (`PuffinExperiment.experimentalSleepV2Enabled`), the declared default the Settings toggle binds to
/// (`experimentalSleepV2Default`, which `@AppStorage` returns for an unset key), and the one-shot
/// re-score that re-derives already-persisted V1 hypnograms under the new default.
///
/// The specific trap being pinned: `UserDefaults.bool(forKey:)` reads an UNSET key as `false`, so the
/// original accessor would have pinned a default-ON flag permanently off. The fix is the
/// `object(forKey:) as? Bool ?? default` idiom, which requires a stored value to win in BOTH
/// directions — anyone who deliberately turned V2 off must STAY off across the default flip.
final class SleepStagerDefaultTests: XCTestCase {

    /// A suite-scoped domain so these never touch the app's real defaults.
    private var defaults: UserDefaults!
    private let suite = "SleepStagerDefaultTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    /// The accessor's exact idiom, evaluated against an injectable domain. Kept in lockstep with
    /// `PuffinExperiment.experimentalSleepV2Enabled` — if that read changes shape, change this too.
    private func v2Enabled(in d: UserDefaults) -> Bool {
        d.object(forKey: PuffinExperiment.experimentalSleepV2Key) as? Bool
            ?? PuffinExperiment.experimentalSleepV2Default
    }

    // MARK: - The default

    func testDefaultIsOn() {
        XCTAssertTrue(PuffinExperiment.experimentalSleepV2Default)
    }

    func testUnsetKeyReadsAsOn() {
        XCTAssertNil(defaults.object(forKey: PuffinExperiment.experimentalSleepV2Key))
        XCTAssertTrue(v2Enabled(in: defaults))
    }

    /// The regression the idiom change exists for: `bool(forKey:)` cannot express a default-ON flag.
    func testBoolForKeyWouldHavePinnedTheDefaultOff() {
        XCTAssertFalse(defaults.bool(forKey: PuffinExperiment.experimentalSleepV2Key),
                       "bool(forKey:) reads an unset key as false — this is why the accessor uses object(forKey:)")
        XCTAssertTrue(v2Enabled(in: defaults), "the shipped accessor must not inherit that behaviour")
    }

    // MARK: - A stored value wins in both directions

    func testExplicitOffSurvivesTheDefaultFlip() {
        defaults.set(false, forKey: PuffinExperiment.experimentalSleepV2Key)
        XCTAssertFalse(v2Enabled(in: defaults),
                       "a user who deliberately turned V2 off must stay off when the default flips on")
    }

    func testExplicitOnIsHonoured() {
        defaults.set(true, forKey: PuffinExperiment.experimentalSleepV2Key)
        XCTAssertTrue(v2Enabled(in: defaults))
    }

    // MARK: - The one-shot re-score

    /// Existing installs hold V1-staged hypnograms. The key had to be bumped, or an install that
    /// already consumed the v1 one-shot would keep V1 nights beside newly-written V2 nights.
    func testRescoreKeyWasBumpedForTheFlip() {
        XCTAssertEqual(ScoreEngine.round4RescoreDoneKey, "wm.heal.round4StagingAndSpread.v2")
    }

    /// A restore lands a store staged by whatever build wrote it, so the widened re-score must re-arm.
    func testRescoreIsReArmedByRestore() {
        XCTAssertTrue(RestoreHealReset.storeScopedOneShots.contains(ScoreEngine.round4RescoreDoneKey),
                      "a restored store's hypnograms would keep their old stager without this")
    }

    func testRestoreReArmClearsTheRescoreFlag() {
        defaults.set(true, forKey: ScoreEngine.round4RescoreDoneKey)
        RestoreHealReset.rearm(in: defaults)
        XCTAssertNil(defaults.object(forKey: ScoreEngine.round4RescoreDoneKey),
                     "re-arm removes the key so it returns to its never-run state")
    }

    /// The flag must NOT ride into a backup — a restore has to re-run the pass against the landed rows.
    func testRescueKeyIsNotInTheBackupWhitelist() {
        XCTAssertNil(WmBackup.settingsWhitelist[ScoreEngine.round4RescoreDoneKey])
    }
}
