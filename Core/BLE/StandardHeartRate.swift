import Foundation

/// The Bluetooth SIG Heart Rate Measurement characteristic (0x2A37).
///
/// A pure decode, so it can be tested against captured bytes without a radio.
public enum StandardHeartRate {
    public static func parse(_ data: [UInt8]) -> (hr: Int, rr: [Int])? {
        guard let flags = data.first else { return nil }
        var i = 1

        // Bit 0 says whether the rate is 8- or 16-bit. Every length is checked before the read: this
        // is untrusted radio input, and a truncated packet must return nil rather than trap.
        let hr: Int
        if flags & 0x01 != 0 {
            guard i + 1 < data.count else { return nil }
            hr = Int(data[i]) | (Int(data[i + 1]) << 8)
            i += 2
        } else {
            guard i < data.count else { return nil }
            hr = Int(data[i])
            i += 1
        }

        if flags & 0x08 != 0 { i += 2 }           // energy expended, present and unused

        var rr: [Int] = []
        if (flags >> 4) & 0x01 != 0 {
            // Intervals are in 1/1024 s, not milliseconds. Reading them as ms understates every
            // interval by about 2%, which is enough to move an HRV figure.
            while i + 1 < data.count {
                let raw = Int(data[i]) | (Int(data[i + 1]) << 8)
                rr.append(Int((Double(raw) / 1024.0 * 1000.0).rounded()))
                i += 2
            }
        }
        return (hr, rr)
    }
}
