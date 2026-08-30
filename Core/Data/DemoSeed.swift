import Foundation
import StrapProtocol
import StrapStore
import StrapAnalytics

/// DEBUG-only demo seed so the simulator (which has no BLE) can exercise the whole
/// store → repository → UI loop: launched with `--seed-demo` and an EMPTY store, it writes ~30 days of
/// deterministic, physiologically-plausible daily metrics + Rest series + sleep sessions under the
/// canonical "my-whoop" id (the imported lane — the same lane a WHOOP-export import fills, so the
/// imported-over-computed merge path is exercised too). Everything is SYNTHETIC and DETERMINISTIC
/// (fixed-seed SplitMix64, no Date.now randomness in the values); it runs at most once and never
/// clobbers real data. The seeding body is compiled out of Release builds entirely.
enum DemoSeed {

    /// Seed only if requested AND the store has no daily rows (either lane). Safe to call every launch.
    static func runIfRequested(store: StrapStore?) async {
        #if DEBUG
        guard requested, let store else { return }
        let wide = ("0000-01-01", "9999-12-31")
        let imported = (try? await store.dailyMetrics(deviceId: whoop, from: wide.0, to: wide.1)) ?? []
        let computed = (try? await store.dailyMetrics(deviceId: whoop + "-computed", from: wide.0, to: wide.1)) ?? []
        guard imported.isEmpty && computed.isEmpty else { return }
        do {
            try await seed(into: store)
            // Opt-in HR-only auto-detect ships OFF; the seed plants one free-standing elevated HR
            // bout (no motion) for it to surface, so flip it on here — only on a fresh --seed-demo
            // store, never in the DemoSeedTests path that calls `seed(into:)` directly.
            UserDefaults.standard.set(true, forKey: PuffinExperiment.autoDetectWorkoutsKey)
        }
        catch { NSLog("DemoSeed: seed failed — \(error)") }
        #endif
    }

    #if DEBUG
    /// True when the process was launched asking for the demo seed (Xcode scheme arg or
    /// `simctl launch … --seed-demo`, or the edge variant below).
    static var requested: Bool {
        CommandLine.arguments.contains("--seed-demo") || edgeToday
    }

    /// `--seed-demo-edge`: same seed, but TODAY gets only a strain (no recovery / rest / vitals /
    /// sleep) — the real morning-before-sync shape that regressed the Today screen to blank
    /// (the anchor-day carry's repro fixture).
    static var edgeToday: Bool { CommandLine.arguments.contains("--seed-demo-edge") }

    private static let whoop = "my-whoop"
    private static let DAYS = 30

    /// 007 F2: the anomaly night ends this many days before today. Internal (not private) so the
    /// DemoSeed tests can find the same day the seed planted.
    static let anomalyDaysAgo = 3

    /// 016 P2: the one night the stager KEPT BUT FLAGGED (`CachedSleepSession.lowConfidence`) ends this
    /// many days before today. Internal (not private) so the DemoSeed tests can find the same night the
    /// seed planted. Distinct from `anomalyDaysAgo` (3) and the day that contexts it (4), so neither
    /// fixture stands on the other.
    ///
    /// ONE NIGHT PAST THE DEBT LEDGER'S TRAILING WINDOW, deliberately. The screen the simulator opens on
    /// is the newest night, and it must be byte-identical to before this wave: no hero caveat (it is not
    /// that night) AND no flagged-nights clause on the debt line (`SleepDebt.ledger` counts back
    /// `defaultWindowNights` NIGHTS WITH DATA, and this one falls outside that count). The `+ 1` is what
    /// covers the `--seed-demo-edge` fixture too: its today banks no night at all, which slides the same
    /// 14-night window exactly one night older.
    ///
    /// It is still reachable in two gestures (014 gave Rest a stepper): the History strip's oldest bar is
    /// 13 nights back, then two taps of the back chevron.
    static let lowConfidenceDaysAgo = SleepDebt.defaultWindowNights + 1

    /// That night's recorded CLOCK SPAN in seconds — the ONLY quantity the stager's cap gates on
    /// (`(p.end - p.start) > maxMainSleepSpanS`, `SleepStaging.swift:1043`), never the staged asleep
    /// total. Expressed against the stager's own constant so a cap change carries the fixture with it
    /// instead of quietly leaving a seeded "flagged" night under the limit it claims to have passed.
    ///
    /// 72 min over the 16 h cap = 17 h 12 min, the span 016's worked example quotes.
    static let lowConfidenceSpanS = SleepDetection.maxMainSleepSpanS + 72 * 60

    /// The lane the seeded journal history writes under — the IMPORTED lane
    /// (`JournalStore.importedSourceId`), the same lane a restored imported backup fills, so a user's
    /// own chip taps (the native "wm-journal" lane) still win the merged read.
    static let journalLane = "imported-journal"

    // Internal (not private) so DemoSeedTests can seed a temp store directly and assert the seeded
    // shape (e.g. efficiency stored as a 0–1 fraction). DEBUG-only, so it never ships in Release.
    static func seed(into store: StrapStore) async throws {
        var rng = SplitMix64(seed: 0x57A9_DC0D_E5EE_D001)
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd"
        let startDay = cal.date(byAdding: .day, value: -(DAYS - 1), to: cal.startOfDay(for: Date()))!

        try? await store.upsertDevice(id: whoop, mac: nil, name: "WHOOP (demo)")

        // ── 007 F1: the journal tag plan, decided up front on its OWN rng stream (so the
        // pre-existing daily value stream stays byte-identical in shape). Alcohol ~2×/wk with a
        // NEXT-morning HRV/RHR dip baked into the values below, caffeine/stress scattered, sauna
        // twice (deliberately below the n≥5 insights gate — the honest "keep logging" row). The
        // anomaly day and THE DAY BEFORE IT carry no behavior tags: the night keyed D is contexted by
        // D-1's tags, so either one being tagged suppresses the health-monitor flag the seed demos.
        var jrng = SplitMix64(seed: 0x57A9_DC0D_E5EE_D002)
        let anomalyIndex = DAYS - 1 - anomalyDaysAgo
        var tagPlan: [Int: Set<JournalTag>] = [:]
        for i in 0..<DAYS where i != anomalyIndex {
            var tags: Set<JournalTag> = []
            if jrng.nextDouble() < 0.30 { tags.insert(.alcohol) }
            if jrng.nextDouble() < 0.30 { tags.insert(.caffeineLate) }
            if jrng.nextDouble() < 0.20 { tags.insert(.stress) }
            if jrng.nextDouble() < 0.12 { tags.insert(.lateMeal) }
            // ── 009: the night keyed D reads D-1's behavior tags (`nightContextTags`), so the day that
            // CONTEXTS the anomaly must be clean too — the `where` above only ever spared the anomaly
            // day itself. Index 25 drew ["alcohol", "caffeine_late"], which made the real pipeline score
            // the showcase night .suppressed (× confounderDampen) instead of .raised; latent since 007.
            // The tags are discarded AFTER the four draws, never instead of them, so the stream stays
            // byte-identical and every downstream seeded value — including the hand-calibrated anomaly
            // fixture — is unmoved. (Index 26 consumes zero draws: the `where` filters the SEQUENCE.)
            guard i != anomalyIndex - 1 else { continue }
            if !tags.isEmpty { tagPlan[i] = tags }
        }
        for i in [6, 15] where i != anomalyIndex && i != anomalyIndex - 1 {
            tagPlan[i, default: []].insert(.sauna)
        }

        // ── 009: the weed days, HAND-AUTHORED rather than a Bernoulli draw — the Weed screen's
        // "longest logged-free run" needs real runs and breaks, which noise at a fixed rate does not
        // reliably produce. A dense block (7…11), a lone day, a second block (19…22), a 6-day break,
        // then today — a 7-day opening run is the longest, so "longest break" reports 7. 25 and 26 are
        // the anomaly night and the day that contexts it, and stay clean.
        //
        // ALCOHOL OVERLAP IS DELIBERATE, at alcohol's own base rate: 4 of these 11 days are seeded
        // alcohol days [0, 2, 3, 4, 9, 17, 19, 21, 22, 27, 28] — 36% of the weed days against 37% of
        // the rest. `BehaviorInsights.effect` is an unadjusted two-group Welch split, so the ONLY way
        // to keep alcohol out of weed's numbers is to give both groups the same share of it. The
        // first cut of this seed placed weed on the alcohol-free COMPLEMENT instead, which does not
        // remove the confound — it inverts it: weed days became exactly the days alcohol had NOT
        // depressed, and the demo shipped "Charge was 34% higher" (|d| 1.49, the magnitude bar pinned
        // at its cap) as its headline weed finding, outranking the deliberately baked Rest penalty on
        // the one screen where overclaiming costs most. Balanced, every non-Rest weed pair falls to
        // |d| ≤ 0.35 / q ≈ 0.71 and the baked Rest effect ranks alone (measured: |d| 1.33, q 0.0009).
        let weedDays: Set<Int> = [7, 8, 9, 10, 11, 16, 19, 20, 21, 22, 29]   // 11 days, the gate is 5
        for i in weedDays where i != anomalyIndex && i != anomalyIndex - 1 {
            tagPlan[i, default: []].insert(.weed)
        }
        let weedRows = weedSessionPlan(days: weedDays, anomalyIndex: anomalyIndex,
                                       startDay: startDay, cal: cal, fmt: fmt)

        // ── 016 P2: which seeded night the stager kept but flagged (see `lowConfidenceDaysAgo`).
        let lowConfidenceIndex = DAYS - 1 - lowConfidenceDaysAgo

        var daily: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        var series: [MetricPoint] = []
        var journalRows: [JournalEntry] = []

        for i in 0..<DAYS {
            let date = cal.date(byAdding: .day, value: i, to: startDay)!
            let day = fmt.string(from: date)
            let weekday = cal.component(.weekday, from: date)
            let weekend = (weekday == 1 || weekday == 7)
            let trained = rng.nextDouble() < (weekend ? 0.4 : 0.6)

            // Ranges per the W1 spec: recovery 30–95, strain 10–70, totalSleepMin 320–520,
            // efficiency 80–97 (a PERCENTAGE here, feeding the recovery/rest/in-bed formulas below;
            // DailyMetric.efficiency is stored as a 0–1 FRACTION to match the engine — SleepStager writes
            // `min(1, tst/tib)` — while CachedSleepSession.efficiency stays a 0–100 percent), restingHr
            // 44–60, avgHrv 40–110, resp 13–16, skinTempDev −0.4…0.6, sleep_performance 55–95. Internally
            // correlated so the dashboard reads like a real account.
            var totalSleep = gauss(&rng, 430, 45).clamped(320, 520)
            var efficiency = gauss(&rng, 90, 4).clamped(80, 97)
            if i == anomalyIndex { totalSleep = 395; efficiency = 84 }   // restless anomaly night
            let deep = (totalSleep * gauss(&rng, 0.20, 0.03)).clamped(40, 120)
            let rem = (totalSleep * gauss(&rng, 0.23, 0.03)).clamped(50, 140)
            let light = max(60, totalSleep - deep - rem)
            let disturbances = Int(gauss(&rng, 6, 3).clamped(0, 15))
            var hrv = (gauss(&rng, 74, 9) + (weekend ? 5 : 0) - (trained ? 6 : 0)).clamped(40, 110)
            var rhrD = gauss(&rng, 52, 3) + (trained ? 1.5 : 0)
            var resp = gauss(&rng, 14.4, 0.7).clamped(13, 16)
            var skinDev = gauss(&rng, 0.05, 0.2).clamped(-0.4, 0.6)
            // ── 007 F1: baked NEXT-morning journal effects, so the insights ranker has a real
            // signal to find (alcohol big + consistent → significant; stress mild → usually not).
            var restAdj = 0.0
            let prevTags = tagPlan[i - 1] ?? []
            if prevTags.contains(.alcohol) { hrv = max(32, hrv - 16); rhrD += 4; restAdj -= 9 }
            if prevTags.contains(.caffeineLate) { restAdj -= 3 }
            if prevTags.contains(.stress) { hrv = max(32, hrv - 5) }
            // ── 009: weed's baked effect is Rest-ONLY. Rest (`sleep_performance`) is one of the four
            // insights outcomes, so the ranked row is a real finding; and because hrv / rhrD / resp are
            // left alone, the anomaly's z is PROVABLY unmoved — the fold that scores it reads only
            // those three. Deliberately NOT baked into deep/rem: those are `let`s here, and moving them
            // would shift the population the 007 fixture is calibrated against for no analytical gain.
            if prevTags.contains(.weed) { restAdj -= 7 }
            // ── 007 F2: the anomaly night. The SAME values the raw night streams (seed007Fixtures
            // below) re-derive, so the engine's own health monitor computes a RAISED flag for this
            // day rather than the seed hand-inserting one (which the next analyzeRecent pass would
            // overwrite with its own honest evaluation).
            //
            // RE-PLANTED against the bias-corrected spread. These are absolute values, so they only
            // mean anything relative to the dispersion the fold reports — and the fold used to
            // UNDER-report it, because the spread EWMA carried an un-removed floor-valued seed for
            // ~91 nights. At this seed's n = 30 that phantom was still 38% of the stored spread, so
            // HEAD scored the day against σ_hrv 11.55 / σ_rhr 3.65 / σ_resp 0.80 when the seeded
            // population's TRUE SD is 15.19 / 4.37 / 0.87. The old values (hrv 30, resp 17.1) only
            // cleared the raise threshold on that inflated z-scale; against honest dispersion they
            // read −2.0σ / +2.7σ / +3.1σ, well short of the "+3.5σ / −3.5σ / +4σ" this fixture has
            // always claimed. Deepened so the day is anomalous against the CORRECTED spread, which
            // is what the demo dashboard's raised banner is there to show.
            //
            // The extra depth is taken from RHR, NOT respiration, and every value here is capped by
            // the fold's HARD-OUTLIER GATE rather than by taste. Two candidates were measured and
            // rejected for the same reason — they made the night so extreme it was thrown out of its
            // OWN baseline (nValid 30 → 29), which tightened that metric's spread and FLATTERED the
            // z it was supposed to earn:
            //   • resp 17.8 (vs 17.1)  — rejected; also pointless, since the recovered rate is
            //     frequency-bin quantized (0.285 and 0.296 Hz both land on 120/7 ≈ 17.14 br/min), so
            //     the STREAM value barely moves however hard the row is pushed.
            //   • rhrD 69 (vs 68)      — rejected; σ_rhr collapsed 4.48 → 3.84 and z jumped 3.10 →
            //     3.98 purely from the exclusion.
            // A fixture that reads as anomalous only because it was excluded from the record proves
            // nothing. These values all fold (nValid 30 on all three) and still raise: measured
            // z −2.47 / +3.10 / +3.01 → composite 56.8 against the 50-point raise threshold.
            if i == anomalyIndex { hrv = 25; rhrD = 68; resp = 17.1; skinDev = 0.5 }
            // Ceiling raised 66 → 69 so the anomaly's febrile RHR is not clipped below what the raw
            // stream re-derives. It only ever binds on that night — ordinary nights are gauss(52, 3).
            let rhr = Int(rhrD.clamped(44, 69))
            let recovery = (38 + (hrv - 70) * 0.6 + (efficiency - 85) * 0.7
                            - (Double(rhr) - 52) * 1.5 + gauss(&rng, 0, 5)).clamped(30, 95)
            let strain = (trained ? gauss(&rng, 48, 12) : gauss(&rng, 20, 6)).clamped(10, 70)
            let rest = (totalSleep / 480 * 78 + (efficiency - 85) * 0.8
                        + gauss(&rng, 0, 4) + restAdj).clamped(50, 95)

            for tag in (tagPlan[i] ?? []).sorted(by: { $0.rawValue < $1.rawValue }) {
                journalRows.append(JournalEntry(day: day, question: tag.rawValue,
                                                answeredYes: true, notes: nil))
            }

            // Edge fixture: today is still forming — strain only, nothing from last night yet.
            let edge = edgeToday && i == DAYS - 1
            daily.append(edge
                ? DailyMetric(day: day, totalSleepMin: nil, efficiency: nil,
                              deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                              restingHr: nil, avgHrv: nil, recovery: nil,
                              strain: round1(strain), exerciseCount: nil)
                : DailyMetric(
                    day: day, totalSleepMin: round1(totalSleep), efficiency: round2(efficiency / 100),
                    deepMin: round1(deep), remMin: round1(rem), lightMin: round1(light),
                    disturbances: disturbances, restingHr: rhr, avgHrv: round1(hrv),
                    recovery: round1(recovery), strain: round1(strain), exerciseCount: trained ? 1 : 0,
                    spo2Pct: round1(gauss(&rng, 96.5, 0.7).clamped(94, 99)),
                    skinTempDevC: round2(skinDev), respRateBpm: round1(resp),
                    // Daily activity totals (v11 columns) so the Steps / Calories catalog tiles demo:
                    // trained days walk and burn more, correlated like a real account. Both are the
                    // APPROXIMATE on-device estimates in real use and stay in plausible ranges here.
                    steps: Int(gauss(&rng, trained ? 12_500 : 8_200, 1_800).clamped(3_000, 20_000)),
                    activeKcalEst: round1(gauss(&rng, trained ? 2_680 : 2_260, 170).clamped(1_800, 3_400))))
            if edge { continue }

            // Rest score under the imported lane (the same `sleep_performance` key ScoreEngine writes
            // computed nights under, so Repository.restSeries reads both lanes).
            series.append(MetricPoint(day: day, key: "sleep_performance", value: round1(rest)))

            // The previous night ~23:15 → wake, with a REAL stage timeline in the shape
            // SleepStager/SleepView use: [{"start":epoch,"end":epoch,"stage":"light|deep|rem|wake"}].
            let onsetDay = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: date)!)
            let onset = Int(onsetDay.timeIntervalSince1970) + 23 * 3600 + 15 * 60 + rng.nextInt(-1500, 1500)
            let inBedSec = Int((totalSleep + totalSleep * (100 - efficiency) / 100) * 60)
            // ── 016 P2: ONE night the stager KEPT BUT FLAGGED, so the low-confidence caveat is a state
            // the simulator can render instead of one only a unit test has ever seen. The gate is on the
            // run's own CLOCK SPAN, so the fixture is a session whose SPAN clears the cap — this day's
            // `totalSleepMin` is the value it always drew, untouched (016 decision 1: this wave changes
            // no number). That gap IS the fixture: the hero keeps its ~7 h Asleep numeral while the
            // caveat quotes 17 h 12 min, which is the only pair of numbers that can show why the cap
            // fired.
            //
            // The END is pushed out, not the start — the recording keeps banking a frozen still stretch
            // long after the staged night ended, which is the artefact `maxMainSleepSpanS` was written
            // for. Three things stay exactly as drawn that way: `startTs` (the row's natural key AND the
            // instant `stagesJSON` is laid from, so bed time still agrees with the first stage segment),
            // this night's local day key (its end lands ~16:30, the same day at every drawn onset and
            // either side of a DST shift), and the ~6 h clear water before the next night's 23:15 onset.
            //
            // NO DRAW IS TAKEN: the span is a constant off `SleepDetection.maxMainSleepSpanS`, so the
            // SplitMix64 stream stays byte-identical (decision 6, the 009 rule) and every other seeded
            // day — including the hand-calibrated 007 anomaly — is unmoved.
            let flagged = i == lowConfidenceIndex
            sleeps.append(CachedSleepSession(
                // 0–1 fraction, matching the engine (`effWeighted/inBedS`) and the daily row above; the
                // Rest screen scales ×100 for display, so seeding a percent here double-scales to "8310 %".
                startTs: onset, endTs: onset + (flagged ? lowConfidenceSpanS : inBedSec),
                efficiency: round2(efficiency / 100), restingHr: rhr, avgHrv: round1(hrv),
                stagesJSON: stagesJSON(onset: onset, deep: deep, rem: rem, light: light,
                                       awakeMin: Double(disturbances) * 1.5),
                lowConfidence: flagged))
        }

        _ = try await store.upsertDailyMetrics(daily, deviceId: whoop)
        _ = try await store.upsertMetricSeries(series, deviceId: whoop)
        _ = try await store.upsertSleepSessions(sleeps, deviceId: whoop)
        _ = try await store.upsertJournal(journalRows, deviceId: journalLane)
        // 009 sessions. Cleared first rather than upserted over: `weedSession` deliberately has no
        // UNIQUE natural key (two taps in the same minute are legal), so a re-seed on a different
        // calendar date would otherwise leave the previous run's rows stranded on stale day keys.
        // Scoped to source "demo" — a real user's "manual" sessions are never in reach.
        _ = try await store.deleteWeedSessions(deviceId: StrapStore.weedSourceId, source: "demo")
        _ = try await store.upsertWeedSessions(weedRows)
        // 024 intake events, cleared-then-written by lane for the same reason as weed above.
        _ = try await store.deleteIngestionEvents(deviceId: StrapStore.intakeSourceId, source: "demo")
        _ = try await store.upsertIngestionEvents(
            intakeEventPlan(tagPlan: tagPlan, anomalyIndex: anomalyIndex,
                            startDay: startDay, cal: cal, fmt: fmt))
        let intakeTape = intakeTapeFixture(startDay: startDay, cal: cal)
        _ = try await store.insert(Streams(hr: intakeTape.hr, rr: intakeTape.rr,
                                           skinTemp: intakeTape.skinTemp,
                                           gravity: intakeTape.gravity), deviceId: whoop)
        try await seedWorkouts(into: store)
        try await seed007Fixtures(into: store)
        NSLog("DemoSeed: seeded \(daily.count) demo days under \(whoop).")
    }

    // MARK: - 009 weed sessions

    /// The timestamped sessions for the hand-authored weed days, drawn on a THIRD rng stream — a fifth
    /// draw on `jrng` would shift every existing tag draw and re-plant the whole 007 fixture, and `rng`
    /// is the daily-value stream. Evening clock times (21:00–23:30 local), because weed rides the same
    /// D-1 evening convention as alcohol — clamped back on the anchor day, the one day whose evening
    /// has not happened yet. `method` + `potency` are recorded on roughly two thirds and
    /// left NIL on the rest, so the "not recorded" shape the one-tap chip writes has a specimen; roughly
    /// one in five single-session days carries `tsExact: false` at the back-dated chip's 21:00
    /// placeholder, so the "Time not recorded" row has one too. The `day` key is the seed's own day key
    /// — never derived from `ts`, the table's load-bearing rule — so a session and its journal boolean
    /// can never disagree.
    ///
    /// Days are walked SORTED: `Set<Int>` iteration order is hash-seeded per PROCESS, so an unsorted
    /// walk would hand different days different draws on every launch — the one way this file's
    /// determinism promise can break without a seed changing.
    private static func weedSessionPlan(days: Set<Int>, anomalyIndex: Int, startDay: Date,
                                        cal: Calendar, fmt: DateFormatter) -> [WeedSessionRow] {
        var wrng = SplitMix64(seed: 0x57A9_DC0D_E5EE_D003)
        let methods = ["flower", "vape", "edible", "concentrate"]
        let now = Int(Date().timeIntervalSince1970)
        var out: [WeedSessionRow] = []
        for i in days.sorted() where i != anomalyIndex && i != anomalyIndex - 1 {
            let date = cal.date(byAdding: .day, value: i, to: startDay)!
            let day = fmt.string(from: date)
            let midnight = Int(date.timeIntervalSince1970)
            // 1 or 2 sessions: the Weed screen's Recent strip inks 0 / 1 / 2+ at three weights, so a
            // demo that only ever logged once would leave the heaviest cell unrendered.
            let n = wrng.nextDouble() < 0.35 ? 2 : 1
            var minutes: [Int] = []                                  // 21:00–23:30 local, ascending
            for _ in 0..<n { minutes.append(wrng.nextInt(21 * 60, 23 * 60 + 31)) }
            minutes.sort()
            // The newest seeded day is TODAY, and an evening draw on it is in the FUTURE at any
            // daytime launch — a midday sim rendered sessions at 11:19 PM and 11:25 PM that had not
            // happened. Shift that ONE day's clock back so its last session sits 20 min before now,
            // which keeps the drawn spacing (and so two sessions stay distinct and ordered) rather
            // than collapsing both onto a single clamp. Floors at midnight, which only binds on a
            // launch in the small hours — the one window with no past evening to place them in.
            let latest = i == DAYS - 1 ? Swift.max(0, (now - midnight) / 60 - 20) : Int.max
            if let last = minutes.last, last > latest {
                let shift = last - latest
                minutes = minutes.map { Swift.max(0, $0 - shift) }
            }
            for (k, minute) in minutes.enumerated() {
                let recorded = wrng.nextDouble() < 0.66
                // A placeholder clock only ever comes from a BACK-DATED chip tap, which writes exactly
                // one session for the day — so a day the user added a second session to always carries
                // real times. Drawn on the LEFT of the `&&` so the stream is consumed either way.
                let placeholder = wrng.nextDouble() < 0.20 && n == 1
                // The placeholder's fixed 21:00 needs the same guard as a drawn time, and it is not
                // in `minutes` — a back-dated chip tap on today would otherwise re-plant the future.
                let ts = midnight + Swift.min(placeholder ? 21 * 60 : minute, latest) * 60
                // Category draws take the top 53 bits (`nextDouble`) rather than `nextInt`'s modulo —
                // not a bias fix (nextInt is uniform at scale), but at this seed's ten recorded
                // sessions the modulo path happened to leave Heavy and two of the four methods with
                // no specimen at all, and an unrenderable case is an unreviewed case.
                out.append(WeedSessionRow(
                    id: "demo-weed-\(day)-\(k)", deviceId: StrapStore.weedSourceId, day: day, ts: ts,
                    tsExact: !placeholder,
                    method: recorded ? methods[Int(wrng.nextDouble() * Double(methods.count))] : nil,
                    potency: recorded ? Int(wrng.nextDouble() * 3) + 1 : nil,
                    source: "demo", createdAt: ts))
            }
        }
        return out
    }

    // MARK: - 024 intake events

    /// The day the tape specimen's meal sits on — SEVEN days before today, and the seven is the
    /// whole point.
    ///
    /// This sat at `DAYS - 3` (two days ago) until the 024 audit measured it. `seed007Fixtures`
    /// plants a waking-hours HR capture trail at 2-minute cadence over 08:00–22:00 for `daysAgo`
    /// 0…6 (`:595`), which lands squarely on top of this fixture's 19:10–22:40 window: seven stray
    /// samples fell inside the deliberate 12-minute hole, leaving alternating present/absent minutes
    /// (70, 72, 74…) instead of the clean break the fixture exists to demonstrate. `daysAgo 7` is the
    /// first day past that loop, and is clear of every other 007/workout fixture too (naps at 5 and
    /// `anomalyDaysAgo`, tennis at 1, run at 4, detectable bout at 2, suggestion arc at 3).
    ///
    /// Measured, not assumed: replaying the tape arithmetic over the seeded store showed the peak was
    /// NOT affected — +11 bpm at +31 min either way, because the strays run 64–69 bpm against a 59
    /// reference. Only the gap demonstration was compromised. Still inside the raw horizon (7 ≪ 28),
    /// past the anomaly night and its context day, and never in the future at any launch hour.
    private static let intakeTapeDayIndex = DAYS - 8

    /// Id suffix the specimen dinner carries, so `--intake-response` can find THAT entry rather than
    /// simply the newest one with a window. Without it the flag landed on an ordinary drink whose
    /// window the seed plants no streams under, and screenshotted a near-empty tape.
    static let intakeTapeSuffix = "dinner-tape"

    /// The timestamped intake events, on a FOURTH rng stream so no existing draw shifts.
    ///
    /// **The one constraint that shapes this whole plan:** `IntakeStore.repair` RAISES the journal
    /// tag an event owes at launch. So an alcohol event on a day the demo did not already tag
    /// `alcohol` would add a real alcohol day to the seed — and 009's weed statistics are
    /// hand-calibrated against the exact alcohol day set (`weedDays` above: *"the ONLY way to keep
    /// alcohol out of weed's numbers is to give both groups the same share of it"*). One extra
    /// alcohol day would silently re-balance the demo's headline weed finding.
    ///
    /// So alcohol and late-caffeine events are placed ONLY on days that already carry the matching
    /// tag, read from the `tagPlan` that was actually drawn rather than from the day list in a
    /// comment. Meals, water and MORNING caffeine project nothing (024 decision 5) and are free to
    /// land anywhere. Pinned by `IntakeTests.testDemoSeedRaisesNoNewTags`, which seeds a temp store and
    /// asserts `IntakeStore.missingTagDays` comes back empty — the exact check `repair` makes at launch.
    ///
    /// Days are walked in index order for the same determinism reason `weedSessionPlan` sorts its set.
    private static func intakeEventPlan(tagPlan: [Int: Set<JournalTag>], anomalyIndex: Int,
                                        startDay: Date, cal: Calendar,
                                        fmt: DateFormatter) -> [IngestionEventRow] {
        var irng = SplitMix64(seed: 0x1A7A_4E00_D0FF_EE24)
        let now = Int(Date().timeIntervalSince1970)
        var out: [IngestionEventRow] = []

        func add(_ day: String, _ ts: Int, _ kind: IntakeKind, count: Int? = nil, size: Int? = nil,
                 variant: IntakeVariant? = nil, mg: Int? = nil,
                 exact: Bool = true, suffix: String) {
            // Never plant an event in the future — a midday launch would otherwise render a dinner
            // that has not happened, the trap `weedSessionPlan` documents for its evening draws.
            guard ts <= now else { return }
            out.append(IngestionEventRow(
                id: "demo-intake-\(day)-\(suffix)", deviceId: StrapStore.intakeSourceId, day: day,
                ts: ts, tsExact: exact, kind: kind.rawValue, countValue: count, sizeOrdinal: size,
                // Forwarded explicitly. An earlier cut took these as parameters and dropped them
                // here, which Swift compiles without a murmur (an unused parameter is not a warning)
                // and which seeded 28 caffeine rows with null form and null milligrams while the
                // call sites all read correctly. Same shape as the night/typical defect in 026.
                variant: variant?.rawValue, amountMg: mg,
                source: "demo", createdAt: ts))
        }

        for i in 0..<DAYS where i != anomalyIndex && i != anomalyIndex - 1 {
            let date = cal.date(byAdding: .day, value: i, to: startDay)!
            let day = fmt.string(from: date)
            let midnight = Int(date.timeIntervalSince1970)
            let tags = tagPlan[i] ?? []

            // Morning coffee on most days. Before 14:00, so it raises NOTHING — the specimen for the
            // half of the caffeine rule that is easy to forget exists.
            if irng.nextDouble() < 0.8 {
                // A brewed drink, in milligrams — an ESTIMATE, which is what the form records.
                add(day, midnight + irng.nextInt(7 * 60, 9 * 60 + 30) * 60, .caffeine,
                    variant: .drink, mg: irng.nextDouble() < 0.35 ? 190 : 95, suffix: "coffee-am")
            }
            // An afternoon one ONLY on days already tagged caffeine_late, at/after 14:00 so the
            // projection it owes is the tag the day already has.
            if tags.contains(.caffeineLate) {
                // Alternate the afternoon dose between the two forms so the packet-vs-estimate
                // distinction — the whole reason 027 could add milligrams — has a specimen of each.
                let asPill = irng.nextDouble() < 0.5
                add(day, midnight + irng.nextInt(14 * 60, 16 * 60 + 30) * 60, .caffeine,
                    variant: asPill ? .pill : .drink, mg: asPill ? 200 : 95, suffix: "coffee-pm")
            }
            // Lunch, most days; dinner, most days.
            if irng.nextDouble() < 0.75 {
                add(day, midnight + irng.nextInt(12 * 60, 13 * 60 + 45) * 60, .meal,
                    size: Int(irng.nextDouble() * 3) + 1, suffix: "lunch")
            }
            // The specimen day's dinner is PINNED to the fixture's clock (19:40) rather than drawn,
            // because the 1 Hz streams `intakeTapeFixture` plants are centred on exactly that
            // instant — a drawn time would leave the one reviewable tape reading a window its data
            // is offset from. The gate and size draws are taken up front so they are consumed either
            // way; the pinned branch skips only the clock draw, on the one fixed day index, so the
            // plan stays deterministic.
            let dinnerDraw = irng.nextDouble(), dinnerSize = Int(irng.nextDouble() * 3) + 1
            if i == intakeTapeDayIndex {
                add(day, midnight + 19 * 3_600 + 40 * 60, .meal, size: 3, suffix: intakeTapeSuffix)
            } else if dinnerDraw < 0.85 {
                add(day, midnight + irng.nextInt(18 * 60 + 30, 20 * 60 + 30) * 60, .meal,
                    size: dinnerSize, suffix: "dinner")
            }
            // Water, a couple of days in three — the kind that logs and draws no tape at all.
            if irng.nextDouble() < 0.65 {
                add(day, midnight + irng.nextInt(10 * 60, 17 * 60) * 60, .water,
                    count: irng.nextInt(1, 4), suffix: "water")
            }
            // Drinks only on days the seed already tags alcohol (see the type doc). One day in four
            // of those puts the last drink AFTER midnight — the load-bearing case: its `ts` is on the
            // NEXT calendar date while its `day` key stays this one, which is exactly what a key
            // re-derived from the clock would get wrong.
            if tags.contains(.alcohol) {
                let n = irng.nextDouble() < 0.4 ? 2 : 1
                add(day, midnight + irng.nextInt(20 * 60, 22 * 60) * 60, .alcohol, count: n,
                    suffix: "drink")
                if irng.nextDouble() < 0.25 {
                    add(day, midnight + 24 * 3_600 + irng.nextInt(10, 70) * 60, .alcohol, count: 1,
                        suffix: "nightcap")
                }
            }
            // One back-dated entry with no clock, so the "Time not recorded" row and the response
            // screen's no-origin refusal both have a specimen. Deliberately NOT on
            // `intakeTapeDayIndex`: that day's dinner is the tape fixture, and a clock-less entry
            // beside it would put a "no response to draw" row next to the one entry that draws one.
            if i == DAYS - 11 {
                add(day, midnight + IntakeStore.placeholderHour * 3_600, .meal, exact: false,
                    suffix: "no-clock")
            }
        }
        return out
    }

    /// 1 Hz HR + gravity + skin temp around the specimen dinner, so ONE entry in the demo renders a
    /// real tape instead of the honest-but-unreviewable "nothing recorded in this window".
    ///
    /// Shaped to exercise every rule the tape claims to keep:
    ///  - a still pre-roll, so there IS a reference line;
    ///  - a walk to the kitchen either side of the event (strongly oscillating gravity for ~11 min),
    ///    which must render as a shaded stretch AND be excluded from the peak;
    ///  - a post-prandial HR rise that resolves, and a slower skin-temp rise;
    ///  - a 12-minute hole at +70 min, so the broken-line rule is visible rather than asserted.
    ///
    /// Skin temp is written as RAW register units on the 4.0 scale (`Whoop4SkinTemp`: 826 ↔ 33.0 °C,
    /// 0.05 °C per unit), because `WhoopModel.persisted` defaults to `.whoop4` and the demo registry
    /// row names no model — so that is the family `ScoreEngine.skinTempFamily` will resolve.
    private static func intakeTapeFixture(startDay: Date, cal: Calendar)
        -> (hr: [HRSample], gravity: [GravitySample], skinTemp: [SkinTempSample],
            rr: [RRInterval], ts: Int) {
        let date = cal.date(byAdding: .day, value: intakeTapeDayIndex, to: startDay)!
        let eventTs = Int(date.timeIntervalSince1970) + 19 * 3_600 + 40 * 60
        var srng = SplitMix64(seed: 0x7A9E_D00D_1247_BEEF)
        var hr: [HRSample] = [], grav: [GravitySample] = [], skin: [SkinTempSample] = []
        var rr: [RRInterval] = []

        for s in (-30 * 60)...(180 * 60) {
            let minute = Double(s) / 60.0
            if (70.0...82.0).contains(minute) { continue }          // the deliberate hole
            let ts = eventTs + s
            let moving = minute >= -4 && minute <= 7
            // Post-prandial arc: nothing before the meal, a broad ~11 bpm rise peaking near +40 min.
            let rise = minute < 0 ? 0 : 11 * exp(-pow((minute - 40) / 45, 2))
            let walk = moving ? 15.0 : 0
            hr.append(HRSample(ts: ts, bpm: Int((58 + rise + walk + srng.nextDouble() * 2).rounded())))
            // Gravity: a still wrist drifts by ~0.01 g between records; walking swings it far past
            // the 0.15 g smoothed threshold `SedentaryDetector` gates on.
            let swing = moving ? 0.55 : 0.01
            grav.append(GravitySample(ts: ts,
                                      x: sin(Double(s) / 1.7) * swing,
                                      y: cos(Double(s) / 2.3) * swing,
                                      z: 1.0 - swing * 0.2))
            // Skin temp at 1 Hz, +0.3 °C over the window = +6 raw units on the 4.0 slope.
            let warm = minute < 0 ? 0 : 6 * (1 - exp(-minute / 60))
            skin.append(SkinTempSample(ts: ts, raw: Int((826 + warm).rounded())))

            // R-R, and deliberately NOT everywhere. The strap only produces clean beat-to-beat on a
            // quiet wrist, so the corpus shows it covering roughly half a dinner window against ~97%
            // for HR — plant that shape, not a third dense lane, or the demo would advertise a
            // coverage the hardware does not give. Dropped entirely while moving, and every third
            // still minute is left out on top.
            if !moving, Int(minute.rounded(.down)) % 3 != 0 {
                // ~46 ms resting RMSSD, dipping ~9 ms after the meal (parasympathetic withdrawal
                // during digestion). Beat-to-beat scatter is what RMSSD measures, so the interval
                // alternates around the mean rather than sitting on it.
                // RMSSD is the root-mean-square of SUCCESSIVE differences, so a strictly alternating
                // series of ±amp gives a stable RMSSD of 2·amp. Alternate DETERMINISTICALLY on the
                // sample index: an earlier cut randomised the sign per sample, which made the minute
                // -to-minute rMSSD swing wildly and rendered the lane as scribble — a fixture
                // artefact that made an honest lane look broken.
                let dip = minute < 0 ? 0.0 : -9 * exp(-pow((minute - 35) / 40, 2))
                let amp = (46.0 + dip) / 2
                rr.append(RRInterval(ts: ts, rrMs: Int((1000.0 + (s % 2 == 0 ? amp : -amp)).rounded())))
            }
        }
        // ── The typical-hour band's raw material (wave B). The band needs at least
        // `IntakeTypicalBand.minCoveredDays` PRIOR days carrying most of this same clock window, and
        // the 007 capture trail only reaches `daysAgo` 0…6 — which this fixture deliberately sits
        // outside. So plant a plain evening trail at the same clock offsets on the preceding days,
        // varying the level per day so the band has real width instead of collapsing to a line.
        for back in 1...IntakeTypicalBand.lookbackDays {
            let dayOrigin = eventTs - back * 86_400
            let level = 57.0 + Double((back * 7) % 9) - 4      // ~53–61 bpm across days
            for s in stride(from: -30 * 60, through: 180 * 60, by: 30) {
                let minute = Double(s) / 60.0
                // A gentle evening decline, no post-prandial arc — this is the ORDINARY evening the
                // logged one is being read against.
                let drift = -2.5 * (minute / 180)
                hr.append(HRSample(ts: dayOrigin + s, bpm: Int((level + drift).rounded())))
            }
        }
        return (hr: hr, gravity: grav, skinTemp: skin, rr: rr, ts: eventTs)
    }

    // MARK: - 007 fixtures (naps, strap health, anomaly-night raw streams)

    /// Seed the raw material the 007 features read: two daytime naps (25 + 45 min, imported-lane
    /// sleep sessions), a 7-day battery sawtooth (~0.9 %/h with one charge event, ~40 % now), a
    /// waking-hours HR capture trail for the last week with a deliberate 3-h gap two days ago
    /// (not off-wrist — a genuine capture gap), and the anomaly night's raw streams (still 1 Hz
    /// night at an elevated 66 bpm with a crushed-HRV RR trace) so `analyzeRecent` itself derives
    /// the raised health-monitor flag — the honest way, same reason seedWorkouts banks a real
    /// detectable bout instead of hand-inserting a "detected" row.
    private static func seed007Fixtures(into store: StrapStore) async throws {
        let cal = Calendar.current
        let todayMid = cal.startOfDay(for: Date())
        let now = Int(Date().timeIntervalSince1970)
        func ts(daysAgo: Int, hour: Int, minute: Int) -> Int {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: todayMid)!
            return Int(day.timeIntervalSince1970) + hour * 3600 + minute * 60
        }

        // ── Two daytime naps in the last week (short, light-stage, own rows — SleepStager's shape
        // for a detected nap; never folded into the night totals). The 45-min one lands on the
        // anomaly day: napping while run-down reads true.
        let nap1Start = ts(daysAgo: 5, hour: 13, minute: 5)          // 25 min
        let nap2Start = ts(daysAgo: anomalyDaysAgo, hour: 14, minute: 10)  // 45 min
        var naps = [
            CachedSleepSession(startTs: nap1Start, endTs: nap1Start + 25 * 60, efficiency: 0.92,
                               restingHr: nil, avgHrv: nil,
                               stagesJSON: stagesJSON(onset: nap1Start, deep: 0, rem: 0,
                                                      light: 23, awakeMin: 2)),
            CachedSleepSession(startTs: nap2Start, endTs: nap2Start + 45 * 60, efficiency: 0.94,
                               restingHr: nil, avgHrv: nil,
                               stagesJSON: stagesJSON(onset: nap2Start, deep: 0, rem: 0,
                                                      light: 42, awakeMin: 3)),
        ]
        // ── A nap on the NEWEST demo day too: the Rest screen renders naps only for its displayed
        // (newest slept) day, so without one the whole nap section is invisible in the sim. Today's
        // timeline only runs to "now", so this one floats — it ends 40 min ago — and is seeded only
        // when that keeps a genuinely DAYTIME onset (≥ 11:00 local; earlier would sit in the
        // overnight band and bridge into the main night, #861). An early-morning launch skips it
        // (the two fixed naps above still exercise Data). The edge fixture skips it too — its
        // whole point is a still-forming today.
        let todayNapEnd = now - 40 * 60
        let todayNapStart = todayNapEnd - 30 * 60
        if !edgeToday, todayNapStart >= ts(daysAgo: 0, hour: 11, minute: 0) {
            naps.append(CachedSleepSession(startTs: todayNapStart, endTs: todayNapEnd,
                                           efficiency: 0.93, restingHr: nil, avgHrv: nil,
                                           stagesJSON: stagesJSON(onset: todayNapStart, deep: 0,
                                                                  rem: 0, light: 28, awakeMin: 2)))
        }
        _ = try await store.upsertSleepSessions(naps, deviceId: whoop)

        // ── Battery: 7-day sawtooth at ~0.9 %/h with one ~2.5 h charge to full ~66 h ago, landing
        // at ~40 % now (30-min cadence, the persisted `battery` table the strap-health trend reads).
        _ = try await store.insert(Streams(battery: batterySawtooth(now: now)), deviceId: whoop)

        // ── Waking-hours HR capture trail (2-min cadence, 08:00–22:00) for the last week, with a
        // 13:00–16:00 hole two days ago and NO off-wrist events around it — a true capture gap.
        // Today's trail stops at "now" (and is skipped entirely in the edge fixture, whose whole
        // point is a still-forming today).
        var hr: [HRSample] = []
        for daysAgo in 1...6 {
            hr += coverageArc(from: ts(daysAgo: daysAgo, hour: 8, minute: 0),
                              to: ts(daysAgo: daysAgo, hour: 22, minute: 0),
                              skip: daysAgo == 2
                                  ? (ts(daysAgo: 2, hour: 13, minute: 0),
                                     ts(daysAgo: 2, hour: 16, minute: 0))
                                  : nil)
        }
        if !edgeToday {
            hr += coverageArc(from: ts(daysAgo: 0, hour: 8, minute: 0),
                              to: min(now, ts(daysAgo: 0, hour: 22, minute: 0)), skip: nil)
        }

        // ── The anomaly night's raw streams, ending 06:30 on the anomaly day. Constant 68 bpm
        // (the RHR floor), still gravity (in-bed), and an RSA-modulated RR trace at ±23 ms /
        // 0.296 Hz — planting RMSSD ≈ 25.1 ms and a recovered respiration of ~17.14 br/min. The
        // engine re-derives the same anomalous vitals the imported daily row carries and flags the
        // day itself.
        //
        // The three knobs are COUPLED, which is why they moved together when this was re-planted
        // for the bias-corrected spread (see 007 F2 above): RMSSD scales with amplitude × mean R-R
        // × frequency, mean R-R is 60000/bpm, and respiration is the frequency (×60). So raising
        // the HR to deepen the RHR signal also SHRINKS RMSSD, and raising the frequency to lift
        // respiration grows it back. Every value here was measured through the real engine rather
        // than solved for on paper.
        let night = anomalyNight(endTs: ts(daysAgo: anomalyDaysAgo, hour: 6, minute: 30))
        _ = try await store.insert(Streams(hr: hr + night.hr, rr: night.rr, gravity: night.gravity),
                                   deviceId: whoop)
    }

    /// A gently varying daytime HR trail at a 2-min banked cadence, with an optional `[start, end)`
    /// hole (the seeded capture gap).
    private static func coverageArc(from: Int, to: Int, skip: (Int, Int)?) -> [HRSample] {
        var out: [HRSample] = []
        var t = from
        while t < to {
            if let skip, t >= skip.0, t < skip.1 { t += 120; continue }
            let frac = Double(t - from) / 3600.0
            let bpm = 71 + 6 * sin(frac * 1.9) + 3 * sin(frac * 5.3)
            out.append(HRSample(ts: t, bpm: Int(bpm.rounded())))
            t += 120
        }
        return out
    }

    /// The anomaly night fixture (same shape as the ScaleContractTests crafted night): 7.5 h of
    /// 1 Hz constant-68-bpm HR + still gravity, and an RR trace whose mean matches the HR with a
    /// ±23 ms RSA modulation at 0.296 Hz (planting RMSSD ≈ 25.1 ms and respiration ≈ 17.14 br/min).
    private static func anomalyNight(endTs: Int)
        -> (hr: [HRSample], rr: [RRInterval], gravity: [GravitySample]) {
        let durationS = Int(7.5 * 3600)
        let start = endTs - durationS
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        hr.reserveCapacity(durationS)
        grav.reserveCapacity(durationS)
        for t in start..<endTs {
            hr.append(HRSample(ts: t, bpm: 68))
            grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
        }
        var rr: [RRInterval] = []
        var tSec = 0.0
        let meanMs = 60_000.0 / 68.0
        while tSec < Double(durationS) {
            let rrMs = meanMs + 23.0 * sin(2.0 * Double.pi * 0.296 * tSec)
            tSec += rrMs / 1000.0
            rr.append(RRInterval(ts: start + Int(tSec), rrMs: Int(rrMs)))
        }
        return (hr, rr, grav)
    }

    /// The 7-day battery sawtooth: discharge at ~0.9 %/h from ~97 %, one 2.5-h charge back to full
    /// ~66 h ago, discharging since to ~40 % now. 30-min cadence.
    private static func batterySawtooth(now: Int) -> [BatterySample] {
        let dischargePerHour = 0.9
        let chargeEnd = now - 66 * 3600
        let chargeStart = chargeEnd - Int(2.5 * 3600)
        let windowStart = now - 7 * 24 * 3600
        var out: [BatterySample] = []
        var t = windowStart
        while t <= now {
            let soc: Double
            var charging = false
            if t < chargeStart {
                soc = 8.0 + Double(chargeStart - t) / 3600.0 * dischargePerHour
            } else if t < chargeEnd {
                charging = true
                soc = 8.0 + 92.0 * Double(t - chargeStart) / Double(chargeEnd - chargeStart)
            } else {
                soc = 100.0 - Double(t - chargeEnd) / 3600.0 * dischargePerHour
            }
            let clamped = soc.clamped(0, 100)
            out.append(BatterySample(ts: t, soc: round1(clamped),
                                     mv: Int(3500 + clamped * 7), charging: charging))
            t += 30 * 60
        }
        return out
    }

    /// Seed a handful of workouts so the sim exercises the Live list / detail + the Today last-workout
    /// row (W7): one MANUAL session (with a strap HR arc so its detail HR-curve + zone bars render), one
    /// IMPORTED-style row carrying `zonesJSON`, and — crucially — a real HR+gravity workout day so the
    /// engine's own `analyzeRecent` DETECTS a bout and persists a "detected" row under the computed id.
    ///
    /// The detected row is created by the engine, not hand-inserted: `analyzeRecent` deletes then
    /// re-derives every sport="detected" row each pass, so a hand-inserted one would be wiped on the first
    /// launch. Seeding the raw HR + gravity that make the detector fire is the honest way to demo it.
    private static func seedWorkouts(into store: StrapStore) async throws {
        let cal = Calendar.current
        let todayMid = cal.startOfDay(for: Date())
        func ts(daysAgo: Int, hour: Int, minute: Int) -> Int {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: todayMid)!
            return Int(day.timeIntervalSince1970) + hour * 3600 + minute * 60
        }

        // Manual Tennis, yesterday evening — an HR arc (no gravity → not auto-detected, stays a single
        // manual row) so the detail HR-curve + zone bars render off real strap samples.
        let tennisStart = ts(daysAgo: 1, hour: 18, minute: 5)
        let tennisDur = 52 * 60
        let tennisHr = hrArc(startTs: tennisStart, durationS: tennisDur, base: 108, peak: 170)
        let manual = WorkoutRow(startTs: tennisStart, endTs: tennisStart + tennisDur, sport: "Tennis",
                                source: "manual", durationS: Double(tennisDur), energyKcal: 384,
                                avgHr: 132, maxHr: 168, strain: 11.4, distanceM: nil,
                                zonesJSON: nil, notes: nil)

        // Imported-style Running, four days ago — carries zonesJSON so the detail zone bars render even
        // without strap HR in its window.
        let runStart = ts(daysAgo: 4, hour: 8, minute: 0)
        let runDur = 38 * 60
        let imported = WorkoutRow(startTs: runStart, endTs: runStart + runDur, sport: "Running",
                                  source: "whoop", durationS: Double(runDur), energyKcal: 432,
                                  avgHr: 155, maxHr: 179, strain: 12.1, distanceM: nil,
                                  zonesJSON: #"{"z1":6,"z2":22,"z3":41,"z4":24,"z5":7}"#, notes: nil)

        _ = try await store.upsertWorkouts([manual, imported], deviceId: whoop)

        // A real detectable bout two mornings ago: rest → 42-min elevated-HR + oscillating-gravity effort
        // → rest, banked as raw strap streams. `analyzeRecent` reads this and persists a "detected" row.
        let det = workoutDay(activeStart: ts(daysAgo: 2, hour: 7, minute: 20),
                             restMin: 12, activeMin: 42, base: 60, activeBase: 120, peak: 176)

        // A free-standing HR-only bout three afternoons ago (17:30, ~26 min, ~112→150 bpm). It carries
        // NO gravity, so the gravity-gated ScoreEngine never writes a "detected" row for it and it stays
        // UNSAVED — which is exactly what lets the opt-in HR-only AutoWorkoutDetector surface it as the
        // one live "Looks like a workout?" suggestion (sustained ≥ resting+30 far past its 12-min gate).
        // Placed clear of the Tennis / Running / detected windows and above the ~71 bpm coverage trail,
        // so it reads as a clean rest → elevated → rest bout.
        let suggHr = hrArc(startTs: ts(daysAgo: 3, hour: 17, minute: 30), durationS: 26 * 60,
                           base: 112, peak: 150)
        _ = try await store.insert(Streams(hr: tennisHr + det.hr + suggHr, gravity: det.gravity),
                                   deviceId: whoop)
    }

    /// A plausible warmup → peak → cooldown HR arc at a coarse ~5 s cadence (enough for the detail curve
    /// and time-in-zone), spanning `base`…`peak` bpm with a small oscillation. HR only (no motion).
    private static func hrArc(startTs: Int, durationS: Int, base: Int, peak: Int, stepS: Int = 5) -> [HRSample] {
        let n = max(2, durationS / stepS)
        var out: [HRSample] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let frac = Double(i) / Double(n - 1)
            let arc = sin(frac * Double.pi)                     // 0 → 1 → 0
            let bpm = Double(base) + (Double(peak) - Double(base)) * arc + 5 * sin(frac * 24)
            out.append(HRSample(ts: startTs + i * stepS, bpm: Int(bpm.rounded())))
        }
        return out
    }

    /// A full workout day the auto-detector can fire on: quiet rest (low HR, still gravity), then a
    /// sustained elevated-HR bout with strongly oscillating gravity (motion), then rest again — at 1 Hz so
    /// the strain/zone gates clear. Mirrors the fixture the WorkoutDetectionSmokeTests use.
    private static func workoutDay(activeStart: Int, restMin: Int, activeMin: Int,
                                   base: Int, activeBase: Int, peak: Int) -> (hr: [HRSample], gravity: [GravitySample]) {
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        func rest(_ start: Int, _ minutes: Int) {
            for i in 0..<(minutes * 60) {
                hr.append(HRSample(ts: start + i, bpm: base))
                grav.append(GravitySample(ts: start + i, x: 0, y: 0, z: 1))
            }
        }
        rest(activeStart - restMin * 60, restMin)
        let n = activeMin * 60
        for i in 0..<n {
            let frac = Double(i) / Double(n - 1)
            let arc = sin(frac * Double.pi)                     // 0 → 1 → 0
            let bpm = Double(activeBase) + (Double(peak) - Double(activeBase)) * arc + 4 * sin(frac * 24)
            hr.append(HRSample(ts: activeStart + i, bpm: Int(bpm.rounded())))
            let x = (i % 2 == 0) ? 0.9 : -0.9                   // ±0.9 flip → large motion delta
            grav.append(GravitySample(ts: activeStart + i, x: x, y: 0, z: 0.4))
        }
        rest(activeStart + n, restMin)
        return (hr, grav)
    }

    // MARK: - helpers

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// Box–Muller normal sample off the deterministic RNG.
    private static func gauss(_ rng: inout SplitMix64, _ mean: Double, _ sd: Double) -> Double {
        let u1 = rng.nextDouble().clamped(1e-9, 1)
        let u2 = rng.nextDouble()
        return mean + sd * (sqrt(-2.0 * log(u1)) * cos(2.0 * Double.pi * u2))
    }

    /// A plausible light→deep→rem cycle as the segment array SleepView decodes, laid end-to-end
    /// from `onset` (same shape `DayEngine.encodeStages` writes for computed nights).
    private static func stagesJSON(onset: Int, deep: Double, rem: Double, light: Double,
                                   awakeMin: Double) -> String {
        var t = onset
        var parts: [String] = []
        func seg(_ stage: String, _ minutes: Double) {
            let secs = Int(minutes * 60)
            guard secs > 0 else { return }
            parts.append("{\"start\":\(t),\"end\":\(t + secs),\"stage\":\"\(stage)\"}")
            t += secs
        }
        seg("light", light * 0.35); seg("deep", deep * 0.6); seg("light", light * 0.30)
        seg("rem", rem * 0.6); seg("deep", deep * 0.4); seg("light", light * 0.35)
        seg("rem", rem * 0.4); seg("wake", awakeMin)
        return "[" + parts.joined(separator: ",") + "]"
    }
    #else
    /// Release ships no argv check at all: statically false, so a `--seed-demo` launch can never
    /// bypass FirstRun into an empty shell (the seeding body isn't compiled in either).
    static var requested: Bool { false }
    #endif
}

#if DEBUG
/// Deterministic SplitMix64 PRNG — a fixed, reproducible demo dataset across runs. Not for security use.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)  // 2^53
    }

    /// Uniform Int in [lower, upper).
    mutating func nextInt(_ lower: Int, _ upper: Int) -> Int {
        guard upper > lower else { return lower }
        let span = UInt64(upper - lower)
        return lower + Int(next() % span)
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
#endif
