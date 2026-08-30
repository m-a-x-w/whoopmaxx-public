#if os(iOS)
import AppIntents
import SwiftUI

/// The CONFIGURABLE half of quick-log (031): what a Lock Screen accessory widget or a Control is set
/// to log when it is tapped.
///
/// 028 shipped a Home Screen widget with four hardwired buttons. A Lock Screen surface cannot work
/// that way — an accessory widget is a few points tall and a Control is a single button, so there is
/// room for exactly ONE action. The action therefore has to be the user's choice, which is what makes
/// this file exist: the kind, and the standing amount that goes with it, picked once in `Edit Widget`.
///
/// **The enums are mirrors, not the domain types.** `IntakeKind` / `IntakeVariant` / `MealSize` live in
/// `Core/`, which the widget extension does not compile (it builds `Shared/` + `Widgets/` only — see
/// project.yml). The raw values here are the SAME persisted strings/ordinals, and `IntakeStore.drainOutbox`
/// maps them back through `IntakeKind(rawValue:)`; a mirror that drifted would simply leave its entries
/// in the outbox rather than corrupt anything, because the drain skips kinds it does not recognise.
///
/// **Provenance.** Anything configured here is a STANDING declaration, not a measurement taken at the
/// moment — the exact distinction `IntakeOutbox.source` was introduced to keep separable. Nothing in
/// this file may stamp a value the user did not choose: a nil amount stays nil, and nil means NOT
/// RECORDED all the way down.

// MARK: - Mirrors

/// `IntakeKind`, as an `AppEnum` so it can be a widget/control parameter.
public enum IntakeKindChoice: String, AppEnum, CaseIterable {
    case meal
    case caffeine
    case alcohol
    case water

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Kind"
    public static let caseDisplayRepresentations: [IntakeKindChoice: DisplayRepresentation] = [
        .meal:     DisplayRepresentation(title: "Meal", image: .init(systemName: "fork.knife")),
        .caffeine: DisplayRepresentation(title: "Caffeine", image: .init(systemName: "cup.and.saucer")),
        .alcohol:  DisplayRepresentation(title: "Alcohol", image: .init(systemName: "wineglass")),
        .water:    DisplayRepresentation(title: "Water", image: .init(systemName: "drop"))
    ]
}

/// `IntakeVariant` (caffeine's form). Not cosmetic: the form is what decides whether the milligrams
/// beside it are a LABEL (pill) or an ESTIMATE (drink) — see `IntakeVariant.milligramCaveat`.
public enum IntakeFormChoice: String, AppEnum, CaseIterable {
    case drink
    case pill

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Form"
    public static let caseDisplayRepresentations: [IntakeFormChoice: DisplayRepresentation] = [
        .drink: DisplayRepresentation(title: "Drink", image: .init(systemName: "cup.and.saucer")),
        .pill:  DisplayRepresentation(title: "Pill", image: .init(systemName: "pills"))
    ]
}

/// `MealSize`, raw values kept as the persisted 1|2|3 ordinal.
public enum IntakeMealSizeChoice: Int, AppEnum, CaseIterable {
    case light = 1
    case usual = 2
    case heavy = 3

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Size"
    public static let caseDisplayRepresentations: [IntakeMealSizeChoice: DisplayRepresentation] = [
        .light: "Light",
        .usual: "Usual",
        .heavy: "Heavy"
    ]
}

// MARK: - Preset

/// One resolved tap: exactly the fields this kind is allowed to carry, plus the strings a one-button
/// surface draws. Pure value type, built by `IntakeQuickPreset.make` — so the per-kind rules are
/// testable without a widget host.
public struct IntakeQuickPreset: Equatable, Sendable {
    public let kind: String
    public let variant: String?
    public let countValue: Int?
    public let sizeOrdinal: Int?
    public let amountMg: Int?

    /// The kind's own noun — "Caffeine", "Water".
    public let label: String
    /// The configured amount in words, or empty when the tap is bare. Never invented: empty here means
    /// the user set no amount, and the event goes in with nils.
    public let caption: String
    /// SF Symbol. Caffeine's follows the FORM (a pill is not a cup), every other kind follows the kind.
    public let symbol: String

    /// The intent a tap fires. Built here so the accessory widget and the Control cannot disagree
    /// about what a given configuration logs.
    public var logIntent: LogIntakeIntent {
        LogIntakeIntent(kind: kind, amountMg: amountMg, countValue: countValue,
                        variant: variant, sizeOrdinal: sizeOrdinal)
    }

    /// Apply the per-kind rules and drop everything that does not belong.
    ///
    /// Filtering by kind is the point, not tidiness. `Edit Widget` keeps every parameter it has ever
    /// been shown, so a widget configured for two drinks and later switched to Meal still carries
    /// `countValue = 2` in its configuration — writing that through would file a meal as "2 drinks",
    /// which is a fact the user never stated. Each kind takes ONLY its own amount field:
    ///
    /// - `caffeine` — form + milligrams (027; cups are legacy and no new tap writes one)
    /// - `alcohol` / `water` — a count of drinks / glasses
    /// - `meal` — the 1|2|3 size ordinal, because a portion is not a count of discrete things
    ///
    /// Non-positive amounts collapse to nil: "0 mg" is not a dose the user meant to declare, and nil
    /// is the codebase's word for NOT RECORDED.
    public static func make(kind: IntakeKindChoice,
                            form: IntakeFormChoice? = nil,
                            countValue: Int? = nil,
                            mealSize: IntakeMealSizeChoice? = nil,
                            amountMg: Int? = nil) -> IntakeQuickPreset {
        let count = positive(countValue)
        let mg = positive(amountMg)

        switch kind {
        case .caffeine:
            let form = form
            return IntakeQuickPreset(
                kind: kind.rawValue, variant: form?.rawValue, countValue: nil,
                sizeOrdinal: nil, amountMg: mg,
                label: "Caffeine",
                caption: caffeineCaption(mg: mg, form: form),
                symbol: form == .pill ? "pills" : "cup.and.saucer")
        case .alcohol:
            return IntakeQuickPreset(
                kind: kind.rawValue, variant: nil, countValue: count,
                sizeOrdinal: nil, amountMg: nil,
                label: "Alcohol",
                caption: countCaption(count, singular: "drink", plural: "drinks"),
                symbol: "wineglass")
        case .water:
            return IntakeQuickPreset(
                kind: kind.rawValue, variant: nil, countValue: count,
                sizeOrdinal: nil, amountMg: nil,
                label: "Water",
                caption: countCaption(count, singular: "glass", plural: "glasses"),
                symbol: "drop")
        case .meal:
            return IntakeQuickPreset(
                kind: kind.rawValue, variant: nil, countValue: nil,
                sizeOrdinal: mealSize?.rawValue, amountMg: nil,
                label: "Meal",
                caption: mealCaption(mealSize),
                symbol: "fork.knife")
        }
    }

    /// The gallery/preview sample. A bare meal: the one configuration that asserts no amount at all,
    /// so a preview tile can never be mistaken for a real standing declaration.
    public static let preview = make(kind: .meal)

    // MARK: Captions

    static func caffeineCaption(mg: Int?, form: IntakeFormChoice?) -> String {
        let formWord = form.map { $0 == .pill ? "Pill" : "Drink" }
        switch (mg, formWord) {
        case let (mg?, word?): return "\(mg) mg · \(word)"
        case let (mg?, nil):   return "\(mg) mg"
        case let (nil, word?): return word
        default:               return ""
        }
    }

    static func countCaption(_ count: Int?, singular: String, plural: String) -> String {
        guard let count else { return "" }
        return "\(count) \(count == 1 ? singular : plural)"
    }

    static func mealCaption(_ size: IntakeMealSizeChoice?) -> String {
        switch size {
        case .light: return "Light"
        case .usual: return "Usual"
        case .heavy: return "Heavy"
        case nil:    return ""
        }
    }

    /// nil for anything that is not a positive amount — see `make`.
    static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

// MARK: - Configuration intents

/// What the two configurable surfaces have in common. The `@Parameter` wrappers cannot live on a
/// protocol, so each concrete intent declares its own set and this supplies the shared derivation —
/// which keeps the accessory widget and the Control from resolving the same choices differently.
public protocol IntakeQuickConfiguring {
    var kind: IntakeKindChoice { get }
    var form: IntakeFormChoice? { get }
    var countValue: Int? { get }
    var mealSize: IntakeMealSizeChoice? { get }
    var amountMg: Int? { get }
}

public extension IntakeQuickConfiguring {
    var preset: IntakeQuickPreset {
        .make(kind: kind, form: form, countValue: countValue,
              mealSize: mealSize, amountMg: amountMg)
    }
}

/// `Edit Widget` for the Lock Screen accessory widget.
///
/// The parameter summary is branched per kind on purpose: showing a milligram field on a Water widget
/// invites an amount the app would then have to refuse, and showing all four amount controls at once
/// makes the sheet read like a form rather than a choice.
public struct IntakeQuickConfigIntent: WidgetConfigurationIntent, IntakeQuickConfiguring {
    public static let title: LocalizedStringResource = "Log intake"
    public static let description = IntentDescription("Pick what one tap logs, and the amount it stands for.")

    @Parameter(title: "Kind", default: .caffeine)
    public var kind: IntakeKindChoice
    @Parameter(title: "Form")
    public var form: IntakeFormChoice?
    @Parameter(title: "Amount")
    public var countValue: Int?
    @Parameter(title: "Size")
    public var mealSize: IntakeMealSizeChoice?
    @Parameter(title: "Milligrams")
    public var amountMg: Int?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$kind, .equalTo, IntakeKindChoice.caffeine) {
            Summary("Log \(\.$kind)") {
                \.$form
                \.$amountMg
            }
        } otherwise: {
            When(\.$kind, .equalTo, IntakeKindChoice.meal) {
                Summary("Log \(\.$kind)") {
                    \.$mealSize
                }
            } otherwise: {
                Summary("Log \(\.$kind)") {
                    \.$countValue
                }
            }
        }
    }
}

/// The same choices for a Control — a separate type because `ControlConfigurationIntent` and
/// `WidgetConfigurationIntent` are distinct protocols, and because the two surfaces are configured
/// independently by the user (one Control and one Lock Screen widget can log different things).
public struct IntakeControlConfigIntent: ControlConfigurationIntent, IntakeQuickConfiguring {
    public static let title: LocalizedStringResource = "Log intake"
    public static let description = IntentDescription("Pick what one tap logs, and the amount it stands for.")

    @Parameter(title: "Kind", default: .caffeine)
    public var kind: IntakeKindChoice
    @Parameter(title: "Form")
    public var form: IntakeFormChoice?
    @Parameter(title: "Amount")
    public var countValue: Int?
    @Parameter(title: "Size")
    public var mealSize: IntakeMealSizeChoice?
    @Parameter(title: "Milligrams")
    public var amountMg: Int?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$kind, .equalTo, IntakeKindChoice.caffeine) {
            Summary("Log \(\.$kind)") {
                \.$form
                \.$amountMg
            }
        } otherwise: {
            When(\.$kind, .equalTo, IntakeKindChoice.meal) {
                Summary("Log \(\.$kind)") {
                    \.$mealSize
                }
            } otherwise: {
                Summary("Log \(\.$kind)") {
                    \.$countValue
                }
            }
        }
    }
}
#endif
