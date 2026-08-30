import SwiftUI
import StrapProtocol
import StrapStore
import StrapAnalytics

/// HRV mode — an on-device R-R **Poincaré** scatter (RR[n] × RR[n+1]) with the SD1/SD2 "comet" ellipse,
/// an RMSSD needle and a rolling-RMSSD trend spark beside it. It lays autonomic tone bare the way
/// LIVE/HISTORY lay the raw channels bare:
/// every beat is plotted, ectopic / out-of-range beats show DIMMED as off-axis outliers, and the ellipse
/// is fit on the CLEANED NN only. All geometry comes from the pure `Poincare` engine; the cleaning +
/// RMSSD/SDNN come from the frozen `HRVAnalyzer`, so nothing here re-derives a statistic — including the
/// prominent needle, which reads the SAME `Poincare.descriptors.rmssd` the readout cell reads so the two
/// cannot print different RMSSDs for one window.
///
/// Beside the time-domain descriptors the readout carries the FREQUENCY-domain family (LF / HF / LF-HF /
/// total power) from `HRVFreqDomain`'s Lomb-Scargle periodogram — but only on a lane whose beats carry
/// wall-clock times, and only once a MEASURED coverage check says the record has no dropout sewn shut by
/// the engine's cumulative time base. See `HRVFreqReadout` for why that gate has to live here.
///
/// Source is LIVE-first: with a strap connected it accumulates a rolling comet of the newest R-R beats
/// (`LiveState.rrRecent`, then grown from the live packet stream); with no strap it falls back to the most
/// recent stored R-R window (~30 min) read once from the Repository — mirroring how HISTORY fetches. Fully
/// previewable with no store and no radio via injected synthetic R-R (a clean set + a set with ectopics).
///
/// NEUTRAL INK: HRV is not a Charge / Effort / Rest domain, so the scatter, ellipse and needle stay ink /
/// graphite — color is reserved for data domains. WELLNESS / awareness only, no clinical claim.
struct SignalLabHRVView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState

    /// Preview / no-store seam: when set, this R-R window IS the source (both live + Repository reads are
    /// skipped) so the panel renders a synthetic comet in `#Preview`s. nil in the real app.
    var injectedRR: [RRInterval]? = nil

    /// The rolling live comet, seeded from `LiveState.rrRecent` and grown from the live packet stream.
    @State private var liveBuffer: [Int] = []
    /// A moving trend of the current rolling-RMSSD while live (one sample per live packet, bounded).
    @State private var liveTrend: [Double] = []
    @State private var didSeedLive = false
    /// The most-recent stored R-R window, read once from the Repository when no strap is connected.
    @State private var storedRR: [RRInterval] = []
    @State private var loading = false
    /// Bumped per stored load so a late read can't clobber a newer one.
    @State private var loadGen = 0

    /// The computed Poincaré panel (classify + ellipse fit + pNN50 + the frequency bands) and the
    /// rolling-RMSSD trend, CACHED off the render path. `HRVPanel(rr:timed:)` and
    /// `HRVAnalyzer.rollingRmssd` are heavy, so they run only when the source R-R actually changes (a new
    /// live packet, a stored/injected load, a source switch) — never rebuilt inside `body`.
    @State private var panel = HRVPanel(rr: [], timed: [])
    @State private var trendCache: [Double] = []

    /// How many beats the live comet retains — a couple of minutes at ~1 Hz, longer than `rrRecent`'s own
    /// cap so the comet has a visible tail while staying bounded.
    private static let maxLiveBeats = 240
    /// Cap on the live rolling-RMSSD trend buffer.
    private static let maxTrend = 120
    /// The stored fallback window: the last ~30 minutes of banked R-R.
    private static let storedWindowSeconds = 30 * 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WM.Space.l) {
                sourceLine
                needle(panel)
                scatter(panel)
                readout(panel)
                Text("Poincaré of consecutive R-R beats. SD1 (⟂ the identity line) is short-term, SD2 (along it) long-term variability. Ectopic / out-of-range beats are dimmed and excluded from the ellipse. Awareness only — not a medical measure.")
                    .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(panel.freq.caption)
                    .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .task(id: isLive) { if !isLive { await loadStored() } }
        .onAppear { seedLiveIfNeeded(); refreshPanel() }
        .onChange(of: isLive) { was, now in
            // Rising edge (reconnect): a disconnect can span hours, so DON'T let the pre-disconnect comet
            // tail bleed into the reconnected one. Reset the live buffers and reseed from the strap's
            // current rolling R-R so the comet restarts clean rather than appending onto stale beats.
            if now && !was {
                didSeedLive = false
                liveBuffer = []
                liveTrend = []
                seedLiveIfNeeded()
            }
            refreshPanel()
        }
        // Grow the comet off the MONOTONIC packet counter, not `live.rr`: two consecutive identical R-R
        // packets (common at rest) leave the Equatable `rr` unchanged, so an `onChange(of: live.rr)` would
        // silently drop the repeat beat. The counter bumps on every valid packet, so none are missed.
        .onChange(of: live.rrPacketSeq) { _, _ in
            guard isLive else { return }
            for ms in live.rr where ms > 0 { liveBuffer.append(ms) }
            if liveBuffer.count > Self.maxLiveBeats {
                liveBuffer.removeFirst(liveBuffer.count - Self.maxLiveBeats)
            }
            if let r = SignalLabMath.rollingRMSSD(liveBuffer) {
                liveTrend.append(r)
                if liveTrend.count > Self.maxTrend { liveTrend.removeFirst(liveTrend.count - Self.maxTrend) }
            }
            refreshPanel()
        }
    }

    /// Recompute the cached panel + trend from whichever source is active. The only place
    /// `HRVPanel(rr:timed:)` and the stored rolling-RMSSD are built.
    private func refreshPanel() {
        panel = HRVPanel(rr: sourceRR, timed: timedRR, comet: isLive)
        trendCache = computeTrend()
    }

    // MARK: Source resolution (live-first, else stored, else injected preview)

    /// LIVE whenever a strap is connected AND we're not in an injected preview.
    private var isLive: Bool { injectedRR == nil && live.connected }

    /// The ordered R-R values (ms) feeding the panel, from whichever source is active.
    private var sourceRR: [Double] {
        if let injectedRR { return injectedRR.map { Double($0.rrMs) } }
        if isLive { return liveBuffer.map(Double.init) }
        return storedRR.map { Double($0.rrMs) }
    }

    /// The active window WITH each beat's wall clock, when the lane carries one — `HRVFreqReadout` needs
    /// it to measure how much of the window's real duration the kept beats actually account for. nil on
    /// the live comet: `LiveState.rrRecent` is intervals only (`LiveState.swift:73`), so there is no clock
    /// to check the record against and the bands stay blank rather than report a shifted frequency.
    private var timedRR: [RRInterval]? {
        if let injectedRR { return injectedRR }
        if isLive { return nil }
        return storedRR
    }

    /// The rolling-RMSSD trend series: the live moving trend when live, else a windowed trend over the
    /// stored / injected R-R via the frozen `HRVAnalyzer.rollingRmssd`. Cached into `trendCache` by
    /// `refreshPanel`; the sparkline reads the cache, so this is never recomputed inside `body`.
    private func computeTrend() -> [Double] {
        if isLive { return liveTrend }
        let rr = injectedRR ?? storedRR
        guard rr.count >= 8 else { return [] }
        return HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 120, stepSec: 15).map { $0.rmssd }
    }

    private var sourceLabel: String {
        if injectedRR != nil { return "Synthetic" }
        if isLive { return "Live · comet" }
        return "Stored · last 30 min"
    }

    // MARK: Header source line

    private var sourceLine: some View {
        HStack {
            Text("Poincaré HRV").wmOverline(WM.Ground.inkSecondary)
            Spacer()
            Text(sourceLabel).font(WMType.overline).kerning(WMType.overlineTracking)
                .foregroundStyle(WM.Ground.inkTertiary)
        }
    }

    // MARK: RMSSD needle (prominent current value + small trend)

    private func needle(_ panel: HRVPanel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WM.Space.l) {
            VStack(alignment: .leading, spacing: WM.Space.xs) {
                Text("RMSSD").wmOverline()
                HStack(alignment: .firstTextBaseline, spacing: WM.Space.s) {
                    // The SAME expression the RMSSD readout cell uses, deliberately. The needle used to
                    // hand-roll `SignalLabMath.rollingRMSSD` over the RAW buffer — no range filter, no
                    // ectopic rejection, last 60 beats — while the grid three inches below read the
                    // cleaned `Poincare.descriptors`, so the panel contradicted itself on one window.
                    Text(panel.descriptors.map { fmt($0.rmssd) } ?? "—")
                        .font(WMType.display(56)).foregroundStyle(WM.Ground.ink)
                        .monospacedDigit().wmAnimation(value: panel.cleaned.count)
                    Text("ms").font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            Spacer()
            trendSpark
                .frame(width: 108, height: 46)
                .accessibilityLabel("Rolling RMSSD trend")
        }
    }

    /// A hairline sparkline of the recent rolling-RMSSD, with a small "needle" tick at the newest value.
    private var trendSpark: some View {
        Canvas { ctx, size in
            let base = CGRect(x: 0, y: size.height - WM.hairline, width: size.width, height: WM.hairline)
            ctx.fill(Path(base), with: .color(WM.Ground.rule))
            let vals = trendCache
            guard vals.count >= 2 else { return }
            let lo = vals.min() ?? 0, hi = vals.max() ?? 1
            let span = hi - lo
            func x(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(vals.count - 1) * size.width }
            func y(_ v: Double) -> CGFloat {
                let f = span == 0 ? 0.5 : (v - lo) / span
                return size.height - CGFloat(f) * (size.height - 4) - 2
            }
            var path = Path()
            for (i, v) in vals.enumerated() {
                let p = CGPoint(x: x(i), y: y(v))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(WM.Ground.inkSecondary), lineWidth: 1.1)
            if let last = vals.last {
                let px = x(vals.count - 1), py = y(last)
                // Needle: a short vertical tick + head dot at the current value.
                var tick = Path(); tick.move(to: CGPoint(x: px, y: 0)); tick.addLine(to: CGPoint(x: px, y: size.height))
                ctx.stroke(tick, with: .color(WM.Ground.ink.opacity(0.25)), lineWidth: 1)
                let r: CGFloat = 2.6
                ctx.fill(Path(ellipseIn: CGRect(x: px - r, y: py - r, width: 2 * r, height: 2 * r)),
                         with: .color(WM.Ground.ink))
            }
        }
    }

    // MARK: Poincaré scatter

    private func scatter(_ panel: HRVPanel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("RR[n] → RR[n+1]").font(WMType.overline).kerning(WMType.overlineTracking)
                    .foregroundStyle(WM.Ground.inkTertiary)
                Spacer()
                Text("ms").font(WMType.overline).foregroundStyle(WM.Ground.inkTertiary.opacity(0.7))
            }
            // A square canvas so ms→px is equal on both axes — the identity diagonal and the rotated
            // ellipse only read true when x and y share a scale.
            Canvas { ctx, size in draw(panel, in: ctx, size: size) }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity, alignment: .center)
            if panel.cleaned.count < Poincare.minEllipseBeats {
                Text(panel.rr.isEmpty ? (isLive ? "Collecting live beats…" : "No stored R-R in this window")
                     : "Too few clean beats for an ellipse")
                    .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
            }
        }
    }

    private func draw(_ panel: HRVPanel, in ctx: GraphicsContext, size: CGSize) {
        // Axis frame (L-shape hairlines — an instrument frame, never a card).
        var frame = Path()
        frame.move(to: CGPoint(x: 0, y: 0)); frame.addLine(to: CGPoint(x: 0, y: size.height))
        frame.addLine(to: CGPoint(x: size.width, y: size.height))
        ctx.stroke(frame, with: .color(WM.Ground.rule), lineWidth: WM.hairline)

        guard let range = panel.displayRange(fallbackSpan: 60) else { return }
        let lo = range.lowerBound, hi = range.upperBound, spanV = hi - lo
        guard spanV > 0 else { return }
        // Equal ms→px on both axes (square canvas) so the 45° identity line and the rotated ellipse are true.
        func px(_ v: Double) -> CGFloat { CGFloat((v - lo) / spanV) * size.width }
        func py(_ v: Double) -> CGFloat { size.height - CGFloat((v - lo) / spanV) * size.height }
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: px(x), y: py(y)) }
        func clampX(_ x: CGFloat) -> CGFloat { min(size.width, max(0, x)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(size.height, max(0, y)) }

        // Line of identity (RR[n] = RR[n+1]) — dashed hairline.
        var identity = Path()
        identity.move(to: pt(lo, lo)); identity.addLine(to: pt(hi, hi))
        ctx.stroke(identity, with: .color(WM.Ground.inkTertiary.opacity(0.5)),
                   style: StrokeStyle(lineWidth: WM.hairline, dash: [3, 3]))

        // Scatter of every consecutive pair, classified by the worse of its two endpoints.
        let rr = panel.rr, classes = panel.classes
        let comet = panel.comet
        if rr.count >= 2 {
            for n in 0..<(rr.count - 1) {
                let x = rr[n], y = rr[n + 1]
                let clean = classes[n] == .clean && classes[n + 1] == .clean
                let cx = clampX(px(x)), cy = clampY(py(y))
                let offscale = px(x) < 0 || px(x) > size.width || py(y) < 0 || py(y) > size.height
                if clean {
                    // Comet: newest pairs emphasized, tail fades (live only); uniform otherwise.
                    let age = rr.count <= 2 ? 1.0 : Double(n) / Double(rr.count - 2)
                    let opacity = comet ? (0.22 + 0.78 * age) : 0.85
                    let r: CGFloat = (comet && n >= rr.count - 3) ? 3.0 : 1.9
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                             with: .color(WM.Ground.ink.opacity(opacity)))
                } else {
                    // Ectopic / out-of-range: dimmed hollow marker; off-scale beats clamp to the frame edge.
                    let r: CGFloat = 2.4
                    let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
                    ctx.stroke(Path(ellipseIn: rect),
                               with: .color(WM.Ground.inkTertiary.opacity(offscale ? 0.35 : 0.55)),
                               lineWidth: WM.hairline)
                }
            }
        }

        // SD1/SD2 ellipse — fit on CLEANED NN only, drawn parametrically in data space so the rotation is
        // exact regardless of the canvas' inverted y.
        if let e = panel.ellipse {
            let cos45 = cos(e.angleRadians), sin45 = sin(e.angleRadians)
            var ellipse = Path()
            let steps = 96
            for i in 0...steps {
                let t = Double(i) / Double(steps) * 2 * Double.pi
                let localX = e.sd2 * cos(t)      // SD2 along the major (identity) axis
                let localY = e.sd1 * sin(t)      // SD1 along the minor (⟂) axis
                let dx = localX * cos45 - localY * sin45
                let dy = localX * sin45 + localY * cos45
                let p = pt(e.centerX + dx, e.centerY + dy)
                if i == 0 { ellipse.move(to: p) } else { ellipse.addLine(to: p) }
            }
            ctx.stroke(ellipse, with: .color(WM.Ground.ink), lineWidth: 1.3)

            // SD1 / SD2 semi-axes as faint guides from the centre.
            func axisLine(_ ax: Double, _ ay: Double, len: Double) {
                var l = Path()
                l.move(to: pt(e.centerX, e.centerY))
                l.addLine(to: pt(e.centerX + ax * len, e.centerY + ay * len))
                ctx.stroke(l, with: .color(WM.Ground.inkSecondary.opacity(0.5)), lineWidth: WM.hairline)
            }
            axisLine(cos45, sin45, len: e.sd2)          // SD2 along identity
            axisLine(-sin45, cos45, len: e.sd1)         // SD1 perpendicular

            // Centre marker at (meanNN, meanNN).
            let c = pt(e.centerX, e.centerY); let cr: CGFloat = 2.2
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - cr, y: c.y - cr, width: 2 * cr, height: 2 * cr)),
                     with: .color(WM.Ground.ink))
        }
    }

    // MARK: Readout row (tabular)

    private func readout(_ panel: HRVPanel) -> some View {
        let d = panel.descriptors
        let timeDomain: [(String, String, String)] = [
            ("SD1", d.map { fmt($0.sd1) } ?? "—", "ms"),
            ("SD2", d.map { fmt($0.sd2) } ?? "—", "ms"),
            ("SD1/SD2", d.map { String(format: "%.2f", $0.ratio) } ?? "—", ""),
            ("RMSSD", d.map { fmt($0.rmssd) } ?? "—", "ms"),
            ("SDNN", d.map { fmt($0.sdnn) } ?? "—", "ms"),
            ("pNN50", panel.pnn50.map { String(format: "%.0f", $0) } ?? "—", "%"),
            ("meanNN", d.map { fmt($0.meanNN) } ?? "—", "ms"),
            ("beats", String(panel.cleaned.count), ""),
            ("rejected", String(panel.rejected), ""),
        ]
        // Nine time-domain descriptors fill exactly three rows, so the frequency family starts a fresh
        // one. `HRVFreqReadout.cells` decides its own em-dashes — a band goes blank in one place only.
        let cells = timeDomain + panel.freq.cells
        let cols = [GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: WM.Space.m) {
            ForEach(cells, id: \.0) { label, value, unit in
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(WMType.overline).kerning(WMType.overlineTracking)
                        .foregroundStyle(WM.Ground.inkTertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(value).font(WMType.numeral(22)).monospacedDigit()
                            .foregroundStyle(WM.Ground.ink)
                        if !unit.isEmpty {
                            Text(unit).font(WMType.overline).foregroundStyle(WM.Ground.inkTertiary)
                        }
                    }
                }
            }
        }
    }

    private func fmt(_ v: Double) -> String { String(Int(v.rounded())) }

    // MARK: Live seeding + stored load

    private func seedLiveIfNeeded() {
        guard !didSeedLive, isLive else { return }
        didSeedLive = true
        liveBuffer = Array(live.rrRecent.suffix(Self.maxLiveBeats))
        if let r = SignalLabMath.rollingRMSSD(liveBuffer) { liveTrend = [r] }
    }

    @MainActor
    private func loadStored() async {
        guard injectedRR == nil else { return }
        loadGen += 1
        let gen = loadGen
        loading = true
        guard let store = await repo.storeHandle() else { loading = false; return }
        // The window anchoring + the bounded read live in `ScopeHistoryLoader` (off-main), beside the
        // HISTORY scope's reads; this view keeps only the stale-load stamp and the publish.
        let rr = await ScopeHistoryLoader.loadStoredRR(store: store, deviceId: repo.deviceId,
                                                       windowSeconds: Self.storedWindowSeconds)
        guard gen == loadGen else { return }
        storedRR = rr
        loading = false
        refreshPanel()
    }
}

// MARK: - Pure panel model (classification + descriptors + ellipse for one R-R window)

/// One computed Poincaré panel over a window of raw R-R values (ms). Pure — built from `Poincare` +
/// `HRVAnalyzer` + `HRVFreqDomain`, so the view only draws what this decides. `comet` toggles the
/// newest-emphasized live rendering; it is metadata for the view, not part of the math.
///
/// `timed` is the SAME window carrying each beat's wall clock, or nil for a lane that has none (the live
/// comet). It feeds `freq` only — the scatter, ellipse and descriptors are unchanged by it.
private struct HRVPanel {
    let rr: [Double]
    let classes: [Poincare.BeatClass]
    let cleaned: [Double]
    let descriptors: Poincare.Descriptors?
    let ellipse: Poincare.Ellipse?
    let pnn50: Double?
    let rejected: Int
    /// The frequency-domain half — gated on its own measured coverage check, see `HRVFreqReadout`.
    let freq: HRVFreqReadout
    var comet: Bool = false

    init(rr: [Double], timed: [RRInterval]?, comet: Bool = false) {
        self.rr = rr
        let classes = Poincare.classify(rr: rr)
        self.classes = classes
        let cleaned = Poincare.cleanedNN(from: rr, classes: classes)
        self.cleaned = cleaned
        let d = Poincare.descriptors(nn: cleaned)
        self.descriptors = d
        self.ellipse = d.flatMap { Poincare.ellipse(descriptors: $0) }
        self.pnn50 = HRVPanel.pnn50(cleaned)
        self.rejected = classes.reduce(0) { $0 + ($1 == .clean ? 0 : 1) }
        // The periodogram is the heaviest thing in this init (~80 frequency evaluations over the window),
        // which is why the panel is cached off the render path. The live lane short-circuits on nil
        // `timed` before any of it runs, so the per-packet refresh pays nothing for this.
        self.freq = HRVFreqReadout.measure(timed)
        self.comet = comet
    }

    /// A square [lo, hi] display range framing the cleaned cloud with generous padding, so the ellipse and
    /// its ⟂ SD1 spread are visible and the identity diagonal spans the plot. nil when there's nothing to
    /// frame. In-range ectopics fall inside naturally; out-of-range beats clamp to the frame edge.
    func displayRange(fallbackSpan: Double) -> ClosedRange<Double>? {
        let base = cleaned.isEmpty ? rr.filter { $0 >= HRVAnalyzer.rrMinMs && $0 <= HRVAnalyzer.rrMaxMs } : cleaned
        guard let mn = base.min(), let mx = base.max() else { return nil }
        let sd2 = descriptors?.sd2 ?? 0
        let pad = max((mx - mn) * 0.25, sd2 * 3, fallbackSpan)
        return (mn - pad)...(mx + pad)
    }

    /// pNN50 (%) over the cleaned NN — the Task Force definition `HRVAnalyzer` uses, computed here so the
    /// exploratory panel shows it for any n ≥ 2 (the analyzer's own pNN50 is gated behind its 20-beat
    /// trustworthiness floor). nil for fewer than two beats.
    private static func pnn50(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        var over = 0
        for i in 1..<nn.count where abs(nn[i] - nn[i - 1]) > 50 { over += 1 }
        return Double(over) / Double(nn.count - 1) * 100
    }
}

// MARK: - Frequency-domain readout (LF / HF / LF-HF / total power + the gate the engine can't apply)

/// The frequency-domain half of the HRV panel: `HRVFreqDomain`'s Lomb-Scargle LF / HF / LF-HF / total
/// power over one R-R window, plus the one gate the engine has no way to apply for itself.
///
/// WHY THE EXTRA GATE. `HRVFreqDomain` builds its tachogram from the CUMULATIVE SUM of the cleaned R-R
/// (`HRVFreqDomain.swift:106-114`): beat k sits at the sum of the beats before it, never at its own wall
/// clock. A dropout is therefore sewn shut invisibly — the record keeps its beat count, loses its real
/// duration, and every frequency it reports is scaled by 1/coverage with no nil to warn anyone. That is
/// measured, not hypothetical: on the 2026-07-26 corpus the stored R-R tiles only 85.4 % of a session's
/// clock, with 108 row gaps over 5 s carrying 14.2 % of the span (`HRVAnalyzer.swift:181-187`). The engine
/// takes interval VALUES, not timestamps, so it cannot notice. This type measures the ratio itself and
/// WITHHOLDS the bands below `minCoverage` rather than print a shifted frequency.
///
/// A source with no per-beat wall clock cannot be measured at all — the live comet is intervals only
/// (`LiveState.swift:73`) — so it reads `—` and the caption says why.
///
/// Descriptive, within-user, non-clinical. LF/HF is the ratio of two band powers and NOTHING more: it is
/// not a sympathetic/parasympathetic balance and must never be captioned as one. Banned from every string
/// in this type: thermoregulation, vasodilation, impaired, poor, abnormal, apnea, insomnia, hypoxemia,
/// arrhythmia, "consider", "you should", "talk to".
enum HRVFreqReadout: Equatable {
    /// Bands that cleared the coverage gate, carrying the measured coverage fraction that cleared it.
    case measured(HRVFreqDomain.Bands, coverage: Double)
    /// No usable per-beat wall clock on this window, so coverage cannot be measured.
    case noTimeBase
    /// `HRVFreqDomain` returned nil: under `HRVFreqDomain.minBeats` clean beats, or under `minSpanForHFSec`.
    case tooShort
    /// Coverage measured and under `minCoverage` — the tachogram would silently compress a gapped record.
    case gapped(coverage: Double)

    /// Floor on measured wall-clock coverage before the four bands are shown. 0.80 admits the 85.4 %
    /// session tiling measured on the real corpus (`HRVAnalyzer.swift:181-187`) — a stricter floor would
    /// blank the cells on every real night — and rejects a window missing a fifth of its own clock.
    static let minCoverage: Double = 0.80

    /// The readout for one window. `rr` is nil for a lane that carries intervals without their wall-clock
    /// times; that resolves HERE rather than at the call site, so there is one place a band goes blank.
    static func measure(_ rr: [RRInterval]?) -> HRVFreqReadout {
        guard let rr else { return .noTimeBase }
        // The same ordering the engine applies internally (`HRVFreqDomain.swift:95`), so the window whose
        // coverage is measured here is exactly the window the spectrum was computed over.
        let ordered = rr.sorted { $0.ts < $1.ts }
        guard let spectrum = HRVFreqDomain.freqDomain(rr: ordered) else { return .tooShort }
        guard let cov = coverage(ordered) else { return .noTimeBase }
        return cov >= minCoverage ? .measured(spectrum, coverage: cov) : .gapped(coverage: cov)
    }

    /// Fraction of a time-ordered window's wall clock that the KEPT beats actually account for:
    /// Σ(kept R-R) ÷ (last kept ts − first kept ts).
    ///
    /// `HRVAnalyzer.cleanRRIndexed` is what makes this measurable: it applies the same range + Malik
    /// filter as `cleanRR` but carries each survivor's position in the raw series (`HRVAnalyzer.swift:194`),
    /// so the survivors are the engine's survivors AND their timestamps are known. The final interval is
    /// left out of the sum because the engine's tachogram ends at the sum of the beats BEFORE the last one
    /// (`HRVFreqDomain.swift:108-114`). Clamped to 1 — beats cannot cover more clock than exists, and a
    /// ratio over 1 means repeated timestamps, not better coverage. nil when there is no clock to measure
    /// against (a zero or backwards span).
    static func coverage(_ ordered: [RRInterval]) -> Double? {
        let kept = HRVAnalyzer.cleanRRIndexed(ordered.map { Double($0.rrMs) })
        guard kept.count >= 2, let first = kept.first, let last = kept.last else { return nil }
        let wall = Double(ordered[last.index].ts - ordered[first.index].ts)
        guard wall > 0 else { return nil }
        let cumulative = kept.dropLast().reduce(0.0) { $0 + $1.value } / 1000.0
        return min(cumulative / wall, 1)
    }

    /// The bands, or nil in every withheld state — the single seam the cells and the caption read.
    var bands: HRVFreqDomain.Bands? {
        if case .measured(let b, _) = self { return b }
        return nil
    }

    /// The four grid cells (label, value, unit) in render order. Every withheld state — plus the engine's
    /// own nil LF on a 60–250 s window — resolves to an em-dash here, never to a plausible-looking zero.
    var cells: [(String, String, String)] {
        let b = bands
        let lf: String = b.flatMap { $0.lf }.map { Self.power($0) } ?? "—"
        let hf: String = b.map { Self.power($0.hf) } ?? "—"
        let ratio: String = b.flatMap { $0.lfhf }.map { String(format: "%.2f", $0) } ?? "—"
        let total: String = b.map { Self.power($0.totalPower) } ?? "—"
        return [("LF", lf, "ms²"), ("HF", hf, "ms²"), ("LF/HF", ratio, ""), ("total power", total, "ms²")]
    }

    /// The caption under the cells: what clock the bands were read on, and — when they are blank — why.
    var caption: String {
        let base: String = "LF 0.04–0.15 Hz, HF 0.15–0.40 Hz, read by Lomb-Scargle straight off the uneven R-R. The clock is the running sum of the kept beats, not wall time, so a gap in the record is stitched shut and every frequency shifts with it. LF/HF is the ratio of those two band powers and nothing more."
        switch self {
        case .measured(_, let coverage):
            return "\(base) Kept beats account for \(Self.pct(coverage)) of this window's wall clock."
        case .gapped(let coverage):
            return "\(base) Kept beats account for \(Self.pct(coverage)) of this window's wall clock, under the \(Self.pct(Self.minCoverage)) floor, so the bands stay blank rather than report shifted frequencies."
        case .tooShort:
            return "\(base) This window is too short for a spectrum: HF needs \(Int(HRVFreqDomain.minSpanForHFSec)) s of R-R, LF needs \(Int(HRVFreqDomain.minSpanForLFSec)) s."
        case .noTimeBase:
            return "\(base) The gap check needs a wall-clock time on every beat and this window carries none — the live comet is intervals only — so the bands stay blank until a stored window loads."
        }
    }

    /// Three significant figures, plain decimal. Band powers swing over orders of magnitude between
    /// windows, and a fixed decimal place prints two visibly different bands as the same "0.00" beside an
    /// LF/HF ratio that says they differ. Never scientific notation: in a tabular readout it reads as a
    /// different instrument.
    static func power(_ v: Double) -> String {
        guard v > 0 else { return "0" }
        let places = min(max(0, 2 - Int(floor(log10(v)))), 5)
        return String(format: "%.\(places)f", v)
    }

    private static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}

// MARK: - Synthetic R-R (previews / no-store)

extension SignalLabHRVView {
    /// A deterministic clean R-R night sample (ms) — a slow respiratory sway around ~940 ms with fine
    /// beat-to-beat jitter, so the Poincaré cloud reads as a real comet. `count` beats, fixed origin ts.
    static func syntheticClean(count: Int = 160, startTs: Int = 1_760_000_000) -> [RRInterval] {
        var out: [RRInterval] = []
        out.reserveCapacity(count)
        var ts = startTs
        for i in 0..<count {
            let phase = Double(i)
            let rsa = 45 * sin(phase / 7)            // respiratory sinus arrhythmia sway
            let jitter = 14 * sin(phase * 1.9) + 8 * sin(phase * 0.53)
            let rr = 940 + rsa + jitter
            let ms = Int(rr.rounded())
            out.append(RRInterval(ts: ts, rrMs: ms))
            ts += 1   // ~1 Hz wall-clock advance (RR ≈ 940 ms)
        }
        return out
    }

    /// The clean set with injected artifacts: a handful of out-of-range beats (a dropped/doubled interval)
    /// and ectopic jumps, so the panel demonstrates the dimmed off-axis outliers + rejected count.
    static func syntheticWithEctopics(count: Int = 160) -> [RRInterval] {
        var rr = syntheticClean(count: count)
        func poke(_ idx: Int, _ ms: Int) { if rr.indices.contains(idx) { rr[idx] = RRInterval(ts: rr[idx].ts, rrMs: ms) } }
        poke(28, 210)    // out-of-range (dropped beat) < 300 ms
        poke(61, 1_480)  // ectopic long jump (in range, ≫ local median)
        poke(96, 520)    // ectopic short jump
        poke(129, 2_300) // out-of-range (missed beat) > 2000 ms
        return rr
    }
}

// MARK: - Previews

#Preview("Signal Lab · HRV (clean) — light") {
    HRVPreviewHost(rr: SignalLabHRVView.syntheticClean()).preferredColorScheme(.light)
}

#Preview("Signal Lab · HRV (ectopics) — dark") {
    HRVPreviewHost(rr: SignalLabHRVView.syntheticWithEctopics()).preferredColorScheme(.dark)
}

#Preview("Signal Lab · HRV (ectopics) — light") {
    HRVPreviewHost(rr: SignalLabHRVView.syntheticWithEctopics()).preferredColorScheme(.light)
}

// 400 beats ≈ 376 s of R-R across a 399 s clock — past `HRVFreqDomain.minSpanForLFSec` and clear of the
// coverage floor, so this pair is the only place the LF and LF/HF cells are exercised. The 160-beat
// previews above sit between the two span gates and correctly show HF only.

#Preview("Signal Lab · HRV (6 min · bands) — light") {
    HRVPreviewHost(rr: SignalLabHRVView.syntheticClean(count: 400)).preferredColorScheme(.light)
}

#Preview("Signal Lab · HRV (6 min · bands) — dark") {
    HRVPreviewHost(rr: SignalLabHRVView.syntheticClean(count: 400)).preferredColorScheme(.dark)
}

private struct HRVPreviewHost: View {
    let rr: [RRInterval]
    private let root = AppRoot()

    var body: some View {
        VStack {
            SignalLabHRVView(injectedRR: rr)
                .padding(WM.Space.gutter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
        .environmentObject(root.repo)
        .environmentObject(root.live)
    }
}
