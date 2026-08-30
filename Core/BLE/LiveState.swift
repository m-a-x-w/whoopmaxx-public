// Derived from ParthJadhav/noop, PolyForm Noncommercial License 1.0.0, Copyright 2026 NoopApp.
// Required Notice: Copyright 2026 NoopApp (https://github.com/ParthJadhav/noop)
// Terms: https://polyformproject.org/licenses/noncommercial/1.0.0 — see ../../LICENSE.

import Foundation
import Combine
import StrapAnalytics
import StrapProtocol

/// The single observable snapshot of the strap link that every screen binds to.
///
/// Only two writers feed it. `BLEManager` supplies the link and radio facts it learns from
/// CoreBluetooth callbacks; `FrameRouter` supplies the biometric and event facts it decodes out of
/// strap frames. Everything else in the app reads.
///
/// Two rules hold across the whole file:
///
/// 1. `@MainActor`, because SwiftUI observes this object. Every mutator below runs on the main queue.
///    The redaction statics are `nonisolated` so the log path in `BLEManager`, which is not always on
///    the main actor, still compiles against them.
/// 2. No member here may do published work per packet. Frames arrive many times a second, and one
///    `@Published` write per frame re-renders every observer at frame rate. That is why
///    `lastFrameAtUnix` is unpublished and collapses to at most one write per second, why the router
///    writes `lastFrameType` behind its own change guard, and why the log sink never touches disk.
///
/// The division that governs the teardown funnel: a value describing the LINK is cleared when the link
/// drops (`clearBiometrics()`), a value describing the STORE is not, because it stays true while the
/// strap is away.
@MainActor
public final class LiveState: ObservableObject {

    // MARK: - Radio

    /// What the phone's own Bluetooth stack can currently do, as CoreBluetooth reports it. Carries only
    /// the `CBManagerState` cases a user can act on, so no view needs to import CoreBluetooth.
    ///
    /// Held strictly apart from every strap-side fact, because the two point at opposite fixes: a phone
    /// that is refusing us is repaired in Settings, a strap that is not answering is repaired by walking
    /// over to it. Conflate them and the user reliably follows the wrong one. Without this distinction
    /// both `centralManagerDidUpdateState` and the scan entry point simply returned unless the radio was
    /// `.poweredOn`, and the pair sheet sat forever on searching copy that blamed a strap for a radio
    /// fault the app already knew about.
    public enum RadioState: Equatable, Sendable {
        /// Nothing reported yet, or a transient reset. The user cannot tell those apart, so both mean "wait".
        case unknown
        case poweredOn
        /// The radio is switched off. Heals itself the moment the user switches it back on.
        case poweredOff
        /// Bluetooth permission was denied for this app. Never heals itself; only Settings clears it.
        case unauthorized
        /// The device has no BLE radio at all (the Simulator). Nothing to fix.
        case unsupported

        /// Actionable copy for a broken radio, or nil when the radio is fine and whatever the screen is
        /// saying really is about the strap.
        ///
        /// The copy sits beside the state instead of inside the views so there is exactly one mapping to
        /// test and every surface says the same thing about the same state. It must never mention charging
        /// the strap or bringing it closer: that is strap advice bolted onto a phone fault, and it sends a
        /// user who revoked a permission on a lap of the house.
        public var problem: String? {
            switch self {
            case .poweredOn, .unknown: return nil
            case .poweredOff:
                return "Bluetooth is turned off, so no app on this phone can reach the strap. "
                    + "Switch it on in Control Centre or Settings, then scan again."
            case .unauthorized:
                return "whoopmaxx has not been allowed to use Bluetooth, so it cannot scan or connect at "
                    + "all. Open Settings, then whoopmaxx, and switch Bluetooth on."
            case .unsupported:
                return "This device has no Bluetooth LE radio, so a strap cannot be connected to it."
            }
        }
    }

    /// Written only on a real change by the manager: hardware churns `.resetting` against `.poweredOn`,
    /// and each publish re-renders the Live and More screens.
    @Published public var radio: RadioState = .unknown

    // MARK: - Link state

    @Published public var connected: Bool = false

    /// True once the strap answers as a paired peer. Also set by the live-HR shortcut on a 5/MG, where HR
    /// streams over the unbonded standard profile and no encrypted bond was ever formed.
    ///
    /// This must NOT auto-clear `pairingHint`. Clearing it here hides still-accurate free-the-strap
    /// guidance from precisely the users who are streaming HR without a real bond. The genuine bond path
    /// clears the hint itself, and a fresh connect attempt resets it.
    @Published public var bonded: Bool = false

    /// True ONLY when the link reached a genuine encrypted bond: the 5/MG CLIENT_HELLO ack, the WHOOP 4
    /// confirmed-write bond, or a restored already-bonded link. Deliberately not set by the live-HR
    /// shortcut, so `bonded` can be true while this is false ("live HR, not fully paired"). WHOOP 4 always
    /// reaches a real bond, so the two move together there. Reset on connect and on disconnect. Buzz,
    /// alarm, double tap and history offload all need the encrypted channel, so they need this.
    @Published public var encryptedBond: Bool = false

    /// True only while a non-WHOOP source (currently the Oura ring) is streaming live HR. Kept apart from
    /// `bonded`, which carries encrypted-bond meaning and gates haptics: a ring has to be able to read as
    /// streaming without unlocking commands it could never answer. The owning source sets it in its
    /// streaming branch and clears it at every teardown.
    @Published public var streamingLiveHR: Bool = false

    /// Wrist-wear state from the WRIST_ON / WRIST_OFF events. Defaults true so wear-gated features work
    /// before the first event of a session lands; the router flips it on a real transition.
    @Published public var worn: Bool = true

    /// True when a connected 5/MG streams live HR happily but hands over no history at all (consecutive
    /// empty backfills). Lets the home state say "connected, history sync is experimental" instead of a
    /// WHOOP-4-style "not recording" or a sync error. Reset on connect and on disconnect.
    @Published public var historySyncExperimental: Bool = false

    /// Set when a 5/MG refuses the encrypted bond on first connect ("Encryption/Authentication is
    /// insufficient"). CoreBluetooth will not start a fresh just-works bond against a strap still bonded to
    /// the official app, so this carries the free-the-strap guidance. Cleared once the link bonds.
    @Published public var pairingHint: String? = nil

    /// Set when a connect fails because the strap wiped its side of the bond ("Peer removed pairing
    /// information"), after a firmware update or a re-bond by the official app. The OS keeps presenting the
    /// now-stale key, so reconnects loop on the same error with no route out. Carries the forget-and-re-pair
    /// guide; cleared by the next successful connect.
    @Published public var reconnectGuide: String? = nil

    /// Set when a marginal radio cannot sustain the WHOOP 4 R10/R11 raw realtime stream and drops the link
    /// the instant that burst is armed. After repeated arm-then-timeout cycles the manager stops arming the
    /// heavy stream and falls back to the low-bandwidth 0x2A37 standard HR profile, so live HR still flows
    /// on a radio that would otherwise loop forever. Cleared on a clean reconnect.
    @Published public var standardHRMode: String? = nil

    /// The short connection label every surface shares, so two of them can never disagree about one state
    /// (a sidebar reading "Connecting" while a card reads "Connected" for the same unbonded 5/MG link).
    /// Purely derived, and deliberately with no separate "syncing" identity: history records and live
    /// records arrive over the same connected link, so a syncing state would only flap against connected.
    ///
    /// Callers append their own suffixes (" · charging", " · NN%"), so the base string must not carry them.
    public var connectionStatusLabel: String {
        if connected && bonded { return "Bonded · streaming" }
        if connected { return "Connected" }
        if bonded { return "Bonded · idle" }
        return "Disconnected"
    }
    /// The link is up and HR is flowing: the status reads green.
    public var connectionStatusIsActive: Bool { connected }
    /// Paired before, but not connected right now: the status reads amber.
    public var connectionStatusIsIdle: Bool { !connected && bonded }

    // MARK: - Live biometrics

    @Published public var heartRate: Int? = nil

    /// Rolling live-bpm ring behind the Live tab's stream strip. It lives on this shared object rather than
    /// in per-view `@State` so the history survives the view swap between the standalone and in-workout
    /// placements at workout start and stop. Two view identities would each own their own ring, and the
    /// swap would blank the strip and throw away the minute of history the user was just watching. One
    /// 1 Hz sampler tied to the tab's lifecycle fills it, so it does not care which view is mounted.
    @Published public private(set) var hrStream: [Int] = []

    /// Ring capacity: one slot per bar in the stream strip.
    public static let hrStreamCapacity = 60

    /// Append the current live rate, dropping the oldest past capacity.
    ///
    /// When an HR reading last ARRIVED, on any lane, changed or not. Unpublished on purpose: the
    /// change-guarded writers deliberately publish nothing for a steady rate, and this stamp exists
    /// to tell that steady-but-alive stream apart from one that silently died mid-connection.
    public private(set) var hrSeenAtUnix: Int?

    /// Every HR arrival stamps this, BEFORE the change guard, so a rock-steady 60 still reads alive.
    public func noteHRSeen(now: Int = Int(Date().timeIntervalSince1970)) { hrSeenAtUnix = now }

    /// A reading older than this with the link still up is a dead stream, not a steady heart.
    public static let hrStaleAfterSeconds = 10

    /// Sampling on a timer instead of off `$heartRate` is deliberate. A steady resting HR publishes nothing
    /// through a change-guarded write, so a value-driven strip would freeze exactly when the reading is at
    /// its most stable. No-op until there is a live rate.
    ///
    /// The staleness check is the honesty half: a stream that stops mid-connection (an unbonded strap
    /// throttling its standard notify, a realtime arm the handshake reset) left the last value painting
    /// forever — a live screen stuck on one number with no way to tell it from a steady heart. Blank it
    /// like a disconnect would; `clearBiometrics` cannot help here because the link never dropped. A nil
    /// stamp stays fresh on purpose — the demo seeder and previews set a rate with no arrival to stamp.
    public func sampleHRStream(now: Int = Int(Date().timeIntervalSince1970)) {
        guard let hr = heartRate, hr > 0 else { return }
        if let seen = hrSeenAtUnix, now - seen > Self.hrStaleAfterSeconds {
            heartRate = nil
            hrStream.removeAll()
            return
        }
        hrStream.append(hr)
        if hrStream.count > Self.hrStreamCapacity {
            hrStream.removeFirst(hrStream.count - Self.hrStreamCapacity)
        }
    }

    /// Seed the ring for previews and specimens, where no live sampler runs. Not DEBUG-gated on purpose:
    /// the specimen that calls it compiles in Release too, and a seeder is harmless.
    public func seedHRStream(_ values: [Int]) { hrStream = Array(values.suffix(Self.hrStreamCapacity)) }

    /// Whether the heavy R10/R11 realtime burst is armed right now.
    ///
    /// Tracks the realtime INTENT (start and stop), never `heartRate`: the lightweight 0x2A37 profile keeps
    /// setting a heart rate while bonded, so an HR-driven toggle could never read "off".
    @Published public var liveFeedActive: Bool = false

    /// The newest R-R packet exactly as it arrived, sentinels included. The fresh-packet surface for
    /// breathing and stress logic that reacts to the latest arrival. Drive it only through `setRRIntervals`.
    @Published public var rr: [Int] = []

    /// Rolling buffer of recent valid R-R intervals, oldest dropped first. A standard HR notification
    /// carries only one or two intervals, so a moving strip or a rolling RMSSD needs its own short history
    /// rather than the latest packet alone. Appended to, never replaced.
    @Published public private(set) var rrRecent: [Int] = []

    /// Monotonic counter bumped on every R-R packet that carried at least one valid interval, including a
    /// packet whose content repeats the one before it.
    ///
    /// A view growing its own buffer must observe THIS, not `rr`. SwiftUI's `onChange(of:)` is
    /// Equatable-driven, so two identical consecutive packets, which is the common case at rest, leave `rr`
    /// unchanged and the repeat beat is silently swallowed. The counter exists only because of that
    /// observation semantic; nothing in the protocol needs it.
    @Published public private(set) var rrPacketSeq: Int = 0

    /// The one funnel for R-R intervals from either source (the standard 0x2A37 profile, or the
    /// REALTIME_DATA frame). Records the fresh packet verbatim, then appends only the positive intervals to
    /// the bounded rolling buffer: a non-positive value is the strap's "no interval this beat" placeholder,
    /// and it would read as an impossible beat in a strip or an RMSSD window.
    public func setRRIntervals(_ intervals: [Int], recentLimit: Int = 60) {
        rr = intervals
        let valid = intervals.filter { $0 > 0 }
        guard !valid.isEmpty else { return }
        rrRecent.append(contentsOf: valid)
        if rrRecent.count > recentLimit {
            rrRecent.removeFirst(rrRecent.count - recentLimit)
        }
        rrPacketSeq &+= 1
    }

    // MARK: - Battery

    @Published public var batteryPct: Double? = nil

    /// Charging flag out of the strap's BATTERY_LEVEL events (u8 bit0 in the payload, offset 26 on 4.0 and
    /// 30 on 5.0), pushed roughly every eight minutes. nil until the first event of a session and cleared
    /// on disconnect, so a stale flag cannot outlive the link that produced it.
    ///
    /// A flag only. The percentage keeps its own family-specific source, and the two are kept side by side
    /// rather than folded together because they age differently: the flag is the latest known charging
    /// state, while the samples below are a time series something else fits a slope to.
    @Published public var charging: Bool? = nil

    /// Rolling `(unix-seconds, SoC%)` readings banked off the live link, the battery counterpart of
    /// `rrRecent`. `setBattery` appends each reading and the estimator fits a discharge slope across them.
    /// Bounded, and cleared on disconnect so a runtime estimate fitted to the previous link cannot be
    /// presented as a statement about the next one.
    ///
    /// The tuple labels are load-bearing: `seedBatterySamples` takes the same shape from the persisted
    /// battery table and `BatteryEstimator` reads the elements by name. A struct here compiles and breaks
    /// both of those.
    @Published public private(set) var batterySamples: [(ts: Int, soc: Double)] = []

    /// Cap on the SoC buffer. Battery events arrive only every eight minutes or so, so a few hundred
    /// readings already cover a couple of days, which is more than a slope fit needs.
    static let maxBatterySamples = 400

    /// The strap's typical full-charge life in hours, the cold-start fallback used before enough of the
    /// user's own discharge has been banked. Set from the connected model once the generation is known.
    ///
    /// The default has to stay the WHOOP 4 figure. Assuming the longer-lived generation would inflate every
    /// pre-identification estimate rather than merely widening it.
    @Published public var batteryRatedHours: Double = BatteryEstimator.ratedLifeHoursWhoop4

    /// Optional hook fired on each battery update, wired by the alert monitor. A closure, so this type
    /// stays a plain observable snapshot with no dependency on the alerting layer.
    public var onBatteryUpdate: ((Double) -> Void)?

    /// The one funnel for battery readings: publish the value, bank the sample, then notify the hook, so
    /// both write sites drive the alert monitor with the same percentage in the same order.
    public func setBattery(_ pct: Double) {
        batteryPct = pct
        bankBatterySample(pct)
        onBatteryUpdate?(pct)
    }

    /// Bank one SoC reading for the runtime estimate.
    ///
    /// The strap re-emits its battery event every eight minutes or so whether or not anything changed, so
    /// an identical percentage inside ten minutes is a duplicate event and not new discharge information.
    /// Banking it pads the series with zero-slope points and flattens the fit. Any change in percentage, or
    /// enough elapsed time, banks a fresh point. `now` is injectable so the estimate is testable without a
    /// live clock.
    func bankBatterySample(_ pct: Double, now: Int = Int(Date().timeIntervalSince1970)) {
        if let last = batterySamples.last, last.soc == pct, now - last.ts < 600 { return }
        batterySamples.append((ts: now, soc: pct))
        if batterySamples.count > Self.maxBatterySamples {
            batterySamples.removeFirst(batterySamples.count - Self.maxBatterySamples)
        }
        // Test-mode observability: the banked reading plus the analysis trace, once per banked point. The
        // gate is a single bool read and the string below is only built when the mode is on. The dedupe
        // above means at most one of these every eight minutes, so this is throttled by construction.
        if TestCentre.active(.battery) {
            append(log: "bank soc=\(String(format: "%.1f", pct)) t=\(now)s", domain: .battery)
            emitBatteryTrace()
        }
    }

    /// Seed the SoC buffer from the persisted battery table on connect.
    ///
    /// Live events are otherwise the only source, so after a reconnect the estimate restarted from an empty
    /// buffer and ignored the long discharge history already sitting on disk. De-dupes by timestamp against
    /// whatever this session already banked, so a seed racing a live reading cannot double-count it, then
    /// re-sorts (the seeded points are older than the live ones but arrive after them) and caps. Idempotent,
    /// because the connect path may run it more than once.
    public func seedBatterySamples(_ seed: [(ts: Int, soc: Double)]) {
        guard !seed.isEmpty else { return }
        let existing = Set(batterySamples.map { $0.ts })
        let fresh = seed.filter { !existing.contains($0.ts) }
        guard !fresh.isEmpty else { return }
        batterySamples.append(contentsOf: fresh)
        batterySamples.sort { $0.ts < $1.ts }
        if batterySamples.count > Self.maxBatterySamples {
            batterySamples.removeFirst(batterySamples.count - Self.maxBatterySamples)
        }
    }

    /// Drop the banked SoC series when the link goes, so nothing fitted to the previous strap survives to
    /// describe the next one.
    public func clearBatterySamples() {
        batterySamples.removeAll()
    }

    /// Runtime estimate for the connected strap, fitted over the banked readings. nil until there is
    /// something to fit: an invented "days left" is worse than an absent one.
    public var batteryEstimate: BatteryEstimator.Estimate? {
        BatteryEstimator.estimate(samples: batterySamples, ratedHours: batteryRatedHours)
    }

    /// The discharge-run, fitted-slope and gate trace for the same banked series. Pure with respect to the
    /// displayed numbers: the estimator hands back the SAME Estimate as `batteryEstimate` alongside the
    /// trace, so reading this can never move a figure the user is looking at.
    public var batteryEstimateTraceLines: [String] {
        BatteryEstimator.estimateTrace(samples: batterySamples, ratedHours: batteryRatedHours).trace
    }

    /// Emit the trace, tagged, while the Battery test mode is on. Off, it costs one bool read.
    public func emitBatteryTrace() {
        guard TestCentre.active(.battery) else { return }
        for line in batteryEstimateTraceLines { append(log: line, domain: .battery) }
    }

    /// Resolve one Battery-mode readout id to a short display string. "--" for an unknown id, and for a
    /// series too thin to estimate from. Reads the same values the badge shows, so the readout cannot
    /// disagree with the headline number.
    public func batteryReadout(_ id: String) -> String {
        guard let e = batteryEstimate else { return "--" }
        switch id {
        case "currentSoc":       return "\(Int(e.currentSoc.rounded()))%"
        case "estimateDaysLeft": return BatteryEstimator.label(hours: e.remainingHours)
        case "slopeSource":      return e.source.rawValue
        default:                 return "--"
        }
    }

    // MARK: - Strap identity, firmware and banked-record window

    /// The strap's BLE advertising name, read back from firmware during the connect handshake. WHOOP 4
    /// only; the rename control shows it as the current name. nil until the first reply lands.
    @Published public var advertisingName: String? = nil

    /// The connected strap's firmware version from the handshake (REPORT_VERSION_INFO on WHOOP 4, GET_HELLO
    /// on 5/MG). nil until the reply lands, and cleared on disconnect so one strap's version can never be
    /// shown beside a different strap.
    @Published public var strapFirmware: String? = nil

    /// Transient, human-readable result of the last rename attempt: the firmware ack, or a local validation
    /// message. Stays externally settable because the rename screen clears it as soon as the field is edited
    /// again. Overwritten by the next attempt.
    @Published public var renameStatus: String? = nil

    /// The strap's last-reported banked-record window, plus the historical record layout it is emitting.
    ///
    /// This is what the export assembler turns into the clock-drift line carried by every diagnostic export,
    /// so a strap whose clock has drifted diagnoses itself on any report instead of only when the connection
    /// test mode happens to be on. Banked unconditionally, since it is observability rather than a gated
    /// feature, and cleared on disconnect. nil until the strap first reports its range this session.
    public struct StrapRange: Equatable, Sendable {
        public var newestUnix: Int
        public var oldestUnix: Int?
        public var firmwareLayout: Int?
        public init(newestUnix: Int, oldestUnix: Int? = nil, firmwareLayout: Int? = nil) {
            self.newestUnix = newestUnix; self.oldestUnix = oldestUnix; self.firmwareLayout = firmwareLayout
        }
    }
    @Published public private(set) var strapRange: StrapRange?

    /// Bank the window from a GET_DATA_RANGE reply. A short reply carries the upper bound only, so a
    /// previously-known `oldestUnix` is preserved rather than nilled: throwing away a good lower bound makes
    /// the export claim the strap holds no history at all.
    public func setStrapRange(newestUnix: Int, oldestUnix: Int?) {
        let firmware = strapRange?.firmwareLayout
        let oldest = oldestUnix ?? strapRange?.oldestUnix
        strapRange = StrapRange(newestUnix: newestUnix, oldestUnix: oldest, firmwareLayout: firmware)
    }

    /// Bank the historical record layout the strap emits, so the clock-drift line is firmware-aware even
    /// before any range reply arrives. Keeps a known window untouched; when the layout is seen first, stores
    /// a layout-only snapshot with a zero window rather than inventing a range that was never reported.
    public func setStrapFirmwareLayout(_ version: Int) {
        if let r = strapRange {
            strapRange = StrapRange(newestUnix: r.newestUnix, oldestUnix: r.oldestUnix, firmwareLayout: version)
        } else {
            strapRange = StrapRange(newestUnix: 0, oldestUnix: nil, firmwareLayout: version)
        }
    }

    /// Drop the window on disconnect, so a clock-drift diagnosis about the previous link cannot ride out on
    /// an export taken after it.
    public func clearStrapRange() { strapRange = nil }

    @Published public var lastFrameType: String? = nil
    @Published public var lastEvent: String? = nil

    /// Unix second of the most recently routed frame.
    ///
    /// Deliberately NOT `@Published`. The raw flood arrives per notification, and a published write per
    /// frame re-renders every observer at frame rate, which is the same churn the `lastFrameType` change
    /// guard exists to avoid. The readout showing it redraws on its own cadence, which is ample for a
    /// freshness label. Cleared with the other live readouts.
    public private(set) var lastFrameAtUnix: Int?

    /// Stamp the last-frame instant. Called after the CRC guard, so corrupt bytes never count as liveness.
    /// The equality guard folds many frames per second into at most one write per whole second; drop it and
    /// this becomes a per-frame write on the hottest path in the app.
    public func noteFrameRouted(now: Int = Int(Date().timeIntervalSince1970)) {
        guard lastFrameAtUnix != now else { return }
        lastFrameAtUnix = now
    }

    // MARK: - Sleep test-mode live readout

    /// Recent live HR samples, banked only while the Sleep test mode is on, so the readout can show the
    /// sample density the detector actually works from. The caller does the gating, so with the mode off
    /// this costs nothing: it is simply not called.
    @Published public private(set) var recentHrSamples: [HRSample] = []

    /// Recent live gravity samples, the gravity-coverage counterpart of `recentHrSamples`.
    @Published public private(set) var recentGravitySamples: [GravitySample] = []

    /// Cap on each readout buffer. Half an hour of 1 Hz HR is plenty for a density snapshot, and the bound
    /// is what stops a test mode left on overnight from growing these without limit.
    static let maxSleepReadoutSamples = 2000

    public func recordSleepLiveHr(ts: Int, bpm: Int) {
        recentHrSamples.append(HRSample(ts: ts, bpm: bpm))
        if recentHrSamples.count > Self.maxSleepReadoutSamples {
            recentHrSamples.removeFirst(recentHrSamples.count - Self.maxSleepReadoutSamples)
        }
    }

    public func recordSleepLiveGravity(_ samples: [GravitySample]) {
        guard !samples.isEmpty else { return }
        recentGravitySamples.append(contentsOf: samples)
        if recentGravitySamples.count > Self.maxSleepReadoutSamples {
            recentGravitySamples.removeFirst(recentGravitySamples.count - Self.maxSleepReadoutSamples)
        }
    }

    // MARK: - Standard fitness-sensor metrics (additive, never HR)

    // Live speed, cadence and power from a standard fitness sensor (a footpod, a bike speed-and-cadence
    // sensor, a power meter) read alongside the HR profile. Purely additive: these never touch `heartRate`,
    // `rr`, or any scoring input, so a workout is recorded by the existing HR-driven flow whether or not a
    // sensor is present. nil before the first packet, cleared on disconnect. Speed and cadence from CSC/CPS
    // are derived across successive packets, so they honestly appear only once two have arrived.

    /// Instantaneous speed in km/h (direct from RSC, derived from CSC/CPS).
    @Published public var sensorSpeedKmh: Double? = nil
    /// Instantaneous cadence: running steps per minute from RSC, crank rpm from CSC/CPS.
    @Published public var sensorCadence: Double? = nil
    /// Instantaneous power in watts from a cycling-power sensor.
    @Published public var sensorPowerWatts: Int? = nil

    /// Clear the sensor metrics on disconnect or source teardown, leaving HR and R-R alone.
    public func clearSensorMetrics() {
        sensorSpeedKmh = nil
        sensorCadence = nil
        sensorPowerWatts = nil
    }

    /// True when any sensor metric is present. Gates whether the additive readout appears at all, so a
    /// workout with HR alone looks exactly as it did before any sensor support existed.
    public var hasSensorMetrics: Bool {
        sensorSpeedKmh != nil || sensorCadence != nil || sensorPowerWatts != nil
    }

    // Display strings for the sensor readout. Each returns nil when the sensor has not sent that field, so
    // the UI hides the tile instead of showing a fabricated zero. Units stay native with no conversion
    // guessing: km/h is the decode unit, and cadence is per-minute for both sensor kinds (this type does not
    // carry which kind it is, so the neutral label is the honest one). `static` so they are testable away
    // from the main actor.
    static func formatSpeedKmh(_ kmh: Double?) -> String? {
        guard let kmh, kmh.isFinite, kmh >= 0 else { return nil }
        return String(format: "%.1f", kmh)
    }
    static func formatCadence(_ perMin: Double?) -> String? {
        guard let perMin, perMin.isFinite, perMin >= 0 else { return nil }
        return String(Int(perMin.rounded()))
    }
    static func formatPowerWatts(_ watts: Int?) -> String? {
        guard let watts, watts >= 0 else { return nil }
        return String(watts)
    }

    // MARK: - Sync and session state

    /// True when the stuck-strap watchdog finds the strap holding newer records than we do while our
    /// frontier refuses to advance. The records are safe on the strap; it is simply not handing them across.
    /// A banner only, never an action.
    @Published public var strapNeedsReboot = false

    /// Wall time of the last offload that completed, including one that found nothing new, since caught up
    /// is still a successful sync. Drives the sync tile and the staleness nudge.
    @Published public var lastSyncedAt: TimeInterval?

    /// Set when an offload ended abnormally, so a stalled history download is not silent. Cleared by the
    /// next completion. Process-local on purpose: the next connect or tick re-offloads anyway, so an error
    /// persisted across launches would outlive its own relevance and alarm the user about nothing.
    @Published public var lastSyncError: String? = nil

    /// True while a historical offload is running, so screens can say history is still arriving rather than
    /// present half-loaded data as final.
    @Published public var backfilling = false

    /// Unix seconds of the newest PERSISTED sample in the store, which the sync row renders as "2d 4h
    /// behind". Fed by an indexed MAX query on the backfill-start edge, and throttled as chunks land.
    ///
    /// Deliberately NOT cleared on disconnect: this is a fact about the store, not about the link. The data
    /// really is still that far behind once the strap walks away.
    @Published public private(set) var persistedFrontierUnix: TimeInterval?

    /// Whether the frontier above has been read at all yet.
    ///
    /// `persistedFrontierUnix` is nil in two completely different situations: nothing has ever been
    /// persisted, and nobody has looked yet. The first is a fact about the user, the second a fact about app
    /// startup, and it holds for the opening frames of EVERY launch because the read is an async query.
    /// Anything reporting on the frontier must stay quiet until this is true, or it states a conclusion
    /// about the user drawn from its own not-having-looked.
    @Published public private(set) var frontierLoaded = false

    /// Bank a fresh frontier read.
    ///
    /// `frontierLoaded` is set BEFORE the equality guard, because a read landing on the value we already had
    /// is still a read that landed. Behind the guard, a store whose frontier never moves would leave every
    /// frontier-dependent surface silent for the entire session. The guard itself is what keeps the
    /// throttled re-reads during a quiet stretch from republishing an unchanged value to every observer.
    public func setPersistedFrontier(_ unix: TimeInterval?) {
        if !frontierLoaded { frontierLoaded = true }
        guard persistedFrontierUnix != unix else { return }
        persistedFrontierUnix = unix
    }

    /// Chunks acked during the current offload. An honest progress signal: the protocol never states how
    /// many are still pending, so this stays a count and is never dressed up as a percentage.
    @Published public var syncChunksThisSession: Int = 0

    /// Undecodable record frames this session whose raw bytes WERE preserved to the on-device archive.
    @Published public var rejectedFramesThisSession: Int = 0
    /// Undecodable record frames the archive could NOT preserve, because its size cap was reached. Counted
    /// separately so the sync status never claims "saved" about bytes that were not saved.
    @Published public var rejectedFramesUnarchived: Int = 0

    /// Per-session chunk tallies that separate an EMPTY completed sync from a clean one: zero decoded chunks
    /// against a high console count means the strap handed over diagnostic frames only, which is what a
    /// strap whose clock has lost sync looks like from here. Reset at session start.
    @Published public var decodedChunksThisSession: Int = 0
    @Published public var consoleChunksThisSession: Int = 0

    /// How many of the experimental R22 SET_CONFIG flags the strap has acked since the last send. The strap
    /// returns a COMMAND_RESPONSE per flag, so this is hardware-confirmed rather than assumed. Reset on each
    /// new attempt.
    @Published public var r22FlagsAccepted: Int = 0

    /// Type-0x2F records seen this session outside our own offload. These turned out to be historical
    /// offload data (another BLE client pulling the backlog over the shared notify channel) and not a
    /// separate live stream, so this stays a diagnostic counter and must not be read as a stream unlocking.
    @Published public var deepPacketsThisSession: Int = 0

    /// Frames captured this session while frame capture is enabled, and where they were flushed to. The
    /// capture status line and the export action read these.
    @Published public var puffinCaptureCount: Int = 0
    @Published public var puffinCaptureURL: URL?

    // MARK: - Event hooks

    /// Fired live when the strap reports a DOUBLE_TAP gesture. The subscriber does the debouncing.
    public var onDoubleTap: (() -> Void)?
    /// Fired live when wrist wear changes (true = put on, false = taken off).
    public var onWristChange: ((Bool) -> Void)?
    /// Fired live when the strap reports it executed its firmware alarm, so the next day's can be re-armed.
    public var onSmartAlarmFired: (() -> Void)?

    // MARK: - Log sink

    /// Cap on the in-memory strap-log ring. A busy live session emits a few lines a minute, so this spans
    /// roughly a day, which is what correlating protocol behaviour against a night of wear needs. Each line
    /// is a short redacted string, so the worst case stays well under a megabyte: bounded, never unbounded.
    static let maxLogLines = 5_000

    /// Rolling log of human-readable lines, newest last, feeding the on-device verification checklist and
    /// the bug-report body. In memory only, for the life of the process.
    @Published public var log: [String] = []

    /// The single sink every log line passes through.
    ///
    /// Order matters: tag first, then redact, so the scrub covers the whole line and the tag is written once
    /// in the form `taggedTail` matches.
    ///
    /// This sink does NO persistence, deliberately. About fifteen of its call sites sit on the BLE hot path,
    /// so a write-amplifying side effect here is exactly the per-packet work this file must never do. Newest
    /// goes last rather than first, so a bug report reads in the order events happened.
    public func append(log line: String, domain: TestDomain? = nil) {
        let tagged = domain.map { "[\($0.id)] " + line } ?? line
        log.append(Self.redactPii(tagged))
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
        // Fold the backfiller's per-session summary into the all-time drained-rows tally right here, at the
        // one sink, rather than opening a fresh seam through the BLE layer. The summary is emitted whenever
        // rows landed, so the counter accrues every session and not only while a test mode happens to be on.
        // The contains() pre-check keeps the ordinary line's cost at a single substring scan.
        if line.contains("session persisted"), let rows = ConnectionReadout.drainedRowsFromSummary(line) {
            TestCentre.noteDrainedRows(rows)
        }
    }

    /// The log lines tagged for one test domain. Read-only, no side effects. Redaction never eats the
    /// prefix, because the tag is prepended before the scrub and the scrub only touches identifiers.
    public func taggedTail(domain: TestDomain) -> [String] {
        let prefix = "[\(domain.id)] "
        return log.filter { $0.hasPrefix(prefix) }
    }

    /// Scrub personal identifiers so a strap log is safe to share in public.
    ///
    /// Three targeted masks in this order: a BLE MAC is reduced to its first and last byte, the WHOOP serial
    /// carried in the device name ("WHOOP 4C1594026", which is tied to the owner's account) is removed, and
    /// the per-install CoreBluetooth peripheral identifier is replaced. The order is load-bearing: the MAC
    /// pattern demands colons and must run before the looser rules, so hex command payloads come through
    /// untouched.
    ///
    /// The UUID rule deliberately KEEPS the standard-BLE base UUIDs (ending 0000-1000-8000-00805f9b34fb, so
    /// the 0x2A37 HR characteristic among them) and the WHOOP vendor service base (ending
    /// 8d6d-82b8-614a-1c8cb0f8dcc6). Those are public, identical on every strap, and are precisely the GATT
    /// diagnostics that make a shared log worth reading. The negative lookahead is that carve-out; get it
    /// wrong in either direction and you either leak an identifier or blind the log.
    ///
    /// Written directly against NSRegularExpression and the BLE identifier formats. A leak here is a
    /// security regression, so change these patterns only alongside a test for the new case.
    nonisolated static func redactPii(_ s: String) -> String {
        var out = s
        func mask(_ re: NSRegularExpression, _ template: String) {
            out = re.stringByReplacingMatches(
                in: out, options: [], range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        mask(macRegex, "$1:••:••:••:••:$2")
        mask(serialRegex, "WHOOP <serial>")
        mask(deviceUUIDRegex, "<device>")
        return out
    }

    // Compiled once per process. `redactPii` runs on every logged line, and building three
    // NSRegularExpression objects per call was pure churn on the log path. `try!` is safe here: the patterns
    // are compile-time constants, so a failure would be a build-time typo and not a runtime condition.
    private nonisolated static let macRegex = try! NSRegularExpression(
        pattern: "([0-9A-Fa-f]{2}):[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:([0-9A-Fa-f]{2})")
    private nonisolated static let serialRegex = try! NSRegularExpression(
        pattern: "WHOOP (\\d[0-9A-Za-z]{5,})")
    private nonisolated static let deviceUUIDRegex = try! NSRegularExpression(
        pattern: "(?![0-9A-Fa-f]{8}-(?:0000-1000-8000-00805f9b34fb|8d6d-82b8-614a-1c8cb0f8dcc6))[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        options: [.caseInsensitive])

    /// One-shot removal of a retired UserDefaults key.
    ///
    /// The log ring used to mirror its last couple of thousand lines into `UserDefaults` under
    /// `strapLog.tail`, for a scheduled export that was never built and is not planned. The whole chain was
    /// write-only: a suffix copy plus a key-value write every twenty-five appends, on a path where roughly
    /// fifteen call sites are on the BLE hot path, for a blob nothing ever read back.
    ///
    /// A `static let` is Swift's run-exactly-once, thread-safe initializer, so this costs one lookup per
    /// PROCESS rather than per instance: the tests and previews that each build their own instance pay
    /// nothing after the first. It lives beside the retired code rather than in the app entry point so the
    /// two cannot drift apart. The `object(forKey:)` pre-check keeps the steady state, already purged or a
    /// fresh install that never had a tail, a pure read with no write and no disk flush.
    private static let purgedRetiredLogTail: Void = {
        let retiredKey = "strapLog.tail"
        if UserDefaults.standard.object(forKey: retiredKey) != nil {
            UserDefaults.standard.removeObject(forKey: retiredKey)
        }
    }()

    public init() {
        // Touch the one-shot purge above. Nothing else belongs in here: this type is a plain observable
        // snapshot, it is constructed on the launch path and in several tests, and construction has to stay
        // free of work and of side effects beyond that single key removal.
        _ = Self.purgedRetiredLogTail
    }

    // MARK: - Teardown

    /// Blank every live readout when the link drops.
    ///
    /// One place naming everything that must not outlive the connection, because forgetting one fails
    /// silently: a stale heart rate, R-R strip, runtime estimate or clock-drift window keeps rendering as
    /// though it were current, and nothing downstream can tell it is describing a strap that is no longer
    /// there.
    ///
    /// `worn` is RESTORED to true rather than cleared to false. WRIST_ON and WRIST_OFF are transition
    /// events, never a connect-time snapshot, so a strap that reconnects already on the wrist sends no
    /// WRIST_ON. A stale `worn = false` carried over from a WRIST_OFF before the drop would silently gate
    /// off every wear-dependent feature for the rest of the session, with no event coming to undo it.
    ///
    /// `persistedFrontierUnix` and `frontierLoaded` are deliberately absent: they describe the store, and
    /// the store did not change because the radio did.
    public func clearBiometrics() {
        heartRate = nil
        worn = true
        hrStream.removeAll()
        rr.removeAll()
        rrRecent.removeAll()
        rrPacketSeq = 0
        clearBatterySamples()
        recentHrSamples.removeAll()
        recentGravitySamples.removeAll()
        clearStrapRange()
        lastFrameAtUnix = nil
        hrSeenAtUnix = nil
    }
}
