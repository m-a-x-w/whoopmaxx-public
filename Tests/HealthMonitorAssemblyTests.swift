import XCTest
import StrapAnalytics
@testable import whoopmaxx

/// Health-monitor wiring (007 F2): `ScoreEngine.healthMonitorResult` assembles the
/// `IllnessSignalEngine` Inputs/Context from one night's vitals + baselines. The ENGINE is already
/// tested in the package — these pin the app-side assembly: per-signal z via `Baselines.deviation`
/// (σ = 1.253 × spread), the NEGATED HRV z, the per-signal trusted gate, the primary
/// (HRV + RHR) `baselineTrusted` gate, and the journal-tag → confounder mapping.
final class HealthMonitorAssemblyTests: XCTestCase {

    // MARK: - Fixture baselines (personal means with realistic spreads; σ ≈ 1.253 × spread)

    private func state(_ mean: Double, spread: Double,
                       status: Baselines.BaselineStatus = .trusted) -> Baselines.BaselineState {
        Baselines.BaselineState(baseline: mean, spread: spread, nValid: status == .trusted ? 20 : 8,
                      nightsSinceUpdate: 0, status: status)
    }

    /// hrv 74 ± σ10, rhr 52 ± σ3, resp 14.4 ± σ0.7, skin 33.5 ± σ0.25 — all trusted.
    private func trustedBaselines() -> DayEngine.ProfileBaselines {
        DayEngine.ProfileBaselines(hrv: state(74, spread: 8),
                                         restingHR: state(52, spread: 2.4),
                                         resp: state(14.4, spread: 0.56),
                                         skinTemp: state(33.5, spread: 0.2))
    }

    /// A clear multi-signal anomaly night: RHR ≈ +3.7σ, HRV ≈ −2.8σ, resp ≈ +3.1σ, skin normal.
    private let anomalous = (hrv: 46.0, rhr: 63.0, resp: 16.6, skin: 33.5)

    // MARK: - Level assembly

    func testNormalNightIsQuiet() {
        let r = ScoreEngine.healthMonitorResult(hrv: 75, rhr: 52, resp: 14.3, skin: 33.5,
                                                baselines: trustedBaselines(), journalTags: [])
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.signalCount, 0)
        XCTAssertLessThan(r.score, IllnessSignalEngine.mildThreshold)
    }

    func testMultiSignalAnomalyRaises() {
        let r = ScoreEngine.healthMonitorResult(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                resp: anomalous.resp, skin: anomalous.skin,
                                                baselines: trustedBaselines(), journalTags: [])
        XCTAssertEqual(r.level, .raised)
        XCTAssertEqual(r.signalCount, 3, "RHR, HRV and respiration all clear z ≥ 2; skin is normal")
        XCTAssertGreaterThanOrEqual(r.score, IllnessSignalEngine.raiseThreshold)
    }

    func testHrvZIsNegated() {
        // An unusually HIGH HRV is the healthy direction — it must never count illness-ward…
        let high = ScoreEngine.healthMonitorResult(hrv: 102, rhr: nil, resp: nil, skin: nil,
                                                   baselines: trustedBaselines(), journalTags: [])
        XCTAssertEqual(high.signalCount, 0, "an HRV RISE must not fire the illness-ward signal")
        // …while the same-magnitude DROP does.
        let low = ScoreEngine.healthMonitorResult(hrv: 46, rhr: nil, resp: nil, skin: nil,
                                                  baselines: trustedBaselines(), journalTags: [])
        XCTAssertEqual(low.signalCount, 1, "an HRV drop of the same magnitude fires")
        XCTAssertEqual(low.level, .quiet, "one signal alone never clears the ≥2 corroboration gate")
    }

    func testUntrustedSignalBaselineExcludesThatSignal() {
        // Respiration's own baseline is only provisional → its (anomalous) value must not corroborate.
        let b = DayEngine.ProfileBaselines(hrv: state(74, spread: 8),
                                                 restingHR: state(52, spread: 2.4),
                                                 resp: state(14.4, spread: 0.56, status: .provisional),
                                                 skinTemp: nil)
        let r = ScoreEngine.healthMonitorResult(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                resp: anomalous.resp, skin: nil,
                                                baselines: b, journalTags: [])
        XCTAssertEqual(r.signalCount, 2, "resp must be dropped while its baseline is untrusted")
    }

    func testUntrustedPrimaryBaselineStaysQuiet() {
        // RHR (a primary lane) is only provisional → Context.baselineTrusted false → the engine
        // stays quiet no matter how loud the other signals read.
        let b = DayEngine.ProfileBaselines(hrv: state(74, spread: 8),
                                                 restingHR: state(52, spread: 2.4, status: .provisional),
                                                 resp: state(14.4, spread: 0.56),
                                                 skinTemp: nil)
        let r = ScoreEngine.healthMonitorResult(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                resp: anomalous.resp, skin: nil,
                                                baselines: b, journalTags: [])
        XCTAssertEqual(r.level, .quiet, "no warning off a cold-start primary baseline")
    }

    func testMissingVitalsStayQuiet() {
        let r = ScoreEngine.healthMonitorResult(hrv: nil, rhr: nil, resp: nil, skin: nil,
                                                baselines: trustedBaselines(), journalTags: [])
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.signalCount, 0)
        XCTAssertEqual(r.score, 0)
    }

    // MARK: - Journal-tag → confounder mapping

    func testAlcoholTagSuppressesAndDampens() {
        let raw = ScoreEngine.healthMonitorResult(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                  resp: anomalous.resp, skin: anomalous.skin,
                                                  baselines: trustedBaselines(), journalTags: [])
        let r = ScoreEngine.healthMonitorResult(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                resp: anomalous.resp, skin: anomalous.skin,
                                                baselines: trustedBaselines(),
                                                journalTags: [JournalTag.alcohol.rawValue])
        XCTAssertEqual(r.level, .suppressed)
        XCTAssertEqual(r.suppressedBy, ["alcohol"])
        XCTAssertEqual(r.score, raw.score * IllnessSignalEngine.confounderDampen, accuracy: 0.001,
                       "the suppressed score is the raw composite × the dampen factor")
    }

    func testWeedTagSuppressesAndDampens() {
        // 009: weed joined `Context` on alcohol's evening convention. It must dampen identically —
        // `confounderDampen` is a single factor, so "weed dampens as hard as alcohol" is a claim the
        // wave makes by omission, and this test is where it is stated.
        let raw = ScoreEngine.healthMonitorResult(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                  resp: anomalous.resp, skin: anomalous.skin,
                                                  baselines: trustedBaselines(), journalTags: [])
        let r = ScoreEngine.healthMonitorResult(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                resp: anomalous.resp, skin: anomalous.skin,
                                                baselines: trustedBaselines(),
                                                journalTags: [JournalTag.weed.rawValue])
        XCTAssertEqual(r.level, .suppressed)
        XCTAssertEqual(r.suppressedBy, ["weed"])
        XCTAssertEqual(r.score, raw.score * IllnessSignalEngine.confounderDampen, accuracy: 0.001)
    }

    func testConfounderListsAgreeWithEngine() {
        // `HealthMonitorModel.confounders(in:)` is a hand-maintained twin of the engine's literal
        // list (suppressedBy is never persisted, so the detail screen re-derives it). The two have
        // already drifted once. Run BOTH over every confounder tag and require exact agreement —
        // a tag the engine names but the app misses renders "you logged a logged behavior".
        let confounderTags: [JournalTag] = [.alcohol, .stress, .sauna, .weed, .travel]
        for tag in confounderTags {
            let r = ScoreEngine.healthMonitorResult(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                    resp: anomalous.resp, skin: anomalous.skin,
                                                    baselines: trustedBaselines(),
                                                    journalTags: [tag.rawValue])
            XCTAssertEqual(r.level, .suppressed, "\(tag.rawValue) must suppress")
            XCTAssertEqual(r.suppressedBy, HealthMonitorModel.confounders(in: [tag.rawValue]),
                           "the app's confounder list disagrees with the engine for \(tag.rawValue)")
        }
        // All at once, which is the only way the ORDER of the two lists is pinned — a single-tag
        // loop passes happily while the app renders "travel and weed" where the engine says
        // "weed and travel".
        let all = Set(confounderTags.map(\.rawValue))
        let r = ScoreEngine.healthMonitorResult(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                resp: anomalous.resp, skin: anomalous.skin,
                                                baselines: trustedBaselines(), journalTags: all)
        XCTAssertEqual(r.suppressedBy, ["alcohol", "stress", "sauna", "weed", "travel"])
        XCTAssertEqual(r.suppressedBy, HealthMonitorModel.confounders(in: all))
    }

    func testTravelTagKeyMapsToEngineConfounder() {
        // The "hard late workout" journal tag was removed; travel remains the workout-adjacent
        // confounder the journal still feeds.
        let r = ScoreEngine.healthMonitorResult(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                resp: anomalous.resp, skin: nil,
                                                baselines: trustedBaselines(),
                                                journalTags: [JournalTag.travel.rawValue])
        XCTAssertEqual(r.level, .suppressed)
        XCTAssertTrue(r.suppressedBy.contains("travel"),
                      "\"travel\" must land on Context.travelPhaseJump")
    }

    func testSickTagRoutesToAlreadyUnwell() {
        let r = ScoreEngine.healthMonitorResult(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                resp: anomalous.resp, skin: nil,
                                                baselines: trustedBaselines(),
                                                journalTags: [JournalTag.sick.rawValue])
        XCTAssertEqual(r.level, .alreadyUnwell, "\"sick\" is a rest-up hint, never a scare")
    }

    // MARK: - Night-context day join (tags are logged on the BEHAVIOR day; the night keyed D is
    // the night FOLLOWING day D-1 — the same lag-1 convention JournalInsightsTests pins)

    func testNightContextTagsReadThePreviousDaysBehaviors() {
        let tags: [String: Set<String>] = [
            "2026-07-10": [JournalTag.alcohol.rawValue],
            "2026-07-11": [JournalTag.sauna.rawValue],
        ]
        // Friday-night alcohol logged Friday (07-10) must context the Saturday-keyed night…
        let sat = ScoreEngine.nightContextTags(day: "2026-07-11", tagsByDay: tags)
        XCTAssertTrue(sat.contains(JournalTag.alcohol.rawValue),
                      "D-1's alcohol must dampen the night keyed D — the morning after a night "
                      + "out is exactly the false positive the confounders exist to prevent")
        // …and the Saturday-afternoon sauna must NOT suppress Saturday's already-completed night,
        XCTAssertFalse(sat.contains(JournalTag.sauna.rawValue),
                       "a same-day behavior tag postdates the night keyed that day")
        // but it DOES context the following (Sunday-keyed) night.
        let sun = ScoreEngine.nightContextTags(day: "2026-07-12", tagsByDay: tags)
        XCTAssertEqual(sun, [JournalTag.sauna.rawValue])
    }

    func testWeedContextsTheFollowingNightNotItsOwn() {
        // 009 deliberately did NOT extend `sick`'s D-1 ∪ D exception to weed: weed routes to
        // `.suppressed`, which HIDES a raised heads-up, so a Tuesday-afternoon session must not
        // explain away Tuesday morning's genuine illness signal.
        let tags: [String: Set<String>] = ["2026-07-10": [JournalTag.weed.rawValue]]
        XCTAssertFalse(ScoreEngine.nightContextTags(day: "2026-07-10", tagsByDay: tags)
                        .contains(JournalTag.weed.rawValue),
                       "a same-day weed log postdates the night keyed that day")
        XCTAssertTrue(ScoreEngine.nightContextTags(day: "2026-07-11", tagsByDay: tags)
                        .contains(JournalTag.weed.rawValue),
                      "D-1's weed contexts the night keyed D, exactly as alcohol does")
    }

    func testNightContextTagsJoinSickFromEitherDay() {
        // `sick` is a state, not an evening behavior — logged on D-1 OR D it must reach the
        // night keyed D so the gentle alreadyUnwell path routes.
        let sameDay = ScoreEngine.nightContextTags(
            day: "2026-07-11", tagsByDay: ["2026-07-11": [JournalTag.sick.rawValue]])
        XCTAssertTrue(sameDay.contains(JournalTag.sick.rawValue))
        let prevDay = ScoreEngine.nightContextTags(
            day: "2026-07-11", tagsByDay: ["2026-07-10": [JournalTag.sick.rawValue]])
        XCTAssertTrue(prevDay.contains(JournalTag.sick.rawValue))
    }

    // MARK: - Persisted per-signal fired bitmask (`strain_fired`)

    func testFiredMaskMatchesTheEnginesFiringSet() {
        // The anomalous fixture fires RHR + HRV + resp (skin normal) — the mask must carry
        // exactly those bits, so the detail screen's "Flagged" markers agree with signalCount.
        let inputs = ScoreEngine.healthMonitorInputs(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                     resp: anomalous.resp, skin: anomalous.skin,
                                                     baselines: trustedBaselines())
        XCTAssertEqual(StrainFiredMask.mask(of: inputs),
                       StrainFiredMask.restingHR | StrainFiredMask.hrv | StrainFiredMask.respiration)
        let quiet = ScoreEngine.healthMonitorInputs(hrv: 75, rhr: 52, resp: 14.3, skin: 33.5,
                                                    baselines: trustedBaselines())
        XCTAssertEqual(StrainFiredMask.mask(of: quiet), 0)
    }

    func testFiredMaskExcludesUntrustedSignals() {
        // Resp's baseline is provisional → its reading is absent → its bit must not set.
        let b = DayEngine.ProfileBaselines(hrv: state(74, spread: 8),
                                                 restingHR: state(52, spread: 2.4),
                                                 resp: state(14.4, spread: 0.56, status: .provisional),
                                                 skinTemp: nil)
        let inputs = ScoreEngine.healthMonitorInputs(hrv: anomalous.hrv, rhr: anomalous.rhr,
                                                     resp: anomalous.resp, skin: nil, baselines: b)
        XCTAssertEqual(StrainFiredMask.mask(of: inputs),
                       StrainFiredMask.restingHR | StrainFiredMask.hrv)
    }

    // MARK: - StrainLevel codec

    func testStrainLevelCodecOrdersLevels() {
        XCTAssertEqual(StrainLevel(.quiet), .quiet)
        XCTAssertEqual(StrainLevel(.mild), .mild)
        XCTAssertEqual(StrainLevel(.raised), .raised)
        XCTAssertEqual(StrainLevel(.suppressed), .suppressed)
        XCTAssertEqual(StrainLevel(.alreadyUnwell), .alreadyUnwell)
        XCTAssertTrue(StrainLevel.quiet < .mild && StrainLevel.mild < .raised,
                      "the Today banner gates on level >= .mild")
    }
}
