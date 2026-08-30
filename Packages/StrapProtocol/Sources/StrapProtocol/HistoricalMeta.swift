import Foundation

/// The sync-progress markers the strap interleaves with its history burst.
public enum HistoricalMeta: Equatable, Sendable {
    case start
    /// The strap is done and is telling us where it will trim from. `trim` is the cursor the ack
    /// carries back — acking is what DESTROYS that backlog on the strap, so this pair has to be
    /// carried exactly.
    case end(unix: UInt32, trim: UInt32)
    case complete
    case other
}

/// Classify one frame as a sync marker, or `.other`.
///
/// Fails closed at every step: a frame that did not decode, is not metadata, or is missing either
/// half of the end marker is `.other`. A half-read end marker would otherwise ack a cursor the
/// strap never sent.
public func classifyHistoricalMeta(_ p: ParsedFrame) -> HistoricalMeta {
    guard p.ok, p.crcOK != false else { return .other }
    guard p.typeName == "METADATA" else { return .other }
    guard case .string(let metaName)? = p.parsed["meta_type"] else { return .other }

    if metaName.hasPrefix("HISTORY_START") {
        return .start
    } else if metaName.hasPrefix("HISTORY_COMPLETE") {
        return .complete
    } else if metaName.hasPrefix("HISTORY_END") {
        guard case .int(let unix)? = p.parsed["unix"],
              case .int(let trim)? = p.parsed["trim_cursor"] else { return .other }
        return .end(unix: UInt32(truncatingIfNeeded: unix),
                    trim: UInt32(truncatingIfNeeded: trim))
    }
    return .other
}

/// The historical records this decoder could NOT turn into biometrics.
///
/// The caller archives these raw so a later field map can recover them. Getting this filter wrong
/// in the permissive direction wastes disk; getting it wrong in the strict direction throws away
/// records the strap has already trimmed and will never send again.
///
/// A record counts as rejected when the envelope failed, or when it decoded but yielded no
/// timestamp, or neither a heart rate nor motion. A record carrying gravity but no per-second HR
/// is REAL data the sleep stager uses — the PPG-waveform layout is exactly that shape — so
/// motion alone is enough to keep it.
public func rejectedHistoricalRecords(_ rawFrames: [[UInt8]], family: DeviceFamily) -> [[UInt8]] {
    let typeIndex = family == .whoop5 ? 8 : 4
    let versionIndex = family == .whoop5 ? 9 : 5
    return rawFrames.filter { f in
        guard f.count > typeIndex, Int(f[typeIndex]) == Int(PacketType.historicalData) else { return false }
        // The PPG-waveform layout carries no biometrics by design — v25 on WHOOP 4.0, v26 on
        // WHOOP 5/MG. Archiving it as "rejected" would file the strap's LARGEST record type as a
        // decode failure on every sync and flood the reject archive with frames that hold nothing
        // to recover. The gen5-only guard here missed the gen4 v25 case entirely, so a WHOOP 4.0
        // reported a burst of "undecodable sensor record(s)" on every offload.
        let ppgWaveformVersion = family == .whoop5 ? 26 : 25
        if f.count > versionIndex, Int(f[versionIndex]) == ppgWaveformVersion { return false }
        let p = parseFrame(f, family: family)
        if !p.ok || p.crcOK == false { return true }
        return p.parsed["unix"]?.intValue == nil
            || (p.parsed["heart_rate"]?.intValue == nil && p.parsed["gravity_x"]?.doubleValue == nil)
    }
}
