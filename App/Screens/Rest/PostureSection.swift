import Foundation
import SwiftUI

/// The Rest "Wrist orientation" cluster (011 W2.3): the night's recurring wrist orientations as a
/// band lane under the hypnogram, their dwell, and how each one's time divided between stages.
///
/// **The orientations are NUMBERED, never named.** Gravity at the wrist fixes 2 of 3 degrees of
/// freedom and the forearm rotates freely inside any torso position, so nothing here knows — or
/// claims — which way the sleeper was facing. The section says one thing: these stretches of the night
/// differed from each other, and they recurred. Naming them needs a user calibration affordance and is
/// a separate feature (011 W3.5); until it exists a number is the honest label, and the copy is
/// written so that reads as honest rather than unfinished.
///
/// The whole read arrives pre-derived from `PostureLoader` (off the SwiftUI frame path, cached per
/// day-view), so this file is a pure render with light and dark previews and no Repository of its own.
///
/// No card, no ring, no dial: `RuleSection` + `WMRule()` + type hierarchy, rest indigo as the only
/// color (011 decisions 6/7/8). READ-ONLY — no score consumes any of it (decision 2).
///
/// Framing register (011 decision 5): descriptive, within-user, no condition name, no probability, no
/// call-to-action. Banned from every string here — *thermoregulation, vasodilation, impaired, poor,
/// abnormal, apnea, insomnia, hypoxemia, arrhythmia, "consider", "you should", "talk to"*.
struct PostureSection: View {
    /// The night's read; nil hides the section — a night that was never banked, or never held still long
    /// enough to compare, has nothing to show, and an eyebrow over an em-dash would assert otherwise.
    /// The ONE exception is a night past the raw horizon (`dayKey` + `RawHorizon`): its gravity was
    /// pruned rather than absent, and vanishing would read as a night with no lane to draw.
    let night: PostureLoader.Night?
    /// Whether the store held ANY gravity for this window. REQUIRED, no default.
    ///
    /// `night == nil` alone cannot carry the aged-out claim: it is also nil for a night whose gravity
    /// is still on disk and merely would not cluster. Telling that user their wrist motion "is no
    /// longer stored" blames retention for a limit of the analysis. Only an empty read is an absence.
    let hadGravity: Bool
    /// The night's `yyyy-MM-dd` key, for the raw-retention horizon test (`RawHorizon`). nil — every
    /// specimen preview — never ages out, so an un-keyed section behaves exactly as it did before.
    /// REQUIRED, deliberately no default: this argument decides whether the section is allowed to
    /// state a finding about a night whose raw signal was pruned. It shipped WITH a default once, the
    /// single production call site omitted it, and the whole aged-out state was unreachable in the
    /// binary while its unit tests stayed green. Every caller now has to say which night it means,
    /// even if the answer is nil (the specimen previews)  14 the compiler is the only thing that
    /// actually catches a dropped argument here.
    let dayKey: String?

    /// The line that keeps the numbering honest. Held to the wrist, in the descriptive register, with
    /// no body position in it and nothing for the reader to do.
    static let honestyLine =
        "The strap reads gravity at the wrist, so it can tell these stretches apart from one another "
        + "\u{2014} not which way you were facing."

    /// The line that stands in for the tape past the horizon (014 decision 5). It names what is no longer
    /// STORED and stops there — no count, no verdict, nothing about the sleeper. An absent section would
    /// say nothing at all, and a tape drawn from nothing would say the wrist never moved. The horizon
    /// comes from `SampleRetention.retentionDays`, so the sentence and the gate move together.
    ///
    /// It deliberately does NOT restate the horizon. On a browsed night past it, this section and the
    /// arousal ledger BOTH render, one after the other — and both used to open "This night is past the
    /// 28-day raw-signal window, so its…", which reads as an app repeating itself rather than as two
    /// findings. Neither sentence was wrong; the PAIR was. The ledger keeps the explanation (it sits
    /// higher and is the more prominent block) and this one says only what it cannot do. It still
    /// stands alone: a reader who never sees the other line still learns the motion is gone and why
    /// there is no lane. Visible only by rendering the two together — `--honesty-gallery` exists for
    /// exactly that, and this is the first thing it found.
    static let agedOutLine =
        "The raw wrist motion behind this lane is no longer stored, so the orientations can't be "
        + "rebuilt."

    /// Staged epochs an orientation needs before its stage mix is a mix rather than a rounding of
    /// three minutes. 20 epochs = 10 minutes.
    private static let minStagedEpochs = 20

    /// True when there is no read to render AND the night sits past the raw horizon.
    ///
    /// `!hadGravity` is the corroboration, and it has to be: a nil read alone does NOT mean the store
    /// was empty. `PostureLoader` returns no night for a window it could not cluster either — too
    /// little held still, or no orientation the night returned to — and on such a night the gravity is
    /// present, so "no longer stored" is false. Claiming it blames retention for a limit of the
    /// analysis, which is the confident kind of wrong this section exists to avoid.
    ///
    /// The date term matters too: `SampleRetention`'s scored-day gate holds an UNSCORED day's samples
    /// to `hardCapDays`, so inside the horizon a real tape keeps rendering.
    var rawAgedOut: Bool { night == nil && !hadGravity && RawHorizon.hasAgedOut(dayKey: dayKey) }

    var body: some View {
        if let night {
            RuleSection("Wrist orientation") {
                VStack(alignment: .leading, spacing: WM.Space.m) {
                    Text(summaryText(night.read))
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PostureTape(epochs: night.read.epochs, start: night.start, end: night.end)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(night.read.orientations, id: \.index) { orientation in
                            if orientation.index > 0 { WMRule() }
                            dwellRow(orientation)
                        }
                    }
                    Text(Self.honestyLine)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    stageMix(night)
                }
            }
        } else if rawAgedOut {
            RuleSection("Wrist orientation") {
                agedOut
            }
        }
    }

    /// The aged-out state (014 decision 5) — the section's whole CONTENT, at the same weight as the
    /// summary line it stands in for. Body/secondary rather than caption/tertiary: `honestyLine` is a
    /// footnote UNDER a tape, this is what there is instead of one.
    private var agedOut: some View {
        Text(Self.agedOutLine)
            .font(WMType.body)
            .foregroundStyle(WM.Ground.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, WM.Space.s)
    }

    // MARK: - Summary

    /// "4 orientations · 12 changes · held still 91% of the 6h 20m measured" — the
    /// ArousalForensicsSection summary idiom, counts only.
    ///
    /// The last clause names the MEASURED span, not the night. `stableFraction` is held ÷ MEASURED —
    /// unmeasured slots deliberately leave the denominator, because an unrecorded minute is not a
    /// restless one — so on a night whose gravity reached three of nine hours, "91% of the night"
    /// would claim eight still hours on three hours of evidence.
    private func summaryText(_ read: PostureEngine.Night) -> String {
        let n = read.orientations.count
        let s = read.summary.switches
        let stable = Int((read.summary.stableFraction * 100).rounded())
        let measured = read.epochs.filter { $0 != .noData }.count
        let span = WMFormat.duration(seconds: Int(Double(measured) * PostureEngine.epochS),
                                     style: .compact)
        return [
            "\(n) orientation\(n == 1 ? "" : "s")",
            "\(s) change\(s == 1 ? "" : "s")",
            "held still \(stable)% of the \(span) measured",
        ].joined(separator: " \u{00B7} ")
    }

    // MARK: - Dwell rows

    private func dwellRow(_ orientation: PostureEngine.Orientation) -> some View {
        HStack(alignment: .top, spacing: WM.Space.m) {
            swatch(orientation.index)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(PostureEngine.label(for: orientation.index))
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    Spacer(minLength: WM.Space.s)
                    Text(duration(orientation.minutes))
                        .font(WMType.body)
                        .monospacedDigit()
                        .foregroundStyle(WM.Ground.ink)
                    Text("\(Int((orientation.share * 100).rounded()))%")
                        .font(WMType.caption)
                        .monospacedDigit()
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .frame(minWidth: 34, alignment: .trailing)
                }
                Text("longest stretch \(duration(orientation.longestHoldMinutes))")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .padding(.vertical, WM.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(PostureEngine.label(for: orientation.index)), "
            + "\(duration(orientation.minutes)), \(Int((orientation.share * 100).rounded())) percent, "
            + "longest stretch \(duration(orientation.longestHoldMinutes))")
    }

    /// The lane's own strength for this rank, so a row and its bands can never disagree about which
    /// orientation they are.
    private func swatch(_ rank: Int) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(WM.Domain.rest.color.opacity(PostureTape.shade(rank)))
            .frame(width: 8, height: 12)
    }

    // MARK: - Stage mix

    /// The cross-tab: how each orientation's time divided between stages, as a thin stacked bar in the
    /// hypnogram's own ramp (so the two lanes read as one instrument). Dropped entirely when the night
    /// carries no stage timeline, and an orientation the stager barely covered says so rather than
    /// rounding ten minutes into four percentages.
    @ViewBuilder
    private func stageMix(_ night: PostureLoader.Night) -> some View {
        let rows = night.mix.filter { $0.staged > 0 }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: WM.Space.s) {
                Text("Stage mix")
                    .wmOverline()
                ForEach(rows, id: \.orientation) { mix in
                    mixRow(mix)
                }
            }
            .padding(.top, WM.Space.xs)
        }
    }

    private func mixRow(_ mix: PostureEngine.StageMix) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(PostureEngine.label(for: mix.orientation))
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkSecondary)
                Spacer(minLength: WM.Space.s)
                Text(mixCaption(mix))
                    .font(WMType.caption)
                    .monospacedDigit()
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            if mix.staged >= Self.minStagedEpochs {
                stackedBar(mix)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(PostureEngine.label(for: mix.orientation)), \(mixCaption(mix))")
    }

    /// "26% deep · 24% REM · 45% light · 5% awake", or an em-dash with its reason under the floor.
    private func mixCaption(_ mix: PostureEngine.StageMix) -> String {
        guard mix.staged >= Self.minStagedEpochs else {
            return "\u{2014} under 10 minutes staged"
        }
        func pct(_ n: Int) -> Int { Int((mix.share(n) * 100).rounded()) }
        return "\(pct(mix.deep))% deep \u{00B7} \(pct(mix.rem))% REM \u{00B7} "
            + "\(pct(mix.light))% light \u{00B7} \(pct(mix.wake))% awake"
    }

    /// The mix as one thin stacked bar in the hypnogram's rest ramp — the locked bars motif, and no
    /// hue this screen doesn't already use.
    /// Deep → REM → light → awake, the hypnogram's own top-to-bottom lane order turned on its side.
    private func stackedBar(_ mix: PostureEngine.StageMix) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                segment(width: geo.size.width * mix.share(mix.deep), stage: 3)
                segment(width: geo.size.width * mix.share(mix.rem), stage: 1)
                segment(width: geo.size.width * mix.share(mix.light), stage: 2)
                segment(width: geo.size.width * mix.share(mix.wake), stage: 0)
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
    }

    private func segment(width: CGFloat, stage: Int) -> some View {
        Rectangle()
            .fill(StepHypnogram.stageColor(stage))
            .frame(width: max(width, 0))
    }

    // MARK: - Formatting

    /// "3h 12m" — `WMFormat`'s compact spelling, the one the night-movement lanes already use.
    private func duration(_ minutes: Double) -> String {
        WMFormat.duration(seconds: Int(minutes * 60), style: .compact)
    }
}

// MARK: - Previews

#Preview("WristOrientation — light") {
    PostureSpecimen(kind: .full).preferredColorScheme(.light)
}

#Preview("WristOrientation — dark") {
    PostureSpecimen(kind: .full).preferredColorScheme(.dark)
}

#Preview("WristOrientation — no staging, light") {
    PostureSpecimen(kind: .unstaged).preferredColorScheme(.light)
}

#Preview("WristOrientation — no staging, dark") {
    PostureSpecimen(kind: .unstaged).preferredColorScheme(.dark)
}

#Preview("WristOrientation — aged out, light") {
    PostureSpecimen(kind: .agedOut).preferredColorScheme(.light)
}

#Preview("WristOrientation — aged out, dark") {
    PostureSpecimen(kind: .agedOut).preferredColorScheme(.dark)
}

private struct PostureSpecimen: View {
    enum Kind {
        /// Four recurring orientations with a staged night behind them.
        case full
        /// The same tape on a night the stager produced no timeline for — the cross-tab vanishes,
        /// the tape and dwell rows stand on their own.
        case unstaged
        /// A night browsed past `SampleRetention.retentionDays`: there is no read to draw, and the
        /// section says why instead of disappearing.
        case agedOut
    }
    let kind: Kind

    /// Only the aged-out specimen carries a key — nil is the "don't test the horizon" default every
    /// other preview (and every un-keyed caller) gets.
    private var dayKey: String? {
        guard kind == .agedOut else { return nil }
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -(SampleRetention.retentionDays + 7),
                           to: cal.startOfDay(for: Date()))!
        return DayKey.local(day)
    }

    /// A deterministic night: four orientations, brief moving slots at each change, one un-banked
    /// stretch, and one held-but-rare stretch that stays `.other` rather than being promoted. Ranks
    /// run in occupancy order exactly as the engine emits them (0 is the most-occupied).
    private var epochs: [PostureEngine.Epoch] {
        var out: [PostureEngine.Epoch] = []
        func run(_ e: PostureEngine.Epoch, _ n: Int) { out += Array(repeating: e, count: n) }
        run(.orientation(1), 120); run(.moving, 3)
        run(.orientation(2), 70);  run(.moving, 2)
        run(.orientation(1), 96);  run(.noData, 24)
        run(.orientation(0), 140); run(.moving, 4)
        run(.other, 12)
        run(.orientation(3), 64);  run(.moving, 2)
        run(.orientation(0), 110)
        return out
    }

    private var read: PostureEngine.Night {
        let counts = [250, 216, 70, 64]
        let assigned = Double(counts.reduce(0, +))
        let longest = [140, 120, 70, 64]
        let orientations = counts.enumerated().map { i, c in
            PostureEngine.Orientation(index: i, epochs: c, share: Double(c) / assigned,
                                      longestHoldEpochs: longest[i])
        }
        var entropy = 0.0
        for o in orientations { entropy -= o.share * log2(o.share) }
        // Five changes: the assigned run is 1, 2, 1, 0, 3, 0 — `.moving`, `.other` and `.noData` are
        // not orientations, so they are skipped rather than counted as changes.
        return PostureEngine.Night(
            start: 1_753_400_000, end: 1_753_400_000 + epochs.count * 30,
            epochs: epochs,
            orientations: orientations,
            summary: PostureEngine.Summary(switches: 5, stableFraction: 0.93,
                                           dominantFraction: Double(counts[0]) / assigned,
                                           entropyBits: entropy, orientationCount: counts.count))
    }

    private var mix: [PostureEngine.StageMix] {
        guard kind == .full else { return [] }
        return [
            PostureEngine.StageMix(orientation: 0, staged: 216, deep: 56, rem: 52, light: 97, wake: 11),
            PostureEngine.StageMix(orientation: 1, staged: 250, deep: 30, rem: 130, light: 80, wake: 10),
            PostureEngine.StageMix(orientation: 2, staged: 70, deep: 18, rem: 15, light: 33, wake: 4),
            // Under the floor on purpose: this row prints an em-dash and its reason, not four
            // percentages rounded out of nine minutes.
            PostureEngine.StageMix(orientation: 3, staged: 17, deep: 4, rem: 3, light: 9, wake: 1),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PostureSection(night: kind == .agedOut ? nil : PostureLoader.Night(read: read, mix: mix),
                               // The aged-out specimen is the no-gravity case by construction; the
                               // others have a read, so gravity was there.
                               hadGravity: kind != .agedOut,
                               dayKey: dayKey)
            }
            .padding(.horizontal, WM.Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }
}
