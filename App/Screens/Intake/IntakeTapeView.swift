import SwiftUI

/// The response tape (024 P3, HRV lane added in wave B): heart rate, skin temperature and rolling
/// RMSSD over the event's window, each drawn against its own pre-event reference, with the minutes
/// the wrist was MOVING marked behind them.
///
/// Reading rules this view is built to keep:
///  - A missing minute is a BREAK in the line, never an interpolation. The strap banking nothing is
///    a fact about the recording, and joining across it would draw a signal nothing measured.
///  - Moving minutes are drawn, not removed (024 decision 3) — they are marked so the reader can see
///    why a rise is there, and excluded from the summary number so the number cannot be built out of
///    a walk to the kitchen.
///  - Every summary number states the still-minute n it was computed over, on the same line. There
///    is no "confidence" word: n is the honest thing and a tier would dress it up.
struct IntakeTapeView: View {
    let tape: IntakeTape
    let event: IntakeEvent
    /// That night's already-scored figures, when the window handed off to sleep and the night has
    /// been scored. Nil otherwise — and nil renders no figures rather than dashes.
    var night: IntakeNightSummary? = nil
    /// What this clock window usually looks like, drawn behind the heart-rate lane. Nil below the
    /// covered-day floor — and nil draws NOTHING, never a thin band with an apology under it.
    var typical: IntakeTypicalBand? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RuleSection("Response") {
                VStack(alignment: .leading, spacing: WM.Space.l) {
                    windowLine
                    if let hr = tape.heartRate {
                        lane(hr, title: "Heart rate", band: typical)
                        if let typical { typicalLine(typical) }
                    }
                    if let skin = tape.skinTemp {
                        lane(skin, title: "Skin temperature")
                    }
                    if let hrv = tape.hrv {
                        lane(hrv, title: "HRV")
                        hrvCoverageLine(hrv)
                    }
                    coverageLine
                }
            }
            if tape.endedAtSleepOnset {
                RuleSection("After this") {
                    sleepHandoff(night)
                }
            }
        }
    }

    // MARK: - Copy

    /// What span is on screen, in words, so the axis needs no labels of its own.
    private var windowLine: some View {
        Text(WMFormat.timeOfDay(tape.eventTs) + " → " + WMFormat.timeOfDay(tape.windowEnd)
             + (tape.endedAtSleepOnset ? ", to sleep onset" : ""))
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
    }

    /// The n, always. A tape whose summary rests on eleven still minutes says eleven.
    private var coverageLine: some View {
        Text(tape.stillMinutes == 0
             ? "No still minutes after this entry — everything in the window was movement, so no "
               + "number is given."
             : "Figures are over the \(tape.stillMinutes) still minute"
               + (tape.stillMinutes == 1 ? "" : "s") + " after this entry. Shaded stretches are "
               + "movement, which is excluded.")
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// HRV's own coverage sentence, because its holes are structural rather than incidental.
    ///
    /// The strap only produces clean beat-to-beat when the wrist is quiet, so this lane is sparse by
    /// nature — measured over the kept corpus, roughly a third to a half of a post-meal window. A
    /// reader who has just seen two near-continuous lanes above will otherwise read the gaps as the
    /// app failing rather than as the strap not having the signal. Stated as a fraction of the window
    /// actually drawn, never as a quality score.
    private func hrvCoverageLine(_ lane: IntakeTape.Lane) -> some View {
        let drawn = lane.points.filter { $0.minute >= 0 }.count
        let span = max(1, (tape.windowEnd - tape.eventTs) / 60)
        return Text("HRV needs a quiet wrist, so it reads on \(drawn) of the \(span) minutes after "
                    + "this entry. The gaps are minutes the strap had no clean beat-to-beat.")
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Where an alcohol window hands off — and, when the night has been scored, the numbers it hands
    /// off TO.
    ///
    /// 024's plan called for a LINK to that night's Rest. Rest's `selectedKey` is private state on a
    /// tab root with no injection point, so a link would mean building a cross-tab deep-link seam
    /// (an app-level request object, the shell consuming it to switch tabs, Rest consuming it to
    /// select the night, and clearing it after) — real plumbing for one arrow. Showing the night's
    /// already-computed numbers here serves the intent more directly: the question was asked on this
    /// screen, so the answer belongs on it.
    ///
    /// Nothing is derived. Every value is read from the same published caches Rest itself renders,
    /// and a night that has not been scored shows the sentence with no numbers rather than dashes.
    private func sleepHandoff(_ night: IntakeNightSummary?) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("The window ends where you fell asleep. What a drink does to sleeping heart rate, "
                 + "HRV and skin temperature is measured across the night, not the hour after.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let night {
                HStack(spacing: WM.Space.l) {
                    ForEach(night.figures, id: \.label) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.label).wmOverline()
                            Text(f.value)
                                .font(WMType.body)
                                .monospacedDigit()
                                .foregroundStyle(WM.Ground.ink)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Lane

    /// Says exactly what the band is, in the words the design decided on: YOUR TYPICAL HOUR, not a
    /// comparison group. Never "days you didn't eat" — see `IntakeTypicalBand`'s type doc for why
    /// that phrasing would be a claim the data cannot support.
    private func typicalLine(_ band: IntakeTypicalBand) -> some View {
        Text("The shaded range is the middle half of what this time of day usually looks like for "
             + "you, across \(band.coveredDays) recent days with data. It is not a comparison with "
             + "days you did not log.")
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lane(_ lane: IntakeTape.Lane, title: String, band: IntakeTypicalBand? = nil) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).wmOverline()
                Spacer(minLength: WM.Space.s)
                Text(summary(lane))
                    .font(WMType.caption)
                    .monospacedDigit()
                    .foregroundStyle(WM.Ground.inkSecondary)
            }
            IntakeLaneChart(lane: lane, tape: tape, band: band)
                .frame(height: 92)
                .accessibilityLabel(title + ", " + summary(lane))
        }
    }

    /// The one number, or an explicit absence. Never a zero standing in for "we couldn't tell".
    private func summary(_ lane: IntakeTape.Lane) -> String {
        guard lane.reference != nil else { return "No still reference before this" }
        guard let peak = lane.peak else { return "No still minutes to compare" }
        let sign = peak.delta >= 0 ? "+" : "−"
        let magnitude = String(format: "%.\(lane.precision)f", abs(peak.delta))
        return "\(sign)\(magnitude) \(lane.unit) at +\(peak.minute) min"
    }
}

/// One lane's plot: the reference as a hairline, the signal as a broken line, moving stretches as a
/// low-contrast wash behind. Hand-drawn in a `Canvas` rather than `BandChart` because the marks here
/// are a time series with GAPS and a background mask, neither of which the bar-and-band workhorse
/// models — and faking gaps as zero-height bars would draw zeros nothing measured.
struct IntakeLaneChart: View {
    let lane: IntakeTape.Lane
    let tape: IntakeTape
    var band: IntakeTypicalBand? = nil

    var body: some View {
        Canvas { ctx, size in
            let minutes = lane.points.map(\.minute)
            guard let firstMinute = minutes.min(), let lastMinute = minutes.max() else { return }

            // A lane covering exactly ONE minute — a strap that banked forty seconds of the window —
            // used to bail here on `lastMinute > firstMinute` and draw nothing at all, under a
            // summary line confidently printing a peak and an n. Same failure mode the isolated-minute
            // dots below were added for; this is the case that slipped past them, because it never
            // reached the drawing code. Draw the one measurement, centred.
            guard lastMinute > firstMinute else {
                // `minutes.min()` succeeded, so there is at least one point. With no span there is no
                // scale to place it on, so it sits centred — a mark saying "one minute, this is all
                // there was", not a curve.
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.4, y: c.y - 1.4, width: 2.8, height: 2.8)),
                         with: .color(WM.Ground.ink))
                return
            }

            var values = lane.points.map(\.value)
            if let reference = lane.reference { values.append(reference) }
            // The band shares the lane's scale, so its extremes must widen it — otherwise a typical
            // range wider than tonight would be clipped and read as narrower than it is.
            if let band { values += band.points.flatMap { [$0.lo, $0.hi] } }
            guard let lo = values.min(), let hi = values.max() else { return }
            // A dead-flat lane would divide by zero; give it a nominal span so it draws as the flat
            // line it is rather than collapsing onto an edge.
            let span = (hi - lo) < 0.0001 ? 1.0 : (hi - lo)
            let pad = span * 0.15

            func x(_ minute: Int) -> CGFloat {
                CGFloat(Double(minute - firstMinute) / Double(lastMinute - firstMinute)) * size.width
            }
            func y(_ value: Double) -> CGFloat {
                let t = (value - (lo - pad)) / (span + pad * 2)
                return size.height * (1 - CGFloat(t))
            }

            // 0. The typical-hour band, behind absolutely everything — it is context, not a mark.
            if let band, band.points.count > 1 {
                var shape = Path()
                let pts = band.points.sorted { $0.minute < $1.minute }
                shape.move(to: CGPoint(x: x(pts[0].minute), y: y(pts[0].hi)))
                for p in pts.dropFirst() { shape.addLine(to: CGPoint(x: x(p.minute), y: y(p.hi))) }
                for p in pts.reversed() { shape.addLine(to: CGPoint(x: x(p.minute), y: y(p.lo))) }
                shape.closeSubpath()
                ctx.fill(shape, with: .color(WM.Ground.ink.opacity(0.07)))
            }

            // 1. Moving stretches, behind everything.
            for span in tape.movingSpans {
                let a = Int(floor(Double(span.lowerBound - tape.eventTs) / 60.0))
                let b = Int(ceil(Double(span.upperBound - tape.eventTs) / 60.0))
                guard b >= firstMinute, a <= lastMinute else { continue }
                let x0 = x(max(a, firstMinute)), x1 = x(min(b, lastMinute))
                guard x1 > x0 else { continue }
                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                         with: .color(WM.Ground.ink.opacity(0.06)))
            }

            // 2. The event instant — minute 0, where the pre-roll ends and the response begins.
            if firstMinute <= 0 && lastMinute >= 0 {
                var mark = Path()
                mark.move(to: CGPoint(x: x(0), y: 0))
                mark.addLine(to: CGPoint(x: x(0), y: size.height))
                ctx.stroke(mark, with: .color(WM.Ground.ink.opacity(0.35)),
                           style: StrokeStyle(lineWidth: WM.hairline))
            }

            // 3. The pre-event reference.
            if let reference = lane.reference {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(reference)))
                line.addLine(to: CGPoint(x: size.width, y: y(reference)))
                ctx.stroke(line, with: .color(WM.Ground.inkTertiary.opacity(0.5)),
                           style: StrokeStyle(lineWidth: WM.hairline, dash: [3, 3]))
            }

            // 4. The signal, BROKEN across missing minutes. A gap of more than one minute starts a
            //    new subpath — the line never spans a minute the strap did not bank.
            //
            //    ISOLATED MINUTES ARE DRAWN AS DOTS. A stroked path made only of `move(to:)` calls
            //    renders NOTHING, so a window whose coverage is scattered single minutes — a strap
            //    dipping in and out of range, which is ordinary — drew a blank chart while the
            //    summary above it confidently reported a peak and an n. Blank reads as "no data",
            //    which is the precise false statement this whole screen is built to avoid.
            var path = Path()
            var run: [IntakeTape.Point] = []

            func flush() {
                guard let first = run.first else { return }
                if run.count == 1 {
                    // A lone minute has no neighbour to join: draw the measurement itself.
                    let c = CGPoint(x: x(first.minute), y: y(first.value))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.4, y: c.y - 1.4, width: 2.8, height: 2.8)),
                             with: .color(WM.Ground.ink))
                } else {
                    path.move(to: CGPoint(x: x(first.minute), y: y(first.value)))
                    for p in run.dropFirst() {
                        path.addLine(to: CGPoint(x: x(p.minute), y: y(p.value)))
                    }
                }
                run = []
            }

            for p in lane.points {
                if let previous = run.last, p.minute - previous.minute != 1 { flush() }
                run.append(p)
            }
            flush()
            ctx.stroke(path, with: .color(WM.Ground.ink),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Tape — meal, light") {
    IntakeTapePreview(scheme: .light)
}

#Preview("Tape — meal, dark") {
    IntakeTapePreview(scheme: .dark)
}

private struct IntakeTapePreview: View {
    let scheme: ColorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IntakeTapeView(tape: IntakeTapeSpecimen.dinner, event: IntakeTapeSpecimen.event)
            }
            .padding(.horizontal, WM.Space.gutter)
        }
        .background(WM.Ground.ground)
        .preferredColorScheme(scheme)
    }
}

/// A storeless specimen tape: a still pre-roll, a walk to the kitchen around the event, a post-meal
/// HR rise that resolves, and one gap where the strap banked nothing.
enum IntakeTapeSpecimen {
    static let eventTs = Int(Date().addingTimeInterval(-3 * 3_600).timeIntervalSince1970)

    static let event = IntakeEvent(id: "specimen-tape", day: TodayModel.key(from: Date()),
                                   ts: eventTs, kind: .meal, sizeOrdinal: .heavy)

    static let dinner: IntakeTape = {
        var hr: [IntakeTape.Point] = []
        var skin: [IntakeTape.Point] = []
        var hrv: [IntakeTape.Point] = []
        for m in -30...180 {
            // A 12-minute hole at +70, so the broken-line rule is visible in the preview.
            if (70...82).contains(m) { continue }
            let moving = (-4...6).contains(m)
            let rise = m < 0 ? 0.0 : 11 * exp(-pow(Double(m - 40) / 45.0, 2))
            let bump = moving ? 14.0 : 0.0
            hr.append(.init(minute: m, value: 58 + rise + bump, moving: moving))
            skin.append(.init(minute: m, value: 33.1 + (m < 0 ? 0 : 0.28 * (1 - exp(-Double(m) / 60))),
                              moving: moving))
            // HRV is drawn ONLY on still minutes, and only on roughly every other one — the sparse,
            // holey shape the corpus measured, so the preview shows the lane as it really renders
            // rather than as a third dense curve.
            if !moving, m % 2 == 0 {
                let dip = m < 0 ? 0.0 : -9 * exp(-pow(Double(m - 35) / 40.0, 2))
                hrv.append(.init(minute: m, value: 46 + dip, moving: false))
            }
        }
        return IntakeTape(
            eventTs: eventTs,
            windowStart: eventTs - 30 * 60,
            windowEnd: eventTs + 180 * 60,
            endedAtSleepOnset: false,
            heartRate: .init(points: hr, reference: 58, precision: 0, unit: "bpm"),
            skinTemp: .init(points: skin, reference: 33.1, precision: 1, unit: "°C"),
            hrv: .init(points: hrv, reference: 46, precision: 0, unit: "ms"),
            movingSpans: [(eventTs - 4 * 60)...(eventTs + 6 * 60)],
            stillMinutes: 168)
    }()
}
