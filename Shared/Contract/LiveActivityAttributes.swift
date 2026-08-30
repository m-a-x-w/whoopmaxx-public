#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for an active live-HR session. Shared between the app (which starts /
/// updates / ends the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island). Ported from the original ActivityAttributes, on whoopmaxx's Charge/Effort axis.
public struct WMActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bpm: Int?
        public var charge: Int?      // Charge / recovery (0–100)
        public var effort: Int?      // Effort / strain (0–100)
        public var bonded: Bool

        public init(bpm: Int?, charge: Int?, effort: Int?, bonded: Bool) {
            self.bpm = bpm
            self.charge = charge
            self.effort = effort
            self.bonded = bonded
        }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "Live HR") {
        self.title = title
    }
}
#endif
