import WidgetKit
import SwiftUI

/// The widget extension entry point. Bundles the glanceable home/lock-screen widget and the live-HR
/// Live Activity (both riding the same App-Group snapshot the app publishes).
@main
struct WMWidgetBundle: WidgetBundle {
    var body: some Widget {
        // 028: the Home Screen quick-log surface. iOS 17+ for interactive widgets.
        if #available(iOS 17.0, *) { WMIntakeWidget() }
        // 031: the same lane on the Lock Screen — the accessory strip around the clock, and the
        // corner/Control-Centre slots. Both carry ONE configured tap (see IntakeQuickConfig).
        WMIntakeAccessoryWidget()
        WMIntakeControl()
        WMWidget()
        WMLiveActivity()
    }
}
