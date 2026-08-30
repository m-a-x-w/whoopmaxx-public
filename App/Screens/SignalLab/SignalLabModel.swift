import Foundation
import StrapProtocol
import StrapAnalytics

/// The stored raw channels the Signal Lab HISTORY scope can draw, in top-to-bottom lane order.
/// READ-ONLY: every channel is sourced from an existing StrapStore reader under the raw strap id.
///
/// `.resp` is NOT respiration, despite the stored table's name. `resp_rate_raw@80` on the WHOOP 4.0 v24
/// record layout is an optical MODE REGISTER: across 1,433,848 real rows it takes exactly two values
/// (3073 = 0x0C01, 2817 = 0x0B01 — a constant 0x01 tag with a high byte toggling 12↔11 in ~29 s bursts
/// every ~19 min), sitting between the `led_drive` and `signal_quality` registers. The lane is labelled
/// for what it is rather than dropped, because the enum case and its `rawValue` are persisted in the
/// user's visible-channel preference — and because a future layout that DOES emit a waveform would
/// surface here. See `RespChannelGate` / `SleepStaging.respChannelUsable`.
enum ScopeChannel: String, CaseIterable, Identifiable, Hashable {
    case hr, rr, gravity, skinTemp, spo2, resp, steps, sleepState
    var id: String { rawValue }

    /// Lane title.
    var title: String {
        switch self {
        case .hr:         return "Heart rate"
        case .rr:         return "R-R interval"
        case .gravity:    return "Gravity"
        case .skinTemp:   return "Skin temp"
        case .spo2:       return "SpO₂"
        case .resp:       return "Sensor mode"     // NOT respiration — see the type note above
        case .steps:      return "Steps"
        case .sleepState: return "Sleep state"
        }
    }

    /// Short chip label for the show/hide toggles.
    var chip: String {
        switch self {
        case .hr:         return "HR"
        case .rr:         return "R-R"
        case .gravity:    return "GRAV"
        case .skinTemp:   return "SKIN"
        case .spo2:       return "SpO₂"
        case .resp:       return "MODE"
        case .steps:      return "STEP"
        case .sleepState: return "SLEEP"
        }
    }

    /// The unit label shown next to the lane readout, for the current [Physical | Raw] toggle. SpO₂ is
    /// stored as raw ADC only (no derived % per sample) and the `.resp` lane is a raw device register,
    /// so both are labelled honestly in BOTH modes — never a fabricated physical unit. `imperial` swaps
    /// the physical skin-temp label °C→°F to match the Units pref (raw ADC never changes).
    func unitLabel(_ unit: SignalLabMath.ScopeUnit, imperial: Bool) -> String {
        switch self {
        case .hr:         return "bpm"
        case .rr:         return "ms"
        case .gravity:    return unit == .raw ? "i16" : "g"
        case .skinTemp:   return unit == .raw ? "ADC" : TempUnit.label(imperial: imperial)
        case .spo2:       return "ADC"          // raw red/IR ADC — NOT a derived %
        case .resp:       return "reg"          // device register word — NOT a breathing rate
        case .steps:      return "count"
        case .sleepState: return "0–3"
        }
    }

    /// True when the [Physical | Raw] toggle actually changes this channel's numbers.
    var hasRawForm: Bool { self == .gravity || self == .skinTemp }

    /// Discrete channel (hold / step lookup at the cursor, never interpolated). `.resp` qualifies: it is a
    /// two-state mode register that HOLDS between switches, so interpolating it would draw a ramp the
    /// device never emitted.
    var isDiscrete: Bool { self == .sleepState || self == .resp }
}

/// One drawable line within a lane (a channel may expose several — gravity x/y/z, SpO₂ red/IR).
struct ScopeTrace: Identifiable {
    let id: String
    /// Sub-label ("" for a single-trace lane; "x"/"y"/"z", "red"/"IR" otherwise).
    let label: String
    let samples: [SignalLabMath.ScopeSample]
    let discrete: Bool
}

/// The raw samples loaded for the HISTORY scope, kept in their NATIVE stored form so the
/// [Physical | Raw] toggle re-renders without a re-read. Timestamps are unix seconds (Double).
struct ScopeHistory: Equatable {
    var hr: [SignalLabMath.ScopeSample] = []      // bpm (raw sample or bucket-mean)
    var rr: [SignalLabMath.ScopeSample] = []      // ms
    var gravity: [GravitySample] = []             // g (x, y, z)
    var skinTemp: [SkinTempSample] = []           // raw ADC register
    var spo2: [SpO2Sample] = []                   // red / IR ADC
    var resp: [RespSample] = []                   // raw optical mode register (NOT respiration)
    var steps: [SignalLabMath.ScopeSample] = []   // cumulative counter
    var sleepState: [SleepStateSample] = []       // 0 wake / 1 still / 2 asleep / 3 up
    /// Family that resolves the physical skin-temp scale (paired model; #938 family-aware).
    var family: DeviceFamily = .whoop5
    /// The window actually read (unix seconds), so the view knows how far the loaded data extends.
    var loadedStart: Double = 0
    var loadedEnd: Double = 0

    var isEmpty: Bool {
        hr.isEmpty && rr.isEmpty && gravity.isEmpty && skinTemp.isEmpty
            && spo2.isEmpty && resp.isEmpty && steps.isEmpty && sleepState.isEmpty
    }

    /// True when this channel has at least one loaded sample.
    func hasData(_ channel: ScopeChannel) -> Bool {
        switch channel {
        case .hr:         return !hr.isEmpty
        case .rr:         return !rr.isEmpty
        case .gravity:    return !gravity.isEmpty
        case .skinTemp:   return !skinTemp.isEmpty
        case .spo2:       return !spo2.isEmpty
        case .resp:       return !resp.isEmpty
        case .steps:      return !steps.isEmpty
        case .sleepState: return !sleepState.isEmpty
        }
    }

    /// The full time extent of everything loaded, for the initial visible window + zoom clamps.
    var timeBounds: ClosedRange<Double>? {
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        func note(_ ss: [SignalLabMath.ScopeSample]) { for s in ss { lo = min(lo, s.t); hi = max(hi, s.t) } }
        note(hr); note(rr); note(steps)
        for s in gravity { lo = min(lo, Double(s.ts)); hi = max(hi, Double(s.ts)) }
        for s in skinTemp { lo = min(lo, Double(s.ts)); hi = max(hi, Double(s.ts)) }
        for s in spo2 { lo = min(lo, Double(s.ts)); hi = max(hi, Double(s.ts)) }
        for s in resp { lo = min(lo, Double(s.ts)); hi = max(hi, Double(s.ts)) }
        for s in sleepState { lo = min(lo, Double(s.ts)); hi = max(hi, Double(s.ts)) }
        guard hi > lo else { return nil }
        return lo...hi
    }

    /// The drawable traces for a channel in the chosen unit. `gravityMagnitude` collapses gravity to a
    /// single |x,y,z| line instead of the three axis lines. `imperial` converts the PHYSICAL skin-temp
    /// trace °C→°F (absolute, ×9/5+32) to match the Units pref — raw ADC mode is untouched.
    func traces(for channel: ScopeChannel, unit: SignalLabMath.ScopeUnit,
                gravityMagnitude: Bool, imperial: Bool) -> [ScopeTrace] {
        switch channel {
        case .hr:
            return [ScopeTrace(id: "hr", label: "", samples: hr, discrete: false)]
        case .rr:
            return [ScopeTrace(id: "rr", label: "", samples: rr, discrete: false)]
        case .steps:
            return [ScopeTrace(id: "steps", label: "", samples: steps, discrete: false)]
        case .skinTemp:
            let s = skinTemp.map { sample -> SignalLabMath.ScopeSample in
                let base = SignalLabMath.skinTempValue(raw: sample.raw, family: family, unit: unit)
                // Physical mode is °C → convert to °F when imperial; raw ADC is a register value, not a
                // temperature, so it's never converted.
                let v = unit == .raw ? base : TempUnit.absolute(base, imperial: imperial)
                return SignalLabMath.ScopeSample(t: Double(sample.ts), v: v)
            }
            return [ScopeTrace(id: "skin", label: "", samples: s, discrete: false)]
        case .resp:
            let s = resp.map { SignalLabMath.ScopeSample(t: Double($0.ts), v: Double($0.raw)) }
            return [ScopeTrace(id: "resp", label: "", samples: s, discrete: true)]
        case .sleepState:
            let s = sleepState.map { SignalLabMath.ScopeSample(t: Double($0.ts), v: Double($0.state)) }
            return [ScopeTrace(id: "sleep", label: "", samples: s, discrete: true)]
        case .spo2:
            let red = spo2.map { SignalLabMath.ScopeSample(t: Double($0.ts), v: Double($0.red)) }
            let ir = spo2.map { SignalLabMath.ScopeSample(t: Double($0.ts), v: Double($0.ir)) }
            return [ScopeTrace(id: "spo2-red", label: "red", samples: red, discrete: false),
                    ScopeTrace(id: "spo2-ir", label: "IR", samples: ir, discrete: false)]
        case .gravity:
            if gravityMagnitude {
                let m = gravity.map {
                    SignalLabMath.ScopeSample(t: Double($0.ts),
                                              v: SignalLabMath.gravityMagnitude(x: $0.x, y: $0.y, z: $0.z, unit: unit))
                }
                return [ScopeTrace(id: "grav-mag", label: "|g|", samples: m, discrete: false)]
            }
            func axis(_ id: String, _ label: String, _ pick: (GravitySample) -> Double) -> ScopeTrace {
                ScopeTrace(id: id, label: label,
                           samples: gravity.map { SignalLabMath.ScopeSample(t: Double($0.ts),
                                                                            v: SignalLabMath.gravityValue(g: pick($0), unit: unit)) },
                           discrete: false)
            }
            return [axis("grav-x", "x", { $0.x }), axis("grav-y", "y", { $0.y }), axis("grav-z", "z", { $0.z })]
        }
    }
}

// MARK: - Synthetic data (previews / no-store)

extension ScopeHistory {
    /// A deterministic synthetic night of every channel, so the HISTORY scope is fully previewable with
    /// NO Repository or BLE. `end` defaults to a fixed instant so previews are stable.
    static func synthetic(end: Double = 1_760_000_000, hours: Double = 6) -> ScopeHistory {
        let start = end - hours * 3600
        var h = ScopeHistory()
        h.family = .whoop5
        h.loadedStart = start
        h.loadedEnd = end

        // ~1 sample / 10 s keeps the preview light while still reading as a continuous trace.
        let step = 10.0
        var t = start
        var i = 0
        var stepCounter = 12_000
        while t <= end {
            let phase = (t - start) / 3600.0                      // hours into the window
            let bpm = 58.0 + 10 * sin(phase * 1.3) + 4 * sin(phase * 7)
            h.hr.append(.init(t: t, v: bpm.rounded()))
            h.rr.append(.init(t: t, v: (60_000.0 / bpm).rounded()))
            let gx = 0.05 * sin(phase * 5)
            let gy = 0.9 + 0.08 * sin(phase * 2.1)
            let gz = 0.1 * cos(phase * 3.3)
            h.gravity.append(GravitySample(ts: Int(t), x: gx, y: gy, z: gz))
            h.skinTemp.append(SkinTempSample(ts: Int(t), raw: Int((3300 + 120 * sin(phase * 0.8)).rounded())))
            h.spo2.append(SpO2Sample(ts: Int(t), red: Int((41_000 + 900 * sin(phase * 4)).rounded()),
                                     ir: Int((52_000 + 1_100 * cos(phase * 3.5)).rounded())))
            // The mode register as the strap actually emits it: 3073 (0x0C01) with a ~29 s excursion to
            // 2817 (0x0B01) roughly every 19 min. The old sinusoid drew a breathing waveform this channel
            // has never carried, which is exactly the misreading the relabel above exists to stop.
            h.resp.append(RespSample(ts: Int(t), raw: (t - start).truncatingRemainder(dividingBy: 1_155) < 29 ? 2_817 : 3_073))
            if i % 6 == 0 { stepCounter += phase > 5 ? 3 : 1 }   // deterministic monotonic counter
            h.steps.append(.init(t: t, v: Double(stepCounter)))
            let state = phase < 0.4 ? 0 : (phase > 5.6 ? 3 : (Int(phase) % 3 == 0 ? 1 : 2))
            h.sleepState.append(SleepStateSample(ts: Int(t), state: state))
            t += step
            i += 1
        }
        return h
    }
}
