import Foundation
import StrapAnalytics

// BreathPattern.swift — the pure, unit-testable core of the Breathe session: the preset model, the
// four-phase pacing math, and the slim UserDefaults prefs. No SwiftUI, no BLE — the felt-language
// constants come straight from the vendored `BreathPacer` (StrapAnalytics), so the strap buzz the
// controller fires and the pace the screen draws share one source of truth.
//
// Ported (logic only) from the original's fixed-pace Breathe path (`BreathingView.Pace` + `BiofeedbackPrefs`).
// Unlike the original two-phase pace, this carries a real four-phase model (inhale · hold-full · exhale ·
// hold-empty) so the Box preset can exercise the HOLD phase; a zero-length hold is simply skipped, so
// the two-phase presets (Relax, Coherence) behave exactly as the original did.

/// One phase of a paced breath. Local to whoopmaxx (the original `Phase` was inhale/exhale only).
enum BreathPhaseWM: String, Equatable, Sendable {
    case inhale
    case holdFull
    case exhale
    case holdEmpty

    /// The on-screen phase word below the column.
    var word: String {
        switch self {
        case .inhale:              return "Breathe in"
        case .holdFull, .holdEmpty: return "Hold"
        case .exhale:              return "Breathe out"
        }
    }

    /// Where the column fill rests during (and at the end of) this phase: full on the inhale/hold-full,
    /// empty on the exhale/hold-empty. The caller animates the fill toward this over the phase duration.
    var expansionTarget: Double {
        switch self {
        case .inhale, .holdFull:   return 1
        case .exhale, .holdEmpty:  return 0
        }
    }

    /// Haptic loops fired at this phase's ONSET — the felt language, taken verbatim from `BreathPacer`
    /// (1 pulse in, 2 pulses out). Holds are silent (`nil`): no buzz mid-hold.
    var buzzLoops: Int? {
        switch self {
        case .inhale:              return BreathPacer.inhaleLoops   // 1
        case .exhale:              return BreathPacer.exhaleLoops   // 2
        case .holdFull, .holdEmpty: return nil
        }
    }
}

/// A breathing preset: the four phase durations (seconds) plus a display name + tagline. Pure value;
/// `cycleSeconds` / `bpm` derive from the durations, and `steps` is the ordered non-empty phase walk.
struct BreathPattern: Equatable, Sendable {
    let name: String
    let inhale: Double
    let holdFull: Double
    let exhale: Double
    let holdEmpty: Double
    let tagline: String

    /// One full breath in seconds.
    var cycleSeconds: Double { inhale + holdFull + exhale + holdEmpty }
    /// Breaths per minute (60 / cycle). Coherence's 5.5-0-5.5-0 is ~5.45 br/min (spec's "~5.5").
    var bpm: Double { cycleSeconds > 0 ? 60.0 / cycleSeconds : 0 }

    /// One element of the phase walk: which phase, how long, and the buzz loops at its onset (nil = hold).
    struct Step: Equatable, Sendable {
        let phase: BreathPhaseWM
        let duration: Double
        let loops: Int?
    }

    /// The ordered phases of one cycle with a non-zero duration — zero-length holds are dropped so the
    /// clock never schedules a zero-delay step (Relax/Coherence collapse to inhale → exhale, as the original).
    var steps: [Step] {
        var out: [Step] = []
        func add(_ phase: BreathPhaseWM, _ dur: Double) {
            guard dur > 0 else { return }
            out.append(Step(phase: phase, duration: dur, loops: phase.buzzLoops))
        }
        add(.inhale, inhale)
        add(.holdFull, holdFull)
        add(.exhale, exhale)
        add(.holdEmpty, holdEmpty)
        return out
    }

    /// Deterministic haptic onset schedule for `cycles` breaths: `(offsetMs, phase, loops)` per BUZZING
    /// onset (holds omitted), computed the exact integer-ms way `BreathController` fires them. Pinned in
    /// tests against `BreathPacer.schedule` for the two-phase presets so the vendored pacer stays canonical.
    func hapticOnsets(cycles: Int) -> [(offsetMs: Int, phase: BreathPhaseWM, loops: Int)] {
        guard cycles >= 1 else { return [] }
        let cycleMs = Int((cycleSeconds * 1000).rounded())
        var out: [(offsetMs: Int, phase: BreathPhaseWM, loops: Int)] = []
        for c in 0..<cycles {
            let base = c * cycleMs
            var t = 0.0
            for step in steps {
                if let loops = step.loops {
                    out.append((offsetMs: base + Int((t * 1000).rounded()), phase: step.phase, loops: loops))
                }
                t += step.duration
            }
        }
        return out
    }

    // MARK: - Presets (the 3 that ship; 4-7-8 + custom deferred)

    /// Long exhale — downshifts to rest. 6 br/min.
    static let relax = BreathPattern(name: "Relax", inhale: 4, holdFull: 0, exhale: 6, holdEmpty: 0,
                                     tagline: "Long exhale · downshift to rest")
    /// Equal breath — the ~5.5 br/min coherence pace.
    static let coherence = BreathPattern(name: "Coherence", inhale: 5.5, holdFull: 0, exhale: 5.5, holdEmpty: 0,
                                         tagline: "Equal breath · ~5.5 br/min")
    /// Square breath — exercises the hold. 3.75 br/min.
    static let box = BreathPattern(name: "Box", inhale: 4, holdFull: 4, exhale: 4, holdEmpty: 4,
                                   tagline: "Square breath · steady focus")

    static let all: [BreathPattern] = [.relax, .coherence, .box]

    /// The preset with `name`, or Coherence if unknown (a moved/renamed pref falls back gracefully).
    static func named(_ name: String) -> BreathPattern {
        all.first { $0.name == name } ?? .coherence
    }
}

/// Slim on-device prefs for Breathe (UserDefaults, `wm.breathe.*`) — the last-used preset + the haptics
/// toggle, restored when the cover opens. Ports only the read/write pattern from the original's `BiofeedbackPrefs`
/// (the resonance-lock / stress / quiet-hours keys are all deferred).
enum BreathePrefs {
    private static var store: UserDefaults { .standard }

    enum Key {
        static let preset  = "wm.breathe.preset"
        static let haptics = "wm.breathe.haptics"
    }

    /// Last-used preset name; defaults to Coherence on a fresh install (parity with the original).
    static var presetName: String {
        get { store.string(forKey: Key.preset) ?? BreathPattern.coherence.name }
        set { store.set(newValue, forKey: Key.preset) }
    }

    /// The resolved last-used pattern.
    static var pattern: BreathPattern { BreathPattern.named(presetName) }

    /// Whether strap-haptic pacing is armed. Defaults ON (manual-first, but haptics are the felt point).
    static var hapticsEnabled: Bool {
        get { store.object(forKey: Key.haptics) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.haptics) }
    }
}
