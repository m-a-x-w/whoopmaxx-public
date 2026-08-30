import Foundation

/// Central smoothing of the live heart rate — the raw per-beat strap value swings with HRV, so every
/// screen shows THIS window median instead of the instantaneous reading.
///
/// Pure state + arithmetic: no Combine, no `ObservableObject`, no BLE, no clock of its own (every entry
/// point takes `now`), so the window bound, the clamp and the #39 blank-on-disconnect rule are unit
/// testable. `AppRoot` owns one, feeds it each coalesced packet's live values, and republishes the
/// result as its `@Published bpm`. (Lifted out of `AppRoot.ingestHR`; ported from the original's ingestHR.)
struct HRSmoother {
    /// The trailing window of ACCEPTED instantaneous samples, oldest → newest.
    private var window: [(t: Date, v: Double)] = []

    /// Longest span the window covers. Older samples are dropped on every accepted ingest.
    private static let windowSeconds: TimeInterval = 10
    /// Hard cap on window size, so a burst of packets can't grow it without bound inside the time window.
    private static let windowCap = 40

    /// Current window depth. The median is deliberately robust, so neither bound is observable through
    /// it — this is how the ~10 s / 40-sample invariants are pinned.
    var sampleCount: Int { window.count }

    /// Fold one packet's live values in and return the CURRENT smoothed value — the window median, or
    /// nil when there is no signal. Prefers the strap's reported HR; falls back to 60000/R-R. Clamps to
    /// a plausible 30–220 range (rejects 0 / garbage spikes).
    ///
    /// A REJECTED sample (out of range with the link still up) leaves the window — and therefore the
    /// returned median — exactly as it was, so the caller's "only republish when the smoothed value
    /// changes" guard naturally publishes nothing.
    mutating func ingest(heartRate: Int?, rr: [Int], now: Date = Date()) -> Int? {
        var inst: Double?
        if let hr = heartRate, hr >= 30, hr <= 220 {
            inst = Double(hr)
        } else if let last = rr.last, last > 0 {
            let v = 60_000.0 / Double(last)
            if v >= 30, v <= 220 { inst = v }
        }
        guard let inst else {
            // #39: when the live source is gone (disconnect blanks heartRate AND rr), drop the stale
            // median so screens showing `bpm` fall through to "—" instead of freezing on the last
            // value. A transient out-of-range sample with the link still up keeps the last median.
            if heartRate == nil && rr.isEmpty { reset() }
            return median(of: window)
        }
        window.append((now, inst))
        window.removeAll { now.timeIntervalSince($0.t) > Self.windowSeconds }   // ~10 s window
        if window.count > Self.windowCap { window.removeFirst(window.count - Self.windowCap) }
        return median(of: window)
    }

    /// Drop the whole window — the deterministic blank used on the disconnect edge (#39/C1) and when a
    /// live screen first arms the realtime stream.
    mutating func reset() { window.removeAll() }

    /// Median over just the trailing `seconds` of the window — the live tab's optional short-smooth
    /// display (the published `bpm` keeps the full window for calmer surfaces).
    func smoothedBpm(over seconds: TimeInterval, now: Date = Date()) -> Int? {
        median(of: window.filter { now.timeIntervalSince($0.t) <= seconds })
    }

    private func median(of samples: [(t: Date, v: Double)]) -> Int? {
        let vals = samples.map(\.v).sorted()
        return vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
    }
}
