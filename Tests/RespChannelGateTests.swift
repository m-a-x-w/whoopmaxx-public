import XCTest
import StrapProtocol
import StrapStore
@testable import whoopmaxx

/// The ingest gate that stops the degenerate raw-respiration channel reaching the store, and the
/// run-once maintenance that reclaims what earlier builds already banked.
///
/// Both exist because `resp_rate_raw@80` on the WHOOP 4.0 v24 record layout is an optical MODE REGISTER,
/// not a waveform: a real 17-day store holds 1,433,848 rows carrying exactly two values (3073 = 0x0C01,
/// 2817 = 0x0B01), costing 72.36 MB — 16.35% of the 442 MB database — to record one bit per row.
final class RespChannelGateTests: XCTestCase {

    private var tmp: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        tmp = try Fixtures.tempDir("resp-gate-tests")
        suiteName = "resp-gate-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        Fixtures.cleanUp(tmp)
    }

    // MARK: - fixtures

    /// The channel as the strap really emits it: 1 Hz, constant 3073 with a 29-sample excursion to 2817
    /// every ~19 minutes (the measured median inter-burst gap is 1155 s).
    private func modeRegisterResp(start: Int = 1_700_000_000, count: Int) -> [RespSample] {
        (0..<count).map { RespSample(ts: start + $0, raw: ($0 % 1_155) < 29 ? 2_817 : 3_073) }
    }

    /// A genuine multi-level respiration waveform — what the channel was assumed to carry.
    private func waveformResp(start: Int = 1_700_000_000, count: Int) -> [RespSample] {
        (0..<count).map {
            RespSample(ts: start + $0, raw: Int((2_048 + 300 * sin(0.25 * 2 * Double.pi * Double($0))).rounded()))
        }
    }

    // MARK: - RespChannelGate

    func testRealTwoValueChannelIsDegenerate() {
        XCTAssertTrue(RespChannelGate.isDegenerate(modeRegisterResp(count: 4_000)),
                      "the real 3073/2817 mode register must be recognised as degenerate")
    }

    func testGenuineWaveformIsNotDegenerate() {
        XCTAssertFalse(RespChannelGate.isDegenerate(waveformResp(count: 4_000)),
                       "the gate is a distinctness test, so a real waveform survives — the code self-heals")
    }

    /// Small chunks are never judged: a handful of records that happen to repeat a value prove nothing,
    /// and dropping them would risk discarding the leading edge of a genuine stream.
    func testSmallChunkIsLeftAlone() {
        let tiny = modeRegisterResp(count: RespChannelGate.minSamples - 1)
        XCTAssertFalse(RespChannelGate.isDegenerate(tiny))
        XCTAssertFalse(RespChannelGate.isDegenerate([]))
    }

    func testDropIfDegenerateBlanksOnlyTheDeadChannel() {
        var degenerate = Streams(hr: [HRSample(ts: 1_700_000_000, bpm: 60)],
                                 resp: modeRegisterResp(count: 4_000))
        RespChannelGate.dropIfDegenerate(&degenerate)
        XCTAssertTrue(degenerate.resp.isEmpty, "the dead channel is blanked before it reaches the store")
        XCTAssertEqual(degenerate.hr.count, 1, "every other stream in the chunk is untouched")

        var real = Streams(resp: waveformResp(count: 4_000))
        RespChannelGate.dropIfDegenerate(&real)
        XCTAssertEqual(real.resp.count, 4_000, "a real waveform is persisted exactly as before")
    }

    /// The reason the gate can be a plain no-op on the store side: `StreamStore.insert` already skips its
    /// INSERT loop on an empty array, so a blanked chunk writes nothing and reports 0 honestly.
    func testBlankedChunkPersistsNoRespRows() async throws {
        let dbPath = tmp.appendingPathComponent("gate.sqlite").path
        let store = try await StrapStore(path: dbPath)
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")

        var streams = Streams(resp: modeRegisterResp(count: 4_000))
        RespChannelGate.dropIfDegenerate(&streams)
        let counts = try await store.insert(streams, deviceId: "my-whoop")

        XCTAssertEqual(counts.resp, 0)
        let readBack = try await store.respSamples(deviceId: "my-whoop", from: 0, to: 2_000_000_000, limit: 10)
        XCTAssertTrue(readBack.isEmpty, "no degenerate row may reach the store")
    }

    // MARK: - RollingJudge (high-freq-sync chunks are too small for the static gate)

    /// The size of a high-freq-sync chunk. `Backfiller.finishChunk` documents the shape: ONE HISTORY_START
    /// then repeated HISTORY_ENDs, "a chunk-close every ~50 records".
    private static let highFreqSyncChunk = 50

    /// The defect, in the shape the real store recorded it. `RespChannelGate.dropIfDegenerate` runs per
    /// CHUNK, and a high-freq-sync chunk is ~50 records — permanently under the 60-sample floor — so the
    /// static gate returns false on every one of them and never fires at all. That is how 67,559 two-value
    /// rows reached a 2026-07-30 backup written by a build that already carried the gate.
    func testHighFreqSyncChunksDefeatTheStaticGate() {
        for chunk in stride(from: 0, to: 30 * Self.highFreqSyncChunk, by: Self.highFreqSyncChunk).map({
            modeRegisterResp(start: 1_700_000_000 + $0, count: Self.highFreqSyncChunk)
        }) {
            XCTAssertFalse(RespChannelGate.isDegenerate(chunk),
                           "a ~50-record chunk can never clear the 60-sample floor — this is the bug")
        }
    }

    /// Same chunks through the judge: it accumulates across them, rules once it has the evidence, and
    /// drops everything after. The pre-verdict admission is bounded by `minSamples`.
    func testJudgeLatchesDegenerateAcrossHighFreqSyncChunks() {
        var judge = RespChannelGate.RollingJudge()
        var admitted = 0
        for i in 0..<30 {
            var streams = Streams(resp: modeRegisterResp(start: 1_700_000_000 + i * Self.highFreqSyncChunk,
                                                         count: Self.highFreqSyncChunk))
            judge.dropIfDegenerate(&streams)
            admitted += streams.resp.count
        }
        XCTAssertEqual(judge.verdict, .degenerate)
        XCTAssertLessThan(admitted, RespChannelGate.minSamples,
                          "at most minSamples-1 rows may be admitted before the judge can rule")
        XCTAssertEqual(admitted, Self.highFreqSyncChunk,
                       "ruled on the second chunk, so only the first one's rows landed")
    }

    /// The self-healing property, preserved: a firmware that emits a real waveform latches `.genuine` on the
    /// first flush that shows a third level, and is never judged again — a `.degenerate` verdict must never
    /// be reachable afterwards.
    func testJudgeLatchesGenuineAndNeverSuppressesAWaveform() {
        var judge = RespChannelGate.RollingJudge()
        var total = 0
        for i in 0..<30 {
            var streams = Streams(resp: waveformResp(start: 1_700_000_000 + i * Self.highFreqSyncChunk,
                                                     count: Self.highFreqSyncChunk))
            judge.dropIfDegenerate(&streams)
            total += streams.resp.count
        }
        XCTAssertEqual(judge.verdict, .genuine)
        XCTAssertEqual(total, 30 * Self.highFreqSyncChunk, "every row of a real waveform is persisted")

        // Even a long degenerate stretch afterwards (the strap parking the register) cannot flip it back.
        var later = Streams(resp: modeRegisterResp(count: 4_000))
        judge.dropIfDegenerate(&later)
        XCTAssertEqual(later.resp.count, 4_000)
        XCTAssertEqual(judge.verdict, .genuine)
    }

    /// THE SEQUENCE A TERMINAL LATCH WOULD BREAK. A firmware update turns the channel into a real
    /// waveform, but the strap still holds days of PRE-update records and offloads OLDEST-FIRST — so the
    /// degenerate evidence necessarily arrives before the genuine data. A `.degenerate` verdict that
    /// stopped looking would drop the good rows and then ack them away, permanently.
    func testDegenerateLatchStillFlipsWhenARealWaveformArrivesLater() {
        var judge = RespChannelGate.RollingJudge()

        // Pre-update records: enough to latch degenerate.
        for i in 0..<10 {
            var old = Streams(resp: modeRegisterResp(start: 1_700_000_000 + i * Self.highFreqSyncChunk,
                                                     count: Self.highFreqSyncChunk))
            judge.dropIfDegenerate(&old)
        }
        XCTAssertEqual(judge.verdict, .degenerate)

        // Post-update records: a genuine waveform must flip the verdict and survive.
        var fresh = Streams(resp: waveformResp(start: 1_800_000_000, count: Self.highFreqSyncChunk))
        judge.dropIfDegenerate(&fresh)
        XCTAssertEqual(judge.verdict, .genuine)
        XCTAssertEqual(fresh.resp.count, Self.highFreqSyncChunk,
                       "the post-update waveform must not be dropped by the pre-update verdict")

        // And it stays genuine for everything after.
        var later = Streams(resp: waveformResp(start: 1_800_010_000, count: Self.highFreqSyncChunk))
        judge.dropIfDegenerate(&later)
        XCTAssertEqual(later.resp.count, Self.highFreqSyncChunk)
    }

    /// An empty chunk must not un-latch a standing verdict, nor count as evidence.
    func testEmptyChunkDoesNotDisturbAStandingVerdict() {
        var judge = RespChannelGate.RollingJudge()
        for i in 0..<10 {
            var c = Streams(resp: modeRegisterResp(start: 1_700_000_000 + i * Self.highFreqSyncChunk,
                                                   count: Self.highFreqSyncChunk))
            judge.dropIfDegenerate(&c)
        }
        XCTAssertEqual(judge.verdict, .degenerate)

        var consoleOnly = Streams(hr: [HRSample(ts: 1_700_100_000, bpm: 60)])
        judge.dropIfDegenerate(&consoleOnly)
        XCTAssertEqual(judge.verdict, .degenerate, "an empty chunk is not evidence in either direction")

        var stillDead = Streams(resp: modeRegisterResp(start: 1_700_200_000, count: Self.highFreqSyncChunk))
        judge.dropIfDegenerate(&stillDead)
        XCTAssertTrue(stillDead.resp.isEmpty, "and the verdict still applies")
    }

    /// A judge that has never seen a sample is `.undecided` and drops nothing — empty flushes must not
    /// count as evidence in either direction.
    func testJudgeStaysUndecidedOnEmptyFlushes() {
        var judge = RespChannelGate.RollingJudge()
        for _ in 0..<100 {
            var streams = Streams(hr: [HRSample(ts: 1_700_000_000, bpm: 60)])
            judge.dropIfDegenerate(&streams)
        }
        XCTAssertEqual(judge.verdict, .undecided)
    }

    /// The judge leaves the rest of the chunk alone, exactly as the static gate does.
    func testJudgeBlanksOnlyTheDeadChannel() {
        var judge = RespChannelGate.RollingJudge()
        var streams = Streams(hr: [HRSample(ts: 1_700_000_000, bpm: 60)],
                              resp: modeRegisterResp(count: 4_000))
        judge.dropIfDegenerate(&streams)
        XCTAssertTrue(streams.resp.isEmpty)
        XCTAssertEqual(streams.hr.count, 1)
    }

    // MARK: - StoreMaintenance (run-once purge of what earlier builds banked)

    /// Seed a throwaway store with `resp` rows through the real writer, closing it so the purge's own
    /// connection isn't fighting a live handle.
    private func seedStore(named name: String, resp: [RespSample]) async throws -> String {
        let path = tmp.appendingPathComponent(name).path
        let store = try await StrapStore(path: path)
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        _ = try await store.insert(Streams(resp: resp), deviceId: "my-whoop")
        _ = try? await store.checkpointWAL()
        return path
    }

    private func respRowCount(atPath path: String) async throws -> Int {
        let store = try await StrapStore(path: path)
        return try await store.respSamples(deviceId: "my-whoop", from: 0, to: 2_000_000_000, limit: 500_000).count
    }

    func testPurgeRemovesTheDegenerateChannelOnce() async throws {
        let path = try await seedStore(named: "purge.sqlite", resp: modeRegisterResp(count: 4_000))
        let seeded = try await respRowCount(atPath: path)
        XCTAssertEqual(seeded, 4_000, "fixture must actually bank the rows")

        let outcome = StoreMaintenance.purgeDegenerateRespSamplesIfNeeded(databaseAt: path, defaults: defaults)
        guard case .purged(let rows, _) = outcome else {
            return XCTFail("expected .purged, got \(outcome)")
        }
        XCTAssertEqual(rows, 4_000)
        let remaining = try await respRowCount(atPath: path)
        XCTAssertEqual(remaining, 0, "the banked rows must be gone")
        XCTAssertTrue(defaults.bool(forKey: StoreMaintenance.respPurgeDefaultsKey))

        // Run-once: a second call must not even open the file.
        XCTAssertEqual(StoreMaintenance.purgeDegenerateRespSamplesIfNeeded(databaseAt: path, defaults: defaults),
                       .alreadyRun)
    }

    /// The purge is CONDITIONAL. A store whose respiration really is a waveform keeps every row, and the
    /// flag is set so we never look at it again.
    func testPurgeLeavesAGenuineWaveformAlone() async throws {
        let path = try await seedStore(named: "keep.sqlite", resp: waveformResp(count: 4_000))

        XCTAssertEqual(StoreMaintenance.purgeDegenerateRespSamplesIfNeeded(databaseAt: path, defaults: defaults),
                       .notDegenerate)
        let kept = try await respRowCount(atPath: path)
        XCTAssertEqual(kept, 4_000,
                       "a real respiration waveform must survive the purge untouched")
        XCTAssertTrue(defaults.bool(forKey: StoreMaintenance.respPurgeDefaultsKey))
    }

    /// Before the store's first open there is no file (and then no table) — the purge must report
    /// `.notReady` WITHOUT setting the flag, so it gets its one chance after the migrations run.
    func testMissingDatabaseIsNotReadyAndDoesNotBurnTheFlag() {
        let absent = tmp.appendingPathComponent("nope.sqlite").path
        XCTAssertEqual(StoreMaintenance.purgeDegenerateRespSamplesIfNeeded(databaseAt: absent, defaults: defaults),
                       .notReady)
        XCTAssertFalse(defaults.bool(forKey: StoreMaintenance.respPurgeDefaultsKey),
                       "a not-yet-created store must leave the run-once flag unset")
    }
}

/// The one-shot purge must not settle the question from an empty table.
///
/// A fresh install reaches the purge on its second launch with an essentially empty `respSample`. It used
/// to treat "too few rows" as a verdict and burn the run-once flag — permanently disarming itself from
/// zero evidence, so if the channel later banked the degenerate mode register, nothing would ever reclaim
/// it. Only a store that has actually shown `minSamples` rows can answer.
final class RespPurgeEvidenceTests: XCTestCase {

    private var tmp: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        tmp = try Fixtures.tempDir("resp-purge-evidence")
        suiteName = "resp-purge-evidence-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        Fixtures.cleanUp(tmp)
    }

    /// THE REGRESSION: an empty store must stay undecided, and must NOT burn the flag.
    func testAnEmptyStoreDoesNotSettleTheQuestion() async throws {
        let dbPath = tmp.appendingPathComponent("empty.sqlite").path
        _ = try await StrapStore(path: dbPath)

        let outcome = StoreMaintenance.purgeDegenerateRespSamplesIfNeeded(databaseAt: dbPath,
                                                                          defaults: defaults)
        XCTAssertEqual(outcome, .notReady, "no evidence is not a verdict")
        XCTAssertFalse(defaults.bool(forKey: StoreMaintenance.respPurgeDefaultsKey),
                       "the one-shot must remain armed for a store that has not answered yet")
    }

    /// A store carrying a genuine waveform still settles it forever — that verdict IS evidence-based.
    func testAGenuineWaveformStillSettlesIt() async throws {
        let dbPath = tmp.appendingPathComponent("waveform.sqlite").path
        let store = try await StrapStore(path: dbPath)
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        let resp = (0..<200).map {
            RespSample(ts: 1_700_000_000 + $0,
                       raw: Int((2_048 + 300 * sin(0.25 * 2 * Double.pi * Double($0))).rounded()))
        }
        _ = try await store.insert(Streams(resp: resp), deviceId: "my-whoop")

        let outcome = StoreMaintenance.purgeDegenerateRespSamplesIfNeeded(databaseAt: dbPath,
                                                                          defaults: defaults)
        XCTAssertEqual(outcome, .notDegenerate)
        XCTAssertTrue(defaults.bool(forKey: StoreMaintenance.respPurgeDefaultsKey))
    }
}
