import XCTest
import StrapAnalytics
@testable import whoopmaxx

/// Pure targeted tests for the Breathe pacing core (W10). No BLE / SwiftUI: the preset math, the
/// felt-language mapping, the two-phase parity with the vendored `BreathPacer` (which stays canonical),
/// the hold-preset onset shape, and the `BreathePrefs` round-trip. The clock/teardown itself is exercised
/// in the simulator.
final class BreathPatternTests: XCTestCase {

    // MARK: - Preset cycle / bpm math

    func testPresetCycleSecondsIsSumOfPhases() {
        for p in BreathPattern.all {
            XCTAssertEqual(p.cycleSeconds, p.inhale + p.holdFull + p.exhale + p.holdEmpty, accuracy: 1e-9)
        }
    }

    func testRelaxIsSixBreathsPerMinute() {
        XCTAssertEqual(BreathPattern.relax.cycleSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(BreathPattern.relax.bpm, 6.0, accuracy: 1e-9)
    }

    func testCoherenceIsAboutFiveAndAHalfBreathsPerMinute() {
        // 5.5 + 5.5 = 11 s → 60/11 ≈ 5.4545 br/min (the "~5.5" coherence pace).
        XCTAssertEqual(BreathPattern.coherence.cycleSeconds, 11, accuracy: 1e-9)
        XCTAssertEqual(BreathPattern.coherence.bpm, 60.0 / 11.0, accuracy: 1e-9)
        XCTAssertEqual(BreathPattern.coherence.bpm, 5.5, accuracy: 0.05)
    }

    func testBoxCycleAndRate() {
        // 4-4-4-4 = 16 s → 3.75 br/min. (The Box preset trades rate for the HOLD it exercises.)
        XCTAssertEqual(BreathPattern.box.cycleSeconds, 16, accuracy: 1e-9)
        XCTAssertEqual(BreathPattern.box.bpm, 3.75, accuracy: 1e-9)
    }

    // MARK: - Phase walk (zero-length holds skipped)

    func testTwoPhasePresetsSkipZeroLengthHolds() {
        XCTAssertEqual(BreathPattern.relax.steps.map(\.phase), [.inhale, .exhale])
        XCTAssertEqual(BreathPattern.coherence.steps.map(\.phase), [.inhale, .exhale])
    }

    func testBoxKeepsAllFourPhases() {
        XCTAssertEqual(BreathPattern.box.steps.map(\.phase), [.inhale, .holdFull, .exhale, .holdEmpty])
        for step in BreathPattern.box.steps {
            XCTAssertEqual(step.duration, 4, accuracy: 1e-9)
        }
    }

    // MARK: - Felt-language mapping (vendored BreathPacer is the source of truth)

    func testFeltLanguageMatchesBreathPacerConstants() {
        XCTAssertEqual(BreathPacer.inhaleLoops, 1)
        XCTAssertEqual(BreathPacer.exhaleLoops, 2)
        XCTAssertEqual(BreathPhaseWM.inhale.buzzLoops, 1)   // one pulse in
        XCTAssertEqual(BreathPhaseWM.exhale.buzzLoops, 2)   // two pulses out
        XCTAssertNil(BreathPhaseWM.holdFull.buzzLoops)      // holds are silent
        XCTAssertNil(BreathPhaseWM.holdEmpty.buzzLoops)
    }

    // MARK: - Two-phase parity with BreathPacer (offsets/phase/loops must agree)

    func testRelaxOnsetsMatchBreathPacer() { assertParity(.relax, cycles: 3) }
    func testCoherenceOnsetsMatchBreathPacer() { assertParity(.coherence, cycles: 3) }

    /// For a two-phase preset, the controller's derived onset schedule must equal `BreathPacer.schedule`
    /// for the same pace (bpm + inhale fraction), N cycles — the vendored pacer stays canonical.
    private func assertParity(_ pattern: BreathPattern, cycles: Int,
                              file: StaticString = #filePath, line: UInt = #line) {
        let mine = pattern.hapticOnsets(cycles: cycles)
        let frac = pattern.inhale / pattern.cycleSeconds
        let pacer = BreathPacer.schedule(bpm: pattern.bpm, inhaleFraction: frac, cycles: cycles)

        XCTAssertEqual(mine.count, pacer.count, file: file, line: line)
        for (a, b) in zip(mine, pacer) {
            XCTAssertEqual(a.offsetMs, b.offsetMs, file: file, line: line)
            XCTAssertEqual(a.loops, b.loops, file: file, line: line)
            XCTAssertEqual(a.phase.rawValue, b.phase.rawValue, file: file, line: line) // inhale/exhale
        }
    }

    // MARK: - Hold preset: one inhale + one exhale onset per cycle, zero buzz during holds

    func testBoxYieldsOnlyInhaleAndExhaleOnsets() {
        let cycles = 3
        let onsets = BreathPattern.box.hapticOnsets(cycles: cycles)
        XCTAssertEqual(onsets.count, 2 * cycles)   // no hold buzzes
        XCTAssertEqual(onsets.filter { $0.phase == .inhale }.count, cycles)
        XCTAssertEqual(onsets.filter { $0.phase == .exhale }.count, cycles)
        XCTAssertTrue(onsets.allSatisfy { $0.phase == .inhale || $0.phase == .exhale })
        for o in onsets where o.phase == .inhale { XCTAssertEqual(o.loops, 1) }
        for o in onsets where o.phase == .exhale { XCTAssertEqual(o.loops, 2) }
        // Onsets are strictly time-ordered and land at the expected cycle offsets (16 s cycle, exhale @ +8 s).
        XCTAssertEqual(onsets.map(\.offsetMs), [0, 8000, 16000, 24000, 32000, 40000])
    }

    // MARK: - BreathePrefs round-trip + first-launch defaults

    func testBreathePrefsDefaultsAndRoundTrip() {
        let d = UserDefaults.standard
        let savedPreset = d.object(forKey: BreathePrefs.Key.preset)
        let savedHaptics = d.object(forKey: BreathePrefs.Key.haptics)
        defer {
            if let savedPreset { d.set(savedPreset, forKey: BreathePrefs.Key.preset) }
            else { d.removeObject(forKey: BreathePrefs.Key.preset) }
            if let savedHaptics { d.set(savedHaptics, forKey: BreathePrefs.Key.haptics) }
            else { d.removeObject(forKey: BreathePrefs.Key.haptics) }
        }

        // First-launch defaults: haptics on, preset Coherence.
        d.removeObject(forKey: BreathePrefs.Key.preset)
        d.removeObject(forKey: BreathePrefs.Key.haptics)
        XCTAssertEqual(BreathePrefs.presetName, BreathPattern.coherence.name)
        XCTAssertTrue(BreathePrefs.hapticsEnabled)
        XCTAssertEqual(BreathePrefs.pattern, .coherence)

        // Round-trip.
        BreathePrefs.presetName = BreathPattern.box.name
        BreathePrefs.hapticsEnabled = false
        XCTAssertEqual(BreathePrefs.presetName, "Box")
        XCTAssertEqual(BreathePrefs.pattern, .box)
        XCTAssertFalse(BreathePrefs.hapticsEnabled)
    }

    // MARK: - Controller lifecycle (single in-flight work item; clean stop / background teardown)

    @MainActor
    func testStartSchedulesExactlyOnePhaseWorkAndStopClearsIt() {
        let c = BreathController()   // no configure() — canBuzz is false, so no BLE is touched
        XCTAssertFalse(c.isPhaseWorkScheduled)

        c.start(pattern: .coherence)
        XCTAssertTrue(c.running)
        // The pace clock holds exactly one in-flight advance (never an ever-growing array).
        XCTAssertTrue(c.isPhaseWorkScheduled)

        // Stop (the same path scenePhase .background calls) tears everything down and resets state.
        c.stop()
        XCTAssertFalse(c.running)
        XCTAssertFalse(c.isPhaseWorkScheduled)
        XCTAssertEqual(c.phase, .inhale)
        XCTAssertEqual(c.expansionTarget, 0)
        XCTAssertEqual(c.phaseDuration, 0)
    }

    @MainActor
    func testStopIsIdempotent() {
        let c = BreathController()
        c.start(pattern: .box)
        c.stop()
        c.stop()   // second stop must not crash or re-arm anything
        XCTAssertFalse(c.running)
        XCTAssertFalse(c.isPhaseWorkScheduled)
    }
}
