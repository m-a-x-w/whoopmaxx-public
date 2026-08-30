#if os(iOS)
import AppIntents
import WidgetKit

/// The project's FIRST `AppIntent` — one Home Screen tap becomes one pending intake entry (028).
///
/// It appends to `IntakeOutbox` and returns. It deliberately does NOT open the app and does NOT touch
/// the database: the store lives in the app container, not the App Group, so this process could not
/// write it even if it wanted to (see `IntakeOutbox`'s type doc for why that stays true).
///
/// `openAppWhenRun = false` is the whole point. The value of a widget button is capturing the moment
/// without a context switch; launching the app to log a coffee is the context switch.
@available(iOS 17.0, *)
public struct LogIntakeIntent: AppIntent {
    public static var title: LocalizedStringResource = "Log intake"
    public static var description = IntentDescription("Log a meal, drink or dose from the Home Screen.")
    public static var openAppWhenRun = false

    /// `IntakeKind` raw value. A String rather than the app's enum so this contract does not drag the
    /// domain layer into the widget target.
    @Parameter(title: "Kind") public var kind: String
    /// The amount the user configured for this kind in `Edit Widget`, if any. Nil means the tap logs
    /// bare — and bare is honest, because a single tap genuinely knows nothing about quantity.
    @Parameter(title: "Milligrams") public var amountMg: Int?
    @Parameter(title: "Count") public var countValue: Int?
    @Parameter(title: "Form") public var variant: String?
    /// `MealSize` raw ordinal (1|2|3). Added in 031 for the configurable Lock Screen surfaces — the
    /// outbox and the drain have carried `sizeOrdinal` since 028, this was the one hop that dropped it,
    /// so a meal could only ever be logged bare. Optional and additive: an already-installed 028 widget
    /// keeps firing the intent without it and still logs exactly what it logged before.
    @Parameter(title: "Size") public var sizeOrdinal: Int?

    public init() { kind = "" }

    public init(kind: String, amountMg: Int? = nil, countValue: Int? = nil,
                variant: String? = nil, sizeOrdinal: Int? = nil) {
        self.kind = kind; self.amountMg = amountMg
        self.countValue = countValue; self.variant = variant
        self.sizeOrdinal = sizeOrdinal
    }

    public func perform() async throws -> some IntentResult {
        // A tap that cannot possibly be stored must not report success. Without the App Group on THIS
        // target, `UserDefaults(suiteName:)` hands back a private store: the append "works", the app
        // never sees it, and the user's log is gone with no indication anywhere. Fail loudly instead —
        // in Release too, which is the only build where this actually goes wrong.
        guard WidgetSnapshot.isGroupProvisioned else { throw LogIntakeError.appGroupUnavailable }
        IntakeOutbox.append(.init(kind: kind,
                                  ts: Int(Date().timeIntervalSince1970),
                                  variant: variant,
                                  countValue: countValue,
                                  sizeOrdinal: sizeOrdinal,
                                  amountMg: amountMg))
        // Redraw so today's count moves under the user's finger rather than at the next timeline tick.
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// Why a tap could not be logged. One case, because there is exactly one way this fails that the user
/// can do anything about.
enum LogIntakeError: Error, CustomLocalizedStringResourceConvertible {
    case appGroupUnavailable

    var localizedStringResource: LocalizedStringResource {
        "whoopmaxx was installed without its App Group, so the widget can't reach the app. Reinstall a build packaged by scripts/build-ipa.sh."
    }
}
#endif
