import SwiftUI
import StrapAnalytics

/// The opt-in "Looks like a workout?" suggestion on Today — Today's "Detected" section, one open row
/// (never a card), gated on Settings → Preferences → "Suggest detected workouts" AND a non-empty
/// `WorkoutRepository.autoDetectCandidates()` queue. The row holds the FULL queue (newest first) and
/// shows its head; saving or dismissing advances to the next suggestion immediately — no waiting for
/// new HR. It only ever SUGGESTS: Save creates a manual-style "Workout" for the window; "Not a
/// workout" dismisses it durably so it never re-prompts.
///
/// Layout (037, the Line rows): the question over the window's clock and length on the leading
/// side, the bout's average heart rate as a numeral in the Effort color trailing (bpm is Effort's
/// data), and the two actions as quiet text buttons beneath — "Save it" in ink, "Not a workout" in
/// secondary ink.
struct AutoWorkoutRow: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var workoutRepo: WorkoutRepository

    /// Read the toggle here too so the row disappears the instant it's switched off.
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectEnabled = false

    /// The production suggestion queue, newest first (`WorkoutRepository.autoDetectCandidates()`).
    @State private var queue: [DetectedWorkout] = []
    /// Spans saved or dismissed THIS session — the synchronous hide: the head advances the instant
    /// the user acts, before the durable write + queue refetch land. Filtered by OVERLAP (not
    /// identity) so a just-saved span also hides any queued candidate it covers, exactly like the
    /// refetch will once the saved row is visible to the pipeline.
    @State private var handledSpans: [(start: Int, end: Int)] = []
    @State private var saving = false
    /// Stale-drop stamp for `reload()` — the view-side spelling of `Core/Concurrency/Generation.swift`'s
    /// claim/check, the same guard `WorkoutRepository.refresh()` runs one layer down, and the same
    /// `loadGen` idiom the Signal Lab panels use for their heavy reads.
    ///
    /// WHY this row needs one. `reload()` has THREE callers that can be in flight AT THE SAME TIME: the
    /// `.task(id:)` below (raw-HR watermark / toggle), `save()`'s unstructured `Task`, and `dismiss()`'s.
    /// Nothing serialises them. `autoDetectCandidates()` suspends repeatedly before it returns — the
    /// bucketed HR read, the 30-day saved-workout read, then a `Task.detached` fold over up to ~120k
    /// points — and `Task.detached` is deliberately NOT cancellation-linked to this view's `.task`, so
    /// SwiftUI cancelling the old task on an id bump does not stop that body from running to completion
    /// and assigning `queue`. Two independent detached passes also carry no ordering guarantee between
    /// them, so the later-STARTED reload can be the earlier to FINISH.
    ///
    /// Without the stamp the last write wins regardless of which read was fresher, and a reload that
    /// began before a save/dismiss/HR-growth landed can overwrite the queue computed after it. The
    /// visible damage is a suggestion going missing: `handledSpans` still hides anything acted on this
    /// session, so the failure mode is not a resurrected candidate but a REAL new bout the fresher pass
    /// found being replaced by an older queue that predates it — and nothing re-fires until the next
    /// watermark bump, which can be hours away on a strap that is not syncing.
    @State private var reloadGen = 0

    /// The first queue entry not overlapping a span already handled this session.
    private var visibleHead: DetectedWorkout? {
        queue.first { w in
            !handledSpans.contains { w.startSec < $0.end && $0.start < w.endSec }
        }
    }

    var body: some View {
        Group {
            if autoDetectEnabled, let w = visibleHead {
                RuleSection("Detected") {
                    row(for: w)
                }
            }
        }
        // Key the heavy detector reload on the raw-HR watermark, NOT `refreshSeq` (P5): `reload()` reads
        // ~120k bucketed HR points + resolves 30 days of workouts + runs both detectors, so it must re-run
        // only when raw HR actually grew — not on every daily/score/sleep change a `refreshSeq` bump covers.
        // Save/dismiss hide the head synchronously (`handledSpans`) and then refetch the queue themselves
        // (the new saved row / dismissed span must suppress overlapping candidates), so losing the
        // per-refresh re-fire costs nothing there.
        .task(id: LoadKey(watermark: repo.hrWatermark, enabled: autoDetectEnabled)) { await reload() }
    }

    private func row(for w: DetectedWorkout) -> some View {
        // Formatted once: the visible line and the spoken label read the same string.
        let prompt = promptText(w)
        return VStack(alignment: .leading, spacing: WM.Space.xs) {
            HStack(alignment: .center, spacing: WM.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Looks like a workout")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(WM.Ground.ink)
                    Text(prompt)
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: WM.Space.s)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(w.avgBpm)")
                        .font(WMType.numeral(28))
                        .foregroundStyle(WM.Domain.effort.color)
                    Text("avg bpm")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            // One element for the reading; the two buttons below stay their own elements.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Looks like a workout, \(prompt), average \(w.avgBpm) beats per minute")

            HStack(spacing: WM.Space.sectionTight) {
                actionButton("Save it", color: saving ? WM.Ground.inkTertiary : WM.Ground.ink) { save(w) }
                actionButton("Not a workout", color: WM.Ground.inkSecondary) { dismiss(w) }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// A quiet text action (the `WMSecondaryButton` metrics, sized to its word): 15 semibold rounded,
    /// flush-left in a ≥44pt hit box so the word lines up with the text above it.
    private func actionButton(_ title: String, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving)
    }

    /// "14:05–14:32 · 27 min" (today), with a "Yesterday, " / dated prefix for older bouts.
    private func promptText(_ w: DetectedWorkout) -> String {
        let startDate = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        let start = Self.timeFmt.string(from: startDate)
        let end = Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(w.endSec)))
        let cal = Calendar.current
        let when: String
        if cal.isDateInToday(startDate) { when = "" }
        else if cal.isDateInYesterday(startDate) { when = "Yesterday, " }
        else { when = "\(Self.dateFmt.string(from: startDate)), " }
        return "\(when)\(start)–\(end) · \(w.durationMin) min"
    }

    /// Refetch the suggestion queue, newest-caller-wins. `@MainActor` for the reason
    /// `Generation.swift` gives: the claim and the check are the two halves of ONE decision, and actor
    /// isolation is what makes the claim atomic — two reloads must never read-then-bump across each
    /// other. It codifies where this body already ran (every line touches `@State` or the `@MainActor`
    /// `WorkoutRepository`); it does not move any work onto the UI actor that wasn't there.
    @MainActor
    private func reload() async {
        // CLAIM synchronously, before the first await AND before the disabled early-out. Stamping the
        // toggle-off path too is deliberate: it does no work, but it must still invalidate an older
        // enabled reload that is mid-resolve, or that reload lands afterwards and refills `queue`
        // behind a row the toggle has already hidden — stale candidates waiting to flash on the next
        // switch-on. Wrapping add per `Generation`: the counter only has to separate CONCURRENT
        // reloads, so overflow is a trap this can never usefully take.
        reloadGen &+= 1
        let gen = reloadGen
        guard autoDetectEnabled else { queue = []; return }
        let fresh = await workoutRepo.autoDetectCandidates()
        // CHECK after the awaits: a newer reload claimed a higher stamp while this one resolved, which
        // means this result is now the OLDER read no matter which of the two finished first. Drop it
        // rather than publish it over the fresher queue. Detection itself is untouched — this only
        // decides whose already-computed answer is allowed to become the visible one.
        guard gen == reloadGen else { return }
        queue = fresh
    }

    private func save(_ w: DetectedWorkout) {
        saving = true
        handledSpans.append((w.startSec, w.endSec))   // synchronous hide + advance
        Task {
            _ = await workoutRepo.saveDetectedWorkout(w)
            // Refetch AFTER the save landed: the new saved span must suppress any queued candidate
            // that overlaps it, and the next survivor becomes the head.
            await reload()
            // Unconditional, and NOT stamp-guarded: both buttons are disabled while `saving`, so only
            // one save is ever in flight, and the flag has to clear even when a newer reload superseded
            // this one's queue — a dropped result must never leave the row's buttons dead.
            saving = false
        }
    }

    private func dismiss(_ w: DetectedWorkout) {
        workoutRepo.dismissDetectedSuggestion(w)      // durable, synchronous write
        handledSpans.append((w.startSec, w.endSec))   // synchronous hide + advance
        Task { await reload() }                        // dismissed span now filters the queue
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    private struct LoadKey: Equatable { let watermark: Repository.HRWatermark; let enabled: Bool }
}
