import XCTest
import Foundation
import StrapProtocol
import StrapStore
import StrapAnalytics
@testable import whoopmaxx

/// SCALE-CONTRACT GUARD (a tripwire, not a feature).
///
/// Every app-side caller of the vendored producers assumes a fixed SCALE for each field they read:
/// efficiency is a 0–1 FRACTION, the Charge/Effort/Rest scores are 0–100, SpO₂ is a percent, skin-temp
/// is a small signed °C DEVIATION, respiration/resting-HR are in physiological ranges. A future rescale
/// of a producer — or a fixture/engine bug like the past "8310 %" double-scale (a percent seeded where a
/// fraction was expected, then multiplied ×100 for display) — must fail HERE, in CI, instead of shipping
/// a dashboard reading "1 %" sleep efficiency or "8310 %".
///
/// This drives the REAL engine two ways and pins the produced values against the ranges callers depend on:
///   1. `DayEngine.analyzeDay` on a crafted, physiologically-plausible synthetic night (with
///      personal baselines so Charge/recovery, the skin-temp deviation, and respiration are all actually
///      produced, not cold-started to nil).
///   2. `DemoSeed.seed` into a fixture store — the rows the simulator dashboard actually renders — read
///      back as `DailyMetric` / `CachedSleepSession` / the `sleep_performance` `MetricPoint` series.
///
/// Each assertion names the expected scale in its failure message on purpose: a red here should read as a
/// scale/units regression, not a mystery.
final class ScaleContractTests: XCTestCase {

    // ── The contracts, as named bounds (referenced in the failure messages below) ──
    private let scoreRange = 0.0...100.0          // Charge / Effort / Rest / SpO₂ percent
    private let efficiencyRange = 0.0...1.0       // FRACTION, never a 0–100 percent
    private let skinDevBand = -5.0...5.0          // °C deviation from personal baseline
    private let respRange = 4.0...40.0            // breaths/min
    private let rhrRange = 20...240               // bpm
    private let rrMsRange = 200.0...2500.0        // inter-beat interval (ms)
    private let skinAbsBand = 20.0...45.0         // absolute worn skin temp (°C)

    // MARK: - 1) Crafted synthetic night → DayEngine.analyzeDay

    /// A still, low-HR night ending at 06:00 UTC on `endDay` — the same fixture shape the package's
    /// AnalyticsEngineTests use, so the REAL SleepStager detects exactly one session and analyzeDay rolls
    /// up a full DailyMetric. RR is RSA-modulated (mean 1200 ms ⇒ HR 50, ±40 ms at 0.25 Hz ⇒ a planted
    /// ~15 breaths/min) so respiration is actually produced; skin is a worn 34 °C plateau (raw = °C×100,
    /// the 5/MG centidegree scale) so the wear-gated nightly skin mean + its deviation are produced too.
    private func craftedNight(endDay: String, hours: Int)
        -> (hr: [HRSample], rr: [RRInterval], gravity: [GravitySample], skin: [SkinTempSample]) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let dayMidnight = Int(fmt.date(from: endDay)!.timeIntervalSince1970)
        let end = dayMidnight + 6 * 3600
        let start = end - hours * 3600

        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        var skin: [SkinTempSample] = []
        for t in start..<end {
            hr.append(HRSample(ts: t, bpm: 50))            // resting-HR floor 50 bpm
            grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))   // still → in-bed
            skin.append(SkinTempSample(ts: t, raw: 3400))  // worn 34.0 °C (centidegrees)
        }
        // RSA-modulated RR so the respiration estimator has a real signal to recover.
        var rr: [RRInterval] = []
        var tSec = 0.0
        while tSec < Double(end - start) {
            let rrMs = 1200.0 + 40.0 * sin(2.0 * Double.pi * 0.25 * tSec)
            tSec += rrMs / 1000.0
            rr.append(RRInterval(ts: start + Int(tSec), rrMs: Int(rrMs)))
        }
        return (hr, rr, grav, skin)
    }

    func testAnalyzeDayOutputsHonorCallerScaleContracts() throws {
        let day = "2021-06-15"
        let n = craftedNight(endDay: day, hours: 8)

        // Personal baselines around the values this night produces, so Charge/recovery and the skin-temp
        // deviation are genuinely SCORED (not nil-gated by a cold-start baseline).
        let hrvBase = Baselines.foldHistory(Array(repeating: 40.0, count: 14), cfg: Baselines.metricCfg["hrv"]!)
        let rhrBase = Baselines.foldHistory(Array(repeating: 50.0, count: 14), cfg: Baselines.metricCfg["resting_hr"]!)
        let skinBase = Baselines.foldHistory([33.5, 33.4, 33.6, 33.5], cfg: Baselines.metricCfg["skin_temp"]!)
        XCTAssertTrue(hrvBase.usable && rhrBase.usable && skinBase.usable,
                      "test fixture baselines must be usable, or the scored terms below never populate")

        let result = DayEngine.analyzeDay(
            day: day, hr: n.hr, rr: n.rr, gravity: n.gravity, skinTemp: n.skin,
            profile: UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male"),
            baselines: DayEngine.ProfileBaselines(hrv: hrvBase, restingHR: rhrBase, skinTemp: skinBase))

        // The night must actually have scored, or the contract assertions below are vacuous.
        XCTAssertEqual(result.sleepSessions.count, 1, "the still synthetic night must detect exactly one sleep")
        let d = result.daily

        // ── efficiency: a 0–1 FRACTION (the "8310 %" regression) ──
        let eff = try XCTUnwrap(d.efficiency, "a scored night must produce an efficiency")
        XCTAssert(efficiencyRange.contains(eff),
                  "DailyMetric.efficiency must be a 0–1 FRACTION (asleep/in-bed), NEVER a 0–100 percent; got \(eff) on \(d.day)")
        XCTAssertLessThanOrEqual(eff, 1.0,
                  "efficiency \(eff) > 1 means a percent leaked into the fraction lane (the 8310 % double-scale)")
        // The same fraction contract on the per-session cache row the Sleep screen scales ×100 for display.
        for s in result.cachedSleep {
            let se = try XCTUnwrap(s.efficiency, "a detected session must carry an efficiency")
            XCTAssert(efficiencyRange.contains(se),
                      "CachedSleepSession.efficiency must be a 0–1 FRACTION (the Rest screen multiplies ×100); got \(se)")
        }

        // ── Charge / recovery ∈ [0,100] ──
        let recovery = try XCTUnwrap(result.recovery, "usable baselines must yield a Charge/recovery score")
        XCTAssertEqual(result.daily.recovery, result.recovery, "daily.recovery and DayResult.recovery must agree")
        XCTAssert(scoreRange.contains(recovery),
                  "Charge/recovery must be a 0–100 score; got \(recovery)")

        // ── Effort / strain ∈ [0,100] (or nil) ──
        if let strain = result.strain {
            XCTAssert(scoreRange.contains(strain), "Effort/strain must be a 0–100 score; got \(strain)")
            XCTAssertEqual(d.strain, result.strain, "daily.strain and DayResult.strain must agree")
        }

        // ── Rest / sleep_performance ∈ [0,100] ──
        let rest = try XCTUnwrap(result.restScore, "a scored night must produce a Rest composite")
        XCTAssert(scoreRange.contains(rest),
                  "Rest / sleep_performance must be a 0–100 score; got \(rest)")

        // ── SpO₂ (%) ∈ [0,100] or nil (analyzeDay leaves it nil today; pin the range for when it lands) ──
        if let spo2 = d.spo2Pct {
            XCTAssert(scoreRange.contains(spo2), "SpO₂ must be a 0–100 percent (or nil); got \(spo2)")
        }

        // ── skinTempDevC: a small signed °C DEVIATION, not an absolute temperature ──
        let dev = try XCTUnwrap(d.skinTempDevC, "worn skin + a usable baseline must produce a deviation")
        XCTAssert(skinDevBand.contains(dev),
                  "skinTempDevC must be a small signed °C DEVIATION in \(skinDevBand) (not an absolute temp / not a raw ADC); got \(dev)")
        // The wear-gated nightly ABSOLUTE mean °C (the deviation's source) must be a real body temp.
        let skinC = try XCTUnwrap(result.nightlySkinTempC, "the worn 34 °C plateau must yield a nightly mean")
        XCTAssert(skinAbsBand.contains(skinC),
                  "nightlySkinTempC must be an absolute worn skin temp in \(skinAbsBand) °C; got \(skinC)")

        // ── Respiration ∈ ~[4,40] br/min (or nil) ──
        if let resp = d.respRateBpm {
            XCTAssert(respRange.contains(resp),
                      "respRateBpm must be plausible breaths/min in \(respRange); got \(resp)")
        }

        // ── Resting HR ∈ ~[20,240] bpm (or nil) ──
        if let rhr = d.restingHr {
            XCTAssert(rhrRange.contains(rhr), "restingHr must be plausible bpm in \(rhrRange); got \(rhr)")
        }

        // ── Per-night HRV (RMSSD, ms) ≥ 0 — reachable via avgHrv on the day + each session ──
        let rmssd = try XCTUnwrap(d.avgHrv, "the RR stream must yield an avgHrv (RMSSD)")
        XCTAssertGreaterThanOrEqual(rmssd, 0, "avgHrv (RMSSD) must be non-negative ms; got \(rmssd)")
        XCTAssertLessThan(rmssd, 500, "avgHrv (RMSSD) must be a plausible ms value (< 500), not a mis-scaled figure; got \(rmssd)")
        for s in result.cachedSleep {
            if let sh = s.avgHrv {
                XCTAssertGreaterThanOrEqual(sh, 0, "CachedSleepSession.avgHrv (RMSSD) must be non-negative ms; got \(sh)")
            }
        }
    }

    // MARK: - 2) DemoSeed rows — the shapes the simulator dashboard actually renders

    func testDemoSeedRowsHonorScaleContracts() async throws {
        let store = try await StrapStore.inMemory()
        try await DemoSeed.seed(into: store)
        let whoop = "my-whoop"

        // ── Daily rows ──
        let rows = try await store.dailyMetrics(deviceId: whoop, from: "0000-01-01", to: "9999-12-31")
        XCTAssertFalse(rows.isEmpty, "DemoSeed must write daily rows")
        for r in rows {
            if let eff = r.efficiency {
                XCTAssert(efficiencyRange.contains(eff),
                          "DemoSeed DailyMetric.efficiency must be a 0–1 FRACTION, NOT a 0–100 percent (the 8310 % regression); got \(eff) on \(r.day)")
            }
            if let recovery = r.recovery {
                XCTAssert(scoreRange.contains(recovery), "Charge/recovery must be 0–100; got \(recovery) on \(r.day)")
            }
            if let strain = r.strain {
                XCTAssert(scoreRange.contains(strain), "Effort/strain must be 0–100; got \(strain) on \(r.day)")
            }
            if let spo2 = r.spo2Pct {
                XCTAssert(scoreRange.contains(spo2), "SpO₂ must be a 0–100 percent (or nil); got \(spo2) on \(r.day)")
            }
            if let dev = r.skinTempDevC {
                XCTAssert(skinDevBand.contains(dev),
                          "skinTempDevC must be a small signed °C DEVIATION in \(skinDevBand); got \(dev) on \(r.day)")
            }
            if let resp = r.respRateBpm {
                XCTAssert(respRange.contains(resp), "respRateBpm must be plausible breaths/min in \(respRange); got \(resp) on \(r.day)")
            }
            if let rhr = r.restingHr {
                XCTAssert(rhrRange.contains(rhr), "restingHr must be plausible bpm in \(rhrRange); got \(rhr) on \(r.day)")
            }
        }

        // ── Per-session cache rows: efficiency is a 0–1 FRACTION (the exact "8310 %" tripwire) ──
        let sessions = try await store.sleepSessions(deviceId: whoop, from: 0, to: Int(Date().timeIntervalSince1970) + 86_400, limit: 4000)
        XCTAssertFalse(sessions.isEmpty, "DemoSeed must write sleep sessions")
        for s in sessions {
            if let se = s.efficiency {
                XCTAssert(efficiencyRange.contains(se),
                          "DemoSeed CachedSleepSession.efficiency must be a 0–1 FRACTION (seeding a percent here double-scales to \"8310 %\"); got \(se)")
            }
            if let sh = s.avgHrv {
                XCTAssertGreaterThanOrEqual(sh, 0, "session avgHrv (RMSSD) must be non-negative ms; got \(sh)")
            }
        }

        // ── The persisted Rest series (`sleep_performance`) is a 0–100 score ──
        let rest = try await store.metricSeries(deviceId: whoop, key: "sleep_performance", from: "0000-01-01", to: "9999-12-31")
        XCTAssertFalse(rest.isEmpty, "DemoSeed must write a sleep_performance series")
        for p in rest {
            XCTAssert(scoreRange.contains(p.value),
                      "sleep_performance (Rest) must be a 0–100 score; got \(p.value) on \(p.day)")
        }
    }
}
