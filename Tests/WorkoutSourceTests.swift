import XCTest
import StrapStore
@testable import whoopmaxx

/// Pins the pure workout-editing logic ported into whoopmaxx (W7): source classification (the read model
/// has no deviceId, so origin is recovered from `source`), the durable dismissed-span filter, cross-source
/// dedup, manual-row validation, field preservation on edit, the filter predicate, and merge math. Trimmed
/// from the original's `WorkoutSourceTests` — the Test-Centre trace helpers were stripped in the port, so their
/// tests are dropped.
final class WorkoutSourceTests: XCTestCase {

    private func row(start: Int, end: Int, sport: String, source: String,
                     avgHr: Int? = nil, maxHr: Int? = nil, strain: Double? = nil) -> WorkoutRow {
        Fixtures.workoutRow(startTs: start, endTs: end, sport: sport, source: source,
                            durationS: Double(end - start), avgHr: avgHr, maxHr: maxHr,
                            strain: strain)
    }

    // MARK: - classify

    func testClassifyOrdersComputedBeforeWhoop() {
        // "my-whoop-computed" contains "whoop" — the -computed suffix MUST win, else a detected bout would be
        // classified as an imported WHOOP row and become un-dismissable.
        XCTAssertEqual(WorkoutSource.classify("my-whoop-computed"), .detected)
        XCTAssertEqual(WorkoutSource.classify("whoop"), .whoop)
        XCTAssertEqual(WorkoutSource.classify("manual"), .manual)
        XCTAssertEqual(WorkoutSource.classify("lifting"), .lifting)
        XCTAssertEqual(WorkoutSource.classify("activity-file"), .activityFile)
        XCTAssertEqual(WorkoutSource.classify("apple_health"), .apple)
        XCTAssertEqual(WorkoutSource.classify("apple-health"), .apple)
    }

    func testAppleHealthSourceAcceptsCanonicalAndLegacySpellings() {
        XCTAssertTrue(WorkoutSource.isAppleHealth("apple-health"))
        XCTAssertTrue(WorkoutSource.isAppleHealth("apple_health"))
        XCTAssertTrue(WorkoutSource.isAppleHealth("APPLE_HEALTH"))
        XCTAssertFalse(WorkoutSource.isAppleHealth("whoop"))
    }

    func testDisplaySportRenamesDetectedTokenAndSplitsCamelCase() {
        XCTAssertEqual(WorkoutSource.displaySport("detected"), "Activity")
        XCTAssertEqual(WorkoutSource.displaySport("Running"), "Running")
        XCTAssertEqual(WorkoutSource.displaySport("TraditionalStrengthTraining"),
                       "Traditional Strength Training")
    }

    // MARK: - dismissed spans (durable #107 filter)

    func testParseDismissedSpansDropsMalformed() {
        let spans = WorkoutSource.parseDismissedSpans(["100:200", "bad", "5:5", "9:3", "300:400"])
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 100); XCTAssertEqual(spans[0].end, 200)
        XCTAssertEqual(spans[1].start, 300); XCTAssertEqual(spans[1].end, 400)
    }

    func testIsDismissedOnlyHidesOverlappingDetectedRows() {
        let spans = WorkoutSource.parseDismissedSpans(["1000:2000"])
        let detectedOverlap = row(start: 1500, end: 2500, sport: "detected", source: "my-whoop-computed")
        let detectedClear = row(start: 3000, end: 4000, sport: "detected", source: "my-whoop-computed")
        let manualOverlap = row(start: 1500, end: 2500, sport: "Running", source: "manual")
        XCTAssertTrue(WorkoutSource.isDismissed(detectedOverlap, spans: spans))
        XCTAssertFalse(WorkoutSource.isDismissed(detectedClear, spans: spans))
        XCTAssertFalse(WorkoutSource.isDismissed(manualOverlap, spans: spans))
    }

    func testIsDismissedSurvivesStartTsDrift() {
        let spans = WorkoutSource.parseDismissedSpans(["1000:2000"])
        let drifted = row(start: 1040, end: 2030, sport: "detected", source: "my-whoop-computed")
        XCTAssertTrue(WorkoutSource.isDismissed(drifted, spans: spans))
    }

    func testDismissedTokenRoundTrips() {
        let r = row(start: 1_700_000_000, end: 1_700_003_600, sport: "detected", source: "my-whoop-computed")
        XCTAssertEqual(WorkoutSource.dismissedToken(for: r), "1700000000:1700003600")
        let spans = WorkoutSource.parseDismissedSpans([WorkoutSource.dismissedToken(for: r)])
        XCTAssertTrue(WorkoutSource.isDismissed(r, spans: spans))
    }

    // MARK: - cross-source dedup (#687)

    private func richRow(start: Int, end: Int, sport: String, source: String) -> WorkoutRow {
        Fixtures.workoutRow(startTs: start, endTs: end, sport: sport, source: source,
                            durationS: Double(end - start), energyKcal: 600, avgHr: 150, maxHr: 178,
                            strain: 14.0, distanceM: 10_000, zonesJSON: #"{"z1":10}"#)
    }
    private func thinImport(start: Int, end: Int, sport: String, source: String) -> WorkoutRow {
        Fixtures.workoutRow(startTs: start, endTs: end, sport: sport, source: source,
                            durationS: Double(end - start), energyKcal: 590)
    }

    func testSportKeyFoldsCamelCaseAndSpacing() {
        XCTAssertEqual(WorkoutSource.sportKey("TraditionalStrengthTraining"),
                       WorkoutSource.sportKey("Traditional Strength Training"))
        XCTAssertEqual(WorkoutSource.sportKey("Running"), WorkoutSource.sportKey("running"))
        XCTAssertNotEqual(WorkoutSource.sportKey("Running"), WorkoutSource.sportKey("Cycling"))
    }

    func testSameActivityRequiresSportAndMajorityOverlap() {
        let live = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")
        let importDrift = thinImport(start: 1040, end: 4570, sport: "Running", source: "health-connect")
        XCTAssertTrue(WorkoutSource.sameActivity(live, importDrift))
        let otherSport = thinImport(start: 1040, end: 4570, sport: "Cycling", source: "health-connect")
        XCTAssertFalse(WorkoutSource.sameActivity(live, otherSport))
        let nextRun = richRow(start: 4500, end: 8100, sport: "Running", source: "whoop")
        XCTAssertFalse(WorkoutSource.sameActivity(live, nextRun))
    }

    func testDedupCollapsesLiveAndImportKeepingRicher() {
        let live = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")
        let hc = thinImport(start: 1030, end: 4580, sport: "Running", source: "health-connect")
        let a = WorkoutSource.dedupCrossSource([live, hc])
        let b = WorkoutSource.dedupCrossSource([hc, live])
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(a.first?.source, "whoop")
        XCTAssertEqual(b.first?.source, "whoop")
        XCTAssertEqual(a.first?.strain, 14.0)
    }

    func testDedupKeepsNonImportOnRichnessTie() {
        let manual = thinImport(start: 1000, end: 4600, sport: "Walking", source: "manual")
        let hc = thinImport(start: 1010, end: 4590, sport: "Walking", source: "health-connect")
        let out = WorkoutSource.dedupCrossSource([hc, manual])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.source, "manual")
    }

    func testDedupLeavesDistinctSessionsAndIsStable() {
        let run = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")
        let lift = richRow(start: 5000, end: 8600, sport: "Strength Training", source: "whoop")
        let hcRun = thinImport(start: 1020, end: 4580, sport: "Running", source: "health-connect")
        let out = WorkoutSource.dedupCrossSource([run, lift, hcRun])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].sport, "Running")
        XCTAssertEqual(out[1].sport, "Strength Training")
    }

    // MARK: - detected-vs-real overlap collapse (#975)

    func testDetectedShadowIsDroppedWhenItOverlapsAManualSession() {
        let manual = richRow(start: 1000, end: 4600, sport: "Strength Training", source: "manual")
        let detected = row(start: 900, end: 4800, sport: "detected", source: "my-whoop-computed",
                           avgHr: 175, maxHr: 190, strain: 19.0)
        let out = WorkoutSource.dedupCrossSource([detected, manual])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.source, "manual")
    }

    func testDetectedBoutKeptWhenItDoesNotOverlapAnyReal() {
        let detected = row(start: 1000, end: 4600, sport: "detected", source: "my-whoop-computed",
                           avgHr: 150, maxHr: 170, strain: 12.0)
        let manualLater = richRow(start: 20_000, end: 23_600, sport: "Running", source: "manual")
        let out = WorkoutSource.dedupCrossSource([detected, manualLater])
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.contains { WorkoutSource.classify($0.source) == .detected })
    }

    // MARK: - buildManualRow + preservingCaptured

    func testBuildManualRowHappyPath() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(3600)
        let r = WorkoutSource.buildManualRow(start: start, durationMin: 45, sport: "  Running ",
                                             avgHr: 150, energyKcal: 540, now: now)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.sport, "Running")
        XCTAssertEqual(r?.source, "manual")
        XCTAssertEqual(r?.durationS, 45 * 60)
        XCTAssertEqual(r?.endTs, r!.startTs + 45 * 60)
        XCTAssertEqual(r?.avgHr, 150)
        XCTAssertNil(r?.strain)
    }

    func testBuildManualRowRejectsBadInput() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(3600)
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 0, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 25 * 60, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "   ", avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: now.addingTimeInterval(60), durationMin: 30, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "Run", avgHr: 10, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "Run", avgHr: nil, energyKcal: 99_999, now: now))
    }

    func testPreservingCapturedCarriesUnexposedFieldsOnEdit() {
        let old = row(start: 100, end: 3700, sport: "Workout", source: "manual",
                      avgHr: 130, maxHr: 175, strain: 13.5)
        let rebuilt = row(start: 100, end: 3700, sport: "Running", source: "manual", avgHr: 140)
        let merged = WorkoutSource.preservingCaptured(rebuilt, from: old)
        XCTAssertEqual(merged.sport, "Running")
        XCTAssertEqual(merged.avgHr, 140)
        XCTAssertEqual(merged.maxHr, 175)
        XCTAssertEqual(merged.strain, 13.5)
    }

    func testPreservingCapturedIsNoOpForFreshAdd() {
        let rebuilt = row(start: 100, end: 3700, sport: "Running", source: "manual", avgHr: 140)
        XCTAssertEqual(WorkoutSource.preservingCaptured(rebuilt, from: nil), rebuilt)
    }

    // MARK: - Filter predicate (#64)

    private func fullRow(start: Int, end: Int, sport: String, source: String) -> WorkoutRow {
        Fixtures.workoutRow(startTs: start, endTs: end, sport: sport, source: source,
                            durationS: Double(end - start))
    }

    func testFilterInactiveWhenEmptyPassesEverythingUntouched() {
        let rows = [fullRow(start: 100, end: 3700, sport: "Running", source: "whoop"),
                    fullRow(start: 5000, end: 8600, sport: "Cycling", source: "manual")]
        let f = WorkoutFilter()
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(f.apply(rows), rows)
    }

    func testFilterSportSourceAndSearchCompose() {
        let run = fullRow(start: 100, end: 3700, sport: "Running", source: "whoop")
        let manualRun = fullRow(start: 5000, end: 8600, sport: "Running", source: "manual")
        let cycle = fullRow(start: 9000, end: 12000, sport: "Cycling", source: "manual")
        let detected = fullRow(start: 13000, end: 14000, sport: "detected", source: "my-whoop-computed")
        let rows = [run, manualRun, cycle, detected]
        XCTAssertEqual(WorkoutFilter(sport: "Running").apply(rows), [run, manualRun])
        XCTAssertEqual(WorkoutFilter(sport: "Activity").apply(rows), [detected])
        XCTAssertEqual(WorkoutFilter(sourceClass: .manual).apply(rows), [manualRun, cycle])
        XCTAssertEqual(WorkoutFilter(sport: "Running", sourceClass: .manual).apply(rows), [manualRun])
        XCTAssertEqual(WorkoutFilter(search: "cyc").apply(rows), [cycle])
        XCTAssertEqual(WorkoutFilter(search: "  RUN ").apply(rows), [run, manualRun])
        XCTAssertEqual(WorkoutFilter(sport: "Running", sourceClass: .whoop, search: "run").apply(rows), [run])
    }

    // MARK: - Merge (#64)

    private func mergeRow(start: Int, end: Int, sport: String, source: String,
                          avgHr: Int? = nil, kcal: Double? = nil, dist: Double? = nil,
                          maxHr: Int? = nil, notes: String? = nil) -> WorkoutRow {
        Fixtures.workoutRow(startTs: start, endTs: end, sport: sport, source: source,
                            durationS: Double(end - start), energyKcal: kcal, avgHr: avgHr,
                            maxHr: maxHr, distanceM: dist, notes: notes)
    }

    func testMergeEligibilityGatesOnManualOrDetected() {
        let manual = mergeRow(start: 100, end: 3700, sport: "Running", source: "manual")
        let detected = mergeRow(start: 100, end: 3700, sport: "detected", source: "my-whoop-computed")
        let whoop = mergeRow(start: 100, end: 3700, sport: "Running", source: "whoop")
        XCTAssertTrue(WorkoutMerge.isMergeable(manual))
        XCTAssertTrue(WorkoutMerge.isMergeable(detected))
        XCTAssertFalse(WorkoutMerge.isMergeable(whoop))
        XCTAssertTrue(WorkoutMerge.canMerge([manual, detected]))
        XCTAssertFalse(WorkoutMerge.canMerge([manual]))
        XCTAssertFalse(WorkoutMerge.canMerge([manual, whoop]))
    }

    func testMergeTwoManualSumsAndSpansAndWeightsHr() {
        let a = mergeRow(start: 1000, end: 4600, sport: "Running", source: "manual",
                         avgHr: 150, kcal: 600, dist: 10_000, maxHr: 178)
        let b = mergeRow(start: 5000, end: 7400, sport: "Running", source: "manual",
                         avgHr: 120, kcal: 300, dist: 5_000, maxHr: 150)
        let m = WorkoutMerge.merge([a, b])
        XCTAssertEqual(m?.source, "manual")
        XCTAssertEqual(m?.sport, "Running")
        XCTAssertEqual(m?.startTs, 1000)
        XCTAssertEqual(m?.endTs, 7400)
        XCTAssertEqual(m?.durationS, 6000)
        XCTAssertEqual(m?.energyKcal, 900)
        XCTAssertEqual(m?.distanceM, 15_000)
        XCTAssertEqual(m?.maxHr, 178)
        XCTAssertNil(m?.strain)
        XCTAssertEqual(m?.avgHr, 138)
    }

    func testMergeSportResolutionPrefersRealLabelOverDetected() {
        let detected = mergeRow(start: 1000, end: 4600, sport: "detected", source: "my-whoop-computed")
        let manual = mergeRow(start: 4600, end: 6000, sport: "Strength Training", source: "manual")
        XCTAssertEqual(WorkoutMerge.resolvedSport([detected, manual]), "Strength Training")
        let detected2 = mergeRow(start: 6000, end: 7000, sport: "detected", source: "my-whoop-computed")
        XCTAssertNil(WorkoutMerge.resolvedSport([detected, detected2]))
        XCTAssertEqual(WorkoutMerge.merge([detected, detected2])?.sport, "Activity")
        XCTAssertEqual(WorkoutMerge.merge([detected, detected2], sport: "Yoga")?.sport, "Yoga")
    }

    func testMergeRejectsFewerThanTwo() {
        let a = mergeRow(start: 1000, end: 4600, sport: "Running", source: "manual")
        XCTAssertNil(WorkoutMerge.merge([a]))
        XCTAssertNil(WorkoutMerge.merge([]))
    }
}
