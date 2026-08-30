import Foundation
import StrapProtocol
import StrapStore

/// What this clock hour usually looks like for you — the band drawn behind the response tape's heart
/// rate lane (024 decisions 8 and 9).
///
/// **IT IS NOT A CONTROL GROUP, AND THAT IS THE WHOLE DESIGN.**
///
/// The intuitive version of this feature is "evenings you did NOT eat late", which would make the
/// tape a treatment-vs-control comparison. That version is unbuildable honestly here, because not
/// logging is not the same as not eating. Early on, the "control" evenings are overwhelmingly
/// evenings the user ate and forgot to log — so the band drifts toward the treatment and the feature
/// systematically UNDERSTATES every response, while looking rigorous doing it.
///
/// So the counterfactual is removed rather than approximated. This band is the distribution of the
/// same clock window across recent days, **regardless of what was logged**. It makes one claim:
/// "this is what 19:40–22:40 usually looks like for you." Nothing about causes, nothing about
/// whether those days were different from this one.
///
/// The gate follows from that. Because the claim rests on SENSOR COVERAGE rather than on user
/// diligence, the floor is days-with-data — something the app measures — and never days-logged,
/// which it cannot verify. A user who has never logged anything still gets a truthful band.
///
/// HR ONLY. Skin temp would need the same treatment per family and moves far less across a window;
/// HRV is far too sparse to have a stable per-minute distribution (see `IntakeTape.hrv` — ~27% of
/// minutes clear the RMSSD floor, so most minutes would have a handful of days behind them and the
/// band would be noise wearing a band's clothes).
struct IntakeTypicalBand: Equatable, Sendable {

    /// One minute of the window, described across days.
    struct Point: Equatable, Sendable {
        /// Minutes from the event, matching `IntakeTape.Point.minute`.
        let minute: Int
        /// 25th percentile across days.
        let lo: Double
        /// Median across days.
        let mid: Double
        /// 75th percentile across days.
        let hi: Double
        /// How many days contributed a value to THIS minute. Minutes differ — a strap that came off
        /// at 21:00 on three days leaves those minutes thinner than the ones before.
        let days: Int
    }

    let points: [Point]
    /// Days that cleared `minDayCoverage` over the window and so contributed at all.
    let coveredDays: Int

    /// How many covered days the band needs before it is shown at all.
    ///
    /// Five, matching the `n >= 5` floor the shared journal-insights family already gates its groups
    /// at (`BehaviorInsights.minGroupForSignificance`). Reusing that number rather than inventing a
    /// second one keeps "enough days to say something" meaning one thing in this app — even though
    /// this band makes a far weaker claim than those tests do.
    static let minCoveredDays = 5

    /// Trailing days considered. Bounded by `SampleRetention.retentionDays` in practice: past the
    /// horizon there are no raw samples to read, so asking for more would silently return fewer.
    static let lookbackDays = 14

    /// Fraction of the window's minutes a day must carry before it counts as covered. A day the
    /// strap was on for ten minutes should not get a vote on what the hour usually looks like.
    static let minDayCoverage = 0.6

    /// Whether there is enough to draw. Below the floor the screen shows NOTHING rather than a thin
    /// band with a caveat — a two-day band is a line through two points, and a caveat under it does
    /// not stop it reading as "typical".
    var isShowable: Bool { coveredDays >= Self.minCoveredDays && !points.isEmpty }
}

// MARK: - Pure assembly

enum IntakeTypicalBandBuilder {

    /// Build the band from per-day, per-minute values already aligned to the event's minute grid.
    ///
    /// - Parameter days: one entry per past day, each mapping window-relative minute → value for
    ///   that day at the same clock time. Days that fail the coverage floor must be filtered by the
    ///   caller (`load` does it) so this stays a pure percentile reduction.
    /// - Parameter minutes: the minutes the tape actually drew, so the band spans exactly the lane it
    ///   sits behind and no further.
    static func build(days: [[Int: Double]], minutes: [Int]) -> IntakeTypicalBand {
        var points: [IntakeTypicalBand.Point] = []
        for m in minutes.sorted() {
            let values = days.compactMap { $0[m] }.sorted()
            // A minute needs a majority of the contributing days behind it, or its percentiles are
            // describing two evenings and calling it typical.
            guard values.count >= max(3, days.count / 2) else { continue }
            points.append(.init(minute: m,
                                lo: percentile(values, 0.25),
                                mid: percentile(values, 0.50),
                                hi: percentile(values, 0.75),
                                days: values.count))
        }
        return IntakeTypicalBand(points: points, coveredDays: days.count)
    }

    /// Linear-interpolated percentile over a SORTED array. Interpolated rather than nearest-rank
    /// because at n = 5 the nearest-rank p25 and p50 collapse onto the same element, which would
    /// draw a band with no width on exactly the days it is thinnest.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let pos = p * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        if lo == hi { return sorted[lo] }
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }
}

// MARK: - Loader

/// Reads the trailing days' streams and hands them to the pure reducer above — the same split as
/// `IntakeTapeLoader`: everything that touches the store lives here, everything that decides
/// anything lives in `IntakeTypicalBandBuilder`.
///
/// AND ITS ISOLATION, which this file got only half of. Wave 1 moved `IntakeTapeLoader`'s reduction
/// off the UI actor and left this loader `@MainActor` end to end — which is backwards, because this
/// is the LARGER of the two CPU blocks on the same screen open. The tape buckets ONE window; this
/// buckets FOURTEEN of them at the same clock offsets. An alcohol window runs up to 10.5 h of true
/// 1 Hz heart rate — ~37 800 rows — so a full lookback puts on the order of half a million rows
/// through the `floor((ts - origin) / 60)` loop below, plus fourteen `mapValues` averages over the
/// buckets it fills. All of it ran on the UI actor, in fourteen bursts interleaved with the fourteen
/// reads, while the response screen was trying to draw the very tape this band sits behind.
///
/// `StrapStore` is an actor, so the reads themselves were already suspending off main; main was only
/// ever holding the CPU BETWEEN them, and that is exactly the part that moves here. Split in two
/// rather than made wholly nonisolated for the same reason as the tape: the only genuinely
/// main-actor facts are `Repository`'s own, so `load` resolves those and `band` does the work.
enum IntakeTypicalBandLoader {

    /// Main-actor half: resolve what only exists on the UI actor, then get off it.
    ///
    /// Kept at this signature so the one call site (`IntakeResponseScreen`'s `.task(id:)`) is
    /// unchanged — the isolation move is entirely inside.
    @MainActor
    static func load(event: IntakeEvent, tape: IntakeTape, repo: Repository) async
        -> IntakeTypicalBand? {
        guard let store = await repo.storeHandle() else { return nil }
        // The HR-lane guard that used to open this function now opens `band`, beside the lane it
        // actually reads. Nothing is lost by it no longer short-circuiting ahead of the handle: this
        // loader only ever runs after `IntakeTapeLoader.load` returned a NON-NIL tape, which means
        // that call already cleared `repo.storeHandle()`, so `ensureStore` hands back its cached
        // handle here without opening or resolving anything.
        return await band(event: event, tape: tape, store: store, deviceId: repo.deviceId)
    }

    /// Read the same clock window on each of the trailing days and reduce it to a band —
    /// NONISOLATED, so the fourteen-day bucketing runs on the cooperative pool instead of between
    /// two frames of the response screen.
    ///
    /// Uses the SAME wall-clock offsets as the event, day by day, via calendar arithmetic rather than
    /// 86 400-second steps — the 23- and 25-hour DST days are not 86 400 s, and stepping by seconds
    /// would slide the compared window an hour on either side of a transition.
    ///
    /// - Parameters:
    ///   - tape: the already-built tape whose HR lane fixes the minute grid — the band spans exactly
    ///     the lane it sits behind and no further.
    ///   - store: an open StrapStore (from `Repository.storeHandle()`).
    ///   - deviceId: the strap/import lane the raw HR lives under (`Repository.deviceId`).
    static func band(event: IntakeEvent, tape: IntakeTape, store: StrapStore,
                     deviceId: String) async -> IntakeTypicalBand? {
        guard let hrLane = tape.heartRate, !hrLane.points.isEmpty else { return nil }

        let cal = Calendar.current
        let anchor = Date(timeIntervalSince1970: TimeInterval(event.ts))
        let minutes = hrLane.points.map(\.minute)
        guard let firstMinute = minutes.min(), let lastMinute = minutes.max() else { return nil }
        let expected = Double(lastMinute - firstMinute + 1)

        var perDay: [[Int: Double]] = []
        for back in 1...IntakeTypicalBand.lookbackDays {
            guard let dayAnchor = cal.date(byAdding: .day, value: -back, to: anchor) else { continue }
            let origin = Int(dayAnchor.timeIntervalSince1970)
            let from = origin + firstMinute * 60
            let to = origin + (lastMinute + 1) * 60
            let rows = (try? await store.hrSamples(deviceId: deviceId, from: from, to: to,
                                                   limit: 100_000)) ?? []
            guard !rows.isEmpty else { continue }

            var buckets: [Int: [Double]] = [:]
            for r in rows where r.bpm > 0 {
                buckets[Int(floor(Double(r.ts - origin) / 60.0)), default: []].append(Double(r.bpm))
            }
            // The coverage floor: a day that banked a sliver of the window gets no vote.
            guard Double(buckets.count) / expected >= IntakeTypicalBand.minDayCoverage else { continue }
            perDay.append(buckets.mapValues { $0.reduce(0, +) / Double($0.count) })
        }

        // Named `assembled`, not `band`, purely so it does not shadow this function's own name.
        let assembled = IntakeTypicalBandBuilder.build(days: perDay, minutes: minutes)
        return assembled.isShowable ? assembled : nil
    }
}
