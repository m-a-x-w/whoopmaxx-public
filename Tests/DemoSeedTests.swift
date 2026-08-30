import XCTest
import StrapStore
import StrapAnalytics
@testable import whoopmaxx

/// DEBUG demo seeding must write the SAME shapes the engine expects — notably `DailyMetric.efficiency`
/// as a 0–1 fraction (SleepStager writes `min(1, tst/tib)`), not a 0–100 percent. A 0–100 seed made the
/// demo dashboard's efficiency-derived reads wrong (C2).
final class DemoSeedTests: XCTestCase {

    func testSeededEfficiencyIsA01Fraction() async throws {
        let (store, dir) = try await Fixtures.tempStore("demo-seed-tests")
        defer { Fixtures.cleanUp(dir) }

        try await DemoSeed.seed(into: store)

        let rows = try await store.dailyMetrics(deviceId: "my-whoop", from: "2000-01-01", to: "2100-01-01")
        XCTAssertFalse(rows.isEmpty, "demo seed should write daily rows")
        for r in rows {
            if let e = r.efficiency {
                XCTAssert(e >= 0 && e <= 1,
                          "DailyMetric.efficiency must be a 0–1 fraction, got \(e) on \(r.day)")
            }
        }
    }

    // MARK: - 007 fixtures (journal / naps / battery / capture gap)

    /// The local "yyyy-MM-dd" key `daysAgo` days before today (the seed's own keyer shape).
    private func dayKey(daysAgo: Int) -> String {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date()))!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: d)
    }

    func testSeeds007JournalNapsBatteryAndCaptureGap() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)
        let now = Int(Date().timeIntervalSince1970)

        // ── Journal: ~30 days of tags on the imported lane, alcohol frequent enough to clear the
        // insights n≥5 group gate, and the anomaly day deliberately untagged (a same-day tag would
        // confound-suppress the health-monitor flag the seed demos).
        let journal = try await store.journalEntries(deviceId: DemoSeed.journalLane,
                                                     from: "0000-01-01", to: "9999-12-31")
        XCTAssertFalse(journal.isEmpty, "the seed must write journal history")
        let alcoholDays = Set(journal.filter { $0.question == "alcohol" && $0.answeredYes }
                                     .map { $0.day })
        XCTAssertGreaterThanOrEqual(alcoholDays.count, 5,
                                    "alcohol must clear the insights group gate (n≥5)")
        // The anomaly day AND the day before it must both be clean: the night keyed D is contexted by
        // D-1's behavior tags (`ScoreEngine.nightContextTags`), so a tag on EITHER suppresses the flag.
        // The seed's D-1 drew ["alcohol", "caffeine_late"] from 007 until 009 — the shipped bug.
        let anomalyDay = dayKey(daysAgo: DemoSeed.anomalyDaysAgo)
        let contextDay = dayKey(daysAgo: DemoSeed.anomalyDaysAgo + 1)
        XCTAssertTrue(journal.filter { $0.day == anomalyDay }.isEmpty,
                      "the anomaly day must carry no tags, or the monitor suppresses the flag")
        XCTAssertTrue(journal.filter { $0.day == contextDay }.isEmpty,
                      "the day that CONTEXTS the anomaly night must carry no tags either; got "
                      + "\(journal.filter { $0.day == contextDay }.map { $0.question }.sorted())")

        // ── Naps: the two fixed daytime sessions in the last week, plus — when the run time
        // allows a plausible past daytime nap today (see seed007Fixtures) — one floating nap on
        // the newest demo day so the Rest screen's nap section renders.
        let sessions = try await store.sleepSessions(deviceId: "my-whoop",
                                                     from: now - 8 * 86_400, to: now, limit: 4_000)
        let shorts = sessions.filter { $0.endTs - $0.startTs <= 3_600 }
        XCTAssertTrue((2...3).contains(shorts.count),
                      "two fixed daytime naps (+ the optional newest-day nap) must be seeded")
        if shorts.count == 3 {
            let newest = try XCTUnwrap(shorts.map { $0.endTs }.max())
            XCTAssertGreaterThan(newest, now - 3_600,
                                 "the floating third nap must sit on the newest demo day, "
                                 + "ending within the last hour")
        }
        for nap in shorts {
            let offset = TimeZone.current.secondsFromGMT(
                for: Date(timeIntervalSince1970: TimeInterval(nap.endTs)))
            let key = DayEngine.dayString(nap.endTs, offsetSec: offset)
            let dayAll = try await store.sleepSessions(deviceId: "my-whoop",
                                                       from: nap.endTs - 86_400,
                                                       to: nap.endTs + 86_400, limit: 100)
            XCTAssertTrue(NapCredit.naps(for: key, sleeps: dayAll, offsetSec: offset)
                              .contains { $0.startTs == nap.startTs },
                          "the seeded nap must classify as a nap, not the main night")
        }

        // ── Battery: a week-long sawtooth landing at ~40 % now, with a full charge and a deep
        // trough inside the window (the strap-health trend + low-battery fixtures).
        let battery = try await store.batterySamples(deviceId: "my-whoop",
                                                     from: 0, to: now + 86_400, limit: 10_000)
        XCTAssertGreaterThanOrEqual(battery.count, 300, "a 30-min cadence week is ~336 samples")
        let socs = battery.compactMap { $0.soc }
        XCTAssertEqual(socs.last ?? 0, 40, accuracy: 6, "current charge must read ~40 %")
        XCTAssertGreaterThan(socs.max() ?? 0, 90, "the sawtooth must include a full charge")
        XCTAssertLessThan(socs.min() ?? 100, 15, "the sawtooth must include the pre-charge trough")

        // ── Capture: a ≥3-h worn HR gap two days ago inside the waking window.
        let gapDay = dayKey(daysAgo: 2)
        let offset = TimeZone.current.secondsFromGMT(
            for: Date(timeIntervalSince1970: TimeInterval(now - 2 * 86_400)))
        let dayStart = try XCTUnwrap(GapScan.localDayStart(gapDay, offsetSec: offset))
        let hr = try await store.hrSamples(deviceId: "my-whoop", from: dayStart,
                                           to: dayStart + 86_400, limit: 200_000)
        let cov = GapScan.dayCoverage(dayKey: gapDay, hrTimestamps: hr.map { $0.ts },
                                      offWrist: [], offsetSec: offset)
        XCTAssertTrue(cov.gaps.contains { $0.durationS >= 3 * 3_600 },
                      "the seeded 13:00–16:00 hole must scan as a ≥3-h capture gap")
        XCTAssertLessThan(cov.coverage, 0.9, "the gap must dent the day's coverage")
    }

    /// The seed's promise for the health monitor: the anomaly night's RAW streams, scored by the
    /// real engine against baselines folded from the seeded history (the same fold ScoreEngine's
    /// pass 2 performs), must produce anomalous vitals that the monitor assembly flags RAISED.
    func testSeededAnomalyNightRaisesHealthMonitor() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)

        // The anomaly day's night window, exactly as analyzeRecent reads a past day (#500).
        let cal = Calendar.current
        let dayDate = cal.date(byAdding: .day, value: -DemoSeed.anomalyDaysAgo,
                               to: cal.startOfDay(for: Date()))!
        let dayStart = Int(dayDate.timeIntervalSince1970)
        let offset = TimeZone.current.secondsFromGMT(for: dayDate)
        let day = DayEngine.dayString(dayStart, offsetSec: offset)
        let from = dayStart - 30 * 3_600
        let to = dayStart + 86_400

        let hr = try await store.hrSamples(deviceId: "my-whoop", from: from, to: to, limit: 200_000)
        let rr = try await store.rrIntervals(deviceId: "my-whoop", from: from, to: to, limit: 200_000)
        let grav = try await store.gravitySamples(deviceId: "my-whoop", from: from, to: to, limit: 200_000)
        XCTAssertGreaterThan(hr.count, 20_000, "the seeded 1 Hz anomaly night must be banked")

        // Baselines folded from the seeded imported history — ScoreEngine pass 2's fold shape.
        let hist = try await store.dailyMetrics(deviceId: "my-whoop", from: "0000-01-01",
                                                to: "9999-12-31").sorted { $0.day < $1.day }
        let hrvBase = Baselines.foldHistory(hist.map { $0.avgHrv }, cfg: Baselines.metricCfg["hrv"]!)
        let rhrBase = Baselines.foldHistory(hist.map { $0.restingHr.map(Double.init) },
                                            cfg: Baselines.metricCfg["resting_hr"]!)
        let respBase = Baselines.foldHistory(hist.map { $0.respRateBpm },
                                             cfg: Baselines.metricCfg["resp"]!)
        XCTAssertTrue(hrvBase.trusted && rhrBase.trusted && respBase.trusted,
                      "30 seeded nights must trust all three baselines (≥14 valid)")

        let baselines = DayEngine.ProfileBaselines(hrv: hrvBase, restingHR: rhrBase,
                                                         resp: respBase)
        let result = DayEngine.analyzeDay(
            day: day, hr: hr, rr: rr, gravity: grav,
            profile: UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male"),
            baselines: baselines, tzOffsetSeconds: offset)

        // The still 1 Hz night must be detected, and re-derive the planted anomalous vitals.
        let hrv = try XCTUnwrap(result.daily.avgHrv, "the anomaly night must score an HRV")
        let rhr = try XCTUnwrap(result.daily.restingHr, "the anomaly night must score an RHR")
        XCTAssert((24.0...36.0).contains(hrv), "planted RMSSD ≈ 30 ms; got \(hrv)")
        XCTAssert((63...69).contains(rhr), "planted RHR floor 66 bpm; got \(rhr)")
        let resp = result.daily.respRateBpm
        if let resp {
            XCTAssert((16.2...18.0).contains(resp), "planted respiration ≈ 17.1 br/min; got \(resp)")
        }

        // The monitor assembly over those vitals must flag RAISED — the banner + strain_level ≥ 2 the
        // demo dashboard shows for this day. NOTE the `journalTags: []` here is a BYPASS: it asserts
        // the assembly in a vacuum the real pipeline never provides, which is how a confounded seed
        // stayed invisible for two waves. The real context is pinned by the companion below.
        let monitor = ScoreEngine.healthMonitorResult(hrv: hrv, rhr: Double(rhr), resp: resp,
                                                      skin: nil, baselines: baselines,
                                                      journalTags: [])
        let zDiag = "z(hrv)=\(Baselines.deviation(hrv, state: hrvBase).z) "
            + "vs mean \(hrvBase.baseline) spread \(hrvBase.spread); "
            + "z(rhr)=\(Baselines.deviation(Double(rhr), state: rhrBase).z) "
            + "vs mean \(rhrBase.baseline) spread \(rhrBase.spread); "
            + "z(resp)=\(resp.map { Baselines.deviation($0, state: respBase).z } ?? .nan) "
            + "vs mean \(respBase.baseline) spread \(respBase.spread)"
        XCTAssertEqual(monitor.level, .raised,
                       "the seeded anomaly night must raise the health monitor "
                       + "(score \(monitor.score), fired \(monitor.signalCount); \(zDiag))")
        XCTAssertGreaterThanOrEqual(monitor.score, IllnessSignalEngine.raiseThreshold)
    }

    /// The companion the bug hid behind: the assembly above is driven with `journalTags: []`, but the
    /// real loop passes `ScoreEngine.nightContextTags` — D-1's behavior tags. The seed drew
    /// ["alcohol", "caffeine_late"] on the anomaly's D-1, so the shipped demo rendered "likely what
    /// you logged" (.suppressed, × confounderDampen) where the whole fixture promises "Heads-up".
    /// Routed through the same tag lookup the loop uses, so a future seed draw landing a confounder on
    /// D-1 fails here instead of silently downgrading the showcase banner.
    func testSeededAnomalyNightIsNotConfoundedByItsOwnJournalHistory() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)

        let day = dayKey(daysAgo: DemoSeed.anomalyDaysAgo)
        let journal = try await store.journalEntries(deviceId: DemoSeed.journalLane,
                                                     from: "0000-01-01", to: "9999-12-31")
        var tagsByDay: [String: Set<String>] = [:]
        for e in journal where e.answeredYes { tagsByDay[e.day, default: []].insert(e.question) }
        let context = ScoreEngine.nightContextTags(day: day, tagsByDay: tagsByDay)
        XCTAssertTrue(context.isEmpty,
                      "the anomaly night's confounder context must be empty; got \(context.sorted())")

        // Drive the real assembly with that context over the day's SEEDED vitals (hrv 25 / rhr 68 /
        // resp 17.1), against baselines folded from the same history — ScoreEngine pass 2's shape.
        let hist = try await store.dailyMetrics(deviceId: "my-whoop", from: "0000-01-01",
                                                to: "9999-12-31").sorted { $0.day < $1.day }
        let row = try XCTUnwrap(hist.first { $0.day == day }, "the seed must write the anomaly day")
        let baselines = DayEngine.ProfileBaselines(
            hrv: Baselines.foldHistory(hist.map { $0.avgHrv }, cfg: Baselines.metricCfg["hrv"]!),
            restingHR: Baselines.foldHistory(hist.map { $0.restingHr.map(Double.init) },
                                             cfg: Baselines.metricCfg["resting_hr"]!),
            resp: Baselines.foldHistory(hist.map { $0.respRateBpm },
                                        cfg: Baselines.metricCfg["resp"]!))
        let monitor = ScoreEngine.healthMonitorResult(
            hrv: row.avgHrv, rhr: row.restingHr.map(Double.init), resp: row.respRateBpm,
            skin: nil, baselines: baselines, journalTags: context)
        XCTAssertEqual(monitor.level, .raised,
                       "the demo's showcase anomaly must read Heads-up, not a suppressed \"likely "
                       + "what you logged\" (score \(monitor.score), suppressedBy \(monitor.suppressedBy))")
    }

    // MARK: - 009 weed (days, baked Rest effect, sessions)

    /// The seeded weed history the Weed screen demos: booleans on the imported journal lane (so a
    /// user's own chip taps still win the merge), enough logged days to clear the insights n≥5 gate,
    /// carrying alcohol at ITS OWN BASE RATE (the effect split is an unadjusted two-group test, so
    /// the only way to keep alcohol out of weed's numbers is to give both groups the same share of
    /// it — excluding alcohol inverts the confound rather than removing it, see the ranking test
    /// below), and clear of the anomaly night and the day that contexts it. Sessions are additive
    /// DETAIL under their own lane, never the definition of a weed day.
    func testSeedsWeedDaysAndSessions() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)

        let journal = try await store.journalEntries(deviceId: DemoSeed.journalLane,
                                                     from: "0000-01-01", to: "9999-12-31")
        let weedDays = Set(journal.filter { $0.question == "weed" && $0.answeredYes }.map { $0.day })
        let alcoholDays = Set(journal.filter { $0.question == "alcohol" && $0.answeredYes }
                                     .map { $0.day })
        XCTAssertGreaterThanOrEqual(weedDays.count, 5, "weed must clear the insights group gate (n≥5)")
        let seededDays = Set(try await store.dailyMetrics(deviceId: "my-whoop", from: "0000-01-01",
                                                          to: "9999-12-31").map { $0.day })
        let others = seededDays.subtracting(weedDays)
        let alcoholShareWith = Double(weedDays.intersection(alcoholDays).count) / Double(weedDays.count)
        let alcoholShareWithout = Double(others.intersection(alcoholDays).count) / Double(others.count)
        XCTAssertEqual(alcoholShareWith, alcoholShareWithout, accuracy: 0.15,
                       "weed days must carry alcohol at its base rate — an unadjusted two-group split "
                       + "cancels a confounder only when both groups hold the same share of it "
                       + "(\(alcoholShareWith) with vs \(alcoholShareWithout) without)")
        XCTAssertFalse(weedDays.contains(dayKey(daysAgo: DemoSeed.anomalyDaysAgo)),
                       "the anomaly day must stay clean of weed too")
        XCTAssertFalse(weedDays.contains(dayKey(daysAgo: DemoSeed.anomalyDaysAgo + 1)),
                       "and so must the day that contexts it")
        // The Weed screen reports a "longest logged-free run", so the plan must contain a real
        // multi-day break — a Bernoulli scatter at this rate reliably does not.
        var run = 0, longestFree = 0
        for d in seededDays.sorted() {
            run = weedDays.contains(d) ? 0 : run + 1
            longestFree = max(longestFree, run)
        }
        XCTAssertGreaterThanOrEqual(longestFree, 5,
                                    "the weed plan must keep a real break for the pattern row to "
                                    + "report; longest logged-free run is \(longestFree) days")

        // Sessions: their own lane, under the demo provenance so a re-seed can clear only its own.
        let sessions = try await store.weedSessions(deviceId: StrapStore.weedSourceId,
                                                    from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(Set(sessions.map { $0.day }), weedDays,
                       "every seeded weed day must carry a session, and no session may sit on a day "
                       + "whose boolean is not logged")
        XCTAssertGreaterThan(sessions.count, weedDays.count,
                             "some day must carry two sessions — the Recent strip's heaviest ink is "
                             + "the 2+ cell, and a demo that never renders it never gets reviewed")
        XCTAssertTrue(sessions.allSatisfy { $0.source == "demo" },
                      "seeded sessions must be provenance-tagged, or a re-seed clears a user's own")
        XCTAssertTrue(sessions.contains { $0.method != nil && $0.potency != nil },
                      "some sessions must record method + potency")
        XCTAssertTrue(sessions.contains { $0.method == nil && $0.potency == nil },
                      "and some must leave them NOT RECORDED — the one-tap chip's shape")
        XCTAssertTrue(sessions.contains { !$0.tsExact },
                      "and one must be a declared placeholder clock, so the \"Time not recorded\" "
                      + "row has a specimen to render")
        XCTAssertTrue(sessions.compactMap { $0.potency }.allSatisfy { (1...3).contains($0) },
                      "potency is the 1|2|3 ordinal a user sets, not a dose")
        // The evening draw lands on the ANCHOR day too, whose evening has not happened yet: at a
        // midday launch the demo rendered sessions at 11:19 PM and 11:25 PM. Only the newest day can
        // ever be affected, and the clamp keeps two sessions distinct rather than collapsing them.
        let now = Int(Date().timeIntervalSince1970)
        XCTAssertTrue(sessions.allSatisfy { $0.ts <= now },
                      "no seeded session may be timestamped in the future; latest "
                      + "\(sessions.map { $0.ts }.max() ?? 0) vs now \(now)")
        let today = sessions.filter { $0.day == dayKey(daysAgo: 0) }
        XCTAssertEqual(Set(today.map { $0.ts }).count, today.count,
                       "the anchor day's clamp must shift the drawn times, not stack them")

        // Re-seeding must not duplicate: `weedSession` has no UNIQUE natural key, so idempotence
        // comes from clearing the "demo" lane first plus stable per-day ids. Byte-identity holds for
        // every day EXCEPT the anchor one, whose clock is clamped against "now" and therefore moves
        // with the wall clock between two seeds — asserting it would be asserting something untrue.
        try await DemoSeed.seed(into: store)
        let again = try await store.weedSessions(deviceId: StrapStore.weedSourceId,
                                                 from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(again.map { $0.id }, sessions.map { $0.id },
                       "a second seed must produce the same rows in the same order, never a duplicate")
        XCTAssertEqual(again.filter { $0.day != dayKey(daysAgo: 0) },
                       sessions.filter { $0.day != dayKey(daysAgo: 0) },
                       "every past day must re-seed byte-identical")
        XCTAssertTrue(again.allSatisfy { $0.ts <= Int(Date().timeIntervalSince1970) },
                      "and the re-seeded anchor day must still sit in the past")
    }

    /// Weed's baked effect is Rest-ONLY, and that is what keeps the 007 anomaly fixture safe: the fold
    /// that scores the showcase night reads HRV / resting HR / respiration, so leaving all three alone
    /// makes its z provably unmoved (measured: the whole seeded vitals population is byte-identical to
    /// pre-009). Pinned from both ends — the Rest effect exists, and the anomaly day still carries its
    /// hand-calibrated absolute overrides. A future "let weed dent HRV too" edit re-plants 007 and
    /// fails here rather than in a screenshot.
    func testWeedEffectIsBakedIntoRestOnly() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)

        let journal = try await store.journalEntries(deviceId: DemoSeed.journalLane,
                                                     from: "0000-01-01", to: "9999-12-31")
        let weedDays = Set(journal.filter { $0.question == "weed" && $0.answeredYes }.map { $0.day })
        let rows = try await store.dailyMetrics(deviceId: "my-whoop", from: "0000-01-01",
                                                to: "9999-12-31").sorted { $0.day < $1.day }
        let rest = try await store.metricSeries(deviceId: "my-whoop", key: "sleep_performance",
                                                from: "0000-01-01", to: "9999-12-31")
        let restByDay = Dictionary(uniqueKeysWithValues: rest.map { ($0.day, $0.value) })

        // Split the NEXT-morning Rest scores by whether D-1 was a weed day — the same lag-1 convention
        // the insights ranker applies, so this is the row the Weed screen will actually show.
        var with: [Double] = [], without: [Double] = []
        for (i, r) in rows.enumerated() where i > 0 {
            guard let v = restByDay[r.day] else { continue }
            if weedDays.contains(rows[i - 1].day) { with.append(v) } else { without.append(v) }
        }
        func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
        XCTAssertGreaterThanOrEqual(with.count, 5, "the Rest split must clear the insights n≥5 gate")
        XCTAssertLessThan(mean(with), mean(without),
                          "Rest after a logged weed day must read lower — the baked -7 is the whole "
                          + "reason weed ranks as a real insights row (\(mean(with)) vs \(mean(without)))")

        let anomaly = try XCTUnwrap(rows.first { $0.day == dayKey(daysAgo: DemoSeed.anomalyDaysAgo) })
        XCTAssertEqual(anomaly.avgHrv ?? 0, 25, accuracy: 0.001, "the anomaly HRV override must stand")
        XCTAssertEqual(anomaly.restingHr ?? 0, 68, "the anomaly RHR override must stand")
        XCTAssertEqual(anomaly.respRateBpm ?? 0, 17.1, accuracy: 0.001,
                       "the anomaly respiration override must stand")
    }

    /// The sentence the Weed screen actually renders, through the real ranking model. Baking an
    /// effect is not enough: the row the demo shows is whichever (weed × outcome) pair wins the
    /// family, so a seeded confound can outrank the finding on the one screen where overclaiming
    /// costs most. It did — the first cut placed weed on the alcohol-free COMPLEMENT, which does not
    /// remove the confound but INVERTS it (weed days become exactly the days alcohol had not
    /// depressed), and the demo advertised "On days you logged 'Weed', Charge was 34% higher (avg 46
    /// vs 35, n=10 vs 20)" with |d| 1.49 pinned at the magnitude bar's cap. Fixed by giving weed days
    /// alcohol's own base rate — `BehaviorInsights.effect` is an unadjusted two-group Welch split, so
    /// a confounder cancels only when both groups carry the same share of it.
    func testSeededWeedInsightRanksAsItsBakedRestEffect() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)

        // The three inputs JournalScreen hands the model, read straight from the seeded store.
        let journal = try await store.journalEntries(deviceId: DemoSeed.journalLane,
                                                     from: "0000-01-01", to: "9999-12-31")
        var tagDays: [String: Set<String>] = [:]
        for e in journal where e.answeredYes { tagDays[e.question, default: []].insert(e.day) }
        let days = try await store.dailyMetrics(deviceId: "my-whoop", from: "0000-01-01",
                                                to: "9999-12-31").sorted { $0.day < $1.day }
        let rest = try await store.metricSeries(deviceId: "my-whoop", key: "sleep_performance",
                                                from: "0000-01-01", to: "9999-12-31")
        let restSeries = Dictionary(uniqueKeysWithValues: rest.map { ($0.day, $0.value) })

        let rows = JournalInsightsModel.compute(tagDays: tagDays, days: days, restSeries: restSeries)
        let weed = try XCTUnwrap(rows.first { $0.key == "weed" }, "weed must carry an insights row")
        let ranked = try XCTUnwrap(weed.effect,
                                   "the seeded weed days must clear the n≥5 group gate at some lag")
        XCTAssertEqual(ranked.outcome, "Rest",
                       "the demo's weed headline must be the BAKED Rest penalty, not a confound; got "
                       + "\"\(ranked.sentence())\"")
        XCTAssertEqual(ranked.lag, 1, "baked on the D-1 evening convention — the NEXT morning")
        XCTAssertLessThan(ranked.effect.delta, 0, "and lower, never higher")
        XCTAssertTrue(weed.significant,
                      "and family-corrected significant, or the demo shows the below-gate copy "
                      + "(q \(weed.qValue ?? .nan))")

        // Nothing else weed-linked may even come close: HRV / resting HR / Charge are untouched by
        // the seed's weed block, so any effect they show is confounding, and it must stay far below
        // the finding AND below raw significance (a stricter bar than the family-corrected q).
        for outcome in JournalInsightsModel.outcomes(days: days, restSeries: restSeries)
        where outcome.label != "Rest" {
            guard let other = EffectRanker.bestLag(behaviorDays: tagDays["weed"] ?? [],
                                                   outcomeByDay: outcome.byDay,
                                                   behavior: "Weed", outcome: outcome.label)
            else { continue }
            XCTAssertLessThan(abs(other.effect.cohensD), abs(ranked.effect.cohensD),
                              "a spurious \(outcome.label) effect must not rival the baked Rest one; "
                              + "got \"\(other.sentence())\"")
            XCTAssertFalse(other.effect.significant,
                           "and must not read as a finding at all; got \"\(other.sentence())\"")
        }
    }

    // MARK: - 016 P2: the night the stager kept but flagged

    /// The three lanes `RestScreen` renders Rest from, read back out of a freshly seeded store — the
    /// same read-set `Repository` publishes as `days` / `sleeps` / `restSeries`. `napSeries` is left to
    /// the caller because the seed writes none: `nap_min` is ScoreEngine's series, persisted at runtime,
    /// and an empty map is exactly what the store holds after a seed.
    private func seededRestInputs(_ store: StrapStore) async throws
        -> (days: [DailyMetric], sleeps: [CachedSleepSession], restSeries: [String: Double]) {
        let days = try await store.dailyMetrics(deviceId: "my-whoop", from: "0000-01-01",
                                                to: "9999-12-31")
        let sleeps = try await store.sleepSessions(deviceId: "my-whoop", from: 0,
                                                   to: Int(Date().timeIntervalSince1970) + 86_400,
                                                   limit: 4_000)
        let rest = try await store.metricSeries(deviceId: "my-whoop", key: "sleep_performance",
                                                from: "0000-01-01", to: "9999-12-31")
        return (days, sleeps, Dictionary(uniqueKeysWithValues: rest.map { ($0.day, $0.value) }))
    }

    /// The seed's 016 promise: EXACTLY ONE night carries the stager's `lowConfidence` flag, it sits on
    /// the day `lowConfidenceDaysAgo` names, and what makes it flag-worthy is its recorded CLOCK SPAN
    /// clearing `SleepDetection.maxMainSleepSpanS` — the only quantity the stager's cap gates on
    /// (`SleepStaging.swift:1043`). Every other seeded night stays confident.
    ///
    /// Turns red: drop `lowConfidence: flagged` from the `CachedSleepSession` the day loop appends (0
    /// flagged), or widen `flagged` to a second index (2).
    func testSeedsExactlyOneFlaggedNightAtTheExpectedDay() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)

        let sessions = try await store.sleepSessions(deviceId: "my-whoop", from: 0,
                                                     to: Int(Date().timeIntervalSince1970) + 86_400,
                                                     limit: 4_000)
        let flagged = sessions.filter { $0.lowConfidence }
        XCTAssertEqual(flagged.count, 1,
                       "the seed must plant exactly one low-confidence night — a state five plans "
                       + "running have called un-screenshottable; got \(flagged.count)")
        let night = try XCTUnwrap(flagged.first)

        XCTAssertEqual(night.endTs - night.startTs, DemoSeed.lowConfidenceSpanS)
        XCTAssertGreaterThan(night.endTs - night.startTs, SleepDetection.maxMainSleepSpanS,
                             "a seeded \"flagged\" night whose span is UNDER the cap would caption a "
                             + "limit it never passed")
        // The span and the limit must READ differently once minute-floored, or the caveat argues with
        // itself on screen ("16 h recorded against a 16 h limit").
        XCTAssertNotEqual(WMFormat.duration(seconds: DemoSeed.lowConfidenceSpanS, style: .spelled),
                          WMFormat.duration(seconds: SleepDetection.maxMainSleepSpanS, style: .spelled))

        // It keys to its END day — the day `RestNight.sessions(for:in:)` will look for it on.
        let offset = TimeZone.current.secondsFromGMT(
            for: Date(timeIntervalSince1970: TimeInterval(night.endTs)))
        XCTAssertEqual(DayEngine.dayString(night.endTs, offsetSec: offset),
                       dayKey(daysAgo: DemoSeed.lowConfidenceDaysAgo),
                       "the flagged night must land on the day its constant names, or the tests and "
                       + "the screenshot instructions describe different nights")
        XCTAssertNotEqual(DemoSeed.lowConfidenceDaysAgo, DemoSeed.anomalyDaysAgo,
                          "the two showcase fixtures must not stand on the same night")
    }

    /// THE TRAP, at the seed: the flag is set by the session SPAN, and this day's `totalSleepMin` is the
    /// ordinary value it always drew (016 decision 1 — this wave changes no number). That gap is the
    /// whole fixture: the hero keeps a ~7 h Asleep numeral while the caveat quotes 17 h 12 min, which is
    /// the only pair of numbers that can show why the cap fired.
    ///
    /// Turns red: seed the flagged night by inflating `totalSleep` (or `inBedSec`) for that index
    /// instead of overriding the session's span.
    func testTheFlaggedNightsAsleepTotalIsUntouchedAndFarUnderTheCap() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)

        let key = dayKey(daysAgo: DemoSeed.lowConfidenceDaysAgo)
        let rows = try await store.dailyMetrics(deviceId: "my-whoop", from: "0000-01-01",
                                                to: "9999-12-31")
        let row = try XCTUnwrap(rows.first { $0.day == key }, "the seed must write the flagged day")
        let asleep = try XCTUnwrap(row.totalSleepMin)
        XCTAssert((320.0...520.0).contains(asleep),
                  "the flagged night's asleep total must stay in the ordinary seeded band every other "
                  + "night draws from; got \(asleep)")
        XCTAssertLessThan(asleep * 60, Double(SleepDetection.maxMainSleepSpanS),
                          "the asleep total must be well under the cap — it is not what tripped it")
    }

    /// The flag has to survive the whole way to the surface that reads it, as the MAIN NIGHT and not as
    /// a nap: `upsertSleepSessions` → `sleepSessions` → `NapCredit.mainNightSessions` → `RestNight`. A
    /// seeded night that does not reach `RestNight.lowConfidence` makes the screenshot prove the
    /// opposite of what it claims.
    ///
    /// Turns red: drop the flag; seed the over-long stretch as a SECOND session on the day (it would
    /// classify as a nap and the night would render confident); or key it to a day with no daily row.
    func testTheFlaggedNightReachesRestNightAsACaveat() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)
        let input = try await seededRestInputs(store)

        let key = dayKey(daysAgo: DemoSeed.lowConfidenceDaysAgo)
        let day = try XCTUnwrap(input.days.first { $0.day == key })
        let night = RestNight(day: day, score: input.restSeries[key],
                              sessions: RestNight.sessions(for: day, in: input.sleeps))

        XCTAssertTrue(night.lowConfidence,
                      "the seeded flag must reach the Rest hero, or the caveat is unreachable in the "
                      + "simulator exactly as before this wave")
        XCTAssertEqual(night.lowConfidenceSpanS, DemoSeed.lowConfidenceSpanS)
        let caption = try XCTUnwrap(night.lowConfidenceCaption)
        XCTAssertTrue(caption.contains(WMFormat.duration(seconds: DemoSeed.lowConfidenceSpanS,
                                                         style: .spelled)), caption)
        XCTAssertFalse(caption.contains(RestFormat.hmm(night.asleepMin ?? 0)),
                       "the caveat must not quote the asleep total: \(caption)")
        // Still ONE night, not a night plus a nap: the over-long stretch replaced the session's end, it
        // did not add a row.
        XCTAssertTrue(NapCredit.naps(for: key, sleeps: input.sleeps).isEmpty,
                      "the flagged night must not have spawned a nap row — nap credit moves the debt "
                      + "ledger, and this wave changes no number")
    }

    /// THE OTHER DIRECTION, and the one that pins WHERE the fixture sits. The screen the simulator opens
    /// on is the newest night, and it must render byte-identically to before this wave: no hero caveat
    /// (it is not that night) AND no flagged-nights clause on the debt line — which means the fixture
    /// has to fall outside the newest night's `SleepDebt.ledger` window, not merely off the hero.
    ///
    /// The window count is resolved exactly as `RestScreen`'s `.task` resolves it: over
    /// `ledger.nights`, the nights the balance beside it was actually summed over.
    ///
    /// Turns red: set `lowConfidenceDaysAgo` to anything inside the ledger window (e.g. 1, or
    /// `SleepDebt.defaultWindowNights - 1`).
    func testTheNewestNightAndItsLedgerWindowCarryNoCaveat() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)
        let input = try await seededRestInputs(store)

        let a = RestModel.assemble(days: input.days, restSeries: input.restSeries,
                                   sleeps: input.sleeps, napSeries: [:], habitualMidsleepSec: nil, daysWindowFloor: "2000-01-01")
        let last = try XCTUnwrap(a.lastDay)
        XCTAssertEqual(last.day, dayKey(daysAgo: 0), "the seed's newest night is today's")

        let night = RestNight(day: last, score: input.restSeries[last.day],
                              sessions: RestNight.sessions(for: last, in: input.sleeps))
        XCTAssertFalse(night.lowConfidence, "the default screenshot must be the ordinary state")
        XCTAssertEqual(RestNight.lowConfidenceNightCount(dayKeys: a.ledger.nights.map(\.day),
                                                         sleeps: input.sleeps), 0,
                       "…and its debt line must print the sentence it printed before 016")
    }

    /// Decision 3, in the simulator: stepping back to the flagged night puts BOTH surfaces in one
    /// screenshot — the hero's caveat, and a ledger window that names the night it was summed over. The
    /// gesture path is pinned too, because the seed's own doc comment promises it: the History strip's
    /// oldest bar, then two taps of the back chevron.
    ///
    /// Turns red: move `lowConfidenceDaysAgo` (the two-tap path lands elsewhere), or drop the flag (the
    /// window count falls to 0).
    func testSteppingBackToTheFlaggedNightReachesBothSurfaces() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)
        let input = try await seededRestInputs(store)
        let key = dayKey(daysAgo: DemoSeed.lowConfidenceDaysAgo)

        // The gesture path, off the screen the sim opens on.
        let newest = RestModel.assemble(days: input.days, restSeries: input.restSeries,
                                        sleeps: input.sleeps, napSeries: [:],
                                        habitualMidsleepSec: nil, daysWindowFloor: "2000-01-01")
        let nights = newest.slept.map(\.day)
        let oldestBar = try XCTUnwrap(newest.history.first?.dayKey, "the strip must have bars")
        let oneBack = RestBrowse.previousKey(from: oldestBar, in: nights)
        XCTAssertEqual(RestBrowse.previousKey(from: oneBack, in: nights), key,
                       "History's oldest bar plus two back-taps must land on the flagged night")

        // And the night it lands on carries both halves of the caveat.
        let a = RestModel.assemble(days: input.days, restSeries: input.restSeries,
                                   sleeps: input.sleeps, napSeries: [:], habitualMidsleepSec: nil,
                                   selectedKey: key, daysWindowFloor: "2000-01-01")
        let day = try XCTUnwrap(a.lastDay)
        XCTAssertEqual(day.day, key, "the browse must resolve to the seeded night")
        XCTAssertNotNil(RestNight(day: day, score: input.restSeries[key],
                                  sessions: RestNight.sessions(for: day, in: input.sleeps))
                            .lowConfidenceCaption)
        XCTAssertEqual(RestNight.lowConfidenceNightCount(dayKeys: a.ledger.nights.map(\.day),
                                                         sleeps: input.sleeps), 1,
                       "the ledger ending ON the flagged night counts it, so the hero caveat and the "
                       + "debt line land together (016 decision 3)")
    }
}
