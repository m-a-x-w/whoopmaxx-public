import Foundation

/// A live heart-rate packet (`REALTIME_DATA` 0x28).
public struct RealtimeHr: Equatable, Sendable {
    public let bpm: Int
    public let rrIntervalsMs: [Int]
    /// The strap's own wear flag. Absent on a short packet, where it defaults to worn — a
    /// truncated packet is not evidence the strap came off.
    public let wearing: Bool
    public let tsEpoch: UInt32
}

/// The realtime wire form has room for exactly four R-R slots, at inner [10] [12] [14] [16],
/// bounded by the wear byte at [18].
private let maxRealtimeRR = 4

/// Decode a realtime HR packet. `inner` starts at the packet-type byte.
///
/// Returns nil when the heart rate is outside a living range — on this packet HR is the field
/// that says whether the offsets line up at all.
public func parseRealtimeHr(_ inner: [UInt8]) -> RealtimeHr? {
    guard inner.count >= 9 else { return nil }
    let ts = u32(inner, 2)
    let hr = Int(inner[8])
    guard hr >= 1, hr <= 250 else { return nil }

    // A 9-byte packet carries timestamp and HR and nothing after them. A missing count byte
    // means no intervals, not a failed decode.
    let declared = inner.count > 9 ? Int(inner[9]) : 0
    var rr: [Int] = []
    // A count above the four slots the layout holds means these are not the bytes we think they
    // are. Emit no intervals rather than reading the wear byte — or whatever follows — as a beat.
    if declared > 0 && declared <= maxRealtimeRR {
        for i in 0..<declared {
            let off = 10 + 2 * i
            guard off + 2 <= inner.count else { break }
            let v = Int(u16(inner, off))
            if v >= minRRIntervalMs && v <= maxRRIntervalMs { rr.append(v) }
        }
    }
    let wearing = inner.count > 18 ? inner[18] == 1 : true
    return RealtimeHr(bpm: hr, rrIntervalsMs: rr, wearing: wearing, tsEpoch: ts)
}
