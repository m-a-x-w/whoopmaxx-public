import CoreBluetooth
import StrapProtocol

/// Which strap to look for.
///
/// Scanning is filtered by service, so knowing the family finds the band in seconds instead of
/// sifting every advertiser in range.
public enum WhoopModel: String, CaseIterable, Identifiable, Hashable {
    case whoop4   = "WHOOP 4.0"
    case whoop5mg = "WHOOP 5.0 / MG"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    /// The other family to try when a filtered scan finds nothing.
    ///
    /// A stored preference can go stale — after an update, or a restore onto a new phone — and a
    /// scan filtered on the wrong service runs forever with the strap sitting on the wrist. Rotating
    /// families, and persisting whichever one actually answers, recovers without asking.
    var fallbackScanModel: WhoopModel {
        switch self {
        case .whoop4:   return .whoop5mg
        case .whoop5mg: return .whoop4
        }
    }

    /// The protocol family: framing, checksum width, characteristics, handshake.
    public var deviceFamily: DeviceFamily {
        switch self {
        case .whoop4:   return .whoop4
        case .whoop5mg: return .whoop5
        }
    }

    /// The one key every picker writes and every reader binds to.
    public static let persistedKey = "selectedWhoopModel"

    /// The last chosen model, for scans nobody asked for — a relaunch, a power-on reconnect, a
    /// restored session. Defaulting blindly to one family makes the other family's users wait for a
    /// scan that cannot succeed.
    public static var persisted: WhoopModel {
        UserDefaults.standard.string(forKey: persistedKey)
            .flatMap(WhoopModel.init(rawValue:)) ?? .whoop4
    }

    /// The service to scan for and to discover after connecting.
    ///
    /// Held here rather than read off the connection manager so this stays free of actor isolation;
    /// `CBUUID` compares by value, so the two agree by construction.
    public var scanService: CBUUID {
        switch self {
        case .whoop4:   return CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
        case .whoop5mg: return CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a")
        }
    }
}
