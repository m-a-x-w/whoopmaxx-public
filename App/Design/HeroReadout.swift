import SwiftUI

/// A screen's one hero number (037): a big light rounded numeral (optionally with a
/// unit) on the leading side, and its name plus a one-line reading trailing, bottom-aligned with the
/// numeral's baseline. Pair it with a `.hero` `LineScale` underneath.
///
/// The numeral scales down (never wraps) when a long value meets a narrow width — "6:47" and "116"
/// fit at the spec sizes, a "—" placeholder always does.
struct HeroReadout: View {
    let value: String
    var unit: String? = nil
    let title: String
    var subtitle: String? = nil
    var color: Color = WM.Ground.ink
    var size: CGFloat = 104

    init(value: String, unit: String? = nil, title: String, subtitle: String? = nil,
         color: Color = WM.Ground.ink, size: CGFloat = 104) {
        self.value = value
        self.unit = unit
        self.title = title
        self.subtitle = subtitle
        self.color = color
        self.size = size
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: WM.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(WMType.display(size))
                    .kerning(-size * 0.03)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit {
                    Text(unit)
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(WM.Ground.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Seat the words on the numeral's baseline rather than its descender box.
            .padding(.bottom, size * 0.14)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A secondary score on its own line (037): name (+ optional subtitle) leading, the value as a
/// domain-colored numeral trailing, and a `.row` `LineScale` beneath. Today's Effort and Rest, Rest's
/// score and Regularity.
struct ScoreLine: View {
    let title: String
    var subtitle: String? = nil
    /// Display value ("51", "—").
    let value: String
    /// The reading as a 0…1 fraction of its scale; nil draws an empty track.
    let fraction: Double?
    var band: ClosedRange<Double>? = nil
    var reference: Double? = nil
    let domain: WM.Domain
    /// A provisional reading (carried from another day, or a partial capture): the numeral drops to
    /// inkSecondary and the line to half strength, so it never reads as today's full score.
    var provisional: Bool = false

    init(title: String, subtitle: String? = nil, value: String, fraction: Double?,
         band: ClosedRange<Double>? = nil, reference: Double? = nil, domain: WM.Domain,
         provisional: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.fraction = fraction
        self.band = band
        self.reference = reference
        self.domain = domain
        self.provisional = provisional
    }

    private var numeralColor: Color {
        guard fraction != nil else { return WM.Ground.inkTertiary }
        return provisional ? WM.Ground.inkSecondary : domain.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                    }
                }
                Spacer(minLength: WM.Space.m)
                Text(value)
                    .font(WMType.numeral(30))
                    .foregroundStyle(numeralColor)
            }
            LineScale(value: fraction, band: band, reference: reference,
                      color: provisional ? domain.color.opacity(0.5) : domain.color, style: .row)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("HeroReadout — light") {
    HeroSpecimen().preferredColorScheme(.light)
}

#Preview("HeroReadout — dark") {
    HeroSpecimen().preferredColorScheme(.dark)
}

private struct HeroSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.section) {
            VStack(spacing: 18) {
                HeroReadout(value: "30", title: "Charge", subtitle: "below typical 36–48")
                LineScale(value: 0.30, band: 0.36...0.48, color: WM.Domain.charge.color, style: .hero)
            }
            ScoreLine(title: "Effort", value: "51", fraction: 0.51, band: 0.38...0.52, domain: .effort)
            ScoreLine(title: "Rest", subtitle: "typical 62–74", value: "58", fraction: 0.58,
                      band: 0.62...0.74, domain: .rest)
            HeroReadout(value: "116", title: "bpm", subtitle: "61% of max 190",
                        color: WM.Domain.effort.color, size: 128)
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
