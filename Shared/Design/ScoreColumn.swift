import SwiftUI

/// The signature score viz: a vertical track whose fill height = score/100 in the domain color,
/// a horizontal baseline tick across the track at the 30-day typical, the numeral (display light,
/// small) riding above the fill top, and the domain name as an overline below.
///
/// Calibrating state (`score == nil`): hollow track (hairline outline), dashed tick, em-dash numeral.
struct ScoreColumn: View {
    let domain: WM.Domain
    /// 0–100; nil = calibrating.
    let score: Double?
    /// 0–100 (the 30-day typical); nil hides the tick.
    let baseline: Double?
    /// Overline under the track; defaults to the domain name. Pass "" to hide (ScoreTrio uses this
    /// to hoist labels below the shared floor rule).
    var label: String? = nil
    var showsLabel: Bool = true
    /// When non-nil, this score is CARRIED from a prior day (today hasn't scored yet): the column is
    /// rendered PROVISIONALLY — dimmed fill + secondary-ink numeral — so it never reads as today's
    /// fresh value. The caller shows the source-day caption ("carried · Tue") below the floor rule.
    var carriedFrom: String? = nil
    /// When true, this score was ACCUMULATED over materially incomplete capture (the day's waking-window
    /// coverage fell below `ScoreConfidence.effortSolidCoverage`). Only additive scores can be partial —
    /// Effort, in practice — so the number is a FLOOR, not a measurement. Rendered with the same
    /// half-strength fill and dashed tick the carried state uses, rather than a new color: the design
    /// language reserves color for data. The caller adds the caption under the floor rule.
    var lowCoverage: Bool = false

    private var calibrating: Bool { score == nil }
    private var carried: Bool { carriedFrom != nil }
    /// Both provisional states dim the fill: a carried score is someone else's day, a low-coverage score
    /// is only part of this one. Neither should read as a fresh, complete measurement.
    private var provisional: Bool { carried || lowCoverage }

    var body: some View {
        VStack(spacing: WM.Space.s) {
            GeometryReader { geo in
                track(in: geo.size)
            }
            if showsLabel {
                Text(label ?? domain.displayName).wmOverline()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    @ViewBuilder
    private func track(in size: CGSize) -> some View {
        let h = size.height
        let fillFrac = (score ?? 0).clamped01Fraction
        let fillH = fillFrac * h
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)

        ZStack(alignment: .bottom) {
            // Track: a whisper of the domain (half-wash) behind a hairline outline — the paper stays
            // paper; the vivid fill carries the data. Hollow outline only while calibrating.
            if !calibrating {
                shape.fill(domain.wash.opacity(0.45))
            }
            shape.strokeBorder(calibrating ? WM.Ground.ruleHeavy : WM.Ground.rule,
                               lineWidth: WM.hairline)

            // Score fill. A carried (provisional) score fills at half-strength so it reads as a
            // stand-in for today's not-yet-scored value, not a fresh reading.
            if !calibrating {
                shape
                    .fill(domain.color.opacity(provisional ? 0.5 : 1))
                    .frame(height: max(fillH, 2))
                    .wmAnimation(value: score)
            }

            // Baseline tick across the track at baseline/100 (dashed while calibrating). Full ink —
            // it's a reference mark, but must read over BOTH the vivid fill and the pale track (the
            // tick can sit over either, depending on score vs baseline) in both themes.
            if let baseline {
                TickLine()
                    .stroke(WM.Ground.ink,
                            style: StrokeStyle(lineWidth: 1,
                                               dash: (calibrating || lowCoverage) ? [3, 3] : []))
                    .frame(height: 1)
                    .offset(y: -(baseline.clamped01Fraction * (h - 1)))
            }

            // Numeral riding above the fill top (or a low em-dash while calibrating). When the
            // baseline tick sits just above the fill, hop over it so the digits never strike through.
            Text(numeralText)
                .font(WMType.display(26))
                .foregroundStyle(provisional ? WM.Ground.inkSecondary : WM.Ground.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.bottom, calibrating ? WM.Space.s : numeralBottomPadding(fillH: fillH, h: h))
                .wmAnimation(value: score)
        }
        .clipped()
    }

    private var numeralText: String {
        guard let score else { return "—" }
        return String(Int(score.rounded()))
    }

    /// Bottom padding that seats the numeral just above the fill top, hopping over the baseline
    /// tick when it lands in the numeral's band (score ≈ baseline would otherwise strike through).
    private func numeralBottomPadding(fillH: CGFloat, h: CGFloat) -> CGFloat {
        var bottom = fillH + 6
        if let baseline {
            let tickY = baseline.clamped01Fraction * (h - 1)
            if tickY > fillH - 4, tickY < bottom + 30 {
                bottom = tickY + 8
            }
        }
        return min(bottom, h - 32)
    }

    private var accessibilityText: String {
        let name = label?.isEmpty == false ? label! : domain.displayName
        guard let score else { return "\(name), calibrating" }
        var s = "\(name) \(Int(score.rounded()))"
        // Speak the carried/provisional state — the dim fill + secondary-ink numeral that mark a carried
        // value visually are invisible to VoiceOver, so a stale score would otherwise read as today's.
        if let carriedFrom { s += ", provisional, carried from \(carriedFrom)" }
        // Same reasoning as the carried caveat: the dimmed fill and dashed tick that mark partial capture
        // are invisible to VoiceOver, so without this the real 2026-07-15 reads "Effort 27, typical 44"
        // with no hint that 12.5 hours are missing.
        if lowCoverage { s += ", partial capture" }
        if let baseline { s += ", typical \(Int(baseline.rounded()))" }
        return s
    }
}

/// The shared treatment for the three mutually-exclusive column captions ("carried · Tue", "partial
/// capture", "calibrating · 2 of 4 nights").
///
/// WRAPS RATHER THAN SHRINKS. All three used `lineLimit(1)` + `minimumScaleFactor(0.7)`, which is
/// invisible while every caption is short — and stopped being so when the calibrating one gained its
/// progress note. In a third-width column "calibrating · 2 of 4 nights" does not fit on one line, so it
/// scaled down while the bare "calibrating" beside it did not: two captions in the same row at visibly
/// different type sizes, which reads as a broken layout rather than as two states. Found by rendering
/// the trio, not by reading it — the strings are both correct and the modifier chain was identical.
///
/// Two lines, then scale as a floor for an extreme accessibility size. Applied to all three so a future
/// caption cannot reintroduce the mismatch by being longer than its neighbours.
private struct TrioCaption: ViewModifier {
    func body(content: Content) -> some View {
        content
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A horizontal line through the mid-height of its rect (the baseline tick / floor rule stroke).
private struct TickLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

private extension Double {
    /// self/100 clamped to 0…1.
    var clamped01Fraction: CGFloat { CGFloat(Swift.min(Swift.max(self / 100, 0), 1)) }
}

/// Three ScoreColumns side by side over a shared floor rule, overlines below the rule.
struct ScoreTrio: View {
    struct Entry {
        let score: Double?
        let baseline: Double?
        /// Non-nil ⇒ this score is carried from that (short) source day — the column dims and a
        /// "carried · <day>" caption sits under its label. nil ⇒ a fresh, today's-own value.
        let carriedFrom: String?
        /// True ⇒ this (additive) score was accumulated over materially incomplete capture: the column
        /// dims, its tick dashes, and a "partial capture" caption sits under its label.
        let lowCoverage: Bool
        /// Optional detail for a nil score, e.g. "2 of 4 nights". A nil score ALWAYS captions itself
        /// "calibrating"; this only sharpens it with progress when the caller knows how far along it is.
        ///
        /// WHY A NIL SCORE MUST SAY SOMETHING. Charge is deliberately suppressed until the HRV baseline is
        /// seeded, so for the first 3-4 mornings of a fresh install the column rendered a hollow track and
        /// a bare em-dash — beside a working Effort and Rest — with no caption, no progress, and nothing
        /// tappable. The state was byte-identical to a broken engine. The engine already knew the answer
        /// (`ScoreConfidence.charge` returns `.calibrating`); nothing surfaced it.
        ///
        /// REQUIRED, deliberately no default. It shipped defaulted, no production caller ever supplied
        /// it, and the progress note this field exists for was dead in the binary while its own tests
        /// stayed green — the same shape as 013's restore receipt and 014's aged-out states. A caller
        /// with no calibration progress to report (the widget renders a snapshot) now says `nil` out
        /// loud; a caller that forgets no longer compiles.
        let calibratingNote: String?
        init(score: Double?, baseline: Double?, carriedFrom: String? = nil,
             lowCoverage: Bool = false, calibratingNote: String?) {
            self.score = score
            self.baseline = baseline
            self.carriedFrom = carriedFrom
            self.lowCoverage = lowCoverage
            self.calibratingNote = calibratingNote
        }

        /// The caption a blank column actually renders. The note SHARPENS the word, it never replaces
        /// it: rendering the note alone put "0 of 4 nights" under a blank numeral beside two columns
        /// reading "calibrating" — a bare fraction with no referent on screen, which parses as
        /// something Charge measured rather than as seed progress.
        ///
        /// Joined with "·", the way this file already joins "carried · Tue", and the same shape
        /// `SleepRegularity` uses for the identical state ("Calibrating — 3 of 7 comparisons so far").
        /// A computed property rather than an inline expression so the composition is pinnable — the
        /// tests below assert the FIELD, which is what let the substitution ship.
        var calibratingCaption: String {
            calibratingNote.map { "calibrating \u{00B7} \($0)" } ?? "calibrating"
        }
    }

    let charge: Entry
    let effort: Entry
    let rest: Entry
    var height: CGFloat = 220
    var onTap: ((WM.Domain) -> Void)? = nil
    /// Domains that render as actual tappable buttons (press-dimmable, exposed to VoiceOver as a
    /// button). Defaults to all three; a caller that only acts on one column (Today → Charge) passes
    /// just that domain so the inert columns render as plain, non-button elements. Empty ⇒ nothing
    /// tappable even if `onTap` is set.
    var tappable: Set<WM.Domain> = Set(WM.Domain.allCases)

    private var entries: [(WM.Domain, Entry)] {
        [(.charge, charge), (.effort, effort), (.rest, rest)]
    }

    var body: some View {
        VStack(spacing: WM.Space.s) {
            HStack(alignment: .bottom, spacing: WM.Space.gutter) {
                ForEach(entries, id: \.0) { domain, entry in
                    column(domain: domain, entry: entry)
                        .frame(height: height)
                }
            }
            // Shared floor rule under all three tracks.
            Rectangle()
                .fill(WM.Ground.ruleHeavy)
                .frame(height: WM.hairline)
            HStack(alignment: .top, spacing: WM.Space.gutter) {
                ForEach(entries, id: \.0) { domain, entry in
                    VStack(spacing: 3) {
                        Text(domain.displayName).wmOverline()
                        // Honest "this isn't today's own value yet" caption under a carried column.
                        if let src = entry.carriedFrom {
                            Text("carried · \(src)")
                                .font(WMType.caption)
                                .foregroundStyle(WM.Ground.inkTertiary)
                                .modifier(TrioCaption())
                        } else if entry.score == nil {
                            // A blank score is "not yet", never "broken" — say so. Sits in the same slot
                            // and treatment as the carried/partial captions; all three are exclusive.
                            //
                            // The note SHARPENS the word, it does not replace it. Rendering the note
                            // alone put "0 of 4 nights" under a blank numeral beside two columns
                            // reading "calibrating" — a bare fraction with no referent on screen, which
                            // parses as something Charge measured rather than as seed progress. Joined
                            // with "·", the same way this file already joins "carried · Tue", and the
                            // same shape `SleepRegularity` uses for the identical state ("Calibrating —
                            // 3 of 7 comparisons so far"). Composing HERE means a future note cannot
                            // reintroduce the substitution by wording itself differently.
                            Text(entry.calibratingCaption)
                                .font(WMType.caption)
                                .foregroundStyle(WM.Ground.inkTertiary)
                                .modifier(TrioCaption())
                        } else if entry.lowCoverage {
                            // Reuses the carried caption's slot and treatment — the two states are
                            // mutually exclusive (a carried score belongs to another day entirely).
                            Text("partial capture")
                                .font(WMType.caption)
                                .foregroundStyle(WM.Ground.inkTertiary)
                                .modifier(TrioCaption())
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func column(domain: WM.Domain, entry: Entry) -> some View {
        let col = ScoreColumn(domain: domain, score: entry.score,
                              baseline: entry.baseline, showsLabel: false,
                              carriedFrom: entry.carriedFrom,
                              lowCoverage: entry.lowCoverage)
        // Only wrap ACTIONABLE domains in a Button — an inert column stays a plain element (no press
        // dim, not announced as a "button" with no action by VoiceOver; ScoreColumn's own a11y label
        // still reads its score).
        if let onTap, tappable.contains(domain) {
            Button { onTap(domain) } label: { col }
                .buttonStyle(.plain)
        } else {
            col
        }
    }
}

#Preview("ScoreColumn — light") {
    ScoreTrioSpecimen().preferredColorScheme(.light)
}

#Preview("ScoreColumn — dark") {
    ScoreTrioSpecimen().preferredColorScheme(.dark)
}

private struct ScoreTrioSpecimen: View {
    var body: some View {
        VStack(spacing: WM.Space.sectionLoose) {
            ScoreTrio(charge: .init(score: 82, baseline: 61, calibratingNote: nil),
                      effort: .init(score: 47, baseline: 55, calibratingNote: nil),
                      rest: .init(score: 91, baseline: 74, calibratingNote: nil))
            // Calibrating state.
            ScoreColumn(domain: .charge, score: nil, baseline: 50)
                .frame(width: 88, height: 180)
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WM.Ground.ground)
    }
}
