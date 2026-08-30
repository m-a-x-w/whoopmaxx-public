import Foundation
import StrapProtocol
import StrapStore
import StrapAnalytics

/// The measured signal around one logged intake event (024 P3) — HR and skin temp per minute over
/// the event's window, the stretches where the wrist was MOVING, and a pre-event reference for each
/// lane.
///
/// WHAT THIS IS NOT: a model of digestion. Nothing here decides that a rise was caused by the meal.
/// The tape draws what the strap banked and marks the one confound it can see, which is movement —
/// the user reads the rest. That is the whole claim (024 decision 1), and it is why there is no
/// "effect", no p-value and no verdict anywhere in this type.
///
/// MOTION IS A MARK, NOT A LANE. An earlier shape drew smoothed wrist motion as a fourth numeric
/// series, which would have put TWO notions of movement on one screen: the drawn curve, and the
/// threshold the summary numbers are gated on. Instead the stillness gate itself is what renders —
/// moving stretches are marked behind the lanes — so the thing you see and the thing the numbers
/// exclude are the same thing.
struct IntakeTape: Equatable, Sendable {

    /// One drawn signal.
    struct Lane: Equatable, Sendable {
        /// Per-minute values, ascending by `minute`, gaps simply absent (never interpolated: a
        /// missing minute is a minute the strap did not bank, and joining across it would draw a
        /// line nothing measured).
        let points: [Point]
        /// The pre-event reference: the MEDIAN of this lane over the still minutes of the 30 minutes
        /// before the event. Nil when that window held no still minutes — in which case the lane
        /// draws, and simply has no line to compare against. Never substituted with the window's own
        /// mean, which would compare the response to itself.
        let reference: Double?
        /// Decimal places this lane's numbers are printed to.
        let precision: Int
        /// Unit suffix for the summary line ("bpm", "°C").
        let unit: String
    }

    /// One minute of one lane.
    struct Point: Equatable, Sendable {
        /// Minutes from the event. Negative inside the pre-event reference window.
        let minute: Int
        let value: Double
        /// Whether this minute fell outside a sedentary bout — i.e. the wrist was moving at
        /// walking level. Summary numbers exclude these; the tape still draws them.
        let moving: Bool
    }

    /// Seconds of signal read before the event, for the reference line.
    static let preRollSeconds = 30 * 60

    let eventTs: Int
    let windowStart: Int
    let windowEnd: Int
    /// True when the window's end was set by falling asleep rather than by the kind's own span —
    /// alcohol only. Drives the hand-off line to that night's Rest.
    let endedAtSleepOnset: Bool
    let heartRate: Lane?
    let skinTemp: Lane?
    /// Rolling RMSSD, or nil when the window banked no usable beat-to-beat.
    ///
    /// THE SPARSE LANE, deliberately. Measured over the kept corpus: R-R covers ~48% of a dinner
    /// window and only ~27% of its minutes clear a 60 s RMSSD floor, against ~97% for HR and skin
    /// temp — the strap only produces clean beat-to-beat when the wrist is quiet. So this lane draws
    /// with real holes, and that is honest rather than broken: 97.8% of the RR-sufficient minutes are
    /// already still, so where HRV is missing the motion marks underneath usually say why.
    let hrv: Lane?
    /// Stretches (unix seconds) inside the window where the wrist was moving. Complement of the
    /// sedentary bouts `SedentaryDetector` finds, so the mark and the gate cannot disagree.
    let movingSpans: [ClosedRange<Int>]
    /// Still minutes in the POST-event part of the window — the n every summary number is computed
    /// over, and the n the screen discloses. Never hidden.
    let stillMinutes: Int

    /// No lane read anything. Distinct from a lane of zeroes, and the reason `IntakeResponseContent`
    /// can tell "nothing was banked" from "nothing happened".
    var isEmpty: Bool { heartRate == nil && skinTemp == nil && hrv == nil }

    static let empty = IntakeTape(eventTs: 0, windowStart: 0, windowEnd: 0, endedAtSleepOnset: false,
                                  heartRate: nil, skinTemp: nil, hrv: nil,
                                  movingSpans: [], stillMinutes: 0)
}

// MARK: - Summary

extension IntakeTape.Lane {

    /// The largest departure from `reference`, computed over STILL, POST-event minutes only, with
    /// the minute it landed on. Nil when there is no reference, or when no still post-event minute
    /// was banked — absence, never a zero standing in for "no change".
    ///
    /// Signed, and the extreme is by ABSOLUTE distance: a meal raises HR and a cold drink can lower
    /// skin temp, and reporting only the maximum would silently drop half the answers.
    ///
    /// TIES GO TO THE EARLIEST MINUTE, and this is not incidental. HR is stored as whole bpm, so the
    /// top of a broad post-prandial arc is a PLATEAU several minutes wide, not a point — a 3-hour
    /// window routinely has a dozen minutes sharing the maximum. The screen prints this minute as
    /// "at +N min", i.e. how long the rise took to arrive, and the honest answer to that is when the
    /// value was FIRST reached, not the last minute it happened to still hold.
    var peak: (delta: Double, minute: Int)? {
        guard let reference else { return nil }
        var best: IntakeTape.Point?
        // Ascending by minute (the builder's order), and replaced only on a STRICTLY larger
        // departure — so the first minute of a plateau is the one that survives.
        for p in points where !p.moving && p.minute >= 0 {
            if let current = best, abs(p.value - reference) <= abs(current.value - reference) { continue }
            best = p
        }
        guard let best else { return nil }
        return (delta: best.value - reference, minute: best.minute)
    }
}

// MARK: - Pure assembly

/// Builds a tape from already-read samples. Pure and store-free so the window arithmetic, the
/// stillness gate and the reference can be tested without a database or a clock.
enum IntakeTapeBuilder {

    /// Trailing window each rolling RMSSD point is computed over. 60 s is the span the corpus
    /// coverage figures in `IntakeTape.hrv`'s doc were measured at, so the lane's density on screen
    /// is the density that was measured rather than a different one.
    static let hrvWindowSeconds = 60
    /// Clean intervals a window must keep to emit a point — the corpus-measured floor (~30 R-R per
    /// minute is the median dinner-window density), NOT `rollingRmssd`'s small default of 8. A rMSSD
    /// from eight beats is arithmetic, not a measurement of that minute.
    static let hrvMinBeatsPerWindow = 30

    /// The window `event` should be drawn over, or nil when the kind draws none (water).
    ///
    /// - `sleepOnset` is the start of the first sleep session beginning after the event, when one is
    ///   known. It ENDS an alcohol window: past it the signal is a sleeping body's, which the Rest
    ///   screen already renders properly, and mixing the two into one lane would draw a step that is
    ///   an artefact of falling asleep rather than of the drink.
    ///
    /// Deliberately not floored to a minimum length. A drink ten minutes before bed genuinely has a
    /// ten-minute awake response; stretching the window past sleep onset to make the tape look
    /// substantial would be padding it with a different measurement.
    static func window(for event: IntakeEvent, sleepOnset: Int?)
        -> (start: Int, end: Int, endedAtSleepOnset: Bool)? {
        guard let kind = event.kind else { return nil }
        let start = event.ts - IntakeTape.preRollSeconds
        switch kind.window {
        case .none:
            return nil
        case .fixed(let seconds):
            return (start: start, end: event.ts + seconds, endedAtSleepOnset: false)
        case .toSleepOnset(let cap):
            let capped = event.ts + cap
            // Onsets before the drink are not this drink's night; clamping to `event.ts` keeps the
            // window non-negative without pretending the sleep ended it.
            guard let onset = sleepOnset, onset > event.ts, onset < capped else {
                return (start: start, end: capped, endedAtSleepOnset: false)
            }
            return (start: start, end: onset, endedAtSleepOnset: true)
        }
    }

    /// Assemble the tape.
    ///
    /// - Parameters:
    ///   - gravity: the window's gravity samples. Stillness comes from
    ///     `SedentaryDetector.detectSedentaryBouts` with `minMinutes: 0` — the SHIPPED smoothing and
    ///     the SHIPPED 0.15 g threshold, with only the bout-length floor removed, because a bout
    ///     here is not a "you have been sitting too long" verdict but a per-minute question. Rolling
    ///     our own smoothing would put a second notion of "moving" in the app.
    ///   - rr: the window's R-R intervals, fed to `HRVAnalyzer.rollingRmssd` — the SHIPPED cleaning
    ///     pipeline (range + Malik ectopic rejection, splice-safe ΔNN), so the intraday lane and the
    ///     nightly number are the same measurement at different spans. Rolling our own would put a
    ///     second definition of RMSSD in the app, which is the mistake `SpotHrvReading` documents.
    ///   - sleepOnset: see `window(for:sleepOnset:)`.
    static func build(event: IntakeEvent,
                      hr: [HRSample],
                      skinTemp: [SkinTempSample],
                      rr: [RRInterval],
                      gravity: [GravitySample],
                      family: DeviceFamily,
                      sleepOnset: Int?) -> IntakeTape? {
        guard let w = window(for: event, sleepOnset: sleepOnset) else { return nil }

        let bouts = SedentaryDetector.detectSedentaryBouts(gravity, minMinutes: 0)
        let moving = movingSpans(bouts: bouts, from: w.start, to: w.end)

        // Per-minute reduction. HR takes the MEDIAN of the minute (a 1 Hz stream with the odd
        // artefact beat), skin temp the MEAN (a slow signal with no comparable spikes).
        let hrPoints = perMinute(event: event, window: w, moving: moving,
                                 samples: hr.map { (ts: $0.ts, value: Double($0.bpm)) },
                                 reduce: median)
        let skinPoints = perMinute(event: event, window: w, moving: moving,
                                   samples: skinTemp.map {
                                       (ts: $0.ts, value: skinTempCelsius(raw: $0.raw, family: family))
                                   },
                                   reduce: mean)

        // HRV: the shipped rolling analyzer does the cleaning and the splice-safe ΔNN; all this adds
        // is the per-minute grid the other lanes live on. Its points are already one-per-minute (the
        // `stepSec` stride), so the bucket reduce is a formality — `median` of a single value —
        // rather than a second averaging of an already-windowed statistic.
        let hrvRaw = HRVAnalyzer.rollingRmssd(rr: rr.filter { $0.ts >= w.start && $0.ts <= w.end },
                                              windowSec: hrvWindowSeconds,
                                              stepSec: 60,
                                              minBeatsPerWindow: hrvMinBeatsPerWindow)
        let hrvPoints = perMinute(event: event, window: w, moving: moving,
                                  samples: hrvRaw.map { (ts: $0.ts, value: $0.rmssd) },
                                  reduce: median)

        let hrLane = hrPoints.isEmpty ? nil
            : IntakeTape.Lane(points: hrPoints, reference: reference(hrPoints), precision: 0, unit: "bpm")
        let skinLane = skinPoints.isEmpty ? nil
            : IntakeTape.Lane(points: skinPoints, reference: reference(skinPoints), precision: 1, unit: "°C")
        let hrvLane = hrvPoints.isEmpty ? nil
            : IntakeTape.Lane(points: hrvPoints, reference: reference(hrvPoints), precision: 0, unit: "ms")

        // The disclosed n. Counted on the HR lane when there is one — it is the dense lane and the
        // one whose summary a reader weighs — and falls back to skin temp so a 4.0 banking only
        // skin temp still states an honest n rather than 0.
        let post = (hrPoints.isEmpty ? skinPoints : hrPoints).filter { !$0.moving && $0.minute >= 0 }

        return IntakeTape(eventTs: event.ts,
                          windowStart: w.start,
                          windowEnd: w.end,
                          endedAtSleepOnset: w.endedAtSleepOnset,
                          heartRate: hrLane,
                          skinTemp: skinLane,
                          hrv: hrvLane,
                          movingSpans: moving,
                          stillMinutes: post.count)
    }

    // MARK: Pieces

    /// The complement of the sedentary bouts across `[from, to]` — the stretches the wrist was
    /// moving. A window with NO gravity at all yields no moving spans rather than one covering
    /// everything: absence of the motion stream is not evidence of motion, and marking the whole
    /// tape as moving would suppress every summary number on a technicality.
    static func movingSpans(bouts: [SedentaryDetector.InactivityPeriod], from: Int, to: Int) -> [ClosedRange<Int>] {
        guard !bouts.isEmpty, from <= to else { return [] }
        let still = bouts
            .map { (max($0.start, from), min($0.end, to)) }
            .filter { $0.0 <= $0.1 }
            .sorted { $0.0 < $1.0 }
        guard !still.isEmpty else { return [] }
        var out: [ClosedRange<Int>] = []
        var cursor = from
        for (s, e) in still {
            if s > cursor { out.append(cursor...(s - 1)) }
            cursor = max(cursor, e + 1)
        }
        if cursor <= to { out.append(cursor...to) }
        return out
    }

    /// Whether `ts` lands inside one of the moving stretches. BINARY SEARCH, deliberately, not a scan.
    ///
    /// WHAT WAS WRONG. This used to be a closure — `moving.contains { $0.contains(ts) }` — evaluated
    /// once per admitted sample in every lane. The span list it walks is unbounded by any bout-length
    /// floor: `build` calls `detectSedentaryBouts` with `minMinutes: 0` on purpose (see its doc), so a
    /// restless evening emits hundreds of spans rather than a handful of long bouts. HR and skin temp
    /// are both true 1 Hz, and an alcohol window runs up to 10.5 h, so one tape put ~37 800 samples ×
    /// hundreds of spans through that closure PER LANE — millions of `ClosedRange.contains` calls —
    /// synchronously, before the response screen could produce its first frame.
    ///
    /// WHY THIS SHAPE. The search rests on an invariant `movingSpans` above provably holds: `cursor`
    /// only ever advances and every appended range ends strictly before the next one begins, so the
    /// output is ASCENDING and DISJOINT. A monotonic cursor threaded through `perMinute`'s loop would
    /// be marginally cheaper still, but it would ALSO require the samples to arrive sorted — and
    /// `build` is a documented pure, store-free entry point that the tests call with hand-built
    /// arrays, so unsorted input would silently misflag minutes rather than fail. Binary search needs
    /// only the spans ordered, which is the builder's own guarantee, and costs nothing per sample
    /// beyond ~log₂(spans) comparisons.
    static func isMoving(_ ts: Int, in spans: [ClosedRange<Int>]) -> Bool {
        var lo = 0
        var hi = spans.count - 1
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            let span = spans[mid]
            if ts < span.lowerBound {
                hi = mid - 1
            } else if ts > span.upperBound {
                lo = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    /// Bucket samples into whole minutes RELATIVE TO THE EVENT, so minute 0 starts at the logged
    /// instant and the pre-roll runs negative. Bucketing on absolute clock minutes instead would put
    /// the event at an arbitrary offset inside its own first bucket.
    private static func perMinute(event: IntakeEvent,
                                  window: (start: Int, end: Int, endedAtSleepOnset: Bool),
                                  moving: [ClosedRange<Int>],
                                  samples: [(ts: Int, value: Double)],
                                  reduce: ([Double]) -> Double) -> [IntakeTape.Point] {
        var buckets: [Int: [Double]] = [:]
        var movingMinutes: Set<Int> = []
        for s in samples where s.ts >= window.start && s.ts <= window.end {
            let minute = Int(floor(Double(s.ts - event.ts) / 60.0))
            buckets[minute, default: []].append(s.value)
            // PER SAMPLE OF THIS LANE, not per span. A minute is moving only when a sample THIS lane
            // actually banked fell inside a moving stretch — deriving the moving minutes from the
            // spans alone would look like the same answer and is not: it would flip minutes a span
            // merely straddles, including minutes this lane read nothing in, and so would change
            // which minutes `peak` and `stillMinutes` exclude.
            if isMoving(s.ts, in: moving) { movingMinutes.insert(minute) }
        }
        return buckets.keys.sorted().map { m in
            IntakeTape.Point(minute: m, value: reduce(buckets[m] ?? []), moving: movingMinutes.contains(m))
        }
    }

    /// The pre-event reference: median over the STILL minutes before the event. Still-only for the
    /// same reason the summary is — a reference taken while walking in from the kitchen would make
    /// every meal look like it lowered your heart rate.
    private static func reference(_ points: [IntakeTape.Point]) -> Double? {
        let pre = points.filter { $0.minute < 0 && !$0.moving }.map(\.value)
        return pre.isEmpty ? nil : median(pre)
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    private static func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }
}

// MARK: - Loader

/// Reads the window's streams and hands them to the pure builder. The `ArousalForensicsLoader`
/// shape: everything that touches the store lives here, everything that decides anything lives in
/// `IntakeTapeBuilder`.
///
/// AND ITS ISOLATION, which this file previously did not copy. `ArousalForensicsLoader.load` is
/// nonisolated and takes the store and the device ids as caller-resolved parameters; the earlier
/// shape here took `Repository` and was `@MainActor` end to end, which put three things on the UI
/// thread that have no business there: the pure reduction in `IntakeTapeBuilder.build`
/// (`detectSedentaryBouts`, `rollingRmssd`, three `perMinute` passes), and — worse — the SYNCHRONOUS
/// `DeviceRegistryStore(...).all()` below, which is real blocking file I/O. `StrapStore` is an actor,
/// so the four stream reads were already suspending off main; the CPU and the file read were not.
/// Split in two rather than made wholly nonisolated: the only genuinely main-actor facts are
/// `Repository`'s published caches, so `load` resolves those and `tape` does the work.
enum IntakeTapeLoader {

    /// Main-actor half: resolve what only exists on the UI actor, then get off it.
    ///
    /// Kept at this signature so the one call site (`IntakeResponseScreen`'s `.task(id:)`) is
    /// unchanged — the isolation move is entirely inside.
    @MainActor
    static func load(event: IntakeEvent, repo: Repository) async -> IntakeTape? {
        guard let kind = event.kind, kind.hasResponseTape, event.tsExact else { return nil }
        // Sleep onset comes from the published cache rather than a fresh read: it is only consulted
        // for alcohol, and the first session STARTING after the drink is what ends that window.
        let onset = repo.sleeps
            .map(\.startTs)
            .filter { $0 > event.ts }
            .min()
        guard let store = await repo.storeHandle() else { return nil }
        // The window guard that used to sit here is not lost, it is one line up: `hasResponseTape` is
        // defined as `window != .none`, so a kind that clears that gate always yields a window, and
        // `tape` re-derives it as its own first statement. One resolution, one place.
        return await tape(event: event, store: store, deviceId: repo.deviceId, sleepOnset: onset)
    }

    /// Everything else — NONISOLATED, so the reduction and the registry read run on the cooperative
    /// pool instead of between two frames of the response screen.
    ///
    /// - Parameters:
    ///   - store: an open StrapStore (from `Repository.storeHandle()`).
    ///   - deviceId: the strap/import lane the raw streams live under (`Repository.deviceId`).
    ///   - sleepOnset: already resolved by the caller from the published sleep cache — see
    ///     `IntakeTapeBuilder.window(for:sleepOnset:)` for what it means and why it only binds alcohol.
    static func tape(event: IntakeEvent, store: StrapStore, deviceId: String,
                     sleepOnset: Int?) async -> IntakeTape? {
        guard let w = IntakeTapeBuilder.window(for: event, sleepOnset: sleepOnset) else { return nil }

        let hr = (try? await store.hrSamples(deviceId: deviceId, from: w.start, to: w.end,
                                             limit: 200_000)) ?? []
        let skin = (try? await store.skinTempSamples(deviceId: deviceId, from: w.start, to: w.end,
                                                     limit: 200_000)) ?? []
        let grav = (try? await store.gravitySamples(deviceId: deviceId, from: w.start, to: w.end,
                                                    limit: 200_000)) ?? []
        let rr = (try? await store.rrIntervals(deviceId: deviceId, from: w.start, to: w.end,
                                               limit: 200_000)) ?? []
        // Family-aware raw→°C, or a 4.0's raw ADC reads ~8 °C low and the lane is nonsense (#938).
        // Same resolver AND the same registry read the scorer uses (`ScoreEngine.swift:367-368`),
        // including its paired-family fallback for a registry row that names no model. Synchronous
        // GRDB — which is exactly why this function is not on the main actor.
        let devices = (try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? []
        let family = ScoreEngine.skinTempFamily(forOwner: deviceId, devices: devices)

        return IntakeTapeBuilder.build(event: event, hr: hr, skinTemp: skin, rr: rr, gravity: grav,
                                       family: family, sleepOnset: sleepOnset)
    }
}

// MARK: - The night an alcohol window hands off to

/// The already-computed figures for the night a drink ran into — Rest's own numbers, read from the
/// caches Rest itself renders, never re-derived here.
///
/// Exists so the response screen can answer the question it raises ("what did this do to the
/// night?") in place. There is no new statistic: `restingHr` and `avgHrv` are the stored session's,
/// and the Rest score is the `sleep_performance` series the dashboard already publishes.
struct IntakeNightSummary: Equatable {
    struct Figure: Equatable { let label: String; let value: String }
    let figures: [Figure]

    /// Build from the published caches, or nil when the night has not been scored — an unscored
    /// night shows the hand-off sentence with no numbers, never a row of dashes standing in for
    /// measurements that do not exist.
    @MainActor
    static func make(afterSleepOnset onsetTs: Int, repo: Repository) -> IntakeNightSummary? {
        guard let session = repo.sleeps.first(where: { $0.startTs == onsetTs }) else { return nil }
        var figures: [Figure] = []
        if let hr = session.restingHr { figures.append(.init(label: "Sleeping HR", value: "\(hr) bpm")) }
        if let hrv = session.avgHrv {
            figures.append(.init(label: "Night HRV", value: "\(Int(hrv.rounded())) ms"))
        }
        let day = DayKey.local(Date(timeIntervalSince1970: TimeInterval(session.endTs)))
        if let rest = repo.restSeries[day] {
            figures.append(.init(label: "Rest", value: "\(Int(rest.rounded()))"))
        }
        return figures.isEmpty ? nil : IntakeNightSummary(figures: figures)
    }
}
