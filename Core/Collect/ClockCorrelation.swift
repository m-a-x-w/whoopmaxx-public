import Foundation
import StrapProtocol
import StrapStore

/// Tying the strap's own clock to wall time.
///
/// Live records are stamped from a device clock that is not unix time. One pair of (device, wall)
/// readings taken at connect is what maps every later record onto the calendar.
enum ClockCorrelation {
    /// A reference from a decoded clock response, or nil.
    ///
    /// Nil unless the frame parsed, passed its checksum, and actually carries a clock. Everything
    /// timestamped afterwards depends on this pair, so a frame that is merely probably fine is not
    /// good enough to anchor a night to.
    static func clockRef(from parsed: ParsedFrame, wall: Int) -> ClockRef? {
        guard parsed.ok, parsed.crcOK != false,
              let device = parsed.parsed["clock"]?.intValue else { return nil }
        return ClockRef(device: device, wall: wall)
    }
}
