import SwiftUI
import StrapProtocol

/// The Rest "Wake window" cluster (W9) in the whoopmaxx design language: an open-editorial RuleSection,
/// rest-indigo as the ONLY color, no card. Sits below "Last night" and above "History".
///
/// Content, top to bottom (when enabled): a rest-indigo earliest→latest time pairing hero, an ink enable
/// toggle, two compact DatePickers, and an armed-status line + honesty caption. Disabled collapses to the
/// toggle row + a one-line explainer. Both themes are first-class; it is previewable with a demo settings
/// object (no live Repository / BLE), preserving RestScreenContent's no-live-data preview invariant.
struct WakeWindowSection: View {
    @ObservedObject var settings: SmartAlarmSettings
    /// True when the strap has a genuine encrypted bond, so the firmware backstop is actually armed. The
    /// simulator has no BLE, so this is false there and the section honestly reads "Backup notification
    /// only". Passed in by the RestScreen wrapper off `LiveState.encryptedBond`.
    var strapArmed: Bool
    /// Re-arm/disarm the alarm after any settings change (AppRoot's `alarm.apply()`).
    let onApply: () -> Void
    /// True when a strap is connected, so the Test buzz can actually fire — drives the button's enabled
    /// state (a buzz needs a live link). Defaults false so previews/specimens read the honest disabled copy.
    var canTestBuzz: Bool = false
    /// Fire a one-shot test buzz at the current strength. RestScreen wires this to the coordinator's
    /// `testBuzz()`; the specimen preview leaves it a no-op.
    var onTestBuzz: () -> Void = {}

    var body: some View {
        RuleSection("Wake window") {
            VStack(alignment: .leading, spacing: 0) {
                if settings.enabled {
                    heroPairing
                        .padding(.bottom, WM.Space.l)
                }
                toggleRow
                if settings.enabled {
                    WMRule()
                    pickerRow(label: "Earliest", binding: earliestBinding)
                    WMRule()
                    pickerRow(label: "Latest", binding: latestBinding)
                    statusCaption
                    buzzBlock
                } else {
                    explainer
                }
                thisMorningWake
            }
        }
    }

    // MARK: - This morning's wake (W9.5)

    /// The "This morning's wake" panel, shown ONLY when a real wake fired within the recency window
    /// (~18h). Otherwise omitted entirely — no empty box. Lives in both the enabled and disabled states so
    /// a morning that woke you still explains itself even if you toggled the alarm off afterwards.
    @ViewBuilder
    private var thisMorningWake: some View {
        if let event = settings.latestWakeEvent, ThisMorningWake.isRecent(event, now: Date()) {
            ThisMorningWakeLoader(event: event)
        }
    }

    // MARK: - Hero (the only color on the screen's chrome)

    private var heroPairing: some View {
        HStack(alignment: .firstTextBaseline, spacing: WM.Space.l) {
            heroTime(label: "Earliest", minutes: settings.earliestMin)
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WM.Ground.inkTertiary)
                .accessibilityHidden(true)
            heroTime(label: "Latest", minutes: settings.latestMin)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Wake window, earliest \(Self.timeLabel(settings.earliestMin)) to latest \(Self.timeLabel(settings.latestMin))")
    }

    private func heroTime(label: String, minutes: Int) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text(label).wmOverline()
            Text(Self.timeLabel(minutes))
                .font(WMType.numeral(34))
                .foregroundStyle(WM.Domain.rest.color)
        }
    }

    // MARK: - Rows

    private var toggleRow: some View {
        Toggle(isOn: enabledBinding) {
            Text("Wake me in a window")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
        }
        .tint(WM.Ground.control)
        .padding(.vertical, WM.Space.s)
    }

    private func pickerRow(label: String, binding: Binding<Date>) -> some View {
        HStack {
            Text(label)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Spacer()
            DatePicker("", selection: binding, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(WM.Ground.ink)
                .accessibilityLabel("\(label) wake time")
        }
        .padding(.vertical, WM.Space.m)
    }

    private var explainer: some View {
        Text("Arms a strap buzz within a window. While whoopmaxx is running it can wake you earlier on detected light sleep; the latest time is the guaranteed backstop.")
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, WM.Space.xs)
            .padding(.bottom, WM.Space.s)
    }

    private var statusCaption: some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text(armState.statusLine)
                .font(WMType.label)
                .foregroundStyle(WM.Ground.inkSecondary)
            Text(armState.caption)
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, WM.Space.m)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Buzz strength + test

    /// Buzz strength (Gentle / Standard / Insistent → 1 / 3 / 6 motor loops) + a Test buzz to feel it. Only
    /// the APP-DRIVEN buzzes (early wake + test) vary; the guaranteed latest-edge firmware buzz is fixed.
    private var buzzBlock: some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            WMRule()
            InkSegmentRow(label: "Buzz",
                          options: [(String(BuzzStrength.gentle.loops), "Gentle"),
                                    (String(BuzzStrength.standard.loops), "Standard"),
                                    (String(BuzzStrength.insistent.loops), "Insistent")],
                          selection: buzzStrengthBinding)
            HStack(spacing: WM.Space.s) {
                Button { onTestBuzz() } label: {
                    Text("Test buzz")
                        .font(WMType.body)
                        .foregroundStyle(canTestBuzz ? WM.Ground.ink : WM.Ground.inkTertiary)
                        .frame(minHeight: 44, alignment: .leading)   // HIG 44pt hit height (label padding,
                        .contentShape(Rectangle())                   // not HStack padding, sizes a button)
                }
                .buttonStyle(.plain)
                .disabled(!canTestBuzz)
                Spacer()
                if !canTestBuzz {
                    Text("connect a strap")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            Text("How insistent the early wake-up buzz is. The guaranteed latest-time buzz is a fixed strap pattern.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, WM.Space.m)
    }

    /// Bridges the persisted `buzzLoops` Int to the InkSegmentRow's String selection (loop count as text).
    private var buzzStrengthBinding: Binding<String> {
        Binding(
            get: { String(BuzzStrength.nearest(loops: settings.buzzLoops).loops) },
            set: { settings.buzzLoops = Int($0) ?? BuzzStrength.standard.loops }
        )
    }

    // MARK: - State + bindings

    private var armState: WakeArmState {
        guard settings.enabled else { return .off }
        return strapArmed ? .armedOnStrap : .backupOnly
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { settings.enabled },
                set: { settings.enabled = $0; onApply() })
    }

    private var earliestBinding: Binding<Date> {
        timeBinding(minutes: settings.earliestMin) { settings.setEarliest($0) }
    }

    private var latestBinding: Binding<Date> {
        timeBinding(minutes: settings.latestMin) { settings.setLatest($0) }
    }

    /// Bridge a minutes-since-midnight value to a DatePicker Date, persisting via `apply` on set.
    private func timeBinding(minutes: Int, apply: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = minutes / 60
                c.minute = minutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                apply((c.hour ?? 7) * 60 + (c.minute ?? 0))
                onApply()
            }
        )
    }

    /// Locale-aware HH:mm (respects 12/24-hour), matching the DatePickers below it.
    private static func timeLabel(_ minutes: Int) -> String {
        var c = DateComponents()
        c.hour = minutes / 60
        c.minute = minutes % 60
        let d = Calendar.current.date(from: c) ?? Date()
        return d.formatted(.dateTime.hour().minute())
    }
}

/// The three honest arm states the section presents. Copy is plain, exact, no exclamation.
enum WakeArmState {
    case off
    case backupOnly
    case armedOnStrap

    var statusLine: String {
        switch self {
        case .off:          return "Off"
        case .backupOnly:   return "Backup notification only"
        case .armedOnStrap: return "Armed on the strap"
        }
    }

    var caption: String {
        switch self {
        case .off:
            return ""
        case .backupOnly:
            return "Strap not connected. A backup notification will try to wake you at the latest time. Keep a backup alarm — a notification can be silenced by Focus or silent mode."
        case .armedOnStrap:
            return "The strap itself buzzes your wrist at the latest time — a firm vibration that fires even if whoopmaxx is closed. While the app is open, detection can buzz you earlier on light sleep. It's a vibration, not a sound, so keep a phone alarm as backup in case the strap is off or out of range."
        }
    }
}

// MARK: - This morning's wake — helpers

/// Small pure helpers + constants for the "This morning's wake" panel.
enum ThisMorningWake {
    /// How long after a fire the panel still counts as "this morning" (~18h).
    static let recentWindowSeconds: Double = 18 * 3600

    /// True when `event` fired within the recency window of `now` (and not in the future).
    static func isRecent(_ event: WakeEvent, now: Date) -> Bool {
        let age = now.timeIntervalSince1970 - event.firedEpoch
        return age >= 0 && age <= recentWindowSeconds
    }
}

/// A fully-resolved model for the pure `ThisMorningWakePanel`: the stored HR line over the window, the
/// streamed coverage, and the confidence assessment. Loaded ONCE by `ThisMorningWakeLoader` (cached in
/// @State), so the pure panel + its previews never touch a Repository.
struct WakeTraceModel: Equatable {
    struct Point: Equatable { let ts: Int; let bpm: Int }
    let event: WakeEvent
    let points: [Point]
    let coverageFraction: Double
    let assessment: WakeConfidence.Assessment
    /// False for the loading placeholder (no data fetched yet) — the panel then shows a muted "reading"
    /// state with no numbers, so a fetch never flashes wrong values.
    var resolved: Bool = true
}

// MARK: - This morning's wake — loader (the only Repository-touching part)

/// Fetches the wake window's stored HR line + streamed coverage from the live Repository ONCE (cached in
/// @State, not per frame), runs the confidence rubric, and hands a resolved model to the pure panel. Only
/// ever constructed when there is a recent wake event, so the specimen previews (no event) never require a
/// Repository in the environment.
private struct ThisMorningWakeLoader: View {
    @EnvironmentObject private var repo: Repository
    let event: WakeEvent
    @State private var model: WakeTraceModel?

    var body: some View {
        ThisMorningWakePanel(model: model ?? .placeholder(for: event))
            .task(id: event) { await load() }
    }

    private func load() async {
        let windowStart = Int(event.windowStartEpoch.rounded())
        let deadline = Int(event.deadlineEpoch.rounded())
        let fired = Int(event.firedEpoch.rounded())
        // The window's HR up to the wake (after the wake the user is up). Size the read to the window
        // seconds + margin so a ~1 Hz night isn't truncated by the default 8000-sample cap.
        let lineEnd = max(fired, windowStart + 1)
        let windowSpan = max(1, deadline - windowStart)
        let samples = await repo.hrSamples(from: windowStart, to: lineEnd,
                                           limit: max(8000, windowSpan + 3600))
        // Streamed coverage over the ELAPSED portion of the window (up to the wake). COUNT-only, no rows.
        let coverageEnd = event.trigger == .earlyWatcher ? fired : deadline
        let elapsed = max(1, coverageEnd - windowStart)
        let fp = await repo.hrFingerprint(from: windowStart, to: coverageEnd)
        let coverage = min(1, Double(fp.count) / Double(elapsed))
        let deadlinePassed = Date().timeIntervalSince1970 >= event.deadlineEpoch
        let assessment = WakeConfidence.assess(event: event, hrCoverageFraction: coverage,
                                               deadlinePassed: deadlinePassed)
        model = WakeTraceModel(event: event,
                               points: samples.map { .init(ts: $0.ts, bpm: $0.bpm) },
                               coverageFraction: coverage,
                               assessment: assessment)
    }
}

private extension WakeTraceModel {
    /// The muted loading placeholder — no fetched data, no numbers yet.
    static func placeholder(for event: WakeEvent) -> WakeTraceModel {
        WakeTraceModel(event: event, points: [], coverageFraction: 0,
                       assessment: WakeConfidence.assess(event: event, hrCoverageFraction: 0,
                                                         deadlinePassed: true),
                       resolved: false)
    }
}

// MARK: - This morning's wake — pure panel

/// The pure "This morning's wake" subsection: a sub-eyebrow + hairline, the wake-trace sparkline, a
/// confidence gauge (pips + tier + plain reasons), and one honest sentence. Rest-indigo marks the wake
/// DECISION; everything else stays neutral ink. Fully previewable from a synthetic model.
struct ThisMorningWakePanel: View {
    let model: WakeTraceModel
    private var event: WakeEvent { model.event }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("This morning's wake").wmOverline()
            WMRule()

            WakeTraceSparkline(model: model)
                .frame(height: 84)
                .padding(.top, WM.Space.xs)

            if model.resolved {
                gauge
                Text(Self.sentence(for: model))
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Reading this morning's wake…")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .padding(.top, WM.Space.l)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: model))
    }

    // MARK: Gauge

    private var gauge: some View {
        let a = model.assessment
        let filled = WakeConfidence.filledPips(for: a.score)
        return VStack(alignment: .leading, spacing: WM.Space.xs) {
            HStack(alignment: .center, spacing: WM.Space.s) {
                HStack(spacing: 5) {
                    ForEach(0..<5, id: \.self) { i in
                        Circle()
                            .fill(i < filled ? WM.Domain.rest.color : Color.clear)
                            .overlay(
                                Circle().stroke(i < filled ? Color.clear : WM.Ground.inkTertiary,
                                                lineWidth: WM.hairline)
                            )
                            .frame(width: 8, height: 8)
                    }
                }
                Text(a.tier.label)
                    .font(WMType.label)
                    .foregroundStyle(WM.Ground.inkSecondary)
            }
            Text(a.reasons.joined(separator: " · "))
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Copy (plain, exact — house voice)

    /// One honest sentence describing the wake. Locale-aware time; deterministic numbers.
    static func sentence(for model: WakeTraceModel) -> String {
        let e = model.event
        let fireTime = timeLabel(e.firedEpoch)
        let pct = Int((min(max(model.coverageFraction, 0), 1) * 100).rounded())
        switch e.trigger {
        case .earlyWatcher:
            let minsEarly = Int(((e.deadlineEpoch - e.firedEpoch) / 60).rounded())
            if minsEarly > 0 {
                return "Light-sleep early wake at \(fireTime), \(minsEarly) min before your latest edge — strap streamed \(pct)% of the window."
            }
            return "Light-sleep early wake at \(fireTime) — strap streamed \(pct)% of the window."
        case .strapBackstop:
            if model.coverageFraction < 0.1 {
                return "Woke at your latest edge (\(fireTime)). The app wasn't streaming, so detection couldn't run."
            }
            return "Woke at your latest edge (\(fireTime)). The strap buzzed as a backstop; the live watcher didn't engage."
        }
    }

    static func accessibilityLabel(for model: WakeTraceModel) -> String {
        guard model.resolved else { return "This morning's wake. Reading." }
        return "This morning's wake. " + sentence(for: model) + " " + model.assessment.tier.label + "."
    }

    /// Locale-aware HH:mm for a unix-seconds epoch (matches the pickers above it).
    static func timeLabel(_ epoch: Double) -> String {
        Date(timeIntervalSince1970: epoch).formatted(.dateTime.hour().minute())
    }
}

// MARK: - This morning's wake — the wake-trace sparkline

/// The window's stored HR line with the decision overlaid. The HR line is the neutral instrument trace
/// (ink, matching TimelineStrip's HR-as-ink idiom); Rest-indigo marks the DECISION — the nightly-trough
/// line, the threshold (trough + 6) line, and the fire point where HR first crossed it. For a strap
/// backstop there is no trough/threshold and NO fabricated trip point: the indigo latest-edge marker IS
/// the wake, and the HR line is drawn if any exists.
private struct WakeTraceSparkline: View {
    let model: WakeTraceModel

    var body: some View {
        Canvas { ctx, size in
            let e = model.event
            let x0 = e.windowStartEpoch
            let x1 = max(e.deadlineEpoch, e.firedEpoch)   // axis spans the whole window to the latest edge
            let span = x1 - x0
            guard span > 0 else { return }
            func x(_ ts: Double) -> CGFloat { CGFloat((ts - x0) / span) * size.width }

            // Y-scale over the HR points + any trough/threshold, with a little headroom so a flat night
            // isn't squished onto the floor.
            let bpms = model.points.map { Double($0.bpm) }
            var lo = bpms.min() ?? 50
            var hi = bpms.max() ?? 60
            if let t = e.troughBpm { lo = min(lo, Double(t)) }
            if let th = e.thresholdBpm { hi = max(hi, Double(th)) }
            if hi - lo < 8 { let mid = (hi + lo) / 2; lo = mid - 4; hi = mid + 4 }
            let padY = (hi - lo) * 0.15
            lo -= padY; hi += padY
            let ySpan = max(1, hi - lo)
            func y(_ bpm: Double) -> CGFloat { size.height - CGFloat((bpm - lo) / ySpan) * size.height }

            // Floor hairline so an empty trace still reads as an instrument track.
            let floor = CGRect(x: 0, y: size.height - WM.hairline, width: size.width, height: WM.hairline)
            ctx.fill(Path(floor), with: .color(WM.Ground.rule))

            // Latest-edge marker. For a strap backstop this IS the wake → rest-indigo; for an early wake
            // it's the edge you didn't need → a faint neutral dashed line.
            let isBackstop = e.trigger == .strapBackstop
            let edgeX = x(e.deadlineEpoch)
            var edge = Path()
            edge.move(to: CGPoint(x: edgeX, y: 0))
            edge.addLine(to: CGPoint(x: edgeX, y: size.height))
            ctx.stroke(edge,
                       with: .color(isBackstop ? WM.Domain.rest.color.opacity(0.9)
                                               : WM.Ground.inkTertiary.opacity(0.6)),
                       style: StrokeStyle(lineWidth: isBackstop ? 1 : WM.hairline,
                                          dash: isBackstop ? [] : [2, 2]))

            // Early-watcher only: the indigo decision geometry (trough dashed, threshold solid).
            if e.trigger == .earlyWatcher {
                if let t = e.troughBpm {
                    let ty = y(Double(t))
                    var p = Path(); p.move(to: CGPoint(x: 0, y: ty)); p.addLine(to: CGPoint(x: size.width, y: ty))
                    ctx.stroke(p, with: .color(WM.Domain.rest.color.opacity(0.35)),
                               style: StrokeStyle(lineWidth: WM.hairline, dash: [3, 3]))
                }
                if let th = e.thresholdBpm {
                    let thy = y(Double(th))
                    var p = Path(); p.move(to: CGPoint(x: 0, y: thy)); p.addLine(to: CGPoint(x: size.width, y: thy))
                    ctx.stroke(p, with: .color(WM.Domain.rest.color.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 1))
                }
            }

            // The HR line — the neutral instrument trace.
            if model.points.count >= 2 {
                var line = Path()
                for (i, pt) in model.points.enumerated() {
                    let cg = CGPoint(x: x(Double(pt.ts)), y: y(Double(pt.bpm)))
                    if i == 0 { line.move(to: cg) } else { line.addLine(to: cg) }
                }
                ctx.stroke(line, with: .color(WM.Ground.ink.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }

            // The FIRE point — an indigo dot where HR first crossed the threshold. Early-watcher ONLY; a
            // backstop never fabricates a trip point (the indigo edge line above marks its wake instead).
            if e.trigger == .earlyWatcher, let th = e.thresholdBpm {
                let fx = x(e.firedEpoch)
                let fy = y(Double(th))
                let r: CGFloat = 3.5
                ctx.fill(Path(ellipseIn: CGRect(x: fx - r, y: fy - r, width: r * 2, height: r * 2)),
                         with: .color(WM.Domain.rest.color))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("WakeWindow — enabled, light") {
    WakeWindowSpecimen(enabled: true).preferredColorScheme(.light)
}

#Preview("WakeWindow — enabled, dark") {
    WakeWindowSpecimen(enabled: true).preferredColorScheme(.dark)
}

#Preview("WakeWindow — disabled, light") {
    WakeWindowSpecimen(enabled: false).preferredColorScheme(.light)
}

private struct WakeWindowSpecimen: View {
    let enabled: Bool

    var body: some View {
        // A volatile defaults suite so the preview never touches the app's real alarm settings.
        let settings = SmartAlarmSettings(defaults: UserDefaults(suiteName: "wm.preview.wakewindow")!)
        settings.enabled = enabled
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WakeWindowSection(settings: settings, strapArmed: false, onApply: {})
            }
            .padding(.horizontal, WM.Space.gutter)
        }
        .background(WM.Ground.ground)
    }
}

// MARK: - This morning's wake previews (pure panel + synthetic HR — no Repository/BLE)

#Preview("Wake panel — early, light") {
    ThisMorningWakeSpecimen(kind: .early).preferredColorScheme(.light)
}

#Preview("Wake panel — early, dark") {
    ThisMorningWakeSpecimen(kind: .early).preferredColorScheme(.dark)
}

#Preview("Wake panel — backstop, light") {
    ThisMorningWakeSpecimen(kind: .backstop).preferredColorScheme(.light)
}

#Preview("Wake panel — backstop, dark") {
    ThisMorningWakeSpecimen(kind: .backstop).preferredColorScheme(.dark)
}

private struct ThisMorningWakeSpecimen: View {
    enum Kind { case early, backstop }
    let kind: Kind

    var body: some View {
        ScrollView {
            RuleSection("Wake window") {
                ThisMorningWakePanel(model: Self.model(kind))
            }
            .padding(.horizontal, WM.Space.gutter)
        }
        .background(WM.Ground.ground)
    }

    /// Synthetic model: a 30-minute window ending at the latest edge, a nightly trough of 52 with the
    /// threshold at 58, and HR that settles low then lifts across the threshold at the fire instant.
    static func model(_ kind: Kind) -> WakeTraceModel {
        let deadline = Date().timeIntervalSince1970
        let windowStart = deadline - 30 * 60
        let trough = 52, threshold = 58

        switch kind {
        case .early:
            let fired = deadline - 12 * 60            // woke 12 min before the edge
            var pts: [WakeTraceModel.Point] = []
            let n = Int(fired - windowStart)          // ~1 Hz
            for i in stride(from: 0, to: n, by: 8) {
                let frac = Double(i) / Double(max(1, n - 1))
                // low wobble around the trough, then a rise across the threshold near the fire.
                let base = 50.0 + 3 * sin(Double(i) / 40)
                let lift = frac > 0.8 ? (frac - 0.8) / 0.2 * 9 : 0
                pts.append(.init(ts: Int(windowStart) + i, bpm: Int((base + lift).rounded())))
            }
            let event = WakeEvent(firedEpoch: fired, deadlineEpoch: deadline, windowStartEpoch: windowStart,
                                  trigger: .earlyWatcher, troughBpm: trough, thresholdBpm: threshold,
                                  connected: true, worn: true, encryptedBond: true)
            let a = WakeConfidence.assess(event: event, hrCoverageFraction: 0.82, deadlinePassed: true)
            return WakeTraceModel(event: event, points: pts, coverageFraction: 0.82, assessment: a)

        case .backstop:
            // A sparse, patchy line (app barely streaming) up to the latest edge; no trip point.
            var pts: [WakeTraceModel.Point] = []
            let n = Int(deadline - windowStart)
            for i in stride(from: 0, to: n, by: 60) where Double(i) / Double(n) < 0.4 {
                pts.append(.init(ts: Int(windowStart) + i, bpm: 54 + (i / 60) % 3))
            }
            let event = WakeEvent(firedEpoch: deadline, deadlineEpoch: deadline, windowStartEpoch: windowStart,
                                  trigger: .strapBackstop, troughBpm: nil, thresholdBpm: nil,
                                  connected: false, worn: true, encryptedBond: true)
            let a = WakeConfidence.assess(event: event, hrCoverageFraction: 0.18, deadlinePassed: true)
            return WakeTraceModel(event: event, points: pts, coverageFraction: 0.18, assessment: a)
        }
    }
}
