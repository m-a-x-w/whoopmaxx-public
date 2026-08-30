import Foundation

/// Beat-to-beat bounds, ms. 2500 ms = 24 bpm, 200 ms = 300 bpm.
public let minRRIntervalMs = 200
public let maxRRIntervalMs = 2500
/// Most R-R intervals one historical record may declare.
public let maxRRPerRecord = 8

/// A decoded historical biometric record (packet types 0x2F / 0x28).
///
/// Several fields here are named for what the wire format was once believed to carry rather
/// than what they measure. They are decoded and emitted because they are live columns
/// downstream, and each carries a warning saying what the bytes actually are. Nothing new
/// should be derived from them:
///
/// - `ppgRedIr` is a u16 straddling a float32, so its high byte is that float's mantissa LSB.
/// - `skinContact` is that same float32's sign+exponent byte, which is why its only observed
///   values are {0, 63–70, 194–198}.
/// - `skinTempRaw` moves 5–10 counts/second between consecutive 1 Hz records. No skin
///   temperature does that.
/// - `spo2RedRaw` and `spo2IrRaw` are one signal, not two channels — their difference is a
///   fixed integer within a capture session. A ratio built from them measures baseline drift.
public struct R24: Sendable, Equatable {
    /// Historical layout version, `inner[1]`.
    public let histVersion: Int
    public let tsEpoch: UInt32
    public let tsSubsec: UInt16
    public let counter: UInt32
    public let hr: Int
    /// Count of intervals ACCEPTED — always `rrIntervalsMs.count`, never the declared byte.
    public let rrCount: Int
    public let rrIntervalsMs: [Int]
    public let ppgGreen: Int
    public let ppgRedIr: Int
    /// Gravity vector in g, 3 × float32. Empty on v25 — absent, not a still wrist.
    ///
    /// Not calibrated to 1 g: magnitude runs ~4.6% high. Treat as relative motion. No
    /// correction is applied here on purpose — a scale derived from one corpus would be a
    /// fabricated calibration applied to every stored value.
    public let accelG: [Double]
    public let skinContact: Int
    public let spo2RedRaw: Int
    public let spo2IrRaw: Int
    public let skinTempRaw: Int
    public let ambientRaw: Int
    /// The u16 at inner[76]. NOT covered by the external parity corpus — this offset is our own
    /// claim, carried forward from the previous decoder, and nothing independent confirms it.
    public let respRateRaw: Int
    /// The u16 at inner[78]. Same caveat as `respRateRaw`.
    public let signalQuality: Int
    /// Untouched payload from byte 13, kept so records can be re-decoded as the map improves.
    public let rawTail: [UInt8]
}

/// HR byte offset per layout version. Only the offset is independently confirmed for the
/// versions that are not 24/12 — not the rest of the field map.
private let hrOffsetByVersion: [Int: Int] = [7: 27, 9: 17, 12: 17, 18: 14, 24: 17]

/// Layout versions this decoder has a field map for.
public let knownRecordVersions: Set<Int> = Set(hrOffsetByVersion.keys).union([25])

/// The hardware-validated minimum length for the v24 field map. Never loosen this.
public let legacyMinLength = 89
/// The minimum to read every field this layout touches — the last is `ambientRaw` at [70..<72].
/// Only reached after the 89-byte attempt fails, so devices matching the validated shape are
/// unaffected.
public let shortFrameMinLength = 72

/// Decode a historical biometric record. `inner` starts at the packet-type byte.
///
/// Routing:
/// - v25 → the 24 Hz PPG-waveform layout: timestamp and counter only.
/// - v24 / v12 → the hardware-validated field map, returned as-is.
/// - v18 / v9 / v7 → the same map with that version's HR offset. Only HR, timing and accel
///   are evidenced, so the R-R and optical blocks come back absent, and the decode is
///   returned only if physiologically plausible.
/// - anything else → attempt the v24 map, gated on the same plausibility check.
public func parseR24(_ inner: [UInt8], minLength: Int = legacyMinLength) -> R24? {
    guard inner.count >= 2 else { return nil }
    // Dispatching on inner[1] alone would read a control frame's SEQUENCE byte: a console-log
    // or command frame whose sequence happened to be 24 or 12 would decode as a record, with
    // an HR and an accel vector read out of log text. Two in 256 of any long-enough frame.
    guard inner[0] == PacketType.historicalData || inner[0] == PacketType.realtimeData else { return nil }

    let version = Int(inner[1])
    if version == 25 { return parseV25(inner) }

    let trusted = version == 24 || version == 12
    let hrOffset = hrOffsetByVersion[version] ?? 17
    return parseV24Layout(inner, version: version, hrOffset: hrOffset,
                          validate: !trusted, minLength: minLength)
}

/// The v25 layout is a 24 Hz PPG waveform. Timestamp and counter only — respiratory rate,
/// HRV, SpO2 and perfusion index were each tested against it and each failed.
private func parseV25(_ inner: [UInt8]) -> R24? {
    // Only [3..<11] is read, but a real v25 burst is ~76 bytes; anything shorter is truncated.
    guard inner.count >= 75 else { return nil }
    return R24(histVersion: 25,
               tsEpoch: u32(inner, 7), tsSubsec: 0, counter: u32(inner, 3),
               hr: 0, rrCount: 0, rrIntervalsMs: [],
               ppgGreen: 0, ppgRedIr: 0, accelG: [], skinContact: 0,
               spo2RedRaw: 0, spo2IrRaw: 0, skinTempRaw: 0, ambientRaw: 0,
               respRateRaw: 0, signalQuality: 0,
               rawTail: inner.count > 13 ? Array(inner[13...]) : [])
}

private func parseV24Layout(_ inner: [UInt8], version: Int, hrOffset: Int,
                            validate: Bool, minLength: Int) -> R24? {
    guard inner.count >= minLength, hrOffset < inner.count else { return nil }

    // R-R: declared count at [18], then that many int16 LE from [19].
    //
    // The declared count is UNTRUSTED. Taken raw it addresses up to 255 int16s from [19],
    // walking through ppg@29, the accel float32s@36/40/44, the float32@48, spo2@64/66 and
    // ambient@70 — reinterpreting all of them as beats that then feed RMSSD.
    //
    // These bytes are read ONLY where the v24 map is confirmed. For other versions just the
    // HR offset is established (v7 puts HR at 27, v18 at 14 — proof the layout differs), so
    // reading a count at 18 would be applying v24's map to bytes known not to be v24's. The
    // range filter cannot save that: arbitrary bytes land inside 200–2500 ms often enough to
    // hand HRV a full set of fabricated beats.
    let declaredRRCount = validate ? 0 : Int(inner[18])
    var rrIntervalsMs: [Int] = []
    if declaredRRCount <= maxRRPerRecord {
        for i in 0..<declaredRRCount where 19 + 2 * i + 2 <= inner.count {
            let v = Int(i16(inner, 19 + 2 * i))
            if v >= minRRIntervalMs && v <= maxRRIntervalMs { rrIntervalsMs.append(v) }
        }
    }

    let hr = Int(inner[hrOffset])
    let accelG = [f32(inner, 36), f32(inner, 40), f32(inner, 44)].map { round($0 * 10_000) / 10_000 }

    // A NaN or infinite component means [36..<48] is not the float32 vector this map claims.
    // Emitting 0.0 would poison every downstream mean and standard deviation with a value that
    // reads as a real measurement, so reject the record — the caller archives the raw bytes.
    // Runs BEFORE the validate gate so it covers the trusted path too.
    guard accelG.allSatisfy(\.isFinite) else { return nil }
    if validate && !physiologicallyPlausible(accelG: accelG, hr: hr) { return nil }

    // The optical block gets the same rule as the R-R block: v24's map, read only where that
    // map is confirmed. 0 is this stack's ADC-absent sentinel; every consumer gates on `> 0`.
    let optical = !validate
    return R24(histVersion: version,
               tsEpoch: u32(inner, 7), tsSubsec: u16(inner, 11), counter: u32(inner, 3),
               hr: hr, rrCount: rrIntervalsMs.count, rrIntervalsMs: rrIntervalsMs,
               ppgGreen:    optical ? Int(u16(inner, 29)) : 0,
               ppgRedIr:    optical ? Int(u16(inner, 31)) : 0,
               accelG: accelG,
               skinContact: optical ? Int(inner[51]) : 0,
               spo2RedRaw:  optical ? Int(u16(inner, 64)) : 0,
               spo2IrRaw:   optical ? Int(u16(inner, 66)) : 0,
               skinTempRaw: optical ? Int(u16(inner, 68)) : 0,
               ambientRaw:  optical ? Int(u16(inner, 70)) : 0,
               respRateRaw:   optical ? Int(u16(inner, 76)) : 0,
               signalQuality: optical ? Int(u16(inner, 78)) : 0,
               rawTail: inner.count > 13 ? Array(inner[13...]) : [])
}

/// Gravity magnitude ≈ 1 g (0.5–1.8) AND HR in a live human range (25–230 bpm). Guards
/// speculative decodes only. Compared on magnitude-squared to avoid a square root.
private func physiologicallyPlausible(accelG: [Double], hr: Int) -> Bool {
    guard hr >= 25, hr <= 230, accelG.count == 3 else { return false }
    let magSq = accelG[0] * accelG[0] + accelG[1] * accelG[1] + accelG[2] * accelG[2]
    return magSq >= 0.25 && magSq <= 3.24
}

// MARK: - Little-endian readers
//
// Bounds-checked and offset-based rather than a typed view: `inner` arrives from a radio, and
// an out-of-range read on a truncated frame must be a zero, not a trap.

@inline(__always) func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
    guard i + 1 < b.count else { return 0 }
    return UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
}

@inline(__always) func i16(_ b: [UInt8], _ i: Int) -> Int16 {
    Int16(bitPattern: u16(b, i))
}

@inline(__always) func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
    guard i + 3 < b.count else { return 0 }
    return UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
}

@inline(__always) func f32(_ b: [UInt8], _ i: Int) -> Double {
    guard i + 3 < b.count else { return 0 }
    return Double(Float(bitPattern: u32(b, i)))
}

// MARK: - Timestamp plausibility
//
// A strap with a bad clock reports records dated in 1970, in 2099, or a day past the moment it
// handed them over. These bounds are what a record's OWN timestamp is checked against before it
// is banked — the alternative is a history whose ordering is decided by garbage.

/// Floor for a record's own timestamp: 2023-11. Nothing this strap recorded predates it.
public let MIN_PLAUSIBLE_UNIX = 1_700_000_000

/// Upper bound for "is this field a clock at all", as opposed to "is this record's stamp usable".
///
/// Deliberately far out (2100-01). The record gate is `wallNow + FUTURE_MARGIN`, which is correct
/// for a RECORD — a measurement dated tomorrow is wrong. It is the wrong test for the strap's own
/// RTC, because a strap whose clock is years fast is exactly the case the clock reference exists to
/// correct for. Judging the clock by the record gate withholds the reference precisely when it is
/// needed, which leaves the correction offset at zero and drops the whole offload as implausible.
public let MAX_PLAUSIBLE_UNIX = 4_102_444_800

/// How far past the moment of capture a record may claim to be. A historical record cannot
/// post-date its own offload, so anything beyond a day of slack is a clock fault, not a record.
public let FUTURE_MARGIN = 86_400
