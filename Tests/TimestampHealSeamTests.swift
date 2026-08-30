import XCTest
import StrapStore
@testable import whoopmaxx

/// The #547 timestamp-heal seam. BLEManager pokes `IntelligenceEngine.requestTimestampReheal()` when a
/// sync DROPS implausible (bad-clock) records; `ScoreEngine.analyzeRecent` must honour that poke by
/// forcing its next pass past the #836 idle gate. It matters because dropping those records changes
/// what the affected days score from WITHOUT moving the raw-HR fingerprint the gate compares — so an
/// unforced tick would short-circuit the very pass that was supposed to heal them.
///
/// Observable used: over an EMPTY store a pass that runs to completion scores nothing and lands in the
/// cold-start branch (`note` set), while a pass that short-circuits at the gate returns first and
/// leaves `note` nil. Both tests ARM the gate by stamping the watermark with the store's own current
/// fingerprint, so the only difference between them is the heal flag.
///
/// NOTE the deliberate bypasses this seam has to be isolated from: `ScoreEngine`'s round-4 and 009 weed
/// one-shot widened rescores also force past the #836 gate, for exactly the #547 reason — the corrected
/// stager, the corrected baseline spread and weed's arrival in `IllnessSignalEngine.Context` each change
/// what old days score from without moving the raw-HR fingerprint. `makeArmedEngine` marks them done so
/// the control case below still tests the gate. Every future one-shot folded into `forced` owes the same.
final class TimestampHealSeamTests: XCTestCase {

    /// Control: no heal pending → the armed gate short-circuits the unforced tick.
    @MainActor
    func testUnforcedTickShortCircuitsOnUnchangedFingerprint() async throws {
        let restoreDefaults = snapshotSeamDefaults()
        defer { restoreDefaults() }
        let (engine, dir) = try await makeArmedEngine("heal-seam-control")
        defer { Fixtures.cleanUp(dir) }
        UserDefaults.standard.removeObject(forKey: IntelligenceEngine.timestampHealKey)

        await engine.analyzeRecent(maxDays: 1, force: false)

        XCTAssertNil(engine.note,
                     "an unforced tick with an unchanged HR fingerprint must return at the #836 gate, "
                     + "before the pass can reach its cold-start note")
    }

    /// The seam: a pending heal flag makes the SAME unforced tick run anyway, and is consumed by it.
    @MainActor
    func testPendingTimestampHealBypassesTheIdleGate() async throws {
        let restoreDefaults = snapshotSeamDefaults()
        defer { restoreDefaults() }
        let (engine, dir) = try await makeArmedEngine("heal-seam-pending")
        defer { Fixtures.cleanUp(dir) }
        IntelligenceEngine.requestTimestampReheal()

        await engine.analyzeRecent(maxDays: 1, force: false)

        XCTAssertNotNil(engine.note,
                        "a pending #547 timestamp heal must force the pass past the #836 idle gate — "
                        + "otherwise a sync that dropped bad-clock records never re-scores those days")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: IntelligenceEngine.timestampHealKey),
                       "the pass that honoured the heal must CLEAR the flag, or every later idle tick "
                       + "stays forced forever")
    }

    // MARK: - Support

    /// A `ScoreEngine` over a throwaway EMPTY store, with the #836 watermark already stamped with that
    /// store's current fingerprint — i.e. the idle gate is armed and an unforced pass has every reason
    /// to short-circuit. Returns the temp dir for cleanup.
    @MainActor
    private func makeArmedEngine(_ label: String) async throws -> (ScoreEngine, URL) {
        let (store, dir) = try await Fixtures.tempStore(label)
        let repo = Repository()
        repo.adoptStore(store)
        // Build the watermark the SAME way analyzeRecent does, so this can never drift from the gate.
        let fp = try await store.hrFingerprint(deviceId: repo.deviceId, from: 0, to: 9_999_999_999)
        UserDefaults.standard.set("\(fp.count):\(fp.maxTs)", forKey: ScoreEngine.analyzeWatermarkKey)
        // Mark the one-shot rescores as already done. Each is a DELIBERATE further bypass of the #836
        // gate (the corrected stager / baseline spread, and weed joining the confounder set, change what
        // old days score from without moving the raw-HR fingerprint — the same argument #547 makes), so
        // leaving either armed would make the control case below force for the wrong reason and stop
        // testing anything.
        UserDefaults.standard.set(true, forKey: ScoreEngine.round4RescoreDoneKey)
        UserDefaults.standard.set(true, forKey: ScoreEngine.weedConfounderRescoreDoneKey)
        let engine = ScoreEngine(repo: repo, profile: ProfileStore(), deviceId: repo.deviceId)
        return (engine, dir)
    }

    /// Snapshot the seam keys and hand back the undo. The unit bundle is HOSTED — the live app
    /// shares this UserDefaults suite, so a test run must never leave its idle gate or heal flag armed.
    @MainActor
    private func snapshotSeamDefaults() -> () -> Void {
        let d = UserDefaults.standard
        let watermark = d.object(forKey: ScoreEngine.analyzeWatermarkKey)
        let heal = d.object(forKey: IntelligenceEngine.timestampHealKey)
        let round4 = d.object(forKey: ScoreEngine.round4RescoreDoneKey)
        let weed = d.object(forKey: ScoreEngine.weedConfounderRescoreDoneKey)
        return {
            if let watermark { d.set(watermark, forKey: ScoreEngine.analyzeWatermarkKey) }
            else { d.removeObject(forKey: ScoreEngine.analyzeWatermarkKey) }
            if let heal { d.set(heal, forKey: IntelligenceEngine.timestampHealKey) }
            else { d.removeObject(forKey: IntelligenceEngine.timestampHealKey) }
            if let round4 { d.set(round4, forKey: ScoreEngine.round4RescoreDoneKey) }
            else { d.removeObject(forKey: ScoreEngine.round4RescoreDoneKey) }
            if let weed { d.set(weed, forKey: ScoreEngine.weedConfounderRescoreDoneKey) }
            else { d.removeObject(forKey: ScoreEngine.weedConfounderRescoreDoneKey) }
        }
    }
}
