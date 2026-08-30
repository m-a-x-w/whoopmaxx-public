import SwiftUI
import StrapAnalytics

/// The Rest "Why you woke" cluster: cause-tagged mid-sleep awakenings in the whoopmaxx design language —
/// an open-editorial RuleSection, rest-indigo as the ONLY color, no card. Sits below "Last night".
///
/// A summary line ("3 awakenings · 1 positional · 1 thermal · 1 unexplained") over a compact ledger: each
/// awakening is a tabular time, a dot (FILLED rest-indigo = identified cause, HOLLOW = unexplained), the
/// cause label, and an evidence micro-caption. Honest empty states cover a slept-through night and a
/// no-session/calibrating night. Both themes first-class; previewable with synthetic `Arousal` data,
/// no live Repository / BLE (matching WakeWindowSection's specimen invariant).
///
/// A capture caption closes the block on the nights that earned one — how densely HR was sampled and how
/// much of the window wrist motion covered — so a thin ledger on a sparsely-recorded night reads as a
/// recording fact rather than as a claim about the sleep.
///
/// Past the raw-retention horizon the whole ledger is REPLACED by one line about the data (014 decision
/// 5): the HR the causes are read from is gone, and an empty ledger's "Slept through" is the most
/// confident sentence on the screen.
struct ArousalForensicsSection: View {
    /// The night's meaningful mid-sleep awakenings (may be empty = slept through).
    let arousals: [Arousal]
    /// False when there is no analyzable night to explain — the whole section is hidden then.
    var hasSession: Bool = true
    /// Time zone the awakening clock labels are rendered in (the night's local zone).
    var timeZone: TimeZone = .current
    /// How much of the night the stager had to look at (`ArousalForensicsLoader.Night.capture`). nil —
    /// or a night whose coverage clears the stager's own sparse gate — renders no caption at all.
    var capture: CaptureQuality? = nil
    /// The night's `yyyy-MM-dd` key, for the raw-retention horizon test (`RawHorizon`). nil — every
    /// specimen preview — never ages out, so an un-keyed section behaves exactly as it did before.
    /// REQUIRED, deliberately no default: this argument decides whether the section is allowed to
    /// state a finding about a night whose raw signal was pruned. It shipped WITH a default once, the
    /// single production call site omitted it, and the whole aged-out state was unreachable in the
    /// binary while its unit tests stayed green. Every caller now has to say which night it means,
    /// even if the answer is nil (the specimen previews)  14 the compiler is the only thing that
    /// actually catches a dropped argument here.
    let dayKey: String?

    /// Priority order for the summary breakdown (mirrors the engine's dominant-tag resolution).
    private static let order: [ArousalCause] = [.positional, .respiratory, .thermal, .cardiac, .unexplained]

    /// The slept-through copy, hoisted out of the view so the aged-out line can be pinned against the
    /// exact sentence it exists to keep off a night whose raw HR is gone.
    static let sleptThroughLine = "Slept through \u{2014} no awakenings over 2 minutes."

    /// The line that replaces the ledger past the horizon. It names what is no longer STORED and stops
    /// there — no count, no verdict, nothing about the sleeper, and nothing for the reader to do. The
    /// horizon comes from `SampleRetention.retentionDays`, so the sentence and the gate move together.
    static let agedOutLine =
        "This night is past the \(SampleRetention.retentionDays)-day raw-signal window, so its heart rate "
        + "and wrist motion are no longer stored and the ledger can't be rebuilt."

    /// True when this night sits past the raw horizon AND the pass in fact measured no window on it.
    ///
    /// `capture` is nil exactly when `CaptureQuality.measure` found fewer than two HR samples (or a
    /// zero-length span) — so the pair is a VERIFIED "there was nothing to read", not an inference from
    /// the date alone. That second term matters: `SampleRetention`'s scored-day gate holds an UNSCORED
    /// day's samples to `hardCapDays`, and on such a night the ledger is real and keeps rendering.
    var rawAgedOut: Bool { capture == nil && RawHorizon.hasAgedOut(dayKey: dayKey) }

    var body: some View {
        if hasSession {
            RuleSection("Why you woke") {
                VStack(alignment: .leading, spacing: 0) {
                    if rawAgedOut {
                        agedOut
                    } else if arousals.isEmpty {
                        sleptThrough
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            summary
                                .padding(.bottom, WM.Space.m)
                            ForEach(Array(arousals.enumerated()), id: \.offset) { idx, a in
                                if idx > 0 { WMRule() }
                                row(a)
                            }
                        }
                    }
                    if let line = capture?.caption {
                        captureLine(line)
                    }
                }
            }
        }
    }

    // MARK: - Summary

    private var summary: some View {
        Text(summaryText)
            .font(WMType.body)
            .foregroundStyle(WM.Ground.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(summaryText)
    }

    private var summaryText: String {
        let n = arousals.count
        let head = "\(n) awakening\(n == 1 ? "" : "s")"
        var counts: [ArousalCause: Int] = [:]
        for a in arousals { counts[a.cause, default: 0] += 1 }
        let parts = Self.order.compactMap { cause -> String? in
            guard let c = counts[cause], c > 0 else { return nil }
            return "\(c) \(cause.rawValue)"
        }
        return ([head] + parts).joined(separator: " \u{00B7} ")
    }

    // MARK: - Rows

    private func row(_ a: Arousal) -> some View {
        HStack(alignment: .top, spacing: WM.Space.m) {
            Text(timeLabel(a.start))
                .font(WMType.body)
                .monospacedDigit()
                .foregroundStyle(WM.Ground.inkSecondary)
                // A 12-hour "12:42 AM" already exceeds 54pt, and larger Dynamic Type overflows any fixed
                // width — let the column size to its content + scale rather than clipping the wake time.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 54, alignment: .leading)
            dot(identified: a.cause != .unexplained)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(a.cause.rawValue.capitalized)
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    Spacer(minLength: WM.Space.s)
                    Text(durationLabel(a.durationMin))
                        .font(WMType.caption)
                        .monospacedDigit()
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
                if !a.evidence.isEmpty {
                    Text(a.evidence)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, WM.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(timeLabel(a.start)), \(a.cause.rawValue), \(a.evidence), \(durationLabel(a.durationMin))")
    }

    /// FILLED rest-indigo = an identified cause; HOLLOW = unexplained.
    private func dot(identified: Bool) -> some View {
        Group {
            if identified {
                Circle().fill(WM.Domain.rest.color)
            } else {
                Circle().strokeBorder(WM.Domain.rest.color, lineWidth: WM.hairline * 2)
            }
        }
        .frame(width: 7, height: 7)
    }

    private var sleptThrough: some View {
        Text(Self.sleptThroughLine)
            .font(WMType.body)
            .foregroundStyle(WM.Ground.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, WM.Space.s)
    }

    /// The aged-out state (014 decision 5). Same weight and rhythm as `sleptThrough` — it is the
    /// section's CONTENT, not a footnote about it — because what it replaces is a finding, and a night
    /// past the horizon deserves the same line of text rather than a blank block under a live eyebrow.
    /// The capture caption cannot follow it: `rawAgedOut` requires `capture == nil`.
    private var agedOut: some View {
        Text(Self.agedOutLine)
            .font(WMType.body)
            .foregroundStyle(WM.Ground.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, WM.Space.s)
    }

    /// The capture caption — a footnote about the RECORDING, so tertiary ink at caption size and set off
    /// by whitespace rather than a rule (it is not another ledger row).
    private func captureLine(_ text: String) -> some View {
        Text(text)
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, WM.Space.m)
            .accessibilityLabel(text)
    }

    // MARK: - Formatting

    /// Rendered in the NIGHT's recorded zone (injected per instance), not the device's — a night
    /// logged abroad still reads in local-at-the-time clock terms. `WMFormat` caches one formatter per
    /// zone identifier; this used to allocate a fresh `DateFormatter` on every row.
    private func timeLabel(_ unixSec: Int) -> String {
        WMFormat.timeOfDay(Date(timeIntervalSince1970: TimeInterval(unixSec)), in: timeZone)
    }

    /// "35 min" — a THIRD duration spelling (and it floors at 1 min so a 20-second arousal still
    /// reads as a minute). One caller, so it stays local rather than becoming a `DurationStyle`.
    private func durationLabel(_ minutes: Double) -> String {
        "\(max(1, Int(minutes.rounded()))) min"
    }
}

// MARK: - Previews

#Preview("WhyYouWoke — mixed, light") {
    ArousalForensicsSpecimen(kind: .mixed).preferredColorScheme(.light)
}

#Preview("WhyYouWoke — mixed, dark") {
    ArousalForensicsSpecimen(kind: .mixed).preferredColorScheme(.dark)
}

#Preview("WhyYouWoke — slept through, light") {
    ArousalForensicsSpecimen(kind: .empty).preferredColorScheme(.light)
}

#Preview("WhyYouWoke — sparse capture, light") {
    ArousalForensicsSpecimen(kind: .sparseCapture).preferredColorScheme(.light)
}

#Preview("WhyYouWoke — sparse capture, dark") {
    ArousalForensicsSpecimen(kind: .sparseCapture).preferredColorScheme(.dark)
}

#Preview("WhyYouWoke — aged out, light") {
    ArousalForensicsSpecimen(kind: .agedOut).preferredColorScheme(.light)
}

#Preview("WhyYouWoke — aged out, dark") {
    ArousalForensicsSpecimen(kind: .agedOut).preferredColorScheme(.dark)
}

private struct ArousalForensicsSpecimen: View {
    enum Kind {
        case mixed, empty, sparseCapture
        /// A night browsed past `SampleRetention.retentionDays`: stages survived, the raw HR behind the
        /// causes did not. The ledger is replaced by the one line, not left empty.
        case agedOut
    }
    let kind: Kind

    /// A night the stager ran on its sparse path: HR every ~2.5 min, gravity over a third of the window.
    /// A dense night carries a `CaptureQuality` too — it just has no caption to make.
    private var capture: CaptureQuality? {
        kind == .sparseCapture ? CaptureQuality(hrPerMinute: 0.4, gravityCoverage: 0.34) : nil
    }

    /// Only the aged-out specimen carries a key — nil is the "don't test the horizon" default every
    /// other preview (and every un-keyed caller) gets.
    private var dayKey: String? {
        guard kind == .agedOut else { return nil }
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -(SampleRetention.retentionDays + 7),
                           to: cal.startOfDay(for: Date()))!
        return DayKey.local(day)
    }

    private var arousals: [Arousal] {
        guard kind != .empty, kind != .agedOut else { return [] }
        // Three synthetic awakenings across an early morning, one per identified cause + one unexplained.
        let base = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        func at(_ h: Int, _ m: Int, dur: Double, _ cause: ArousalCause, _ ev: String) -> Arousal {
            let s = base + h * 3600 + m * 60
            return Arousal(start: s, end: s + Int(dur * 60), cause: cause, evidence: ev, durationMin: dur)
        }
        return [
            at(1, 42, dur: 3, .positional, "roll-over"),
            at(3, 15, dur: 4, .thermal, "+0.4\u{00B0}C skin"),
            at(5, 8, dur: 2, .unexplained, "no clear signal"),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ArousalForensicsSection(arousals: arousals, capture: capture, dayKey: dayKey)
            }
            .padding(.horizontal, WM.Space.gutter)
        }
        .background(WM.Ground.ground)
    }
}
