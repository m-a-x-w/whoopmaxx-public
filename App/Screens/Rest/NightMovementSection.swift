import SwiftUI
import StrapProtocol
import StrapAnalytics

/// Night detail's "Movement" section — the Sleep Seismograph: a night's raw body movement drawn as one
/// lane per clock hour (bed→wake), each an ink needle deflecting off a hairline baseline, quiet stretches
/// reading as a near-flat line. Under the lanes, the readouts (stirs, stillest stretch) and a footnote
/// naming the quietest span and the source.
///
/// A PURE render of a prebuilt `NightTape` — no store, no BLE. `NightDetailScreen` reads the night's raw
/// gravity (or the per-epoch motion fallback) once and hands the tape in. Movement is not a
/// Charge/Effort/Rest domain, so the whole section is neutral ink — no fabricated color.
struct NightMovementContent: View {
    let tape: NightTape?
    /// Whether the read has finished; before it has, the section says it is reading rather than
    /// claiming an absence.
    let loaded: Bool
    /// The night's `yyyy-MM-dd` key, for the raw-retention horizon test. nil — the specimen previews —
    /// keeps the original empty-state sentence, which is correct for a night inside the horizon.
    /// REQUIRED, deliberately no default: this argument decides whether the section is allowed to
    /// state a finding about a night whose raw signal was pruned. It shipped WITH a default once, the
    /// single production call site omitted it, and the whole aged-out state was unreachable in the
    /// binary while its unit tests stayed green. Every caller now has to say which night it means,
    /// even if the answer is nil (the specimen previews) — the compiler is the only thing that
    /// actually catches a dropped argument here.
    let dayKey: String?

    @State private var selectedHour: Int?

    init(tape: NightTape?, loaded: Bool, dayKey: String?) {
        self.tape = tape
        self.loaded = loaded
        self.dayKey = dayKey
    }

    var body: some View {
        if let tape, !tape.isEmpty {
            RuleSection("Movement \u{00B7} one line per hour", topGap: WM.Space.sectionTight) {
                VStack(alignment: .leading, spacing: 0) {
                    DrumTape(lanes: tape.lanes, selectedHour: $selectedHour)
                    selectionReadout(tape)
                    readouts(tape.analysis)
                        .padding(.top, WM.Space.l)
                }
                .wmAnimation(WMMotion.transition, value: selectedHour)
            }
        } else {
            RuleSection("Movement", topGap: WM.Space.sectionTight) {
                // Before the async read resolves: a calm line, no spinner chrome.
                Text(loaded ? Self.emptyLine(dayKey: dayKey) : "Reading the night\u{2026}")
                    .font(WMType.body)
                    .foregroundStyle(loaded ? WM.Ground.inkSecondary : WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, WM.Space.s)
            }
        }
    }

    // MARK: Readouts

    private func readouts(_ a: NightMovement.Analysis) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            HStack(alignment: .top, spacing: WM.Space.s) {
                SignalCell(label: "Stirs", value: "\(a.stirCount)", valueSize: 24, fillsWidth: true)
                SignalCell(label: "Stillest",
                           value: a.stillest.map { Self.durationText($0.durationSec) } ?? "\u{2014}",
                           valueSize: 24, fillsWidth: true)
            }
            Text(footnote(a))
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footnote(_ a: NightMovement.Analysis) -> String {
        var parts: [String] = []
        if let s = a.stillest, s.durationSec >= 60 {
            parts.append("Quietest \(Self.clock(s.start))\u{2013}\(Self.clock(s.end))")
        }
        parts.append(a.source == .gravity ? "From raw movement." : "From per-epoch motion.")
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private func selectionReadout(_ tape: NightTape) -> some View {
        if let hour = selectedHour, let lane = tape.lanes.first(where: { $0.hourStart == hour }) {
            Text("\(Self.clock(lane.hourStart))\u{2013}\(Self.clock(lane.hourEnd)) \u{00B7} peak movement \(Int((lane.peak * 100).rounded()))%")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkSecondary)
                .padding(.top, WM.Space.s)
                .transition(.opacity)
        }
    }

    // MARK: Empty-state copy

    /// Past the raw horizon the motion was PRUNED, not missing. The default copy below promises the
    /// seismograph "fills in once a night is worn and synced" — for a night from March that is a promise
    /// nothing can keep, and it reads as an accusation that the strap was never worn. 014 made this
    /// section reachable for every night in the record, which is what put that sentence in front of the
    /// nights it was never written for.
    ///
    /// Worded so it does NOT open the way the arousal ledger's aged-out line does. Movement used to be a
    /// screen of its own; on Night detail the two sit one above the other, and two adjacent sentences
    /// both opening "This night is past the 28-day raw-signal window, so its…" read as an app repeating
    /// itself rather than as two findings (`PostureSection.agedOutLine` records the same lesson). Both
    /// still name the horizon from the constant, and this one still stands alone.
    static let agedOutLine =
        "Raw wrist motion is only kept for a \(SampleRetention.retentionDays)-day window and this night "
        + "is past it, so the seismograph can't be redrawn."

    /// The un-aged sentence: a night INSIDE the horizon with no motion really is a night the strap did
    /// not record, and that copy is correct for it.
    static let neverRecordedLine =
        "No movement recorded for this night. The seismograph needs the strap's raw motion \u{2014} it "
        + "fills in once a night is worn and synced."

    /// Which of the two the section shows. Internal so a test can pin the choice without a view host.
    static func emptyLine(dayKey: String?) -> String {
        RawHorizon.hasAgedOut(dayKey: dayKey) ? agedOutLine : neverRecordedLine
    }

    // MARK: Formatting

    /// Bare local "h:mm" (no am/pm — the hour labels down the left already carry a/p).
    private static let clockFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm"
        return f
    }()
    private static func clock(_ ts: Int) -> String {
        clockFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// "2h 35m" / "45m" — the same COMPACT spelling the strap-health gap rows use.
    private static func durationText(_ sec: Int) -> String {
        WMFormat.duration(seconds: sec, style: .compact)
    }
}

// MARK: - The lanes

/// The stacked hour lanes. Neutral ink only; whitespace between lanes, no ruled paper (the Line
/// language keeps hairlines for list rows).
private struct DrumTape: View {
    let lanes: [NightTape.Lane]
    @Binding var selectedHour: Int?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(lanes) { lane in
                Button {
                    selectedHour = (selectedHour == lane.hourStart) ? nil : lane.hourStart
                } label: {
                    LaneRow(lane: lane, selected: selectedHour == lane.hourStart)
                }
                .buttonStyle(.plain)
                // The lane Canvas carries no a11y content, so label each hour + speak its peak movement —
                // otherwise the per-hour data (reachable by sighted users via tap) is lost to VoiceOver.
                .accessibilityLabel(lane.label)
                .accessibilityValue(lane.hasMovement
                    ? "peak movement \(Int((lane.peak * 100).rounded())) percent" : "still")
                .accessibilityAddTraits(selectedHour == lane.hourStart ? .isSelected : [])
            }
        }
        // `.contain` (not `.ignore`) keeps the lane buttons focusable + activatable while still announcing
        // the group on entry — `.ignore` collapsed the whole tape into one leaf and dropped every lane.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sleep movement seismograph, \(lanes.count) hours")
    }
}

/// One clock-hour lane: a tabular hour caption, then a Canvas with a hairline baseline (the flat "quiet"
/// line) and the symmetric ink needle deflecting off it. The lane is a 44 pt row — it is a tap target —
/// with the trace drawn in its middle 26 pt.
private struct LaneRow: View {
    let lane: NightTape.Lane
    let selected: Bool

    private let rowHeight: CGFloat = 44
    private let traceHeight: CGFloat = 26
    private let labelWidth: CGFloat = 28

    var body: some View {
        HStack(alignment: .center, spacing: WM.Space.m) {
            Text(lane.label)
                .font(WMType.caption)
                .monospacedDigit()
                .foregroundStyle(selected ? WM.Ground.ink : WM.Ground.inkTertiary)
                .frame(width: labelWidth, alignment: .leading)
            Canvas { ctx, size in draw(ctx, size) }
                .frame(height: traceHeight)
                .frame(maxWidth: .infinity)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard size.width > 0 else { return }
        let mid = size.height / 2
        let amp = mid - 1                      // needle headroom off the baseline

        // Baseline hairline — the honest flat line a still hour reads as.
        var base = Path()
        base.move(to: CGPoint(x: 0, y: mid))
        base.addLine(to: CGPoint(x: size.width, y: mid))
        ctx.stroke(base, with: .color(WM.Ground.rule), lineWidth: WM.hairline)

        // The needle: a symmetric filled envelope off the baseline (deflection = each column's peak).
        let cols = lane.envelopes.count
        guard cols > 0, lane.hasMovement else { return }
        let colW = size.width / CGFloat(cols)
        func x(_ c: Int) -> CGFloat { (CGFloat(c) + 0.5) * colW }

        var trace = Path()
        trace.move(to: CGPoint(x: 0, y: mid))
        for c in 0..<cols {                                    // top edge, left → right
            trace.addLine(to: CGPoint(x: x(c), y: mid - CGFloat(lane.envelopes[c].hi) * amp))
        }
        trace.addLine(to: CGPoint(x: size.width, y: mid))
        for c in stride(from: cols - 1, through: 0, by: -1) {  // bottom edge, right → left (mirror)
            trace.addLine(to: CGPoint(x: x(c), y: mid + CGFloat(lane.envelopes[c].hi) * amp))
        }
        trace.addLine(to: CGPoint(x: 0, y: mid))
        trace.closeSubpath()

        ctx.fill(trace, with: .color(selected ? WM.Ground.ink : WM.Ground.inkSecondary))
    }
}

// MARK: - Specimen tape (synthetic night — no Repository / BLE)

#if DEBUG
/// A real-looking tape built from SYNTHETIC gravity: a mostly-still ~8 h night with a handful of injected
/// stirs (position changes), so the seismograph renders in previews without a live store. Shared by this
/// file's previews and Night detail's.
enum NightTapeSpecimen {
    static func tape() -> NightTape {
        let (grav, start, end) = syntheticNight()
        return NightTape.build(analysis: NightMovement.fromGravity(grav, start: start, end: end))
    }

    /// A deterministic mostly-still night: gravity holds an orientation with tiny breathing jitter, and at
    /// a few moments the sleeper rolls (a short burst of large |Δgravity|).
    private static func syntheticNight() -> (grav: [GravitySample], start: Int, end: Int) {
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let base = cal.date(bySettingHour: 23, minute: 10, second: 0, of: yesterday) ?? yesterday
        let start = Int(base.timeIntervalSince1970)
        let dt = 2                                   // one gravity sample every 2 s
        let end = start + Int(8.0 * 3600)            // ~8 h night
        let stirsAtMin: [Double] = [42, 96, 150, 205, 300, 372, 430]  // minutes into the night

        var rng = LCG(seed: 20260716)
        // Current unit orientation (lying on one side): drifts slowly, snaps during a stir.
        var cx = 0.10, cy = 0.28, cz = 0.95
        func normalize() {
            let m = (cx * cx + cy * cy + cz * cz).squareRoot()
            if m > 0 { cx /= m; cy /= m; cz /= m }
        }
        normalize()

        var grav: [GravitySample] = []
        grav.reserveCapacity((end - start) / dt + 1)
        var t = start
        while t < end {
            let minute = Double(t - start) / 60.0
            let inStir = stirsAtMin.contains { abs(minute - $0) < 0.12 }   // ~7 s bursts
            let jitter = inStir ? 0.22 : 0.006                            // roll vs breathing
            cx += (rng.unit() - 0.5) * jitter
            cy += (rng.unit() - 0.5) * jitter
            cz += (rng.unit() - 0.5) * (inStir ? jitter : 0.003)
            normalize()
            grav.append(GravitySample(ts: t, x: cx, y: cy, z: cz))
            t += dt
        }
        return (grav, start, end)
    }

    /// A tiny deterministic PRNG so the preview tape is identical every render.
    private struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }
}

#Preview("NightMovement — light") {
    NightMovementSpecimen(tape: NightTapeSpecimen.tape()).preferredColorScheme(.light)
}

#Preview("NightMovement — dark") {
    NightMovementSpecimen(tape: NightTapeSpecimen.tape()).preferredColorScheme(.dark)
}

#Preview("NightMovement — empty") {
    // nil = a night inside the horizon, so this renders the "not recorded" sentence rather than the
    // aged-out one. The aged-out wording is pinned by RawHorizonTests.
    NightMovementSpecimen(tape: nil).preferredColorScheme(.light)
}

private struct NightMovementSpecimen: View {
    let tape: NightTape?

    var body: some View {
        ScrollView {
            NightMovementContent(tape: tape, loaded: true, dayKey: nil)
                .padding(.horizontal, WM.Space.gutter)
        }
        .background(WM.Ground.ground)
    }
}
#endif
