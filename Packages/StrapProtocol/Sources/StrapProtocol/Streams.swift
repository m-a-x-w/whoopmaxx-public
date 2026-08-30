import Foundation

/// A decoded field value. Frames carry heterogeneous field maps, so event payloads are
/// dictionaries of these rather than a per-event struct.
public enum ParsedValue: Codable, Equatable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    /// A repeated field — the R-R block is the one that matters. Kept as a real array rather
    /// than a joined string so a consumer cannot silently re-split it on the wrong separator.
    case intArray([Int])
}

// MARK: - Samples
//
// Every sample carries a wall-clock unix second in `ts`. The raw-ADC lanes carry an explicit
// `unit` string rather than implying one: the values are ADC counts, and labelling them so is
// what stops a consumer treating a count as a physical measurement.

public struct HRSample: Equatable, Codable, Sendable {
    public let ts: Int
    public let bpm: Int
    public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
}

public struct RRInterval: Equatable, Codable, Sendable {
    public let ts: Int
    public let rrMs: Int
    public init(ts: Int, rrMs: Int) { self.ts = ts; self.rrMs = rrMs }
}

/// PPG-derived per-second HR from the optical buffer. Kept separate from `Streams.hr` — the
/// measured stream — so consumers can coalesce the two without conflating their provenance.
public struct PpgHrSample: Equatable, Codable, Sendable {
    public let ts: Int
    /// Whole bpm — the same domain as the measured `HRSample.bpm`, so a stored value from either
    /// lane compares directly.
    public let bpm: Int
    /// Normalised autocorrelation peak behind `bpm`, 0…1. Carried per sample rather than
    /// thresholded here: a PPG estimate and how much to trust it are two different facts, and
    /// dropping the second leaves a consumer unable to tell a locked-on reading from a guess.
    public let conf: Double
    public init(ts: Int, bpm: Int, conf: Double = 1.0) {
        self.ts = ts; self.bpm = bpm; self.conf = conf
    }
}

public struct WhoopEvent: Equatable, Codable, Sendable {
    /// Real unix seconds from the event RTC — never clock-offset.
    public let ts: Int
    public let kind: String
    public let payload: [String: ParsedValue]
    public init(ts: Int, kind: String, payload: [String: ParsedValue]) {
        self.ts = ts; self.kind = kind; self.payload = payload
    }
}

public struct BatterySample: Equatable, Codable, Sendable {
    public let ts: Int
    public let soc: Double?
    public let mv: Int?
    /// Only the battery-level event reports this; nil everywhere else.
    public let charging: Bool?
    public init(ts: Int, soc: Double?, mv: Int?, charging: Bool? = nil) {
        self.ts = ts; self.soc = soc; self.mv = mv; self.charging = charging
    }
}

/// Red and IR ADC counts.
///
/// These are ONE signal, not two channels: their difference is a fixed integer within a
/// capture session while both drift together. Any red/IR ratio built from them measures that
/// drift, not oxygenation. Carried because they are the bytes at those offsets.
public struct SpO2Sample: Equatable, Codable, Sendable {
    public let ts: Int
    public let red: Int
    public let ir: Int
    public let unit: String
    public init(ts: Int, red: Int, ir: Int, unit: String = "raw_adc") {
        self.ts = ts; self.red = red; self.ir = ir; self.unit = unit
    }
}

/// A raw ADC count from the optical block. Named for the field's original reading; it moves far
/// too fast between consecutive 1 Hz records to be a skin temperature. Do not convert to °C.
public struct SkinTempSample: Equatable, Codable, Sendable {
    public let ts: Int
    public let raw: Int
    public let unit: String
    public init(ts: Int, raw: Int, unit: String = "raw_adc") {
        self.ts = ts; self.raw = raw; self.unit = unit
    }
}

public struct RespSample: Equatable, Codable, Sendable {
    public let ts: Int
    public let raw: Int
    public let unit: String
    public init(ts: Int, raw: Int, unit: String = "raw_adc") {
        self.ts = ts; self.raw = raw; self.unit = unit
    }
}

/// Gravity vector in g. Magnitude is not calibrated to 1 g — treat as relative motion.
public struct GravitySample: Equatable, Codable, Sendable {
    public let ts: Int
    public let x: Double
    public let y: Double
    public let z: Double
    public let unit: String
    public init(ts: Int, x: Double, y: Double, z: Double, unit: String = "g") {
        self.ts = ts; self.x = x; self.y = y; self.z = z; self.unit = unit
    }
}

public struct StepSample: Equatable, Codable, Sendable {
    public let ts: Int
    public let counter: Int
    public let activityClass: Int?
    public init(ts: Int, counter: Int, activityClass: Int? = nil) {
        self.ts = ts; self.counter = counter; self.activityClass = activityClass
    }
}

/// The strap's own per-record sleep state, carried verbatim. An optional signal — a WHOOP 4.0
/// leaves it empty. It never overrides a derived stage.
public struct SleepStateSample: Equatable, Codable, Sendable {
    /// 0 wake · 1 still · 2 asleep · 3 up — the band's own code.
    public let ts: Int
    public let state: Int
    public init(ts: Int, state: Int) { self.ts = ts; self.state = state }
}

// MARK: - Streams

/// Everything decoded out of one chunk of frames, split by lane.
public struct Streams: Equatable, Codable, Sendable {
    public var hr: [HRSample]
    public var rr: [RRInterval]
    public var spo2: [SpO2Sample]
    public var skinTemp: [SkinTempSample]
    public var resp: [RespSample]
    public var gravity: [GravitySample]
    public var steps: [StepSample]
    public var sleepState: [SleepStateSample]
    public var ppgHr: [PpgHrSample]
    public var events: [WhoopEvent]
    public var battery: [BatterySample]

    /// How many records were dropped this chunk for an implausible own-timestamp — a strap with
    /// a bad clock reporting far-past or future-dated records.
    ///
    /// Transient observability only: excluded from `CodingKeys`, so it never round-trips through
    /// a stored fixture, and defaults to 0 so it cannot shift one.
    public var droppedImplausible: Int = 0

    public init(hr: [HRSample] = [], rr: [RRInterval] = [],
                spo2: [SpO2Sample] = [], skinTemp: [SkinTempSample] = [],
                resp: [RespSample] = [], gravity: [GravitySample] = [],
                steps: [StepSample] = [], sleepState: [SleepStateSample] = [],
                ppgHr: [PpgHrSample] = [],
                events: [WhoopEvent] = [], battery: [BatterySample] = []) {
        self.hr = hr; self.rr = rr
        self.spo2 = spo2; self.skinTemp = skinTemp; self.resp = resp; self.gravity = gravity
        self.steps = steps; self.sleepState = sleepState; self.ppgHr = ppgHr
        self.events = events; self.battery = battery
    }

    private enum CodingKeys: String, CodingKey {
        case hr, rr, spo2, skinTemp, resp, gravity, steps, sleepState, ppgHr, events, battery
    }

    /// True when no decoded rows landed in any lane — the signal that a whole chunk's frames
    /// dropped (CRC failure, unmapped layout, out-of-range timestamp). Silent data loss
    /// otherwise looks exactly like a quiet strap.
    public var isEmpty: Bool {
        hr.isEmpty && rr.isEmpty && spo2.isEmpty && skinTemp.isEmpty && resp.isEmpty
            && gravity.isEmpty && steps.isEmpty && sleepState.isEmpty && ppgHr.isEmpty
            && events.isEmpty && battery.isEmpty
    }
}
