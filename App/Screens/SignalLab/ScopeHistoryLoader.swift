import Foundation
import StrapProtocol
import StrapStore
import StrapAnalytics

/// Every raw-store READ behind Signal Lab, lifted out of the View layer: the HISTORY scope's eight
/// bounded per-channel reads (plus the `async let` fan-out that overlaps them) and the HRV panel's
/// stored R-R fallback window. The views keep only their `@State`, their `.task` and their stale-load
/// guard.
///
/// Lives beside `SignalLabModel.swift`, which already owns the `ScopeHistory` value these produce and
/// the `SignalLabMath` policy that bounds them — a `Core/` home would invert the dependency, since both
/// of those types are declared in `App/`.
///
/// READ-ONLY: every channel comes from an existing StrapStore reader under the RAW strap id
/// (`Repository.deviceId` = "my-whoop"). No schema change, no persistence, no writes. Reads are always
/// BOUNDED — the window→(read strategy, sample budget) decision lives in `SignalLabMath`.
///
/// `nonisolated` throughout, so both the reads AND the sample→ScopeSample maps run on the cooperative
/// pool rather than the main actor: a large window never maps tens of thousands of rows on main.
enum ScopeHistoryLoader {

    // MARK: - HISTORY scope

    /// The HISTORY scope's whole load for `[from, to]`, folded into one `ScopeHistory`. The caller
    /// supplies the window (its gesture/zoom policy) and owns the stale-load guard.
    nonisolated static func load(store: StrapStore, deviceId: String, family: DeviceFamily,
                                 from: Int, to: Int) async -> ScopeHistory {
        let id = deviceId
        let windowSeconds = to - from
        // HR — bucketed when zoomed OUT, raw when zoomed IN (SQL downsample vs raw ~1 Hz).
        let hrStrategy = SignalLabMath.hrRead(windowSeconds: windowSeconds)
        // Bounded per-channel `limit:` by native rate (plain `let`s so the concurrent reads capture no
        // shared closure). rr ~1.2 Hz; gravity/skin/SpO₂/resp ~1 Hz; steps/sleep-state ~0.2 Hz.
        let limRR = SignalLabMath.rawChannelLimit(windowSeconds: windowSeconds, nativeHz: 1.2)
        let lim1Hz = SignalLabMath.rawChannelLimit(windowSeconds: windowSeconds, nativeHz: 1)
        let limSlow = SignalLabMath.rawChannelLimit(windowSeconds: windowSeconds, nativeHz: 0.2)

        // All eight reads run concurrently on the store actor; the sample→ScopeSample maps for the
        // mapped channels (hr/rr/steps) run OFF the main actor in the `read*` helpers below, so a large
        // window never maps tens of thousands of rows on main. Each read stays bounded per `SignalLabMath`.
        // TRUNCATION DIRECTION. The store reads these tables `ORDER BY ts ASC LIMIT ?`, so a binding
        // limit keeps the OLDEST rows — but the scope is pinned to the NEWEST end (`applyPreset` anchors
        // the visible span at `bounds.upperBound`). At the shipped "24h" preset the padded read window is
        // 108,000 s while a 1 Hz channel's cap binds at ~24,000 s, so gravity / skin-temp / SpO₂ / resp
        // returned the far-LEFT ~6h40m of the request and the lanes rendered as ~40 minutes of trace at
        // the edge of a 24-hour view, then nothing — while the bucketed HR lane drew the full day.
        //
        // The correction is A-POSTERIORI, inside each read helper: read the requested window first, and
        // only when the store actually RETURNS `limit` rows did the cap really bind — then re-anchor at
        // `to` using the OBSERVED density. Deciding up front from a nominal rate would be wrong in the
        // lossy direction: `rawChannelLimit` saturates purely as a function of the requested SPAN, so a
        // sparse channel (real R-R runs ~0.5 Hz against its 1.2 Hz nominal, resp far sparser) would be
        // narrowed on the default 6 h open even though the cap never bound, DROPPING rows that used to
        // come back. Sparse channels never come back saturated, so they never retry.
        async let hr = readHR(store, id, from, to, hrStrategy)
        async let rr = readRR(store, id, from, to, limRR)
        async let gravity = readGravity(store, id, from, to, lim1Hz)
        async let skinTemp = readSkinTemp(store, id, from, to, lim1Hz)
        async let spo2 = readSpO2(store, id, from, to, lim1Hz)
        async let resp = readResp(store, id, from, to, lim1Hz)
        async let steps = readSteps(store, id, from, to, limSlow)
        async let sleepState = readSleepState(store, id, from, to, limSlow)

        var h = ScopeHistory()
        h.family = family
        h.loadedStart = Double(from)
        h.loadedEnd = Double(to)
        h.hr = await hr
        h.rr = await rr
        h.gravity = await gravity
        h.skinTemp = await skinTemp
        h.spo2 = await spo2
        h.resp = await resp
        h.steps = await steps
        h.sleepState = await sleepState
        return h
    }

    // MARK: - HRV panel (stored fallback)

    /// The HRV panel's stored source: the most recent `windowSeconds` of banked R-R. The window ENDS at
    /// the newest stored HR sample (else now), so a strap that hasn't synced today still shows its last
    /// real window rather than an empty one anchored on the wall clock — the same anchoring the HISTORY
    /// scope's default window uses. Bounded by the SAME `SignalLabMath` budget the HISTORY rr lane takes
    /// (~1.2 Hz native).
    nonisolated static func loadStoredRR(store: StrapStore, deviceId: String,
                                         windowSeconds: Int) async -> [RRInterval] {
        let latest = (try? await store.latestHRSampleTs(deviceId: deviceId)).flatMap { $0 }
        let to = latest ?? Int(Date().timeIntervalSince1970)
        let from = to - windowSeconds
        let limit = SignalLabMath.rawChannelLimit(windowSeconds: windowSeconds, nativeHz: 1.2)
        return (try? await store.rrIntervals(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    // MARK: - Off-main store reads (bounded)

    // One bounded StrapStore read each, plus the sample→ScopeSample map for the mapped channels.

    /// A narrowed `from` for a channel whose `limit` DEMONSTRABLY bound, or nil to keep what we read.
    ///
    /// The store reads `ORDER BY ts ASC LIMIT ?`, so a binding limit keeps the OLDEST rows — but the
    /// scope is pinned to the NEWEST end, so the lane rendered a stub at the far-left edge and nothing
    /// after. Saturation is judged by the rows actually returned, and the re-anchored span uses the
    /// MEASURED density rather than a nominal constant, so a channel is never narrowed on a guess.
    private static func narrowedFrom<T>(_ from: Int, _ to: Int, _ limit: Int,
                                        _ rows: [T], _ ts: (T) -> Int) -> Int? {
        guard rows.count >= limit,
              let first = rows.first.map(ts), let last = rows.last.map(ts), last > first else { return nil }
        let hz = Double(rows.count) / Double(last - first)
        guard hz > 0 else { return nil }
        let narrowed = Swift.max(from, to - Int(Double(limit) / hz))
        return narrowed > from ? narrowed : nil
    }

    private static func readHR(_ store: StrapStore, _ id: String, _ from: Int, _ to: Int,
                               _ strategy: SignalLabMath.HRRead) async -> [SignalLabMath.ScopeSample] {
        switch strategy {
        case let .raw(limit):
            let hr = (try? await store.hrSamples(deviceId: id, from: from, to: to, limit: limit)) ?? []
            return hr.map { .init(t: Double($0.ts), v: Double($0.bpm)) }
        case let .buckets(seconds, limit):
            let b = (try? await store.hrBuckets(deviceId: id, from: from, to: to, bucketSeconds: seconds)) ?? []
            return SignalLabMath.decimate(b, to: limit).map { .init(t: Double($0.ts), v: $0.bpm) }
        }
    }

    private static func readRR(_ store: StrapStore, _ id: String, _ from: Int, _ to: Int, _ limit: Int) async -> [SignalLabMath.ScopeSample] {
        var rr = (try? await store.rrIntervals(deviceId: id, from: from, to: to, limit: limit)) ?? []
        if let f2 = narrowedFrom(from, to, limit, rr, { $0.ts }) {
            rr = (try? await store.rrIntervals(deviceId: id, from: f2, to: to, limit: limit)) ?? rr
        }
        return rr.map { .init(t: Double($0.ts), v: Double($0.rrMs)) }
    }

    private static func readSteps(_ store: StrapStore, _ id: String, _ from: Int, _ to: Int, _ limit: Int) async -> [SignalLabMath.ScopeSample] {
        let steps = (try? await store.stepSamples(deviceId: id, from: from, to: to, limit: limit)) ?? []
        return steps.map { .init(t: Double($0.ts), v: Double($0.counter)) }
    }

    private static func readGravity(_ store: StrapStore, _ id: String, _ from: Int, _ to: Int, _ limit: Int) async -> [GravitySample] {
        var rows = (try? await store.gravitySamples(deviceId: id, from: from, to: to, limit: limit)) ?? []
        if let f2 = narrowedFrom(from, to, limit, rows, { $0.ts }) {
            rows = (try? await store.gravitySamples(deviceId: id, from: f2, to: to, limit: limit)) ?? rows
        }
        return rows
    }

    private static func readSkinTemp(_ store: StrapStore, _ id: String, _ from: Int, _ to: Int, _ limit: Int) async -> [SkinTempSample] {
        var rows = (try? await store.skinTempSamples(deviceId: id, from: from, to: to, limit: limit)) ?? []
        if let f2 = narrowedFrom(from, to, limit, rows, { $0.ts }) {
            rows = (try? await store.skinTempSamples(deviceId: id, from: f2, to: to, limit: limit)) ?? rows
        }
        return rows
    }

    private static func readSpO2(_ store: StrapStore, _ id: String, _ from: Int, _ to: Int, _ limit: Int) async -> [SpO2Sample] {
        var rows = (try? await store.spo2Samples(deviceId: id, from: from, to: to, limit: limit)) ?? []
        if let f2 = narrowedFrom(from, to, limit, rows, { $0.ts }) {
            rows = (try? await store.spo2Samples(deviceId: id, from: f2, to: to, limit: limit)) ?? rows
        }
        return rows
    }

    private static func readResp(_ store: StrapStore, _ id: String, _ from: Int, _ to: Int, _ limit: Int) async -> [RespSample] {
        var rows = (try? await store.respSamples(deviceId: id, from: from, to: to, limit: limit)) ?? []
        if let f2 = narrowedFrom(from, to, limit, rows, { $0.ts }) {
            rows = (try? await store.respSamples(deviceId: id, from: f2, to: to, limit: limit)) ?? rows
        }
        return rows
    }

    private static func readSleepState(_ store: StrapStore, _ id: String, _ from: Int, _ to: Int, _ limit: Int) async -> [SleepStateSample] {
        var rows = (try? await store.sleepStateSamples(deviceId: id, from: from, to: to, limit: limit)) ?? []
        if let f2 = narrowedFrom(from, to, limit, rows, { $0.ts }) {
            rows = (try? await store.sleepStateSamples(deviceId: id, from: f2, to: to, limit: limit)) ?? rows
        }
        return rows
    }
}
