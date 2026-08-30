#if os(iOS)
import Foundation
import AppIntents

/// The CONFIGURABLE half of the score widget (033): which single reading its Lock Screen accessories
/// show.
///
/// The Home Screen families were never the problem — `systemSmall` has room for a hero plus a bar and
/// `systemMedium` draws the whole `ScoreTrio`, so nothing there has to be chosen. The accessory
/// families are the opposite: a circle beside the clock fits ONE number, and until now that number was
/// hardwired to Charge in three places (`chargeGauge`, and the leading term of both the inline and the
/// rectangular layouts). A user whose interest is Rest could not put Rest on their Lock Screen at all.
///
/// **WHY THIS REUSES `GlanceReading` RATHER THAN DECLARING ITS OWN ENUM.** 032's read intent already
/// enumerates exactly these five values, with the display names and SF Symbols the app has settled on
/// for them, for exactly the same reason this needs them: a surface with room for one reading has to
/// ask which. Two enums over one set of cases is two places to add the sixth reading, and — worse —
/// two places for "Strap battery" to end up spelled differently in front of the same user. See
/// `GlanceIntents.swift`; the same collapse argument is made there against five separate intents.
///
/// **WHY THE DEFAULT IS `.charge`, and why that is not merely a taste call.** Migrating the widget from
/// `StaticConfiguration` to `AppIntentConfiguration` under the SAME `kind` keeps every already-placed
/// widget in place, and the system re-renders it with a default-initialised configuration. `.charge` is
/// therefore the value that makes an existing Lock Screen widget keep drawing precisely what it drew
/// before the update. Any other default would silently repurpose a widget the user placed, which is a
/// regression whatever the new reading is.

// MARK: - Configuration intent

/// `Edit Widget` for the score widget.
///
/// The parameter is titled for the surface it governs, not just for its type. WidgetKit shows one Edit
/// sheet per widget KIND — there is no way to offer a parameter to the accessory families and hide it
/// from `systemSmall` / `systemMedium` — so a user editing the Home Screen widget will see this row and
/// find that changing it moves nothing. "Lock Screen reading" says which surface it reaches before they
/// spend a tap finding out.
public struct GlanceWidgetConfigIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Glance"
    public static let description = IntentDescription(
        "Pick the reading the Lock Screen shows. The Home Screen widget always shows Charge, Effort and Rest.")

    @Parameter(title: "Lock Screen reading", default: .charge)
    public var reading: GlanceReading

    public init() {}

    public init(reading: GlanceReading) { self.reading = reading }

    public static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$reading) on the Lock Screen")
    }
}

// MARK: - Resolved accessory

/// One reading resolved against a published snapshot into the exact strings a small surface draws —
/// the pixel-side twin of `GlanceAnswer`, which does the same job for a spoken sentence.
///
/// Pure and snapshot-taking for the same reason `GlanceAnswer.sentence` is: every honesty rule below is
/// then testable without a widget host, a strap or a Lock Screen, rather than asserted only in a
/// comment that the next edit can quietly falsify.
///
/// **ABSENCE IS THE WHOLE POINT OF THE TYPE.** `value == nil` means NOT RECORDED, and it is the
/// caller's job to render that as absence — no ring, no numeral, no dash standing in for a figure. The
/// bug this replaced is the canonical example: the circular gauge filled from `Double(recovery ?? 0)`,
/// so a strap that had never reported drew a genuine, correctly-proportioned ring at zero. A ring at
/// zero is a measurement; the app had taken none. `gauge` is nil in that state precisely so a caller
/// cannot reach for a fill without first deciding what to draw instead.
///
/// **`gauge` IS ALSO NIL FOR A READING THAT HAS NO SCALE.** Charge, Effort, Rest and battery percentage
/// all live on a 0–100 axis the app defines and the user already reads that way. Heart rate does not:
/// there is no maximum in this codebase to divide by, and inventing one (220 − age? the trailing max?)
/// would make the ring's fill assert a relationship the app never computed. So a present heart rate
/// renders as a numeral and an absent one as absence — but never as a proportion of nothing.
public struct GlanceAccessory: Equatable {
    /// Full name, for accessibility and anywhere the space is a sentence rather than a row.
    public let label: String
    /// The name as a headline or list item wants it — "HR", "Battery". Identical to `label` for the
    /// three scores, whose names are already short.
    public let shortLabel: String
    /// The tiny all-caps ring label a circular gauge carries ("CHG"). Four characters at most; the ring
    /// clips anything longer rather than scaling it.
    public let abbreviation: String
    /// SF Symbol. Battery's follows the LEVEL (see `batterySymbol`), every other reading's is fixed.
    public let symbol: String
    /// The figure with its unit — "82", "58 bpm", "84%". **nil means NOT RECORDED.**
    public let value: String?
    /// The bare figure, no unit — for a gauge's centre or a circular tile, where the ring label or the
    /// symbol already carries the unit and there is no room to repeat it. nil in lockstep with `value`.
    public let compact: String?
    /// Position on this reading's 0–100 axis, as a 0…1 fraction. nil when the value is absent OR when
    /// the reading has no scale — see the type doc; both mean "do not draw a fill".
    public let gauge: Double?

    /// True when the app has no measurement for this reading. The rendering rule, stated once: an
    /// absent reading draws its NAME and nothing that looks like a figure.
    public var isAbsent: Bool { value == nil }

    /// The whole resolution for one reading.
    public static func make(reading: GlanceReading, snapshot: WidgetSnapshot) -> GlanceAccessory {
        switch reading {
        case .charge:
            return score("Charge", "CHG", "bolt.heart", snapshot.recovery)
        case .effort:
            return score("Effort", "EFF", "flame", snapshot.effort)
        case .rest:
            return score("Rest", "REST", "moon", snapshot.rest)
        case .heartRate:
            return GlanceAccessory(
                label: "Heart rate", shortLabel: "HR", abbreviation: "HR",
                symbol: "waveform.path.ecg",
                value: snapshot.bpm.map { "\($0) bpm" },
                compact: snapshot.bpm.map(String.init),
                gauge: nil)          // unscaled on purpose — see the type doc
        case .battery:
            let pct = snapshot.batteryPct
            return GlanceAccessory(
                label: "Strap battery", shortLabel: "Battery", abbreviation: "BATT",
                symbol: batterySymbol(pct),
                value: pct.map { "\($0)%" },
                compact: pct.map(String.init),
                gauge: pct.map(fraction))
        }
    }

    /// One of the three scores — all share the 0–100 axis and a name short enough to use everywhere.
    static func score(_ name: String, _ abbreviation: String,
                      _ symbol: String, _ value: Int?) -> GlanceAccessory {
        GlanceAccessory(label: name, shortLabel: name, abbreviation: abbreviation, symbol: symbol,
                        value: value.map(String.init), compact: value.map(String.init),
                        gauge: value.map(fraction))
    }

    /// The supporting readings a rectangular accessory can fit under its headline, in the order it
    /// prefers them and never including the headline's own reading.
    ///
    /// **Absent readings are OMITTED, not dashed.** The layout this replaced printed
    /// "HR — · Effort —" on a fresh install: two labels, two separators and two em-dashes arranged
    /// exactly like a row of figures. A caption that simply gets shorter cannot be misread as a
    /// measurement, and when nothing is left the caller has a better thing to say anyway (whether the
    /// app has ever published at all).
    ///
    /// The order is the one the old hardwired layout used under Charge — live heart rate first, then
    /// Effort — so the default configuration keeps drawing the caption it drew before.
    public static func context(for reading: GlanceReading, snapshot: WidgetSnapshot,
                               limit: Int = 2) -> [String] {
        let order: [GlanceReading] = [.heartRate, .effort, .rest, .charge, .battery]
        return order
            .filter { $0 != reading }
            .compactMap { other -> String? in
                let resolved = make(reading: other, snapshot: snapshot)
                guard let value = resolved.value else { return nil }
                return "\(resolved.shortLabel) \(value)"
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Clamped so a value outside the axis cannot drive a ring past its own end. Clamping the FILL is
    /// not the same as changing the number: the figure beside the ring is always the value as
    /// published, and nothing here rewrites it.
    static func fraction(_ value: Int) -> Double {
        min(max(Double(value), 0), 100) / 100
    }

    /// Strap battery as an SF Symbol.
    ///
    /// Unknown is NOT half. `battery.50` for a nil reading drew a half-full glyph on a fresh install
    /// that had never seen a strap, implying a measurement that does not exist. Lives here rather than
    /// beside the widget's footer strip because the configurable accessory needs the same mapping, and
    /// two copies of it is one copy that can drift back to drawing a half-full unknown.
    public static func batterySymbol(_ pct: Int?) -> String {
        guard let pct else { return "battery.slash" }
        switch pct {
        case ..<0:  return "battery.slash"
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }
}
#endif
