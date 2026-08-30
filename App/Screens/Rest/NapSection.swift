import SwiftUI
import StrapStore

/// The Rest screen's "Naps" section (007 F3): one row per detected nap over the recent debt window — its
/// DATE as the row title, the time span and credited "+h:mm toward need" as the caption, the duration as
/// a numeral, and a `.compact` line of the nap against the daily credit cap (037). Naps are
/// ADDITIVE credit toward sleep need/debt; they never touch the night's own numbers (#525), which is why
/// this is its own section rather than extra stage columns. Rows span the same 14-night window the
/// sleep-debt ledger credits, newest first, so a prior night's nap isn't invisible just because it isn't
/// today's. Pure value view (previewable): the wrapper screen classifies sessions via `NapCredit` and
/// hands in finished rows.
struct NapSection: View {

    /// One classified nap, pre-derived so the view stays pure.
    struct Nap: Identifiable {
        /// Session start unix seconds (stable row identity — one session per start).
        let startTs: Int
        let start: Date
        let end: Date
        /// Clock-span minutes.
        let minutes: Double
        /// Minutes this nap credits toward need (≤ `minutes`; the day's cap distributes
        /// chronologically, so a late nap past the cap credits partially or 0).
        let creditedMin: Double

        var id: Int { startTs }
    }

    let naps: [Nap]

    /// Build rows from a day's classified nap sessions (the `NapCredit.naps` output, sorted by
    /// start), pairing each with its capped per-nap credit.
    static func rows(from sessions: [CachedSleepSession]) -> [Nap] {
        let credits = NapCredit.credits(forNaps: sessions)
        return zip(sessions, credits).map { session, credit in
            Nap(startTs: session.startTs,
                start: Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs)),
                end: Date(timeIntervalSince1970: TimeInterval(session.endTs)),
                minutes: NapCredit.minutes(of: session),
                creditedMin: credit)
        }
    }

    var body: some View {
        RuleSection("Naps") {
            VStack(spacing: 0) {
                ForEach(Array(naps.enumerated()), id: \.element.id) { index, nap in
                    if index > 0 {
                        WMRule()
                    }
                    row(nap)
                }
            }
        }
    }

    private func row(_ nap: Nap) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayLabel(nap.start))
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    Text("\(nap.start.formatted(.dateTime.hour().minute())) \u{2013} \(nap.end.formatted(.dateTime.hour().minute())) \u{00B7} \(creditCaption(nap))")
                        .font(WMType.caption)
                        .monospacedDigit()
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: WM.Space.m)
                Text(RestFormat.hmm(nap.minutes))
                    .font(WMType.numeral(22))
                    .foregroundStyle(WM.Ground.ink)
            }
            durationLine(nap)
        }
        .padding(.vertical, WM.Space.m)
        .accessibilityElement(children: .combine)
    }

    /// The nap's day, relative: "Today" / "Yesterday", a weekday within the last week, else "Jul 15".
    /// Rows can span the 14-night debt window, so each carries its date to place it.
    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        return days < 7 ? date.formatted(.dateTime.weekday(.wide))
                        : date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "+0:25 toward need", or the honest capped readout when the day's 2 h credit ran out.
    private func creditCaption(_ nap: Nap) -> String {
        guard nap.creditedMin >= 1 else { return "over daily cap" }
        return "+\(RestFormat.hmm(nap.creditedMin)) toward need"
    }

    /// The nap's span against the daily credit cap as a `.compact` rest line with no dot — a bar-style
    /// reading (how much of the cap this one nap spans), not a position against a typical.
    private func durationLine(_ nap: Nap) -> some View {
        LineScale(value: min(nap.minutes / NapCredit.maxCreditedMinPerDay, 1),
                  color: WM.Domain.rest.color, style: .compact, showsDot: false)
    }
}

// MARK: - Previews

#Preview("NapSection — light") {
    NapSectionSpecimen().preferredColorScheme(.light)
}

#Preview("NapSection — dark") {
    NapSectionSpecimen().preferredColorScheme(.dark)
}

private struct NapSectionSpecimen: View {
    private var naps: [NapSection.Nap] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            day.addingTimeInterval(TimeInterval(dayOffset * 86_400 + hour * 3600 + minute * 60))
        }
        return [
            NapSection.Nap(startTs: 1, start: at(0, 13, 5), end: at(0, 13, 30), minutes: 25, creditedMin: 25),
            NapSection.Nap(startTs: 2, start: at(-2, 17, 40), end: at(-2, 19, 35), minutes: 115, creditedMin: 95),
            NapSection.Nap(startTs: 3, start: at(-5, 14, 10), end: at(-5, 14, 55), minutes: 45, creditedMin: 45),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NapSection(naps: naps)
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WM.Ground.ground)
    }
}
