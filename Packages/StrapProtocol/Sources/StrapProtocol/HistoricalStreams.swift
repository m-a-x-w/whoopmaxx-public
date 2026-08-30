import Foundation

/// How far outside the strap's own reported sync range a record may still be believed.
public let SESSION_RANGE_MARGIN = 7 * 86_400

/// Absolute plausibility: after the floor, and not meaningfully in the future.
public func isPlausibleHistoricalUnix(_ ts: Int, wallNow: Int) -> Bool {
    ts >= MIN_PLAUSIBLE_UNIX && ts <= wallNow + FUTURE_MARGIN
}

/// Plausibility, additionally bounded by the range the strap said this sync covers.
///
/// The session bounds are the tighter gate and the more trustworthy one: a strap whose clock is
/// months off still reports a self-consistent oldest/newest pair, so a record far outside it is
/// wrong even when it clears the absolute floor. When the strap gave no range — a replay, an
/// import, a sync with no range handshake — this falls back to the absolute check rather than
/// rejecting everything.
public func isPlausibleHistoricalUnix(_ ts: Int, wallNow: Int,
                                      sessionOldestUnix: Int?, sessionNewestUnix: Int?) -> Bool {
    guard isPlausibleHistoricalUnix(ts, wallNow: wallNow) else { return false }
    guard let oldest = sessionOldestUnix, let newest = sessionNewestUnix,
          oldest >= MIN_PLAUSIBLE_UNIX, newest >= oldest else { return true }
    return ts >= oldest - SESSION_RANGE_MARGIN && ts <= newest + SESSION_RANGE_MARGIN
}

/// Fold decoded historical frames into per-lane streams, correcting the strap's clock as it goes.
///
/// A strap that has sat unused runs a stale RTC, so its records are self-consistent but dated
/// months behind. `deviceClockRef`/`wallClockRef` are a matched pair captured this session; the
/// difference between them is the offset to apply.
///
/// The offset is SNAPPED to five minutes before use. An unsnapped offset carries the sampling
/// jitter of whenever the reference pair happened to be taken, which would make the same record
/// land on a different second depending on when it was synced — and the day boundary it falls on
/// is what every downstream nightly metric is keyed by.
public func extractHistoricalStreams(_ parsed: [ParsedFrame],
                                     deviceClockRef: Int, wallClockRef: Int,
                                     sessionOldestUnix: Int? = nil,
                                     sessionNewestUnix: Int? = nil) -> Streams {
    let staleThreshold = 86_400          // beyond a day of skew, the strap's clock is not usable as-is
    let snapGranularity = 300
    let clockOffset = wallClockRef - deviceClockRef
    let wallNow = max(wallClockRef, Int(Date().timeIntervalSince1970))

    var droppedImplausible = 0
    var out = Streams()
    var ppgRecords: [(ts: Int, samples: [Int])] = []

    /// Device time to wall time, for lanes that carry a device-relative stamp.
    func wall(_ deviceTs: Int?) -> Int? {
        guard let d = deviceTs else { return nil }
        return wallClockRef + (d - deviceClockRef)
    }

    /// A record's OWN real-unix stamp, corrected only if the strap's clock is badly off.
    func correctedWall(_ rawTs: Int) -> Int? {
        let candidate: Int
        if abs(clockOffset) <= staleThreshold {
            candidate = rawTs                        // clock is close enough; do not touch the stamp
        } else {
            let snapped = (clockOffset >= 0
                ? (clockOffset + snapGranularity / 2)
                : (clockOffset - snapGranularity / 2)) / snapGranularity * snapGranularity
            let corrected = rawTs + snapped
            // Correcting a record INTO the future means the offset was not what was wrong. Keep
            // the raw stamp and let the plausibility gate rule on it.
            candidate = corrected <= wallClockRef + snapGranularity ? corrected : rawTs
        }
        guard isPlausibleHistoricalUnix(candidate, wallNow: wallNow,
                                        sessionOldestUnix: sessionOldestUnix,
                                        sessionNewestUnix: sessionNewestUnix) else {
            droppedImplausible += 1
            return nil
        }
        return candidate
    }

    func appendBattery(ts: Int, _ p: [String: ParsedValue]) {
        // `battery_pct` is what the decoder emits and what the live router reads; the soc/mv
        // spellings are kept so an older archived frame still maps.
        let soc = p["battery_pct"]?.doubleValue ?? p["battery_soc"]?.doubleValue ?? p["soc"]?.doubleValue
        let mv = p["battery_mv"]?.intValue ?? p["mv"]?.intValue
        guard soc != nil || mv != nil else { return }
        out.battery.append(BatterySample(ts: ts, soc: soc, mv: mv, charging: p["charging"]?.boolValue))
    }

    for r in parsed {
        // A frame that failed its CRC never drives state. A frame that is intact but unrecognised
        // is skipped here too, but the caller keeps its bytes — that is the re-decode path.
        if !r.ok || r.crcOK == false { continue }
        let p = r.parsed

        switch r.typeName {
        case "HISTORICAL_DATA":
            guard let rawTs = p["unix"]?.intValue, let ts = correctedWall(rawTs) else { continue }
            if let samples = p["ppg_waveform"]?.intArrayValue, !samples.isEmpty {
                ppgRecords.append((ts: ts, samples: samples))
            }
            // hr == 0 is the strap's startup reading, not a measurement of a stopped heart.
            if let bpm = p["heart_rate"]?.intValue, bpm != 0 {
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            if let rrs = p["rr_intervals"]?.intArrayValue {
                out.rr.append(contentsOf: rrs.map { RRInterval(ts: ts, rrMs: $0) })
            }
            if let red = p["spo2_red"]?.intValue {
                out.spo2.append(SpO2Sample(ts: ts, red: red, ir: p["spo2_ir"]?.intValue ?? 0))
            }
            if let raw = p["skin_temp_raw"]?.intValue {
                out.skinTemp.append(SkinTempSample(ts: ts, raw: raw))
            }
            if let c = p["step_motion_counter"]?.intValue {
                out.steps.append(StepSample(ts: ts, counter: c,
                                            activityClass: p["activity_class"]?.intValue))
            }
            if let st = p["sleep_state"]?.intValue {
                out.sleepState.append(SleepStateSample(ts: ts, state: st))
            }
            if let raw = p["resp_rate_raw"]?.intValue {
                out.resp.append(RespSample(ts: ts, raw: raw))
            }
            if let gx = p["gravity_x"]?.doubleValue {
                out.gravity.append(GravitySample(ts: ts, x: gx,
                                                 y: p["gravity_y"]?.doubleValue ?? 0,
                                                 z: p["gravity_z"]?.doubleValue ?? 0))
            }

        case "REALTIME_RAW_DATA":
            // This lane carries a DEVICE-relative stamp, so it goes through `wall`, not the
            // record-own-clock correction.
            var rtTs: Int?
            if let w = wall(p["timestamp"]?.intValue) {
                if isPlausibleHistoricalUnix(w, wallNow: wallNow,
                                             sessionOldestUnix: sessionOldestUnix,
                                             sessionNewestUnix: sessionNewestUnix) { rtTs = w }
                else { droppedImplausible += 1 }
            }
            if let ts = rtTs {
                // Same zero rule as every other lane: 0 is the strap's startup reading, not a
                // measurement of a stopped heart.
                if let bpm = p["heart_rate"]?.intValue, bpm != 0 {
                    out.hr.append(HRSample(ts: ts, bpm: bpm))
                }
                if let rrs = p["rr_intervals"]?.intArrayValue {
                    out.rr.append(contentsOf: rrs.map { RRInterval(ts: ts, rrMs: $0) })
                }
            }

        case "EVENT":
            guard let rawTs = p["event_timestamp"]?.intValue, let ts = correctedWall(rawTs) else { continue }
            let kind = p["event"]?.stringValue ?? ""
            if kind.hasPrefix("BATTERY_LEVEL") { appendBattery(ts: ts, p) }
            var payload = p
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "event_timestamp")
            out.events.append(WhoopEvent(ts: ts, kind: kind, payload: payload))

        case "COMMAND_RESPONSE":
            // A command response has no timestamp of its own; it happened now.
            appendBattery(ts: wallClockRef, p)

        default:
            continue
        }
    }

    out.ppgHr = PpgHr.derivePpgHr(records: ppgRecords)
    out.droppedImplausible = droppedImplausible
    return out
}

/// Fold live frames into streams. Realtime packets carry a device-relative stamp, so both
/// references are needed even though nothing here is historical.
public func extractStreams(_ parsed: [ParsedFrame],
                           deviceClockRef: Int, wallClockRef: Int) -> Streams {
    var out = Streams()
    for r in parsed {
        guard r.ok, r.crcOK != false else { continue }
        let p = r.parsed
        guard let raw = p["unix"]?.intValue ?? p["timestamp"]?.intValue else { continue }
        let ts = wallClockRef + (raw - deviceClockRef)
        // Gate the RESULT, not just the inputs. This is the live lane's counterpart to the check
        // the historical extractor already runs, and it was missing entirely: a frame whose stamp
        // is not on the basis this arithmetic assumes yields an arbitrary date that was then
        // persisted unquestioned. A real backup carried a 39-second burst of genuine beats written
        // 56 years into the future, which is invisible in a chart but silently becomes MAX(ts) —
        // the value the UI calls the newest reading.
        guard isPlausibleHistoricalUnix(ts, wallNow: max(wallClockRef, Int(Date().timeIntervalSince1970)))
        else { continue }
        if let bpm = p["heart_rate"]?.intValue, bpm != 0 {
            out.hr.append(HRSample(ts: ts, bpm: bpm))
        }
        if let rrs = p["rr_intervals"]?.intArrayValue {
            out.rr.append(contentsOf: rrs.map { RRInterval(ts: ts, rrMs: $0) })
        }
        if let gx = p["gravity_x"]?.doubleValue {
            out.gravity.append(GravitySample(ts: ts, x: gx,
                                             y: p["gravity_y"]?.doubleValue ?? 0,
                                             z: p["gravity_z"]?.doubleValue ?? 0))
        }
    }
    return out
}
