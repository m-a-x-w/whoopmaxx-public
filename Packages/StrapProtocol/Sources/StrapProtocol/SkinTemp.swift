import Foundation

/// WHOOP 4.0 skin-temp mapping constants, kept in one place so the provisional slope has an
/// obvious home.
public enum Whoop4SkinTemp {
    /// Worn resting raw register value the anchor pins.
    public static let anchorRaw: Double = 826.0
    /// Nocturnal wrist skin temperature the anchor raw maps to (°C).
    public static let anchorCelsius: Double = 33.0
    /// PROVISIONAL °C per raw unit — a single-anchor fit, not a measured transfer function.
    public static let provisionalSlopeCPerRaw: Double = 0.05
}

/// Convert a raw `skinTempRaw` register value to °C, per device family.
///
/// ⚠️ THE INPUT FIELD IS DISPUTED. `skinTempRaw` is the u16 at inner[68], and an independent
/// analysis of a 1,047,400-row export found it moves 5–10 counts per second between consecutive
/// 1 Hz records, while the heart rate carried in those same records moves 0.72 bpm/s. No skin
/// temperature changes that fast. Two genuinely slow, temperature-shaped candidates do exist in
/// the same block — the u16 at inner[72] and at inner[88], both ~0.02 counts/s — but neither is
/// confirmed, and moving slowly is not by itself evidence of being a temperature.
///
/// That analysis and the mapping below explain the SAME observation differently. Under a plain
/// `raw / 100` a worn WHOOP 4.0 value reads ~8.3 °C, which is impossible for a wrist streaming a
/// resting heart rate. This function concludes the SCALE is wrong and re-anchors it; the other
/// analysis concludes the FIELD is wrong. Both fit the evidence; the second has more behind it.
///
/// Kept as-is for now because changing it would silently move every stored skin-temp value and
/// the illness signal built on top of them. Resolve it deliberately, not as a side effect.
///
/// - `.whoop5`: `raw / 100`. Verified on real captures at both ends — worn 3057 → 30.6 °C and
///   off-wrist 2247 → 22.5 °C are both physically right.
/// - `.whoop4`: a single-anchor affine map, all values APPROXIMATE. The downstream use is a
///   deviation from the user's own nightly baseline, so the offset is what has to be right to
///   clear the worn gate; a slope error rescales the deviation but stays directionally correct.
public func skinTempCelsius(raw: Int, family: DeviceFamily) -> Double {
    switch family {
    case .whoop5:
        return Double(raw) / 100.0
    case .whoop4:
        return Whoop4SkinTemp.anchorCelsius
            + (Double(raw) - Whoop4SkinTemp.anchorRaw) * Whoop4SkinTemp.provisionalSlopeCPerRaw
    }
}

/// Build a gen5 command frame. The battery-pack framing is the gen5 envelope — there is no
/// separate wire format, so this is `buildFrame(profile: .gen5)` with the command header.
public func puffinCommandFrame(cmd: UInt8, seq: UInt8, payload: [UInt8] = [0x00],
                               type: UInt8 = PacketType.command) -> [UInt8] {
    buildFrame([type, seq, cmd] + payload, profile: .gen5)
}
