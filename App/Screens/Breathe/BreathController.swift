import Foundation
import Combine
import SwiftUI
import UIKit

// BreathController.swift — the whoopmaxx slim port of the original's `BiofeedbackController` fixed-pace path.
// It is the SINGLE pace clock: one cancellable `asyncAfter` phase chain (ported from `walkCues`) drives
// the published phase / expansion target / phase duration that the column animates AND fires the optional
// strap buzz on the same phase-onset item — so the visual fill and the felt pulse can never drift.
//
// Dropped from the original: the resonance sweep (L1), the "Calm me" metronome (L2), the RMSSD outcome capture,
// and the bond-drop hard-stop (breathing is visual-first, so a mid-session bond drop keeps pacing
// visually and only stops the buzz). Kept: the cancellable schedule, the 1 Hz elapsed timer, the
// `canBuzz = bonded && encryptedBond` gate, the `runHapticsPattern` buzz, and the idempotent teardown
// (cancel every pending pulse + `stopHaptics` + restore the idle timer).
@MainActor
final class BreathController: ObservableObject {

    // MARK: - Published session state (BreatheScreen reads these)

    /// The current breath phase (drives the phase word).
    @Published private(set) var phase: BreathPhaseWM = .inhale
    /// Where the column fill should be (0 empty … 1 full); the view animates toward it over `phaseDuration`.
    @Published private(set) var expansionTarget: Double = 0
    /// Duration of the current phase (seconds) — the fill's animation length.
    @Published private(set) var phaseDuration: Double = 0
    /// Seconds since the session started.
    @Published private(set) var elapsedSeconds: Int = 0
    /// Completed breaths this session.
    @Published private(set) var breathCount: Int = 0
    /// True while a session is live.
    @Published private(set) var running = false

    // MARK: - Dependencies (built lazily from the environment, like the original ControllerBox)

    private weak var ble: BLEManager?
    private weak var live: LiveState?

    // MARK: - Clock

    private var steps: [BreathPattern.Step] = []
    private var stepIndex = 0
    /// The single in-flight phase-advance work item — at most one is ever scheduled (each `beginStep()`
    /// replaces it; `stop()` / `retarget()` cancel it), so a long session never accumulates dead items.
    private var phaseWork: DispatchWorkItem?
    private var secondTimer: AnyCancellable?

    /// Test hook: whether a phase advance is currently scheduled (at most one — never an array).
    var isPhaseWorkScheduled: Bool { phaseWork != nil }

    /// Wire the strap seam once the cover appears. Weak refs — AppRoot owns both for the process lifetime.
    func configure(ble: BLEManager, live: LiveState) {
        self.ble = ble
        self.live = live
    }

    /// Can we actually buzz the strap? Haptic pacing is gated on a genuine encrypted bond (the buzz
    /// channel). Visual-only otherwise — the column + phase word carry the breath (sim is always here).
    var canBuzz: Bool { (live?.bonded ?? false) && (live?.encryptedBond ?? false) }

    /// mm:ss for the elapsed readout.
    var elapsedText: String { String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60) }

    // MARK: - Session control

    /// Start pacing `pattern`. Resets counters, holds the screen awake for the hands-free session, and
    /// arms the first phase (inhale onset buzz). `stop()` first, so a restart never leaks a prior clock.
    func start(pattern: BreathPattern) {
        stop()
        steps = pattern.steps
        guard !steps.isEmpty else { return }
        running = true
        breathCount = 0
        stepIndex = 0
        UIApplication.shared.isIdleTimerDisabled = true   // keep-awake, scoped to the live session
        startSecondTimer()
        beginStep()
    }

    /// Swap the pace WITHOUT ending the session (a preset tap mid-run): cancel the pending advance and
    /// re-arm from inhale, keeping the elapsed clock and breath count. No-op when idle.
    func retarget(to pattern: BreathPattern) {
        guard running else { return }
        cancelPending()
        steps = pattern.steps
        guard !steps.isEmpty else { stop(); return }
        stepIndex = 0
        beginStep()
    }

    /// Stop everything, cancel every queued pulse, clear a wedged strap buzz, restore auto-lock.
    /// Idempotent — Stop, the X close, a swipe-dismiss, and `onDisappear` all funnel here safely.
    func stop() {
        let wasRunning = running
        cancelPending()
        secondTimer?.cancel()
        secondTimer = nil
        // #769 parity: cancelling our items halts NEW pulses but can't recall one the strap is mid-pattern
        // on; tell it to stop haptics too (best-effort — no-op unbonded / on a 5/MG). Only when we buzzed.
        if wasRunning { ble?.send(.stopHaptics, payload: [0x00]) }
        UIApplication.shared.isIdleTimerDisabled = false
        running = false
        phase = .inhale
        expansionTarget = 0
        phaseDuration = 0
    }

    // MARK: - Phase clock (the cancellable asyncAfter walk, ported from walkCues)

    /// Arm the current step: publish its phase/expansion/duration, fire its onset buzz, and schedule the
    /// advance after its duration.
    private func beginStep() {
        let step = steps[stepIndex]
        phase = step.phase
        phaseDuration = step.duration
        expansionTarget = step.phase.expansionTarget
        if let loops = step.loops { fireBuzz(loops: loops) }

        // Replace (never append) the in-flight item: the just-fired one that called us is already done,
        // and cancelling it is a harmless no-op — the array could only ever grow, this can't.
        phaseWork?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.advance() }
        phaseWork = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int((step.duration * 1000).rounded())), execute: item)
    }

    /// Advance to the next phase; wrapping past the last phase completes one breath.
    private func advance() {
        guard running else { return }
        stepIndex += 1
        if stepIndex >= steps.count {
            stepIndex = 0
            breathCount += 1
        }
        beginStep()
    }

    /// Fire the proven strap buzz (`runHapticsPattern`, patternId 2). Gated on the encrypted bond AND the
    /// user's persisted haptics toggle (read live, so muting mid-session takes effect at once). No-op on sim.
    private func fireBuzz(loops: Int) {
        guard canBuzz, BreathePrefs.hapticsEnabled else { return }
        ble?.send(.runHapticsPattern, payload: [2, UInt8(clamping: loops), 0, 0, 0])
    }

    private func startSecondTimer() {
        elapsedSeconds = 0
        secondTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.elapsedSeconds += 1 }
    }

    private func cancelPending() {
        phaseWork?.cancel()
        phaseWork = nil
    }
}
