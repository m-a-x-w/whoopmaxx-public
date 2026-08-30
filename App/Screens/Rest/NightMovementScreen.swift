import SwiftUI
import StrapStore
import StrapProtocol
import StrapAnalytics

/// The Sleep Seismograph — a night's raw body movement rendered as a literal paper-drum tape: one lane
/// per clock hour (bed→wake), the trace a neutral-ink needle deflecting off a hairline baseline, quiet
/// stretches reading as a near-flat line. Reached by tapping "Last night" on the Rest tab.
///
/// READ-ONLY: reads the night's raw gravity (preferred) or the persisted per-epoch motion fallback ONCE,
/// runs `NightMovement`, caches the resulting `NightTape`, and draws from it. No writes, no schema change.
/// Movement is not a Charge/Effort/Rest domain, so the whole screen is neutral ink — no fabricated color.
struct NightMovementScreen: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    let night: RestNight

    @State private var tape: NightTape?
    @State private var loaded = false

    var body: some View {
        NightMovementContent(tape: tape, loaded: loaded, wake: night.wake,
                             dayKey: night.dayKey, onBack: { dismiss() })
            .toolbar(.hidden, for: .navigationBar)
            .task(id: windowKey) { await load() }
    }

    /// Reload only when the night window changes (a different last-night pushed).
    private var windowKey: String {
        "\(Int(night.bed?.timeIntervalSince1970 ?? 0))-\(Int(night.wake?.timeIntervalSince1970 ?? 0))"
    }

    @MainActor
    private func load() async {
        guard let bed = night.bed, let wake = night.wake, wake > bed else { loaded = true; return }
        let start = Int(bed.timeIntervalSince1970)
        let end = Int(wake.timeIntervalSince1970)
        guard let store = await repo.storeHandle() else { loaded = true; return }
        // The per-epoch motion fallback is keyed by the detected session's startTs — resolve it here on the
        // main actor (`repo.sleeps` is main-actor state) so the background builder needs only the key.
        let motionKey = repo.sleeps.first(where: { $0.effectiveStartTs == start && $0.endTs == end })?.startTs
        // Read + analysis + tape build run OFF the main actor (`NightTape.load`, nonisolated), so the
        // sort/scan/decimate over up to 500k gravity samples never blocks UI — mirrors
        // `ArousalForensicsLoader`.
        tape = await NightTape.load(store: store, strapId: repo.deviceId, computedId: repo.computedDeviceId,
                                    start: start, end: end, motionSessionStart: motionKey)
        loaded = true
    }
}

// MARK: - Pure content (previewable without a live Repository)

/// The whole screen, rendered from a prebuilt `NightTape` — no store, no BLE. The tape is the hero; the
/// readouts (stir count, stillest stretch, source) are secondary.
struct NightMovementContent: View {
    let tape: NightTape?
    let loaded: Bool
    /// Wake instant, for the header date caption.
    var wake: Date? = nil
    /// The night's `yyyy-MM-dd` key, for the raw-retention horizon test. nil — the specimen previews —
    /// keeps the original empty-state sentence, which is correct for a night inside the horizon.
    /// REQUIRED, deliberately no default: this argument decides whether the section is allowed to
    /// state a finding about a night whose raw signal was pruned. It shipped WITH a default once, the
    /// single production call site omitted it, and the whole aged-out state was unreachable in the
    /// binary while its unit tests stayed green. Every caller now has to say which night it means,
    /// even if the answer is nil (the specimen previews)  14 the compiler is the only thing that
    /// actually catches a dropped argument here.
    let dayKey: String?
    var onBack: (() -> Void)? = nil

    @State private var selectedHour: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let onBack { backLink(onBack) }
                header
                content
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.top, onBack == nil ? WM.Space.gutter : WM.Space.m)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }

    @ViewBuilder
    private var content: some View {
        if let tape, !tape.isEmpty {
            DrumTape(lanes: tape.lanes, selectedHour: $selectedHour)
                .padding(.top, WM.Space.sectionTight)
            selectionReadout(tape)
            readouts(tape.analysis)
        } else if loaded {
            emptyState
        } else {
            // First render before the async read resolves — a calm placeholder, no spinner chrome.
            Text("Reading the night…")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkTertiary)
                .padding(.top, WM.Space.sectionTight)
        }
    }

    private func backLink(_ onBack: @escaping () -> Void) -> some View {
        WMBackLink(title: "Rest", action: onBack)
            .padding(.top, WM.Space.s)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Movement")
                    .font(WMType.title)
                    .foregroundStyle(WM.Ground.ink)
                Spacer()
                if let wake {
                    Text(wake, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            Text("The night on seismograph paper — one line per hour.")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkSecondary)
        }
        .padding(.top, WM.Space.m)
    }

    // MARK: Readouts (secondary)

    private func readouts(_ a: NightMovement.Analysis) -> some View {
        RuleSection("Readout") {
            VStack(alignment: .leading, spacing: WM.Space.m) {
                HStack(alignment: .top, spacing: WM.Space.sectionLoose) {
                    SignalCell(label: "Stirs", value: "\(a.stirCount)")
                    SignalCell(label: "Stillest",
                               value: a.stillest.map { Self.durationText($0.durationSec) } ?? "—")
                }
                Text(footnote(a))
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
    }

    private func footnote(_ a: NightMovement.Analysis) -> String {
        var parts: [String] = []
        if let s = a.stillest, s.durationSec >= 60 {
            parts.append("Quietest \(Self.clock(s.start))–\(Self.clock(s.end))")
        }
        parts.append(a.source == .gravity ? "From raw movement." : "From per-epoch motion.")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func selectionReadout(_ tape: NightTape) -> some View {
        if let hour = selectedHour, let lane = tape.lanes.first(where: { $0.hourStart == hour }) {
            Text("\(Self.clock(lane.hourStart))–\(Self.clock(lane.hourEnd)) · peak movement \(Int((lane.peak * 100).rounded()))%")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkSecondary)
                .padding(.top, WM.Space.m)
                .transition(.opacity)
        }
    }

    /// Past the raw horizon the motion was PRUNED, not missing. The default copy below promises the
    /// seismograph "fills in once a night is worn and synced" — for a night from March that is a promise
    /// nothing can keep, and it reads as an accusation that the strap was never worn. 014 made this
    /// screen reachable for every night in the record, which is what put that sentence in front of the
    /// nights it was never written for.
    static let agedOutLine =
        "This night is past the \(SampleRetention.retentionDays)-day raw-signal window, so its wrist "
        + "motion is no longer stored and the seismograph can't be redrawn."

    /// The un-aged sentence: a night INSIDE the horizon with no motion really is a night the strap did
    /// not record, and that copy is correct for it.
    static let neverRecordedLine =
        "No movement recorded for this night. The seismograph needs the strap's raw motion \u{2014} it "
        + "fills in once a night is worn and synced."

    /// Which of the two the screen shows. Internal so a test can pin the choice without a view host.
    static func emptyLine(dayKey: String?) -> String {
        RawHorizon.hasAgedOut(dayKey: dayKey) ? agedOutLine : neverRecordedLine
    }

    private var emptyState: some View {
        RuleSection("Movement", topGap: WM.Space.sectionTight) {
            Text(Self.emptyLine(dayKey: dayKey))
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkSecondary)
                .padding(.vertical, WM.Space.s)
        }
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

// MARK: - The drum tape

/// The wrapped seismograph tape: a stack of hour lanes on faint ruled paper. Neutral ink only.
private struct DrumTape: View {
    let lanes: [NightTape.Lane]
    @Binding var selectedHour: Int?

    var body: some View {
        VStack(spacing: 0) {
            // Top edge of the "paper".
            WMRule()
            ForEach(lanes) { lane in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedHour = (selectedHour == lane.hourStart) ? nil : lane.hourStart
                    }
                } label: {
                    LaneRow(lane: lane, selected: selectedHour == lane.hourStart)
                }
                .buttonStyle(.plain)
                // The lane Canvas carries no a11y content, so label each hour + speak its peak movement —
                // otherwise the per-hour data (reachable by sighted users via tap) is lost to VoiceOver.
                .accessibilityLabel(lane.label)
                .accessibilityValue(lane.hasMovement
                    ? "peak movement \(Int((lane.peak * 100).rounded())) percent" : "still")
            }
            // Bottom edge of the "paper".
            WMRule()
        }
        // `.contain` (not `.ignore`) keeps the lane buttons focusable + activatable while still announcing
        // the group on entry — `.ignore` collapsed the whole tape into one leaf and dropped every lane.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sleep movement seismograph, \(lanes.count) hours")
    }
}

/// One clock-hour lane: a tabular hour label, then a fixed-height Canvas with a faint quarter-hour grid,
/// a hairline baseline (the flat "quiet" line), and the symmetric ink needle deflecting off it.
private struct LaneRow: View {
    let lane: NightTape.Lane
    let selected: Bool

    /// Lane geometry.
    private let laneHeight: CGFloat = 46
    private let labelWidth: CGFloat = 30

    var body: some View {
        HStack(alignment: .center, spacing: WM.Space.m) {
            Text(lane.label)
                .font(WMType.numeral(15))
                .foregroundStyle(selected ? WM.Ground.ink : WM.Ground.inkTertiary)
                .frame(width: labelWidth, alignment: .trailing)
            Canvas { ctx, size in draw(ctx, size) }
                .frame(height: laneHeight)
                .frame(maxWidth: .infinity)
        }
        .background(alignment: .leading) {
            // A whisper-faint separator between lanes, like ruled paper.
            Rectangle().fill(WM.Ground.rule.opacity(0.45)).frame(height: WM.hairline)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard size.width > 0 else { return }
        let mid = size.height / 2
        let amp = mid - 4                      // needle headroom off the baseline

        // 1. Faint seismograph-paper grid: quarter-hour verticals.
        var grid = Path()
        for f in [0.25, 0.5, 0.75] {
            let x = size.width * f
            grid.move(to: CGPoint(x: x, y: 3))
            grid.addLine(to: CGPoint(x: x, y: size.height - 3))
        }
        ctx.stroke(grid, with: .color(WM.Ground.rule.opacity(0.5)), lineWidth: WM.hairline)

        // 2. Baseline hairline — the honest flat line a still hour reads as.
        var base = Path()
        base.move(to: CGPoint(x: 0, y: mid))
        base.addLine(to: CGPoint(x: size.width, y: mid))
        ctx.stroke(base, with: .color(WM.Ground.ink.opacity(0.22)), lineWidth: WM.hairline)

        // 3. The needle: a symmetric filled envelope off the baseline (deflection = each column's peak).
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

        let ink = selected ? WM.Ground.ink : WM.Ground.ink.opacity(0.85)
        ctx.fill(trace, with: .color(ink))
    }
}

// MARK: - Previews (synthetic night — no Repository / BLE)

#Preview("NightMovement — light") {
    NavigationStack { NightMovementSpecimen() }.preferredColorScheme(.light)
}

#Preview("NightMovement — dark") {
    NavigationStack { NightMovementSpecimen() }.preferredColorScheme(.dark)
}

#Preview("NightMovement — empty") {
    // nil = a night inside the horizon, so this renders the "not recorded" sentence rather than the
    // aged-out one. The aged-out wording is pinned by RawHorizonTests.
    NightMovementContent(tape: nil, loaded: true, wake: Date(), dayKey: nil, onBack: {})
        .preferredColorScheme(.light)
}

/// Builds a real-looking tape from SYNTHETIC gravity: a mostly-still ~8 h night with a handful of injected
/// stirs (position changes), so the seismograph renders without a live store.
private struct NightMovementSpecimen: View {
    var body: some View {
        let (grav, start, end) = Self.syntheticNight()
        let analysis = NightMovement.fromGravity(grav, start: start, end: end)
        return NightMovementContent(tape: NightTape.build(analysis: analysis),
                                    loaded: true,
                                    wake: Date(timeIntervalSince1970: TimeInterval(end)),
                                    dayKey: nil, onBack: {})
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
