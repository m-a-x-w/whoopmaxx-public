import SwiftUI

/// The sleep-duration history under Rest › "Trend" (037): the shared `SparkHistory` line of hours
/// asleep in rest, over the personal typical-range band, with the latest night dotted, a dashed "need"
/// line across the track, sparse day-of-month labels below, and a caption that says what the lines are.
/// It sits in "Trend" at the bottom of the screen and ends on the night on screen, so the dot carries no
/// drawn value: the Asleep hero at the top already prints it. VoiceOver hears it ("… latest 7:12").
///
/// 014 P2: the strip is also the navigation ("tap night") — tapping a night's column selects
/// it. Opt-in via `onSelect`; without it the strip is the inert chart it has always been.
struct RestHistoryStrip: View {
    struct Night {
        /// `yyyy-MM-dd` day key the night ended on.
        let dayKey: String
        /// Minutes asleep.
        let minutes: Double
    }

    let nights: [Night]
    /// Nightly need in minutes — drawn as the dashed reference line across the track.
    var needMin: Double = 480
    /// The Trend strip's height (037 draws it low under the Regularity line).
    var height: CGFloat = 96
    /// Tapping a night hands back THAT night's `dayKey` (014 P2). nil leaves the strip untappable, which
    /// is what the specimens and any read-only caller want.
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            SparkHistory(
                values: nights.map(\.minutes),
                domain: .rest,
                height: height,
                spokenValue: { RestFormat.hmm($0) },
                reference: (needMin, needLabel),
                xLabels: nights.map { dayOfMonth($0.dayKey) }
            )
            .overlay {
                if onSelect != nil {
                    columns
                }
            }
            Text("Hours asleep \u{00B7} dashed line = your \(RestFormat.hmm(needMin)) need")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
        }
    }

    // MARK: - Tap targets (014 P2)

    /// One FULL-HEIGHT column per night, equal width, laid over the whole chart — track and day label
    /// together (the caption below stays outside it).
    ///
    /// Full height and equal width on purpose. The drawn mark is a 2 pt line, and a short night's mark
    /// sits at the very bottom of the track: hit-testing the ink would leave most nights effectively
    /// unhittable and the shortest ones impossible. Equal columns also mean every night
    /// gets the same target, and each night's point still falls inside its own column — `SparkHistory`
    /// spaces points at `i/(count-1)` of the width, which is inside `[i/count, (i+1)/count]` for every i.
    ///
    /// A Button per column rather than one tap gesture over the chart: the strip becomes reachable by
    /// VoiceOver, which the chart itself is not (`SparkHistory` is one ignored element with a summary
    /// label), and each column can say which night it is.
    private var columns: some View {
        HStack(spacing: 0) {
            ForEach(nights.indices, id: \.self) { i in
                Button {
                    if let key = Self.dayKey(atColumn: i, in: nights) { onSelect?(key) }
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.columnLabel(nights[i]))
            }
        }
    }

    /// The night a COLUMN belongs to, left → right: the strip's OWN row, so a tap can never hand back a
    /// second opinion about which night the mark was drawn from. `nights` is oldest → newest (the order
    /// `SparkHistory` draws them in), so column 0 is the oldest night on the strip and the last column is
    /// the night the screen is already on. nil outside the strip.
    static func dayKey(atColumn index: Int, in nights: [Night]) -> String? {
        nights.indices.contains(index) ? nights[index].dayKey : nil
    }

    /// What VoiceOver reads for a column: the night's date and how long it was.
    private static func columnLabel(_ night: Night) -> String {
        let date = RestFormat.date(fromDayKey: night.dayKey)?
            .formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? night.dayKey
        return "\(date), \(RestFormat.hmm(night.minutes)) asleep"
    }

    /// The need as a clean hour label, rounded to the nearest half hour ("8h", "7.5h").
    private var needLabel: String {
        let halfHours = (needMin / 30).rounded()
        let hours = halfHours / 2
        return hours == hours.rounded()
            ? "\(Int(hours))h"
            : String(format: "%.1fh", hours)
    }

    /// "2026-07-15" → "15" (no leading zero).
    private func dayOfMonth(_ dayKey: String) -> String {
        guard let last = dayKey.split(separator: "-").last, let n = Int(last) else { return "" }
        return "\(n)"
    }
}

#Preview("RestHistoryStrip — light") {
    RestHistorySpecimen().preferredColorScheme(.light)
}

#Preview("RestHistoryStrip — dark") {
    RestHistorySpecimen().preferredColorScheme(.dark)
}

private struct RestHistorySpecimen: View {
    private func nights(base: Double, wobble: Double) -> [RestHistoryStrip.Night] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return (0..<14).map { i in
            let date = cal.date(byAdding: .day, value: i - 13, to: cal.startOfDay(for: Date()))!
            let minutes = base + wobble * sin(Double(i) / 2.2) + Double((i * 37) % 29)
            return RestHistoryStrip.Night(dayKey: fmt.string(from: date), minutes: minutes)
        }
    }

    @State private var tapped: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.sectionLoose) {
            // A realistic sleep strip that mostly rides under the 8h need line, in its tappable form —
            // the columns are invisible by design, so the label below is how the preview shows they are
            // there and which night each one is.
            RestHistoryStrip(nights: nights(base: 430, wobble: 60), onSelect: { tapped = $0 })
            Text(tapped.map { "Selected \($0)" } ?? "Tap a night")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
            // A well-slept strip that sits above need, to prove the band + line both stay legible —
            // untapped, the inert form every other caller gets.
            RestHistoryStrip(nights: nights(base: 500, wobble: 35), needMin: 450)
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
