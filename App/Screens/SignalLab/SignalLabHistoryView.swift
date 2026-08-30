import SwiftUI
import StrapAnalytics

/// HISTORY mode — a stacked multi-lane oscilloscope over the stored raw channels, sharing ONE time
/// x-axis. Per-lane independent y-autoscale, channel show/hide, pinch-zoom + pan the time axis, and a
/// drag cursor that reads out every visible channel's value at time t. Chrome stays neutral ink; the
/// traces themselves are the data (restrained ink/graphite per-trace differentiation for legibility).
///
/// PERFORMANCE: all the heavy work is CACHED off the render path. The per-channel drawable traces are
/// built once per (history · unit · gravity-mode) into `fullTraces`; the decimated, per-lane draw arrays
/// + y-scale are rebuilt only when the visible window SETTLES (`laneDraws`). During an active pinch/pan
/// the Canvas re-projects the last settled points geometrically (pure arithmetic on `vis`) — it never
/// re-slices or re-decimates, so a gesture frame allocates nothing. Edges may thin until the gesture
/// ends, when the proper slice+decimate is recomputed. `timeBounds` and the DateFormatters are cached too.
///
/// Fully previewable with a synthetic `ScopeHistory` — no Repository, no BLE.
struct SignalLabHistoryView: View {
    let history: ScopeHistory
    @Binding var unit: SignalLabMath.ScopeUnit
    /// Called on a settled zoom/pan with the new visible window so the owner can widen/refine the read
    /// (bounded). nil in previews — the synthetic set is drawn as-is.
    var onReload: ((ClosedRange<Double>) -> Void)? = nil

    @State private var visible: ClosedRange<Double>? = nil
    @State private var cursorT: Double? = nil
    @State private var enabled: Set<ScopeChannel> = [.hr, .rr, .gravity, .skinTemp]
    @State private var gravityMag = false
    @State private var gestureBase: ClosedRange<Double>? = nil   // window at gesture start

    /// Metric/Imperial pref → the PHYSICAL skin-temp trace's °C/°F. Part of `cacheKey`, so flipping Units
    /// invalidates `fullTraces` and rebuilds the converted trace (and the readout binary-searches the fresh
    /// cache). Raw ADC mode is unaffected.
    @AppStorage(TempUnit.systemKey) private var unitSystem = "metric"
    private var isImperial: Bool { unitSystem == "imperial" }

    // MARK: Caches (rebuilt OFF the render path — never inside `body`)

    /// Full-resolution drawable traces per channel, in the current unit + gravity mode. Rebuilt only when
    /// `cacheKey` changes (history / unit / gravity toggle). The cursor readout binary-searches these.
    @State private var fullTraces: [ScopeChannel: [ScopeTrace]] = [:]
    /// The full time extent of everything loaded — computed once per history, not scanned per frame.
    @State private var cachedBounds: ClosedRange<Double>? = nil
    /// Per-lane decimated draw arrays + padded y-scale for the SETTLED window. Rebuilt on settle / toggle,
    /// never during an active gesture. The Canvas re-projects these against the live `vis`.
    @State private var laneDraws: [LaneDraw] = []

    /// Smallest allowed visible span (5 s) so a hard pinch-in can't divide by ~0.
    private static let minSpan: Double = 5

    /// One drawn lane's cached geometry: the decimated traces + a padded [yLo, yHi] shared y-scale.
    private struct LaneDraw: Identifiable {
        let channel: ScopeChannel
        var id: ScopeChannel { channel }
        let traces: [DrawTrace]
        let yLo: Double
        let yHi: Double
    }

    /// One decimated trace ready to stroke — points are already sliced to the settled window and reduced
    /// to ≤ `maxDrawPoints`, so the Canvas only maps them through `x`/`yPix`.
    private struct DrawTrace: Identifiable {
        let id: String
        let label: String
        let discrete: Bool
        let points: [SignalLabMath.ScopeSample]
    }

    /// Cheap identity of the inputs that invalidate `fullTraces`. Deliberately O(1) (bounds + per-channel
    /// counts) so comparing it every `body` eval — including per gesture frame — costs nothing; the
    /// arrays themselves are never compared.
    private struct CacheKey: Equatable {
        let loadedStart: Double
        let loadedEnd: Double
        let counts: [Int]
        let unit: SignalLabMath.ScopeUnit
        let gravityMag: Bool
        let imperial: Bool
    }

    private var cacheKey: CacheKey {
        CacheKey(loadedStart: history.loadedStart, loadedEnd: history.loadedEnd,
                 counts: [history.hr.count, history.rr.count, history.gravity.count, history.skinTemp.count,
                          history.spo2.count, history.resp.count, history.steps.count, history.sleepState.count],
                 unit: unit, gravityMag: gravityMag, imperial: isImperial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            controls
            presetRow
            channelChips
            lanes
            readout
            ruler
        }
        .onAppear {
            seedEnabledAndWindow()
            rebuildFullTraces()
        }
        // History reload / unit / gravity toggle → rebuild the full traces (which rebuilds the draw cache).
        .onChange(of: cacheKey) { _, _ in rebuildFullTraces() }
        // Channel show/hide changes which lanes draw → refresh the settled draw cache (cheap).
        .onChange(of: enabled) { _, _ in rebuildDrawCache() }
    }

    // MARK: Derived window

    private var bounds: ClosedRange<Double> {
        cachedBounds ?? (history.loadedStart...max(history.loadedStart + 1, history.loadedEnd))
    }

    /// The visible window, defaulting to the last ≤6 h of loaded data until the user zooms/pans.
    private var vis: ClosedRange<Double> {
        if let v = visible { return v }
        let b = bounds
        let lo = max(b.lowerBound, b.upperBound - 6 * 3600)
        return lo...b.upperBound
    }

    private var activeChannels: [ScopeChannel] {
        ScopeChannel.allCases.filter { enabled.contains($0) && history.hasData($0) }
    }

    // MARK: Cache rebuilds

    /// Rebuild the full-resolution per-channel traces + cached bounds (history / unit / gravity changed),
    /// then refresh the settled draw cache. This is the ONLY place `history.traces(for:…)` is called.
    private func rebuildFullTraces() {
        var t: [ScopeChannel: [ScopeTrace]] = [:]
        for ch in ScopeChannel.allCases where history.hasData(ch) {
            t[ch] = history.traces(for: ch, unit: unit, gravityMagnitude: gravityMag, imperial: isImperial)
        }
        fullTraces = t
        cachedBounds = history.timeBounds
        rebuildDrawCache()
    }

    /// Rebuild the decimated per-lane draw arrays + y-scale for the CURRENT (settled) window. Called on
    /// settle / toggle only — never during a live gesture (`onChanged` just moves `visible`).
    private func rebuildDrawCache() {
        let window = vis
        var draws: [LaneDraw] = []
        draws.reserveCapacity(activeChannels.count)
        for ch in activeChannels {
            var drawTraces: [DrawTrace] = []
            var ys: [Double] = []
            for tr in fullTraces[ch] ?? [] {
                let sliced = Self.visibleSlice(tr.samples, window)
                let dec = SignalLabMath.decimate(sliced, to: SignalLabMath.maxDrawPoints)
                drawTraces.append(DrawTrace(id: tr.id, label: tr.label, discrete: tr.discrete, points: dec))
                // Shared per-lane y-scale over ALL traces' visible samples (full slice, not decimated).
                for s in sliced { ys.append(s.v) }
            }
            let rawLo = ys.min() ?? 0
            let rawHi = ys.max() ?? 1
            let pad = (rawHi - rawLo) == 0 ? 1 : (rawHi - rawLo) * 0.12
            draws.append(LaneDraw(channel: ch, traces: drawTraces, yLo: rawLo - pad, yHi: rawHi + pad))
        }
        laneDraws = draws
    }

    // MARK: Controls (span + reset + unit-independent gravity mode)

    private var controls: some View {
        HStack(spacing: WM.Space.l) {
            Text(Self.spanLabel(vis)).font(WMType.label).foregroundStyle(WM.Ground.inkSecondary)
                .monospacedDigit()
            Spacer()
            if enabled.contains(.gravity) && history.hasData(.gravity) {
                toggleWord(gravityMag ? "|g|" : "xyz", active: true) { gravityMag.toggle() }
                    .accessibilityLabel(gravityMag ? "Gravity magnitude" : "Gravity axes")
            }
            toggleWord("reset", active: false) {
                visible = nil; cursorT = nil
                rebuildDrawCache()
                onReload?(vis)
            }
        }
    }

    private func toggleWord(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).wmOverline(active ? WM.Ground.ink : WM.Ground.inkTertiary)
                .frame(minWidth: 44, minHeight: 44)   // HIG target on BOTH axes (narrow "1h"/"15m" presets
                .contentShape(Rectangle())            // sit adjacent, so width matters as much as height)
        }
        .buttonStyle(.plain)
    }

    // MARK: Window-span presets

    /// A thin left-aligned row of span shortcuts under the controls (kept off the controls row so the
    /// span label + gravity + reset don't crowd). Each word snaps the window to that span, anchored at the
    /// newest end, and fires the bounded re-read — which is how 24h pulls in more than the initial 6 h.
    private var presetRow: some View {
        HStack(spacing: WM.Space.l) {
            presetWord("15m", span: 15 * 60, accessibility: "15 minute window")
            presetWord("1h", span: 3600, accessibility: "1 hour window")
            presetWord("6h", span: 6 * 3600, accessibility: "6 hour window")
            presetWord("24h", span: 24 * 3600, accessibility: "24 hour window")
            Spacer()
        }
    }

    private func presetWord(_ label: String, span: Double, accessibility: String) -> some View {
        toggleWord(label, active: isPresetActive(span)) { applyPreset(span) }
            .accessibilityLabel(accessibility)
    }

    /// Active when the visible span is within ~2 % of `span` AND still anchored at the newest end (a
    /// pinch/pan that drifts the window off the newest edge just leaves the whole row inactive).
    private func isPresetActive(_ span: Double) -> Bool {
        let v = vis
        guard abs((v.upperBound - v.lowerBound) - span) <= span * 0.02 else { return false }
        return abs(v.upperBound - bounds.upperBound) <= span * 0.02
    }

    /// Snap the window to `span` anchored at the newest loaded end. Deliberately does NOT route through
    /// `clampSpan` (which caps at the currently-loaded extent): a 24 h ask must be allowed to grow leftward
    /// past `loadedStart` so `onReload` → the owner's bounded re-read actually widens the loaded window.
    /// Once that read lands, `cacheKey` changes and `rebuildFullTraces` refills the caches over the wider
    /// span. If the store holds less than `span`, the read returns what exists — acceptable.
    private func applyPreset(_ span: Double) {
        let hi = bounds.upperBound
        visible = (hi - span)...hi
        cursorT = nil
        rebuildDrawCache()   // settle path: proper slice + decimate for the new window
        onReload?(vis)
    }

    // MARK: Channel show/hide chips

    private var channelChips: some View {
        // A simple two-row wrap of the 8 channels.
        let cols = [GridItem(.adaptive(minimum: 56), spacing: WM.Space.s)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: WM.Space.s) {
            ForEach(ScopeChannel.allCases) { ch in
                let has = history.hasData(ch)
                Button {
                    if enabled.contains(ch) { enabled.remove(ch) } else { enabled.insert(ch) }
                } label: {
                    Text(ch.chip)
                        .font(WMType.overline)
                        .kerning(WMType.overlineTracking)
                        .foregroundStyle(!has ? WM.Ground.inkTertiary.opacity(0.5)
                                         : (enabled.contains(ch) ? WM.Ground.ground : WM.Ground.ink))
                        .padding(.vertical, 5).frame(maxWidth: .infinity)
                        .background(enabled.contains(ch) && has ? WM.Ground.ink : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(WM.Ground.rule, lineWidth: WM.hairline))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .opacity(has ? 1 : 0.5)
                        .frame(minHeight: 44)          // HIG hit height AFTER the pill styling, so the visible
                        .contentShape(Rectangle())     // pill stays ~23pt while the tap region centers to 44
                }
                .buttonStyle(.plain)
                .disabled(!has)
                .accessibilityLabel("\(ch.title)\(has ? "" : " — no data")")
                .accessibilityAddTraits(enabled.contains(ch) && has ? .isSelected : [])
            }
        }
    }

    // MARK: Lanes (shared x-axis, shared cursor, gestures)

    private var lanes: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let draws = laneDraws
            let laneH = draws.isEmpty ? geo.size.height
                : max(40, min(84, geo.size.height / CGFloat(draws.count)))
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if draws.isEmpty {
                        emptyLanes
                    } else {
                        ForEach(draws) { d in
                            laneCanvas(d, width: w, height: laneH)
                                .frame(height: laneH)
                            WMRule()
                        }
                    }
                }
                // Shared cursor line across all lanes.
                if let t = cursorT, w > 0 {
                    let cx = x(t, w)
                    Rectangle().fill(WM.Ground.ink.opacity(0.55))
                        .frame(width: 1)
                        .offset(x: cx)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(cursorDrag(width: w))
            .gesture(zoomGesture(width: w))
        }
        .frame(minHeight: 220)
    }

    private var emptyLanes: some View {
        VStack {
            Spacer()
            Text(history.isEmpty ? "No stored samples in this window"
                 : "No channels selected")
                .font(WMType.body).foregroundStyle(WM.Ground.inkTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Draw one lane from its CACHED decimated traces. The only per-frame work is mapping the settled
    /// points through `x` (live `vis`) + `yPix` (cached y-scale) — no slice, no decimate, no allocation
    /// beyond the Path itself. During a gesture `vis` moves under the fixed points, so the trace scrolls /
    /// scales geometrically; edges may thin until `rebuildDrawCache` runs on settle.
    private func laneCanvas(_ d: LaneDraw, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                // Baseline + label row.
                let floor = CGRect(x: 0, y: size.height - WM.hairline, width: size.width, height: WM.hairline)
                ctx.fill(Path(floor), with: .color(WM.Ground.rule))
                let lo = d.yLo, hi = d.yHi
                guard hi > lo else { return }
                func yPix(_ v: Double) -> CGFloat {
                    let f = (v - lo) / (hi - lo)
                    return size.height - CGFloat(f) * (size.height - 2) - 1
                }
                for (i, tr) in d.traces.enumerated() {
                    let slice = tr.points
                    guard slice.count >= 1 else { continue }
                    var path = Path()
                    for (j, s) in slice.enumerated() {
                        let px = x(s.t, size.width)
                        let py = yPix(s.v)
                        if j == 0 { path.move(to: CGPoint(x: px, y: py)) }
                        else if tr.discrete {
                            path.addLine(to: CGPoint(x: px, y: path.currentPoint?.y ?? py))
                            path.addLine(to: CGPoint(x: px, y: py))
                        } else {
                            path.addLine(to: CGPoint(x: px, y: py))
                        }
                    }
                    ctx.stroke(path, with: .color(traceInk(i)), lineWidth: i == 0 ? 1.2 : 1)
                }
            }
            laneHeader(d.channel, traces: d.traces)
        }
    }

    private func laneHeader(_ ch: ScopeChannel, traces: [DrawTrace]) -> some View {
        HStack(spacing: WM.Space.s) {
            Text(ch.title.uppercased()).font(WMType.overline)
                .kerning(WMType.overlineTracking).foregroundStyle(WM.Ground.inkTertiary)
            if traces.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(traces.enumerated()), id: \.offset) { i, tr in
                        HStack(spacing: 2) {
                            Rectangle().fill(traceInk(i)).frame(width: 8, height: 1.5)
                            Text(tr.label).font(WMType.overline).foregroundStyle(WM.Ground.inkTertiary)
                        }
                    }
                }
            }
            Spacer()
            Text(ch.unitLabel(unit, imperial: isImperial)).font(WMType.overline)
                .foregroundStyle(WM.Ground.inkTertiary.opacity(0.7))
        }
        .padding(.horizontal, 2).padding(.top, 2)
    }

    /// Restrained ink differentiation — NO saturated domain colours (this is not a Charge/Effort/Rest
    /// surface). Trace 0 is full ink; extras step down through the ink hierarchy.
    private func traceInk(_ i: Int) -> Color {
        switch i {
        case 0:  return WM.Ground.ink
        case 1:  return WM.Ground.inkSecondary
        default: return WM.Ground.inkTertiary
        }
    }

    // MARK: Cursor readout table

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Cursor").font(WMType.overline).kerning(WMType.overlineTracking)
                    .foregroundStyle(WM.Ground.inkTertiary)
                Spacer()
                Text(cursorT.map(Self.timeLabel) ?? "drag on the scope")
                    .font(WMType.label).monospacedDigit().foregroundStyle(WM.Ground.inkSecondary)
            }
            if let t = cursorT {
                ForEach(readoutRows(at: t), id: \.id) { row in
                    HStack {
                        Text(row.label).font(WMType.caption).foregroundStyle(WM.Ground.inkSecondary)
                        Spacer()
                        Text(row.value).font(WMType.caption).monospacedDigit()
                            .foregroundStyle(WM.Ground.ink)
                        Text(row.unit).font(WMType.overline).foregroundStyle(WM.Ground.inkTertiary)
                            .frame(width: 30, alignment: .leading)
                    }
                }
            }
        }
        .frame(minHeight: 44, alignment: .top)
    }

    private struct ReadoutRow { let id: String; let label: String; let value: String; let unit: String }

    /// Cursor values come from the CACHED full-resolution traces (never rebuilt here), binary-searched by
    /// the frozen `SignalLabMath.interpolatedValue` / `holdValue`. So dragging the cursor allocates nothing
    /// and never invalidates the lane draw cache.
    private func readoutRows(at t: Double) -> [ReadoutRow] {
        var rows: [ReadoutRow] = []
        for ch in activeChannels {
            for tr in fullTraces[ch] ?? [] {
                let v = tr.discrete ? SignalLabMath.holdValue(at: t, in: tr.samples)
                                    : SignalLabMath.interpolatedValue(at: t, in: tr.samples)
                let label = tr.label.isEmpty ? ch.title : "\(ch.title) \(tr.label)"
                rows.append(ReadoutRow(id: tr.id, label: label,
                                       value: v.map { Self.format($0, ch, unit) } ?? "—",
                                       unit: ch.unitLabel(unit, imperial: isImperial)))
            }
        }
        return rows
    }

    // MARK: Time ruler + pan

    private var ruler: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                WMRule()
                ForEach(Self.tickTimes(vis), id: \.self) { tt in
                    Text(Self.axisLabel(tt, span: vis.upperBound - vis.lowerBound))
                        .font(WMType.overline).monospacedDigit()
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize()
                        .offset(x: min(max(0, x(tt, w) - 16), w - 34), y: 4)
                }
            }
            .contentShape(Rectangle())
            .gesture(panGesture(width: w))
        }
        .frame(height: 22)
        .accessibilityLabel("Time axis — drag to pan")
    }

    // MARK: Gestures

    private func cursorDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                guard width > 0 else { return }
                cursorT = min(vis.upperBound, max(vis.lowerBound, time(g.location.x, width)))
            }
    }

    private func zoomGesture(width: CGFloat) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { g in
                let base = gestureBase ?? vis
                if gestureBase == nil { gestureBase = base }
                let center = cursorT ?? (base.lowerBound + (base.upperBound - base.lowerBound) / 2)
                let baseSpan = base.upperBound - base.lowerBound
                let span = clampSpan(baseSpan / max(0.05, g.magnification))
                visible = windowAround(center: center, span: span)
            }
            .onEnded { _ in
                gestureBase = nil
                rebuildDrawCache()   // settle: recompute the proper slice + decimate for the new window
                onReload?(vis)
            }
    }

    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                guard width > 0 else { return }
                let base = gestureBase ?? vis
                if gestureBase == nil { gestureBase = base }
                let span = base.upperBound - base.lowerBound
                let dt = -Double(g.translation.width / width) * span
                visible = shift(base, by: dt)
            }
            .onEnded { _ in
                gestureBase = nil
                rebuildDrawCache()   // settle: recompute the proper slice + decimate for the new window
                onReload?(vis)
            }
    }

    // MARK: Window math

    private func clampSpan(_ s: Double) -> Double {
        let maxSpan = max(Self.minSpan, bounds.upperBound - bounds.lowerBound)
        return min(maxSpan, max(Self.minSpan, s))
    }

    private func windowAround(center: Double, span: Double) -> ClosedRange<Double> {
        var lo = center - span / 2
        var hi = center + span / 2
        let b = bounds
        if lo < b.lowerBound { hi += b.lowerBound - lo; lo = b.lowerBound }
        if hi > b.upperBound { lo -= hi - b.upperBound; hi = b.upperBound }
        lo = max(b.lowerBound, lo)
        return lo...max(lo + Self.minSpan, hi)
    }

    private func shift(_ w: ClosedRange<Double>, by dt: Double) -> ClosedRange<Double> {
        let span = w.upperBound - w.lowerBound
        var lo = w.lowerBound + dt
        let b = bounds
        lo = min(max(b.lowerBound, lo), max(b.lowerBound, b.upperBound - span))
        return lo...(lo + span)
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat {
        let span = vis.upperBound - vis.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((t - vis.lowerBound) / span) * w
    }

    private func time(_ px: CGFloat, _ w: CGFloat) -> Double {
        guard w > 0 else { return vis.lowerBound }
        return vis.lowerBound + Double(px / w) * (vis.upperBound - vis.lowerBound)
    }

    /// Binary-search slice of the time-sorted `s` to `w`, including one sample either side so the line
    /// reaches both edges. Pure + static — used only at cache-build time, never per frame.
    private static func visibleSlice(_ s: [SignalLabMath.ScopeSample], _ w: ClosedRange<Double>) -> [SignalLabMath.ScopeSample] {
        guard !s.isEmpty else { return [] }
        // First index with t >= lowerBound.
        var lo = 0, hi = s.count
        while lo < hi { let m = (lo + hi) / 2; if s[m].t < w.lowerBound { lo = m + 1 } else { hi = m } }
        let firstGE = lo
        // First index with t > upperBound → its predecessor is the last with t <= upperBound.
        var a = 0, b = s.count
        while a < b { let m = (a + b) / 2; if s[m].t <= w.upperBound { a = m + 1 } else { b = m } }
        let lastLE = a - 1
        let start = max(0, firstGE - 1)
        let end = min(s.count - 1, lastLE + 1)
        guard start <= end else { return [] }
        return Array(s[start...end])
    }

    private func seedEnabledAndWindow() {
        // Default-enable the four core lanes, keeping only those with data; if none, the first with data.
        var e = enabled.filter { history.hasData($0) }
        if e.isEmpty, let first = ScopeChannel.allCases.first(where: { history.hasData($0) }) {
            e = [first]
        }
        enabled = e
    }

    // MARK: Formatting

    private static func format(_ v: Double, _ ch: ScopeChannel, _ unit: SignalLabMath.ScopeUnit) -> String {
        switch ch {
        case .gravity:
            return unit == .raw ? String(Int(v.rounded())) : String(format: "%.3f", v)
        case .skinTemp:
            return unit == .raw ? String(Int(v.rounded())) : String(format: "%.2f", v)
        default:
            return String(Int(v.rounded()))
        }
    }

    private static func spanLabel(_ w: ClosedRange<Double>) -> String {
        let s = Int((w.upperBound - w.lowerBound).rounded())
        if s < 90 { return "\(s)s window" }
        if s < 5400 { return "\(Int((Double(s) / 60).rounded()))m window" }
        return String(format: "%.1fh window", Double(s) / 3600)
    }

    /// Cached formatters — a fresh `DateFormatter` per label was allocating on every ruler tick + cursor move.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let minuteFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private static func timeLabel(_ t: Double) -> String {
        clockFormatter.string(from: Date(timeIntervalSince1970: t))
    }

    private static func axisLabel(_ t: Double, span: Double) -> String {
        let f = span < 3600 ? clockFormatter : minuteFormatter
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    private static func tickTimes(_ w: ClosedRange<Double>) -> [Double] {
        let span = w.upperBound - w.lowerBound
        guard span > 0 else { return [] }
        let n = 4
        return (0...n).map { w.lowerBound + span * Double($0) / Double(n) }
    }
}

// MARK: - Previews

#Preview("Signal Lab · History — light") {
    HistoryPreviewHost().preferredColorScheme(.light)
}

#Preview("Signal Lab · History — dark") {
    HistoryPreviewHost().preferredColorScheme(.dark)
}

private struct HistoryPreviewHost: View {
    @State private var unit: SignalLabMath.ScopeUnit = .physical
    var body: some View {
        VStack {
            SignalLabHistoryView(history: .synthetic(), unit: $unit)
                .padding(WM.Space.gutter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
