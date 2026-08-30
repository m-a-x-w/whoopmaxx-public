import Foundation

/// The opt-in switches, and what each one actually does to the strap.
///
/// They are grouped here because they share one property worth stating once: several of them WRITE
/// to the band. A read-only probe costs nothing if it is wrong; a config write changes the strap's
/// own state, so those are separately opt-in and individually reversible.
enum PuffinExperiment {

    /// Experimental protocol probes for the 5/MG family.
    ///
    /// Live heart rate on a 5/MG already works over the standard profile, so nothing here is needed
    /// for the app to function. These send framed commands to learn what the strap answers — they
    /// are guesses, which is why they are off by default and only ever written to the strap's own
    /// command characteristic.
    static let defaultsKey = "wmPuffinExperiments"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// The deep-data unlock: the one probe that writes a PERSISTENT feature flag to the strap.
    ///
    /// Kept apart from the read-only probes precisely because it changes strap state. Reversible,
    /// and never sent without this being turned on deliberately.
    static let deepDataKey = "wmWhoop5DeepData"
    static var deepDataEnabled: Bool { UserDefaults.standard.bool(forKey: deepDataKey) }

    /// Broadcast heart rate: asks the strap to advertise the standard Heart Rate Service, so a bike
    /// computer or a gym machine can read it. A config write, reversible, off by default.
    static let broadcastHrKey = "wmBroadcastHr"
    static var broadcastHrEnabled: Bool { UserDefaults.standard.bool(forKey: broadcastHrKey) }

    /// Hold the dense realtime stream armed with no Live screen open, so beat-to-beat intervals are
    /// banked continuously. The history offload is far too sparse for overnight HRV; this is what
    /// makes recovery work out of the box. It costs battery, which is what the window below is for.
    static let keepRealtimeForDataKey = "wmContinuousHrv"
    static let keepRealtimeForDataDefault = true
    static var keepRealtimeForDataEnabled: Bool { flag(keepRealtimeForDataKey,
                                                       default: keepRealtimeForDataDefault) }

    /// Bound that capture to the night rather than the whole day — roughly half the battery for the
    /// HRV that actually matters. Composed with the switch above, so an existing install needs no
    /// migration: base on with this off is the old always-on behaviour.
    static let continuousHrvOvernightOnlyKey = "wmContinuousHrvOvernightOnly"
    static let continuousHrvOvernightOnlyDefault = true
    static var continuousHrvOvernightOnlyEnabled: Bool {
        flag(continuousHrvOvernightOnlyKey, default: continuousHrvOvernightOnlyDefault)
    }

    /// Which stager runs over an already-detected night. A staging switch only: it never moves a
    /// window boundary, and detection and scoring keep their own paths.
    ///
    /// Default on. The band classifier it replaces decides every epoch by WITHIN-NIGHT percentile,
    /// so each band's hit rate is a constant of the algorithm rather than a property of the night —
    /// a night with a quarter deep sleep and a night with none hand it the same rank budget. A rank
    /// statistic cannot answer a level question. It is kept as the fallback.
    ///
    /// Its level-setting constants were fitted against one subject's record. The structural argument
    /// does not depend on that; the exact deep fraction does. Revalidate before treating those
    /// numbers as settled.
    static let experimentalSleepV2Key = "wmExperimentalSleepV2"
    static let experimentalSleepV2Default = true
    static var experimentalSleepV2Enabled: Bool { flag(experimentalSleepV2Key,
                                                       default: experimentalSleepV2Default) }

    /// Offer to save a sustained-elevated stretch of heart rate as a workout. A suggestion only —
    /// nothing is created without a tap, and turning it off stops the scan as well as the card.
    static let autoDetectWorkoutsKey = "wmAutoDetectWorkouts"
    static var autoDetectWorkoutsEnabled: Bool {
        UserDefaults.standard.bool(forKey: autoDetectWorkoutsKey)
    }

    /// Read a flag that DEFAULTS ON.
    ///
    /// `bool(forKey:)` reads an unset key as false, which pins a default-on switch to off forever.
    /// Going through `object(forKey:)` lets a stored value win in both directions — so anyone who
    /// deliberately turned one off stays off — and only an absent key falls through to the default.
    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
}
