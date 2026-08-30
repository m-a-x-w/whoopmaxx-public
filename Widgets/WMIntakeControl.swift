import SwiftUI
import WidgetKit
import AppIntents

/// The quick-log Control (031): the same one configured tap, in the Lock Screen's bottom slots.
///
/// A Control is a different surface from the accessory widget above it, not a duplicate of one. It
/// lands in three places the widget strip cannot reach — the two Lock Screen corner slots, Control
/// Centre, and the Action button — and its tap target is a full system control, which is the largest
/// this action gets anywhere in the app.
///
/// It fires `LogIntakeIntent` directly, so it inherits the property that matters: `openAppWhenRun =
/// false`, on a LOCKED device. Logging a coffee never unlocks the phone or shows the app, and nothing
/// about the user's intake is rendered on the lock screen by this control — only the noun they chose.
///
/// A button and not a toggle, deliberately. `ControlWidgetToggle` implies a state that can be turned
/// back off; an intake event is a record of something that happened, and the un-log path is the Intake
/// list where the row can be seen before it is deleted.
struct WMIntakeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "WMIntakeControl",
                                      provider: IntakeControlProvider()) { preset in
            ControlWidgetButton(action: preset.logIntent) {
                Label(preset.label, systemImage: preset.symbol)
                // The standing amount as the control's supporting line — omitted entirely when the tap
                // is bare, so the control never shows a quantity the user did not declare.
                if !preset.caption.isEmpty {
                    Text(preset.caption)
                }
            }
        }
        .displayName("Log intake")
        .description("One tap to log a meal, drink or dose.")
    }
}

struct IntakeControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: IntakeControlConfigIntent) -> IntakeQuickPreset {
        configuration.preset
    }

    /// No I/O: the value IS the configuration. There is nothing to read back, because a logging
    /// control has no current state — only what the next tap would write.
    func currentValue(configuration: IntakeControlConfigIntent) async throws -> IntakeQuickPreset {
        configuration.preset
    }
}
