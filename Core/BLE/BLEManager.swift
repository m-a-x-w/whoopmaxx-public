// Derived from ParthJadhav/noop, PolyForm Noncommercial License 1.0.0, Copyright 2026 NoopApp.
// Required Notice: Copyright 2026 NoopApp (https://github.com/ParthJadhav/noop)
// Terms: https://polyformproject.org/licenses/noncommercial/1.0.0 — see ../../LICENSE.

import Foundation
import CoreBluetooth
import StrapProtocol
import StrapStore
import StrapAnalytics
// The bond-loop salvage probe hangs off the app-foreground notification, whose name lives in a
// different framework per platform. See installForegroundSalvageProbe.
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Reconnect-loop detectors
//
// Four small value types below, one per failure signature the connect loop can fall into. They are
// pure and `mutating` rather than methods on BLEManager for one reason: each is a decision that has
// to be made from a disconnect callback, where the manager's own state is half torn down. Keeping
// the rule in a value type means the rule can be reasoned about (and exercised) without standing up
// a CBCentralManager.
//
// They all share one shape: a streak counter, a latch, and a `connectionEnded`-style feed that
// returns true EXACTLY ONCE, on the call that crosses the threshold. The once-only return is what
// lets the caller log or surface a banner without repeating it every cycle.

/// A Bluetooth radio too weak to carry the WHOOP 4 R10/R11 raw realtime burst.
///
/// The signature is narrow on purpose: a connection TIMEOUT that lands a few seconds after we armed
/// the burst, over and over. Arm, die, rescan, arm, die. Blaming any drop would mis-trip a healthy
/// radio whose link merely flaps twenty minutes into a session, which would permanently downgrade a
/// user who never had a problem.
///
/// The remedy once tripped is to skip the R10/R11 arm on the next connect and lean on the standard
/// 0x2A37 heart-rate profile, which is low bandwidth and independently subscribed. Either live HR
/// survives on a radio that could not otherwise carry it, or at minimum the arm-then-die loop stops.
struct MarginalRadioDetector {
    /// Consecutive arm-then-quick-timeout cycles required before falling back. One drop is noise;
    /// two in a row immediately after the arm is the radio buckling under the burst.
    let tripThreshold: Int
    /// How soon after the arm a timeout still counts as caused by it. A drop minutes into a healthy
    /// session has nothing to do with the arm and must break the streak instead of extending it.
    let quickTimeoutWindow: TimeInterval

    private(set) var consecutiveArmTimeouts = 0
    /// Latched once the threshold is crossed: the next connect runs standard-HR only.
    private(set) var tripped = false

    init(tripThreshold: Int = 2, quickTimeoutWindow: TimeInterval = 20) {
        self.tripThreshold = tripThreshold
        self.quickTimeoutWindow = quickTimeoutWindow
    }

    /// Feed one ended connection. `wasArmed` means we armed R10/R11 during it, `secondsSinceArm` is
    /// how long after the arm the link died (nil if we never armed), and `timedOut` means the drop
    /// looked like a timeout rather than an intentional teardown. Returns true on the crossing only.
    mutating func connectionEnded(wasArmed: Bool, secondsSinceArm: TimeInterval?, timedOut: Bool) -> Bool {
        let armCausedTimeout = wasArmed && timedOut
            && (secondsSinceArm.map { $0 <= quickTimeoutWindow } ?? false)
        guard armCausedTimeout else {
            // Anything else is evidence the radio is fine. A healthy spell must clear old suspicion,
            // or one bad afternoon would pin the user to standard-HR for the life of the process.
            consecutiveArmTimeouts = 0
            return false
        }
        consecutiveArmTimeouts += 1
        if !tripped && consecutiveArmTimeouts >= tripThreshold {
            tripped = true
            return true
        }
        return false
    }

    /// Drop all suspicion. Called on a clean teardown and whenever the user explicitly re-asks for
    /// the full stream, so a transient radio hiccup is recoverable rather than permanent.
    mutating func reset() {
        consecutiveArmTimeouts = 0
        tripped = false
    }
}

/// A bond that succeeds and then dies about a second later, forever.
///
/// The strap bonds, the encrypted link drops with a connection timeout, the rescan reconnects, it
/// bonds again, and dies again. Nothing in the loop is an error the user can see, so without this
/// the only symptom is a battery draining for no visible reason.
///
/// Same discipline as the marginal-radio detector: the drop must be classified by the OS as a
/// connection timeout (not merely "some error"), and it must land inside the window after a GENUINE
/// bond. A bond that survives well past the window is healthy and breaks the streak. The window is
/// generous relative to the radio detector's because a pre-loop link can limp for several seconds
/// before it gives up, even though the loop's own signature is nearly immediate.
///
/// Tripping surfaces the existing re-pair guide, because the fix is always the same: something else
/// (the official app, or a stale OS pairing) still owns the strap.
struct PostBondTimeoutLoopDetector {
    /// Consecutive bond-then-quick-timeout cycles before the guide is surfaced. Two, not one: a
    /// single quick post-bond drop happens; two in a row is the loop.
    let tripThreshold: Int
    /// How soon after the bond a timeout still counts as caused by it.
    let quickTimeoutWindow: TimeInterval

    private(set) var consecutiveBondTimeouts = 0
    /// Latched once the threshold is crossed: the re-pair guide is up.
    private(set) var tripped = false

    init(tripThreshold: Int = 2, quickTimeoutWindow: TimeInterval = 8) {
        self.tripThreshold = tripThreshold
        self.quickTimeoutWindow = quickTimeoutWindow
    }

    /// Feed one ended connection. Returns true on the crossing only, so the guide is written once.
    mutating func connectionEnded(wasBonded: Bool, secondsSinceBond: TimeInterval?, timedOut: Bool) -> Bool {
        let bondThenQuickTimeout = wasBonded && timedOut
            && (secondsSinceBond.map { $0 <= quickTimeoutWindow } ?? false)
        guard bondThenQuickTimeout else {
            consecutiveBondTimeouts = 0
            return false
        }
        consecutiveBondTimeouts += 1
        if !tripped && consecutiveBondTimeouts >= tripThreshold {
            tripped = true
            return true
        }
        return false
    }

    /// Drop all suspicion: a clean session is flowing, or the user tore the link down themselves.
    mutating func reset() {
        consecutiveBondTimeouts = 0
        tripped = false
    }
}

/// A strap that keeps REFUSING the encrypted bond, as opposed to bonding and then dropping.
///
/// Two jobs, both pure. First, decide when hammering is pointless: after enough consecutive refusals
/// with no bond in between, auto-reconnect stops re-kicking, because no amount of retrying makes a
/// strap held by another central hand over its encryption. Second, emit one summary line recording
/// how the attempt died, carrying the streak and an opaque install-local token so a shared log has
/// the cause with no MAC and no serial in it.
///
/// The streak deliberately survives a disconnect. It is cleared only by a genuine bond or an
/// explicit user reconnect, because every cycle of the loop IS a disconnect, and resetting there
/// would mean the threshold is never reached.
///
/// This has no self-expiring cooldown by design. The pause is lifted by `connect()`, a genuine bond,
/// or the foreground salvage probe, all of which are evidence something changed. A timer expiring is
/// not evidence of anything, and would restart the hammer on a strap still held by the official app.
struct BondRefusalGiveUp {
    /// Consecutive refusals before the pause and the epitaph. Five, not two where the pairing hint
    /// already appears: the hint asks the user to go free the strap, and this gives them several
    /// reconnect cycles to do it. A genuinely held strap reaches five within a couple of minutes.
    let giveUpThreshold: Int

    private(set) var refusals = 0
    /// Latched at the threshold and held until `reset()`, so the pause survives the loop.
    private(set) var gaveUp = false

    init(giveUpThreshold: Int = 5) { self.giveUpThreshold = giveUpThreshold }

    /// Record one refusal. Returns true only on the call that crosses the threshold, so the caller
    /// pauses reconnect and writes the epitaph exactly once. Later refusals return false because
    /// `gaveUp` has latched, which is what keeps a salvage probe from writing a second epitaph.
    mutating func recordRefusal() -> Bool {
        refusals += 1
        if !gaveUp && refusals >= giveUpThreshold {
            gaveUp = true
            return true
        }
        return false
    }

    /// A genuine bond landed, or the user asked again. Re-arms auto-reconnect.
    mutating func reset() {
        refusals = 0
        gaveUp = false
    }

    /// The one-line epitaph. Carries the streak and an opaque token, never a MAC or serial, so the
    /// line is safe to paste into a public issue. Shipped copy: do not reword.
    static func epitaphLine(refusals: Int, opaqueId: String) -> String {
        "Bond epitaph: the strap [\(opaqueId)] refused the encrypted bond \(refusals)x in a row with no successful bond - giving up auto-reconnect to stop hammering it. It is almost certainly held by the official WHOOP app or a stale phone pairing. Free it (close the WHOOP app, put the strap in pairing mode, forget it in Bluetooth settings) then reconnect in whoopmaxx."
    }

    /// The user-facing hint shown while auto-reconnect is paused: why it stopped, and what to do.
    /// Shipped copy: do not reword.
    static func pausedHint() -> String {
        "whoopmaxx stopped retrying because your strap keeps refusing to pair. It is likely still held by the official WHOOP app, or your phone is holding an old pairing. Close the WHOOP app, put the strap in pairing mode (tap until the LEDs flash blue), and if it is listed in your Bluetooth settings choose Forget This Device. Then tap Connect to try again."
    }

    /// A short opaque token from a CoreBluetooth-local peripheral UUID. That UUID is generated per
    /// install and is NOT the hardware address, and keeping only the first eight hex characters
    /// leaves a token stable within one log and useless outside it.
    static func opaqueId(fromLocalUUID uuid: String) -> String {
        let hex = uuid.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.prefix(8))
    }
}

/// A strap that completes its offload but hands over only console output, never sensor records.
///
/// That pattern means the strap's clock has lost sync and it is not banking to flash. But a single
/// console-only cycle is ordinary on a perfectly healthy strap, especially under heavy live-HR
/// polling, so warning on one cycle tells users their clock is broken when it is not. Only a
/// sustained streak is diagnostic; any cycle that banks real records clears it.
struct EmptySyncTracker {
    /// Consecutive console-only completions before the banner is honest. Three: a genuinely
    /// un-banking strap is console-only on every cycle and reaches three within minutes, while a
    /// transient empty cycle among healthy ones never accumulates.
    let threshold: Int
    /// Also read by the backfill rate limiter, which backs the periodic cadence off while the strap
    /// is demonstrably handing over nothing. Not just a banner counter.
    private(set) var consecutiveEmptySyncs = 0

    init(threshold: Int = 3) { self.threshold = threshold }

    /// Record one completed offload. `bankedSensorRecords` means real records arrived, decoded or
    /// archived-undecodable; either way the clock is banking. `consoleOnly` means diagnostics and
    /// nothing else. Returns true once the emptiness is sustained.
    mutating func recordCompletedSync(bankedSensorRecords: Bool, consoleOnly: Bool) -> Bool {
        guard consoleOnly, !bankedSensorRecords else {
            consecutiveEmptySyncs = 0
            return false
        }
        consecutiveEmptySyncs += 1
        return consecutiveEmptySyncs >= threshold
    }
}

/// A WHOOP 5/MG whose firmware acknowledges the offload request and then emits nothing.
///
/// Live HR streams fine over the standard profile, so the link is healthy; the history offload is
/// simply not served on that firmware. Without this the session runs the idle watchdog out every
/// time and reports the WHOOP 4 "strap went quiet" error for a strap that is working, and the quiet
/// data channel also lets the liveness watchdog bounce the link every couple of minutes.
///
/// Counting consecutive empty offloads separates that firmware from a one-off: the very first
/// offload after connect can race the strap waking its flash, so one empty cycle proves nothing.
/// Any offload that banks records clears both the counter and the latch, so a strap that starts
/// serving history recovers on the spot.
struct Whoop5EmptyOffloadTracker {
    /// Consecutive empty offloads before the strap is treated as history-empty.
    let quietThreshold: Int

    private(set) var consecutiveEmpty = 0
    /// Latched at the threshold. Drives the honest "history sync experimental" state and lengthens
    /// the liveness fuse so an idle-by-design data channel stops causing reconnect thrash.
    private(set) var historyEmpty = false

    init(quietThreshold: Int = 2) { self.quietThreshold = quietThreshold }

    /// Record one completed or timed-out offload. Returns true on the crossing only.
    mutating func recordOffload(bankedRecords: Bool) -> Bool {
        guard !bankedRecords else {
            // Banking clears the LATCH as well as the counter. Clearing only the counter would leave
            // a recovered strap stuck reporting "history experimental" until the next disconnect.
            consecutiveEmpty = 0
            historyEmpty = false
            return false
        }
        consecutiveEmpty += 1
        if !historyEmpty && consecutiveEmpty >= quietThreshold {
            historyEmpty = true
            return true
        }
        return false
    }

    /// Fresh connect, or an explicit user sync: start judging this strap from scratch.
    mutating func reset() {
        consecutiveEmpty = 0
        historyEmpty = false
    }
}

/// Whether a just-ended offload should immediately start another one instead of waiting out the
/// periodic floor.
///
/// The strap serves history OLDEST first and roughly a minute's worth per session. On a deep backlog
/// that means each session drains one slice of the oldest data and then idles for fifteen minutes,
/// so last night can take many sessions to arrive even though the strap never disconnected. Chaining
/// sessions back to back closes that gap.
///
/// Every guard has to hold, and the ORDER matters because the cheap and the decisive checks are
/// deliberately ahead of the ones that can be fooled:
///
///  1. still connected, or the ordinary reconnect path owns this instead;
///  2. under the per-connection cap, so a pathological strap cannot pin the radio;
///  3. the trim cursor actually moved, or we would spin on a frozen cursor forever;
///  4. then, and only then, one of the two "there is more to fetch" tests.
struct BackfillContinuation {
    /// Consecutive chained offloads per connection. Six sessions of roughly a minute each drains a
    /// multi-night backlog far faster than the floor without monopolising Bluetooth. Resets on
    /// disconnect.
    static let defaultMaxAutoContinues = 6
    /// How far ahead of our frontier the strap must be before "more remains" is real rather than
    /// clock noise. Kept equal to the stuck-strap detector's gap so the two agree on "behind".
    static let defaultBehindGapSeconds = 300
    /// How far past the wall clock a strap-reported newest may sit before it is not believable.
    ///
    /// A strap whose RTC relatched into the future reports a newest that outruns every real
    /// frontier, so the "strap is ahead of us" test would report backlog forever and burn the whole
    /// cap on empty offloads on every single connect. Two days absorbs timezone confusion and drift;
    /// nothing legitimate banks records two days ahead of the phone.
    static let defaultFutureSkewSeconds = 48 * 3600

    /// Is the strap-reported newest banked record implausibly far in the future?
    ///
    /// Shared between the predicate below and the caller's stop log so the two can never disagree
    /// about why a chain ended. nil means the range was never answered, which is UNKNOWN rather than
    /// future-dated, so it stays false and the stale-epoch rescue below still applies to it.
    static func isFutureDatedNewest(_ strapNewestTs: Int?, wallNowUnix: Int,
                                    futureSkewSeconds: Int = defaultFutureSkewSeconds) -> Bool {
        guard let n = strapNewestTs else { return false }
        return n > wallNowUnix + futureSkewSeconds
    }

    /// `strapNewestTs` is the newest record the strap says it holds (from GET_DATA_RANGE);
    /// `ourFrontierTs` is the newest we have persisted; `wallNowUnix` is passed in rather than read
    /// so the whole decision stays pure. Returns true to re-kick immediately, false to fall back to
    /// the periodic floor.
    static func shouldAutoContinue(stillConnected: Bool,
                                   strapNewestTs: Int?,
                                   ourFrontierTs: Int?,
                                   wallNowUnix: Int,
                                   rowsPersistedThisSession: Int = 0,
                                   lastTrimAdvanced: Bool,
                                   consecutiveCount: Int,
                                   maxAutoContinues: Int = defaultMaxAutoContinues,
                                   behindGapSeconds: Int = defaultBehindGapSeconds,
                                   futureSkewSeconds: Int = defaultFutureSkewSeconds) -> Bool {
        guard stillConnected else { return false }
        guard consecutiveCount < maxAutoContinues else { return false }
        guard lastTrimAdvanced else { return false }

        let futureDated = isFutureDatedNewest(strapNewestTs, wallNowUnix: wallNowUnix,
                                              futureSkewSeconds: futureSkewSeconds)
        let plausibleNewest = futureDated ? nil : strapNewestTs

        // Test A: the strap says it holds data newer than ours by more than the gap. Reliable
        // whenever its clock epoch is sane, which is exactly what nulling a future-dated newest buys.
        if let newest = plausibleNewest, let frontier = ourFrontierTs, (newest - frontier) > behindGapSeconds {
            return true
        }

        // A future-dated newest stops test B too, not just test A. A strap whose clock runs ahead
        // BANKED future-dated records, so the rows this session persisted are themselves
        // future-stamped and are not evidence of genuine backlog. Without this the chain would run
        // the full cap on a future-dated range, each pass to its own idle timeout, turning one sync
        // into a quarter of an hour of nothing. The stale-epoch case test B exists for reads BEHIND
        // the frontier, never ahead of it, so it is untouched by this stop.
        if futureDated { return false }

        // Test B: the strap's reported newest can latch a stale, wrong-epoch value. A strap that was
        // fully discharged, or that carries a previous owner's history, banks records across several
        // clock epochs and can answer with an old one, which reads as "already caught up" and stops
        // the drain after a single session. But guard 3 already proved the trim advanced, so a
        // session that ALSO persisted real rows is demonstrably still being served real backlog.
        // Empty and console-only ends persist nothing, so a stuck or caught-up strap still stops.
        return rowsPersistedThisSession > 0
    }
}

/// When continuous HRV capture is allowed to hold the dense realtime stream open.
///
/// Continuous capture normally keeps the R-R stream armed around the clock, which roughly doubles
/// what the feature costs in battery. Overnight is where the recovery and sleep value is, so the
/// opt-in "overnight only" mode arms it inside a nightly window and lets daytime stress readings be
/// sparser instead.
///
/// The window reuses the app's quiet-hours preference verbatim: the same stored keys, the same
/// defaults, and the same wrap-aware membership. Minutes since LOCAL midnight keeps it DST-agnostic
/// the way quiet hours already is, because a DST jump moves the wall clock and leaves the window
/// definition alone.
///
/// The mode is composed from two booleans rather than stored, so nobody needs a migration:
///   continuous off                 stream never held open
///   continuous on, overnight off   armed around the clock
///   continuous on, overnight on    armed only inside the window
///
/// BLEManager re-derives this at every arm site instead of caching it. A cached want computed inside
/// the window and then acted on after a reconnect outside it would arm the flood at the wrong time
/// and hold it there until the next keep-alive tick noticed.
struct ContinuousHrvSchedule {
    /// The quiet-hours keys written by the notification settings, reused rather than duplicated.
    static let quietStartKey = "notif.quietStartMinutes"
    static let quietEndKey = "notif.quietEndMinutes"
    static let defaultStartMinutes = 22 * 60
    static let defaultEndMinutes = 7 * 60

    /// Is `minuteOfDay` inside `[startMin, endMin)`, where the window may cross midnight? Inclusive
    /// start, exclusive end, matching the quiet-hours membership everywhere else in the app.
    static func windowContains(_ minuteOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        if startMin <= endMin { return minuteOfDay >= startMin && minuteOfDay < endMin }
        return minuteOfDay >= startMin || minuteOfDay < endMin
    }

    /// Should the stream be held open at local wall-clock minute `minuteOfDay`?
    static func streamWanted(continuousHrv: Bool, overnightOnly: Bool,
                             minuteOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        guard continuousHrv else { return false }
        guard overnightOnly else { return true }
        return windowContains(minuteOfDay, startMin: startMin, endMin: endMin)
    }
}

// MARK: - BLEManager

/// The strap link: scan by service, connect, discover, bond, subscribe, reassemble frames, and route
/// them either to the live UI path or to the historical offload.
///
/// Main-actor isolated because it publishes straight into `LiveState` and because every caller in the
/// app (the root model, the alarm coordinator, the habit scheduler, the Live and pairing screens) is
/// already on the main actor. `NSObject` is for the CoreBluetooth delegates; `ObservableObject` is for
/// the pairing sheet, which observes the discovered-strap list directly.
///
/// None of this can run in the simulator, which has no Bluetooth. Behaviour here is verified against
/// real hardware, not against the test suite.
@MainActor
public final class BLEManager: NSObject, ObservableObject {

    // MARK: GATT identifiers

    static let customService   = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    static let whoop5Service   = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a")
    static let cmdWriteChar    = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // commands to the strap
    static let cmdNotifyChar   = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // command responses
    static let eventNotifyChar = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // events
    static let dataNotifyChar  = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // fragmented data
    /// The WHOOP 5/MG command characteristic. It takes the static CLIENT_HELLO that opens a session,
    /// where a WHOOP 4 instead bonds via a confirmed write on its own command characteristic.
    static let whoop5CmdWriteChar = CBUUID(string: "fd4b0002-cce1-4033-93ce-002d5875f58a")
    static let whoop5NotifyChars: [CBUUID] = [
        CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0004-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0007-cce1-4033-93ce-002d5875f58a"),
    ]
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateChar    = CBUUID(string: "2A37") // HR plus R-R, and it works before bonding
    static let batteryService   = CBUUID(string: "180F")
    static let batteryChar      = CBUUID(string: "2A19")

    /// iOS state restoration keys off this string. Changing it makes the system forget every existing
    /// install's restored central, so background reconnects stop happening until each user relaunches.
    static let restoreID = "com.openwhoop.ble.central"

    // MARK: Collaborators and published state

    public let state: LiveState
    private let router: FrameRouter
    private var collector: Collector?

    /// The strap's stable BLE identity, published so the app can persist it onto the active registry
    /// device. This manager never writes the registry itself; it only reports what it connected to.
    @Published public private(set) var connectedPeripheralUUID: String?
    /// Straps seen while the pairing sheet is presenting a scan, collected instead of auto-connected.
    /// Empty on the ordinary connect path.
    @Published public private(set) var discoveredWhoops: [(uuid: String, name: String, rssi: Int)] = []

    /// Which device id live samples are stored under. Seeded from init, then refined once in
    /// `bootstrapStore()` from the device registry before any write uses it.
    private(set) var deviceId: String
    /// The device-clock to wall-clock correlation from GET_CLOCK. nil until the reply lands.
    private(set) var clockRef: ClockRef?

    /// True when the selected strap is a 5/MG. The alarm coordinator reads this to decide whether the
    /// strap alarm is the experimental path, so it stops telling a 5/MG owner they are armed when the
    /// refusal below would have declined to arm them.
    var isWhoop5: Bool { selectedModel.deviceFamily == .whoop5 }

    // MARK: Historical offload

    private var backfiller: Backfiller?
    /// True while an offload session owns the inbound frames.
    private var backfilling = false
    /// When the last offload frame or completion arrived, driving the deep-packet cooldown. A deep
    /// record landing just after a session ends is that session's tail, not a live stream, and
    /// `backfilling` has already flipped false by then so nothing else can tell them apart.
    private var lastOffloadFrameAt: Date?
    /// How long after the last offload frame a deep record still counts as trailing history. Ten
    /// seconds comfortably covers the post-completion drain lull.
    static let deepPacketLiveCooldownSeconds: TimeInterval = 10
    /// How far back the inactivity nudge reads gravity on each completion. Four hours spans the
    /// threshold, the re-nudge cadence, and a separating active break.
    static let inactivityLookbackSeconds = 4 * 3600
    /// Safety net only: the strap reports data newer than ours AND our frontier has not moved for the
    /// window. The behind-gap is what keeps an off-wrist or caught-up strap from reading as stuck.
    private var stuckDetector = StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300)
    /// The newest record the strap says it holds, from GET_DATA_RANGE, refreshed each offload.
    private var strapNewestTs: Int?
    /// Fires when the strap goes silent mid-offload; re-armed by every offload frame.
    private var backfillTimeout: DispatchWorkItem?
    private var uploadTimer: DispatchSourceTimer?
    static let uploadIntervalSeconds = 30
    /// Re-runs the historical offload while connected. This is the primary metric source, not a
    /// once-per-connect catch-up: the strap's stored biometrics are re-offloaded on this cadence the
    /// same way the official app syncs. The rate limiter downstream is the real floor.
    private var backfillTimer: DispatchSourceTimer?
    static let backfillIntervalSeconds = 900
    /// Keep-alive: re-subscribe, re-arm realtime, poll battery, and bounce a link that has gone quiet.
    private var keepAliveTimer: DispatchSourceTimer?
    static let keepAliveIntervalSeconds = 30
    private var keepAliveTick = 0
    /// A service-filtered scan for the wrong family never finds a strap that is sitting right there,
    /// which is the whole of the "will not reconnect after an update" report. Rotate families after a
    /// short miss and persist whichever one actually advertises.
    private var scanFallbackWorkItem: DispatchWorkItem?
    static let scanFallbackDelaySeconds: TimeInterval = 8
    /// When any notification last arrived, feeding the liveness watchdog.
    private var lastDataAt = Date()
    /// A live screen is up and wants the realtime stream. One of the two inputs to the derived want.
    private var screenWantsRealtime = false
    /// The continuous-capture preference wants the stream held open with no screen visible. This is
    /// the RAW intent; the effective want is window-gated through `continuousCaptureWantsNow()`.
    private var keepRealtimeForData = false
    /// The derived want: a screen wants it, or continuous capture does. Recomputed only inside
    /// `reconcileRealtime()`.
    private var wantsRealtime = false
    /// What we last told the strap, so the toggle is sent on the edge rather than on every input
    /// change. Cleared on disconnect because the strap forgets the toggle across a connection.
    private var realtimeArmed = false
    private var marginalRadio = MarginalRadioDetector()
    private var postBondLoop = PostBondTimeoutLoopDetector()
    /// When the encrypted bond landed this connection, so a drop can be measured against it.
    private var bondedAt: Date?
    /// Bumped on every connect. CoreBluetooth REUSES the CBPeripheral object across reconnects, so an
    /// identity check cannot tell one continuous session from a later cycle of a reconnect loop; a
    /// deferred check captures this token and only acts if it is unchanged.
    private var connectGeneration = 0

    // Diagnostic counters for the connection test mode. They change nothing about connecting; every
    // site that reads them is gated on the mode BEFORE any string is built, so they cost a Date or an
    // Int to maintain and produce nothing at all when the mode is off.
    private var connectAttemptStartedAt: Date?
    /// Involuntary reconnects this run. An intentional disconnect ends the count.
    private var connReconnectCount = 0

    private var emptySyncTracker = EmptySyncTracker()
    private var whoop5EmptyOffload = Whoop5EmptyOffloadTracker()
    /// Skip the R10/R11 arm on this connection because the radio could not sustain it. Live HR then
    /// comes only from the standard profile. Set by the detector; cleared by a clean teardown or by
    /// the user explicitly re-asking for the stream.
    private var standardHRFallback = false
    /// When the realtime burst was armed this connection, so a drop can be measured against it.
    private var realtimeArmedAt: Date?
    /// Last offload attempt, persisted so the rate limiter survives a relaunch.
    static let backfillLastAtKey = "backfillLastAt"
    /// Stops a second offload starting on a same-process reconnect to the same strap.
    private var backfillStarted = false
    /// How many chained offloads have run on THIS connection. Cleared only once the continuation
    /// predicate proves we are caught up, never unconditionally on a completion: a strap that slices
    /// one deep offload into many completions would otherwise reset the cap on every slice and spin.
    private var consecutiveAutoContinues = 0
    /// The trim cursor as of the end of the previous session this connection, so the next exit can
    /// tell a session that moved the strap's cursor from one that froze.
    private var lastSessionEndTrim: UInt32?
    /// The connect handshake has run for this connection.
    ///
    /// `didWriteValueFor` re-fires on EVERY confirmed write, which includes the bond write, every
    /// offload request, and every chunk acknowledgement. Without this latch those re-entries re-blast
    /// hello and SET_CLOCK at the strap in the middle of an offload, and the strap stops serving
    /// history. That was the root cause of history never arriving on this platform.
    private var connectHandshakeDone = false
    /// A bounded raw-accelerometer capture is running; a second tap is a no-op until it ends.
    private var rawCaptureInFlight = false
    /// Frames waiting to be drained through the serial offload task, in arrival order.
    private var backfillFrameQueue: [[UInt8]] = []
    private var backfillDraining = false
    /// Small enough that the UI can paint between slices of a long drain.
    private static let backfillDrainBatchSize = 12

    /// Records 5/MG frames to a file for protocol mapping. Passive, opt-in, and a no-op for WHOOP 4.
    /// Lazy so it can share `state` after init.
    private lazy var puffinRecorder = PuffinFrameRecorder(state: state)

    /// Force the capture buffer to disk so an export targets a current file.
    public func flushPuffinCaptures() { puffinRecorder.flush() }

    // MARK: CoreBluetooth handles

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Pin connections to one strap. With it set, every other discovered WHOOP is ignored; with it
    /// nil, which is the only state a single-strap user is ever in, the first WHOOP found wins.
    private var preferredPeripheralUUID: UUID?
    /// The pairing sheet owns the central while this is true: discoveries populate the list instead of
    /// connecting. It must never overlap the ordinary connect flow.
    private var isPresentingScan = false
    /// Captured during state restoration and cleared on connect. Non-nil tells the powered-on handler
    /// to reconnect this specific peripheral rather than start a fresh scan.
    private var restoredPeripheral: CBPeripheral?
    private var cmdCharacteristic: CBCharacteristic?
    private var cmdNotifyCharacteristic: CBCharacteristic?
    private var eventNotifyCharacteristic: CBCharacteristic?
    private var dataNotifyCharacteristic: CBCharacteristic?
    private var heartRateCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    /// The 5/MG notify characteristics, remembered at discovery so they can be subscribed AFTER the
    /// bond. Subscribing them on an unauthenticated link is refused, and the refusal also wedges the
    /// bond itself.
    private var whoop5NotifyCharacteristics: [CBCharacteristic] = []
    private var reassembler = Reassembler()
    private var seq: UInt8 = 0
    private var didBond = false
    /// The 5/MG realtime toggle has been sent for this connection, so the post-bond callback re-firing
    /// on later confirmed writes does not re-send it.
    private var whoop5RealtimeArmed = false
    /// The once-per-connection latch for the 5/MG offload kick. Chunk acknowledgements re-enter the
    /// post-bond branch during an offload, and without this the offload request goes out again in the
    /// middle of the stream.
    private var whoop5SessionStarted = false
    /// Chunk acknowledgements can run into the thousands in one offload. Throttle their log lines so
    /// the strap log stays readable and the UI is not forced to scroll on every ack.
    private var historicalAckLogCounter = 0
    private var clockRequested = false
    /// The deep-data enable sequence has been sent for THIS bond. The strap forgets those flags across
    /// a disconnect, so the sequence has to be re-applied on every bond, exactly like the broadcast-HR
    /// flag beside it.
    private var deepDataApplied = false
    private var intentionalDisconnect = false
    /// Consecutive failed connects, driving the backoff ladder. Cleared by a successful connect. The
    /// disconnect path uses a flat delay instead, which is fine for an already-bonded drop.
    private var failedConnectAttempts = 0
    /// The last peripheral that reached a genuine encrypted bond this run. When a pinned strap keeps
    /// refusing but this one bonds, this is the strap the pin should follow.
    private var lastBondedPeripheralUUID: UUID?
    /// Consecutive bond refusals with no genuine bond in between. Accumulates ACROSS the reconnect
    /// loop and is cleared only by a bond, because every cycle of the loop is a disconnect.
    private var bondRefusalStreak = 0
    private var bondGiveUp = BondRefusalGiveUp()
    /// Auto-reconnect is paused because the strap keeps refusing to bond. The disconnect rescan and
    /// the failed-connect backoff both consult this and schedule nothing. Kept separate from
    /// `intentionalDisconnect` so a paused link still reports its state honestly instead of looking
    /// like a user teardown.
    private var autoReconnectPausedForBondLoop = false
    /// When the pause tripped, or when it was last probed. Drives the salvage probe's floor: a strap
    /// the user has since freed self-heals on the next foreground, while one still held costs at most
    /// one bounded attempt per window. Never persisted.
    private var bondLoopPausedAt: Date?
    private var foregroundSalvageObserver: NSObjectProtocol?
    /// Consecutive bond refusals on the CURRENTLY PINNED peripheral. A stale pin makes the connect
    /// path drop the strap that does bond and loop forever on the dead one.
    private var pinnedBondRefusals = 0
    /// Refusals on the pin before handing it to a strap that is bonding fine. Three, not one: a single
    /// refusal can be a transient race, three in a row while another strap bonds is unrecoverable.
    private let pinBondRefusalLimit = 3
    /// The strap a pin handoff is moving onto, cleared when it re-bonds. Gates the one-time identity
    /// re-publish that confirms the handoff downstream.
    private var readoptingTo: UUID?
    /// Which strap family to scan for and discover against. Hydrated from the persisted pick so a
    /// relaunch or a restore targets the right strap.
    private var selectedModel: WhoopModel = .persisted
    private var lastStandardHRLogAt: Date?

    /// The strap's OWN clock extrapolated to now: its RTC at the last GET_CLOCK plus elapsed time.
    /// Live-gesture freshness is judged in the strap's clock domain rather than wall time, so a real
    /// gesture reads as now and a replayed historical one reads as old no matter how stale the RTC is.
    /// Falls back to wall time before the correlation lands.
    private var strapClockNow: Int {
        let wallNow = Int(Date().timeIntervalSince1970)
        guard let ref = clockRef else { return wallNow }
        return ref.device + (wallNow - ref.wall)
    }

    // MARK: Initialization

    public init(state: LiveState, deviceId: String = "my-whoop") {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        // The store opens asynchronously, so it cannot be built here. bootstrapStore() runs once the
        // central reaches powered-on, which is strictly before any strap data can arrive.
        self.collector = nil
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        #if os(iOS)
        // The restore identifier is the whole of background reconnection: without it CoreBluetooth
        // never relaunches the app to deliver a restored state dictionary.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
        #else
        // Desktop has no background state restoration to identify.
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
        // An inbound event packet is a hint the strap has something to hand over; kick a rate-limited
        // catch-up rather than waiting for the periodic tick.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
        installForegroundSalvageProbe()
    }

    /// Test and preview initializer: takes a pre-built collector instead of opening a store.
    init(state: LiveState, deviceId: String = "my-whoop", collector: Collector?) {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        self.collector = collector
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        #if os(iOS)
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
        #else
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
        installForegroundSalvageProbe()
    }

    /// Open the store and build the collector and backfiller. Safe to call repeatedly; returns early
    /// once the collector exists.
    func bootstrapStore() async {
        guard collector == nil else { return }
        // Surface store-open failures rather than swallowing them. A silent failure here leaves the
        // backfiller nil forever, and the only visible symptom downstream is a "store not ready" tick
        // with no cause attached. On iOS a background reconnect that opens the data-protected store
        // while the device is locked throws, and logging the code is what proves that is what
        // happened; the periodic tick re-attempts, so it heals on unlock.
        let path: String
        do {
            path = try StorePaths.defaultDatabasePath()
        } catch {
            log("Backfill: bootstrap FAILED resolving DB path — \(error)")
            return
        }
        let store: StrapStore
        do {
            store = try await StrapStore(path: path)
        } catch {
            let ns = error as NSError
            log("Backfill: bootstrap FAILED opening store — \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
            return
        }
        // Take the device id from the registry's active row. Best-effort: an empty or unreadable
        // registry leaves the seeded id in place rather than failing the bootstrap.
        if let activeId = try? DeviceRegistryStore(dbQueue: store.registryWriter).activeDeviceId(),
           !activeId.isEmpty {
            self.deviceId = activeId
        }
        try? await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 4.0")
        // Raw frame capture is a research toggle and is off by default; without it the app is
        // decoded-only and never persists raw bytes.
        let enableRawCapture = UserDefaults.standard.bool(forKey: "enableRawCapture")
        collector = Collector(store: store, deviceId: deviceId,
                              enableRawCapture: enableRawCapture)
        // The store can finish bootstrapping after connect() has already chosen a family, since both
        // wait on powered-on. Apply the family configuration here too so whichever finishes last wins.
        configureCollectorFamily()
        backfiller = Backfiller(store: store, deviceId: deviceId,
                                ackTrim: { [weak self] trim, endData in
                                    self?.ackHistoricalChunk(trim: trim, endData: endData)
                                },
                                enableRawCapture: enableRawCapture,
                                log: { [weak self] s in self?.log(s) },
                                rejectedSink: { [weak self] frames, trim, family in
                                    self?.archiveRejectedFrames(frames, trim: trim, family: family) ?? true
                                },
                                onChunk: { [weak self] decoded, console in
                                    if decoded { self?.state.decodedChunksThisSession += 1 }
                                    if console { self?.state.consoleChunksThisSession += 1 }
                                },
                                connectionActive: { TestCentre.active(.connection) },
                                connectionLog: { [weak self] s in self?.state.append(log: s, domain: .connection) },
                                firmwareLayout: { [weak self] v in self?.state.setStrapFirmwareLayout(v) })

        // When the decoder learns a new historical layout, every archived undecodable frame gets
        // another pass. This is the ONLY path by which already-acked history can still be recovered,
        // because the strap has long since freed its copy. Run once per app version so there is no
        // decoder-version constant to forget to bump; re-running is harmless because rows dedupe by
        // timestamp and the archive is small.
        let replayKey = "rejectArchiveReplayedAppVersion"
        if UserDefaults.standard.string(forKey: replayKey) != AppChangelog.currentVersion {
            do {
                let rows = try await rejectedHistoryArchive.replay(into: store, deviceId: deviceId)
                if rows > 0 { log("Backfill: retro-decoded \(rows) record(s) from the reject archive after an update.") }
                // Advance the gate ONLY on success. The archive holds the only surviving copy of these
                // records, so a failed insert has to be retried next launch rather than marked done.
                UserDefaults.standard.set(AppChangelog.currentVersion, forKey: replayKey)
            } catch {
                log("Backfill: reject-archive retro-decode deferred (store insert failed) — will retry next launch.")
            }
        }

        // The battery runtime estimate is fed only by live events, so after a reconnect it restarted
        // from an empty buffer and ignored the discharge history already on disk. Seed it from the
        // persisted series. The setter de-dupes against points already banked this session, so a seed
        // that races the first live reading is safe; rows with no state of charge are dropped because
        // the buffer is non-optional, and a read failure just leaves the estimate cold-starting.
        let seedNow = Int(Date().timeIntervalSince1970)
        let fourteenDays = 14 * 24 * 3600
        if let rows = try? await store.batterySamples(
            deviceId: deviceId, from: seedNow - fourteenDays, to: seedNow, limit: 2000) {
            let seed = rows.compactMap { row -> (ts: Int, soc: Double)? in
                guard let soc = row.soc else { return nil }
                return (ts: row.ts, soc: soc)
            }
            state.seedBatterySamples(seed)
        }
    }

    // MARK: Connect and disconnect

    /// The USER asked to connect: the Connect button, the scan flow, the pairing sheet.
    ///
    /// This is the only entry that re-arms a bond-refusal give-up, because a user gesture is an
    /// explicit "try again" and usually follows them actually freeing the strap. Every system-initiated
    /// path must go through `connectFromSystem()` instead. When both shared one entry point, every
    /// powered-on event (a Bluetooth toggle, a daemon restart) silently un-paused the give-up and
    /// re-ran the full refusal hammer, one burst per event, forever.
    public func connect(model: WhoopModel = .persisted) {
        if autoReconnectPausedForBondLoop {
            bondGiveUp.reset()
            autoReconnectPausedForBondLoop = false
            bondLoopPausedAt = nil
        }
        connectCore(model: model)
    }

    /// The SYSTEM asked to connect. Identical to `connect()` except that it never clears the give-up.
    ///
    /// While paused this makes at most one bounded attempt: a refusal during it cannot write a second
    /// epitaph, because the give-up has latched and `recordRefusal()` returns false, and the paused
    /// disconnect path schedules nothing afterwards, so the hammer cannot restart. A genuine bond still
    /// resets everything through the normal bond path, so a strap freed since the give-up self-heals.
    func connectFromSystem(model: WhoopModel = .persisted) {
        connectCore(model: model)
    }

    private func connectCore(model: WhoopModel) {
        intentionalDisconnect = false
        connectAttemptStartedAt = Date()
        selectedModel = model
        // A 5/MG runs far longer than a 4.0, so point the battery estimator's rated-life fallback at
        // the family we are about to connect. Without this the Today badge always assumed a 4.0.
        state.batteryRatedHours = model.deviceFamily == .whoop5
            ? BatteryEstimator.ratedLifeHoursWhoop5 : BatteryEstimator.ratedLifeHoursWhoop4
        // Frame the inbound stream for this family and tell the router which decoder to use. Fresh per
        // connection so no partially-reassembled bytes from a previous family carry over.
        reassembler = Reassembler(family: model.deviceFamily)
        router.family = model.deviceFamily
        configureCollectorFamily()
        guard central.state == .poweredOn else {
            log("Bluetooth not powered on (state=\(central.state.rawValue)); cannot scan yet")
            return
        }
        // Reuse the held peripheral ONLY when it is the strap we are pinned to. Without the pin check
        // a strap switch reattached to the previously-held strap and ignored the newly-selected one:
        // the registry said one thing and the radio did another. With no pin this is always true.
        if let p = peripheral, p.state == .connected, isPreferredPeripheral(p) {
            state.connected = true
            p.delegate = self
            log("Already connected to \(model.displayName) — refreshing services and notifications")
            discoverPrimaryServices(on: p)
            enableLiveNotifications(reason: "manual refresh")
            return
        }
        // Straps this family already has open at the OS level. CoreBluetooth keeps a bonded strap
        // connected across app sessions, and adopting whichever one the OS had open bypassed the scan,
        // which is the only place the pin was read, so a switch could never move off the wrong strap.
        // With a pin: drop every other open WHOOP so it stops holding the link, and attach only to the
        // pinned one. With no pin: first wins.
        let existing = central.retrieveConnectedPeripherals(withServices: [model.scanService])
        if preferredPeripheralUUID != nil {
            for other in existing where !isPreferredPeripheral(other) {
                log("Dropping non-active WHOOP connection \(other.identifier) — not the selected strap")
                central.cancelPeripheralConnection(other)
            }
        }
        if let p = existing.first(where: { isPreferredPeripheral($0) }) {
            log("Found existing \(model.displayName) connection \(p.identifier) — attaching")
            preparePeripheral(p)
            // Open OUR OWN session even though CoreBluetooth reports the strap connected. An LE link is
            // shared system-wide on Apple platforms, so a strap held by the official app, a previous
            // session, or the OS itself reads as connected while this process has no session at all.
            // Flipping the connected flag and jumping straight to discovery there produced a UI that
            // claimed "connected" while nothing ever arrived. Routing through connect() fires the
            // connect callback almost immediately for an already-open peripheral, which runs the real
            // discover, bond and notify flow and only reports connected once our link is genuinely up.
            central.connect(p, options: nil)
            return
        }
        // Pinned to a strap that is not already open: connect it by identifier. A scan would let any
        // in-range WHOOP satisfy it, and a targeted retrieve can only return the strap we asked for.
        if let preferred = preferredPeripheralUUID,
           let p = central.retrievePeripherals(withIdentifiers: [preferred]).first {
            log("Connecting to selected strap \(preferred) — targeted")
            preparePeripheral(p)
            central.connect(p, options: nil)
            return
        }
        startScan(for: model, allowFallback: true)
    }

    public func disconnect() {
        intentionalDisconnect = true
        cancelScanFallback()
        // A user teardown is a clean slate. Every accumulated suspicion clears so the next manual
        // connect starts fresh rather than inheriting a fallback or a pause it cannot see.
        marginalRadio.reset()
        postBondLoop.reset()
        bondGiveUp.reset()
        autoReconnectPausedForBondLoop = false
        bondLoopPausedAt = nil
        state.reconnectGuide = nil
        readoptingTo = nil
        standardHRFallback = false
        state.standardHRMode = nil
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        central.stopScan()
    }

    /// Fully RELEASE a strap when the user removes it from the devices screen.
    ///
    /// Archiving the registry row alone left the strap connected, because the reconnect timer, the
    /// targeted-connect pin, and state restoration all still pointed at it. It stayed connected, and a
    /// connected WHOOP cannot show its pairing LEDs, so the user could never put it into pairing mode
    /// to re-pair it. Stop auto-reconnect, drop the link, and clear every reference that targets it.
    public func forgetDevice(_ peripheralId: String?) {
        let target = peripheralId.flatMap { UUID(uuidString: $0) }
        let isCurrent = target == nil || peripheral?.identifier == target
        intentionalDisconnect = true            // defuses the disconnect-then-reconnect timer's guard
        cancelScanFallback()
        readoptingTo = nil
        // Clear the targeting pin and the restoration peripheral if either points at this strap, so
        // neither the connect path nor a restore can re-target it.
        if target == nil || preferredPeripheralUUID == target { setPreferredPeripheral(nil) }
        if target == nil || restoredPeripheral?.identifier == target { restoredPeripheral = nil }
        if isCurrent, let p = peripheral {
            central.cancelPeripheralConnection(p)
            peripheral = nil
            resetCharacteristics()
            state.connected = false
            state.bonded = false
            state.encryptedBond = false
            state.pairingHint = nil
            bondRefusalStreak = 0
        }
        // Releasing a strap fully resets the give-up and the pause, so a paused state can never
        // outlive the strap it belonged to and wedge a later re-add of a different one.
        bondGiveUp.reset()
        autoReconnectPausedForBondLoop = false
        bondLoopPausedAt = nil
        central.stopScan()
        log("Device removed — released the strap: stopped auto-reconnect, dropped the link, cleared targeting. Put it in pairing mode (blue LEDs) to re-pair if you want it back.")
    }

    /// Drop the current strap and clear the STICKY bond state before switching models.
    ///
    /// `bonded` deliberately survives an ordinary disconnect, because it means "this strap is paired".
    /// That left a user who owns both a WHOOP 4 and a 5/MG unable to switch: the flag stayed true from
    /// the first strap, which hid the picker and kept the scan pointed at the old family's service.
    public func prepareForModelSwitch() {
        disconnect()
        state.connected = false
        state.bonded = false
        state.encryptedBond = false
    }

    /// Idle the engine before presenting a pairing scan, but only when we are not already connected to
    /// a strap of the same family.
    ///
    /// Opening the scan must not tear down a live bonded same-family link: a 5/MG that has just bonded
    /// refuses the encrypted re-bond on the way back in and then loops. A genuine family switch, or
    /// nothing connected, still idles so the scan starts clean; the connect path reuses a live
    /// same-family peripheral on its refresh branch.
    public func prepareForPresentScan(model: WhoopModel) {
        if state.connected, selectedModel.deviceFamily == model.deviceFamily {
            log("Add-a-WHOOP scan: keeping the live \(selectedModel.displayName) connection — presenting nearby straps without dropping it")
            return
        }
        prepareForModelSwitch()
    }

    // MARK: Bond-loop salvage probe

    /// Minimum time since the pause tripped, or since the last probe, before another probe may fire.
    /// Long enough that a still-held strap sees a handful of bounded attempts a day, short enough that
    /// a strap the user freed reconnects the next time they naturally open the app.
    static let bondLoopSalvageFloorSeconds: TimeInterval = 10 * 60

    /// Probe only while the pause is latched, with no live link, no user teardown in force, and at
    /// least the floor elapsed. A nil elapsed time means there is no trip timestamp, which means never
    /// probe rather than probe now.
    nonisolated static func shouldSalvageProbe(pausedForBondLoop: Bool,
                                               connected: Bool,
                                               intentionalDisconnect: Bool,
                                               secondsSincePauseTripped: TimeInterval?) -> Bool {
        guard pausedForBondLoop, !connected, !intentionalDisconnect else { return false }
        guard let s = secondsSincePauseTripped else { return false }
        return s >= bondLoopSalvageFloorSeconds
    }

    /// Classify a "the strap refused the encrypted bond" error by its ATT CODE first.
    ///
    /// Foundation LOCALIZES CoreBluetooth error strings, so a description match on the English words
    /// silently never fires on a non-English device: no pairing hint, no give-up, no pin handoff, just
    /// the futile reconnect loop with nothing explaining it. The code check is the locale-proof route.
    /// The string match stays as an ADDITIVE fallback because some paths surface plain errors outside
    /// the CoreBluetooth domains, and removing it would regress detection on English devices.
    nonisolated static func isInsufficientAuthError(_ error: Error) -> Bool {
        if let att = error as? CBATTError,
           att.code == .insufficientEncryption || att.code == .insufficientAuthentication {
            return true
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("encryption") || text.contains("authentication")
    }

    /// One bounded attempt while the pause is latched, fired on app foreground.
    ///
    /// This is what makes the give-up provably unable to strand a strap the user has since freed: a
    /// genuine bond on the probe fully resets the pause through the normal bond path, while a strap
    /// still refusing costs one attempt per foreground per floor window and never re-enters the hammer
    /// loop. Re-stamps the pause timestamp so back-to-back foregrounds cannot chain probes.
    func salvageProbeIfBondLoopPaused(now: Date = Date()) {
        let since = bondLoopPausedAt.map { now.timeIntervalSince($0) }
        guard BLEManager.shouldSalvageProbe(pausedForBondLoop: autoReconnectPausedForBondLoop,
                                            connected: state.connected,
                                            intentionalDisconnect: intentionalDisconnect,
                                            secondsSincePauseTripped: since) else { return }
        bondLoopPausedAt = now
        log("Bond-loop pause: one salvage probe (the strap may have been freed since the give-up) - the give-up stays latched")
        connectFromSystem()
    }

    /// Observe the app-foreground notification and run the probe. Installed once per manager from init
    /// so the probe needs no per-scene wiring.
    private func installForegroundSalvageProbe() {
        #if os(iOS) || os(macOS)
        #if os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #else
        let name = NSApplication.didBecomeActiveNotification
        #endif
        foregroundSalvageObserver = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.salvageProbeIfBondLoopPaused() }
        }
        #endif
    }

    // MARK: Multi-strap pinning

    /// Pin connections to one strap by its peripheral identifier, or pass nil to clear the pin and go
    /// back to connecting to the first WHOOP discovered. An unparseable string clears the pin rather
    /// than wedging the scan on a value nothing can match.
    public func setPreferredPeripheral(_ uuidString: String?) {
        let resolved = uuidString.flatMap { UUID(uuidString: $0) }
        // A genuinely NEW pin starts the refusal streak clean, because the old streak belonged to a
        // different strap. Re-applying the SAME pin, which is the common no-op when the active device
        // has not changed, preserves the count in progress. A pin change to anything other than the
        // in-flight handoff target also abandons that handoff, since the target just moved.
        if resolved != preferredPeripheralUUID {
            pinnedBondRefusals = 0
            if resolved != readoptingTo { readoptingTo = nil }
        }
        preferredPeripheralUUID = resolved
    }

    /// True when this is the pinned strap, or when there is no pin at all so any WHOOP is acceptable.
    /// The attach and reconnect paths consult this so they cannot adopt the wrong already-connected
    /// strap while the registry points somewhere else.
    private func isPreferredPeripheral(_ p: CBPeripheral) -> Bool {
        guard let preferred = preferredPeripheralUUID else { return true }
        return p.identifier == preferred
    }

    /// A strap reached a genuine encrypted bond. Remember it as the live working candidate and clear
    /// the pin-refusal streak, since a healthy bond proves the current path works and a later transient
    /// refusal should start counting from zero.
    ///
    /// If this is the strap a handoff is moving onto, confirm the handoff downstream by republishing
    /// its identity WHILE the encrypted-bond flag is true. That combination is the only signal that
    /// distinguishes a vetted re-adoption from the ordinary pre-bond publish on connect.
    private func noteGenuineBond(of p: CBPeripheral) {
        lastBondedPeripheralUUID = p.identifier
        pinnedBondRefusals = 0
        if readoptingTo == p.identifier {
            readoptingTo = nil
            log("Multi-WHOOP: working strap bonded — confirming re-adoption to the registry.")
            // Publish nil FIRST. The downstream subscriber de-duplicates, so republishing the same uuid
            // that was already last-connected would be swallowed and the re-adoption would never land.
            // The nil emission itself is ignored downstream by its own uuid guard.
            connectedPeripheralUUID = nil
            connectedPeripheralUUID = p.identifier.uuidString
        }
    }

    /// The pinned strap keeps refusing the bond while a DIFFERENT strap bonds fine, so the pin is
    /// stale and is making the connect path abandon the strap that actually works. Move the pin onto
    /// the working strap and reconnect, so that once it re-bonds the registry re-adopts it.
    private func readoptWorkingStrap(_ working: UUID, awayFrom stalePin: UUID) {
        log("Multi-WHOOP: pinned strap refused the bond \(pinnedBondRefusals)× but another strap is bonded — handing the pin off to the working strap.")
        preferredPeripheralUUID = working
        pinnedBondRefusals = 0
        readoptingTo = working
        // The stale pin is what made us drop the working strap, so reconnect with the corrected pin.
        // If it somehow still is the held and bonded peripheral, confirm the handoff straight away.
        if let p = peripheral, p.identifier == working, p.state == .connected, state.encryptedBond {
            noteGenuineBond(of: p)
        } else if !intentionalDisconnect {
            connect(model: selectedModel)
        }
    }

    /// Re-point which device id live samples are stored under when the active strap changes.
    ///
    /// Sets this manager's id and re-points the in-flight collector and backfiller, so the very next
    /// flush, standard-HR persist, or historical chunk attributes to the new id without waiting for a
    /// relaunch. Both read their mutable id at persist time, so updating it here is sufficient. The
    /// single-strap path never calls this and keeps the id the bootstrap seeded.
    public func setActiveDeviceId(_ id: String) {
        guard !id.isEmpty else { return }
        deviceId = id
        collector?.deviceId = id
        backfiller?.deviceId = id
    }

    // MARK: Present-scan

    /// Scan the selected family's service and surface every nearby strap WITHOUT connecting to any of
    /// them. Duplicates are allowed so the signal readout refreshes as straps move. The caller owns
    /// the central until it calls `stopWhoopScan()`, and this touches no bond or peripheral state.
    public func scanForWhoops() {
        guard central.state == .poweredOn else {
            log("Add-a-WHOOP scan: Bluetooth not powered on (state=\(central.state.rawValue))")
            return
        }
        cancelScanFallback()            // a family rotation must not fire during a present-scan
        isPresentingScan = true
        discoveredWhoops = []
        central.stopScan()
        central.scanForPeripherals(
            withServices: [selectedModel.scanService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        log("Add-a-WHOOP scan: presenting nearby \(selectedModel.displayName) straps")
    }

    /// End the present-scan and return discovery to its ordinary connect behaviour. Idempotent.
    public func stopWhoopScan() {
        guard isPresentingScan else { return }
        isPresentingScan = false
        central.stopScan()
        log("Add-a-WHOOP scan: stopped")
    }

    // MARK: Storage surface

    /// Apply the raw-outbox retention policy. No-op without a store.
    public func pruneRaw() {
        Task { @MainActor in await collector?.prune() }
    }

    /// Light storage summary for the UI. nil without a store.
    public func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        await collector?.storageStats()
    }

    /// Push the collector's in-memory buffers into the store so a backup taken right now contains
    /// them. False means a write failed and rows are still buffered, so the backup should be refused
    /// rather than shipped short. No collector is vacuously true: nothing is buffered, so nothing can
    /// be lost.
    public func drainForBackup() async -> Bool {
        await collector?.drainForBackup() ?? true
    }

    /// Capture raw accelerometer frames for a bounded window, then stop.
    ///
    /// Persists raw bytes even when the always-on research toggle is off, which is the entire point of
    /// an on-demand capture. The collector's own window expires at its deadline, so a dropped stop
    /// cannot leak raw capture indefinitely.
    public func captureRawAccel(seconds: TimeInterval = 30) {
        guard !rawCaptureInFlight else {
            log("Raw-accel capture: already in flight — ignoring")
            return
        }
        rawCaptureInFlight = true
        let secs = RawCaptureWindow.clamp(seconds)
        collector?.beginRawCapture(seconds: secs)
        send(.startRawData, payload: [0x01])
        send(.toggleIMUMode, payload: [0x01])
        log("Raw-accel capture: started for \(secs)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self else { return }
            // Only stop the raw stream when the always-on toggle is OFF. With it on the continuous
            // stream must keep running, so this just flushes the bounded window we captured rather
            // than halting the wider session.
            if !UserDefaults.standard.bool(forKey: "enableRawCapture") {
                self.send(.stopRawData, payload: [0x01])
            }
            self.rawCaptureInFlight = false
            Task { @MainActor in
                await self.collector?.endRawCapture()
            }
            self.log("Raw-accel capture: stopped + flushed")
        }
    }

    // MARK: Command channel

    /// Write one command to the strap.
    ///
    /// Defaults to an unacknowledged write so existing call sites are unaffected; pass `.withResponse`
    /// for anything whose completion matters, such as a chunk acknowledgement.
    public func send(_ command: WhoopCommand, payload: [UInt8] = [0x00],
                     writeType: CBCharacteristicWriteType = .withoutResponse) {
        // Writing to a peripheral that is no longer connected is a silent no-op here rather than a
        // crash, and the powered-off handler publishes a disconnected state, so the UI cannot show a
        // stale-connected link either.
        guard state.connected, let p = peripheral, p.state == .connected, let ch = cmdCharacteristic else {
            let reason = state.connected ? "command characteristic unavailable" : "not connected"
            log("send(\(command.label)) ignored — \(reason)")
            return
        }
        // A 5/MG speaks a different framing entirely. The realtime toggle is hardware-confirmed on it,
        // which proves the strap acts on commands in that framing, and haptics plus the firmware-alarm
        // family now ride the same proven transport. Everything else is dropped rather than guessed at.
        if selectedModel.deviceFamily == .whoop5 {
            // This allowlist is a SAFETY BOUNDARY, not a convenience filter. The two config commands
            // write persistent flags into the strap, so each is admitted only while its own opt-in is
            // on and must never fire on a default install. The clock pair is mandatory before history:
            // an un-clocked 5 does not save sensor data to flash at all, so offloads complete carrying
            // metadata and nothing else.
            guard command == .toggleRealtimeHR || command == .runHapticsPattern
                || command == .setAlarmTime || command == .getAlarmTime
                || command == .runAlarm || command == .disableAlarm
                || command == .sendHistoricalData || command == .historicalDataResult
                || command == .setClock || command == .getClock
                || (command == .setConfig && PuffinExperiment.deepDataEnabled)
                || (command == .setDeviceConfig && PuffinExperiment.broadcastHrEnabled) else {
                log("send(\(command.label)) skipped — no WHOOP 5/MG framing for this command yet")
                return
            }
            // 5/MG haptics differ from WHOOP 4 on BOTH the opcode and the body. A capture showed the
            // strap rejecting the 4.0 opcode outright, and the body is a waveform preset rather than a
            // pattern id and loop count. The framing pads the inner payload to a four-byte boundary,
            // which this twelve-byte body relies on. WHOOP 4 keeps its own opcode and its own frame.
            let isHaptics = command == .runHapticsPattern
            let puffinCmd: UInt8 = isHaptics ? 0x13 : command.rawValue
            let puffinPayload: [UInt8] = isHaptics ? [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 0] : payload
            seq = seq &+ 1
            let frame = puffinCommandFrame(cmd: puffinCmd, seq: seq, payload: puffinPayload)
            p.writeValue(Data(frame), for: ch, type: writeType)
            let cmdNote = isHaptics ? " cmd=0x13" : ""
            if command == .historicalDataResult {
                historicalAckLogCounter += 1
                if historicalAckLogCounter == 1 || historicalAckLogCounter.isMultiple(of: 25) {
                    log("→ \(command.label) ack #\(historicalAckLogCounter) payload=\(hex(puffinPayload)) (puffin)")
                }
                return
            }
            log("→ \(command.label) payload=\(hex(puffinPayload)) (puffin\(cmdNote))")
            return
        }
        seq = seq &+ 1
        let frame = command.frame(seq: seq, payload: payload)
        p.writeValue(Data(frame), for: ch, type: writeType)
        log("→ \(command.label) payload=\(hex(payload))")
    }

    /// Point the collector's decode at the selected family.
    ///
    /// A 5/MG also gets an identity clock reference, because its live timestamps are already real unix
    /// seconds so the conversion must be a no-op. A WHOOP 4 takes this manager's correlation instead,
    /// which is nil until GET_CLOCK lands. Assigning it either way also EVICTS a stale identity
    /// reference a previous 5/MG session installed, which would otherwise stamp WHOOP 4 device-epoch
    /// frames as if they were wall-clock. Idempotent, and called from both the connect path and the
    /// store bootstrap so it lands whichever finishes last.
    private func configureCollectorFamily() {
        collector?.family = selectedModel.deviceFamily
        if selectedModel.deviceFamily == .whoop5 {
            let now = Int(Date().timeIntervalSince1970)
            collector?.clockRef = ClockRef(device: now, wall: now)
        } else {
            collector?.clockRef = clockRef
        }
    }

    /// Refresh the battery reading. The SOURCE is family-specific and the split is load-bearing.
    ///
    /// On a WHOOP 4 the standard characteristic is a stub that always reports 100, and the real charge
    /// only arrives in the proprietary command's response. Reading both flashed a false full charge
    /// before the true value corrected it, and an unsolicited stub notification could revert a real
    /// reading back to 100. So a 4 uses only the command, and a 5/MG uses only the characteristic.
    public func refreshBattery() {
        guard state.connected, let p = peripheral, p.state == .connected else {
            log("refreshBattery ignored — not connected")
            return
        }

        if selectedModel.deviceFamily == .whoop4 {
            send(.getBatteryLevel, payload: [0x00])
            return
        }

        if let batteryCharacteristic {
            if batteryCharacteristic.properties.contains(.read) {
                p.readValue(for: batteryCharacteristic)
                log("Reading standard Battery Level")
            } else {
                log("Battery Level read unavailable; waiting for notifications")
            }
        } else {
            log("Battery Level characteristic unavailable")
        }
    }

    /// Confirm one chunk so the strap may reuse that flash.
    ///
    /// The acknowledgement echoes the chunk's end metadata verbatim; the trim value is already
    /// persisted as the cursor by the backfiller and is carried here only for logging.
    func ackHistoricalChunk(trim: UInt32, endData: [UInt8]) {
        // THIS is the write that destroys data: acknowledging is what makes the strap discard the
        // chunk, permanently, for every client. A build without history authority must never send one.
        // Unreachable in practice because starting an offload refuses first, but gated directly here
        // because this is the irreversible step.
        guard BuildPolicy.hasHistoryAuthority else {
            log("Ack suppressed — no history authority (\(BuildPolicy.historyAuthorityReason)); the strap keeps its backlog.")
            return
        }
        send(.historicalDataResult, payload: [0x01] + endData, writeType: .withResponse)
        // Progress for the syncing indicator. Deliberately NOT the ack log counter, which is a
        // write-throttle for the 5/MG path and never increments on a WHOOP 4.
        state.syncChunksThisSession += 1
    }

    // MARK: Offload session

    /// Start a historical offload: tell the store machine to begin, take the routing flag, request the
    /// offload, and arm the idle watchdog.
    @discardableResult
    private func beginBackfill() -> Bool {
        // Never offload before the handshake has run. A foreground or restore trigger racing ahead of
        // hello and SET_CLOCK was part of the write storm that stopped the strap serving history.
        guard connectHandshakeDone else {
            log("Backfill: deferred — connect handshake not done yet")
            return false
        }
        // The offload is a DESTRUCTIVE read: acknowledging a chunk makes the strap discard it for
        // every client. Builds without authority stay read-only so a development build cannot eat the
        // nights the user's real install has not synced yet.
        guard BuildPolicy.hasHistoryAuthority else {
            log("Backfill: refused — no history authority (\(BuildPolicy.historyAuthorityReason))")
            return false
        }
        guard let backfiller else {
            // The store is not built. Do NOT fall back to forcing live HR, because the offload is the
            // metric source. Re-attempt the bootstrap here so a transient first-open failure heals: on
            // iOS the data-protected store is unreadable while the phone is locked, so a background
            // reconnect's bootstrap can fail and, with no retry, stay dead for the life of the process.
            // The bootstrap guards on the collector already existing, so this is free once it is up.
            log("Backfill: store not ready — re-attempting bootstrap, will retry next tick")
            Task { @MainActor in await self.bootstrapStore() }
            return false
        }
        // Capture the family at begin rather than at init: the connect path reliably sets it before any
        // offload starts, whereas the bootstrap can build the backfiller before the family is known.
        backfiller.begin(family: selectedModel.deviceFamily)
        backfilling = true
        state.backfilling = true
        state.syncChunksThisSession = 0
        state.rejectedFramesThisSession = 0
        state.rejectedFramesUnarchived = 0
        state.decodedChunksThisSession = 0
        state.consoleChunksThisSession = 0
        state.r22FlagsAccepted = 0
        state.deepPacketsThisSession = 0
        historicalAckLogCounter = 0
        // The payload MUST be a single zero byte, not empty. Verified on hardware: with an empty
        // payload the strap serves zero frames on a stable link with thousands of records pending.
        send(.sendHistoricalData, payload: [0x00], writeType: .withResponse)
        armBackfillTimeout()
        log("Backfill: session started — historical offload requested")
        return true
    }

    /// Queue a frame for the offload, preserving arrival order exactly.
    ///
    /// Frames are appended synchronously from the delegate and drained in small slices, so chunk
    /// assembly can never be reordered while the UI still gets time to paint between slices.
    private func routeBackfillFrame(_ frame: [UInt8]) {
        backfillFrameQueue.append(frame)
        guard !backfillDraining else { return }
        backfillDraining = true
        Task { @MainActor in await drainBackfillFrames() }
    }

    private func drainBackfillFrames() async {
        while !backfillFrameQueue.isEmpty {
            let count = min(Self.backfillDrainBatchSize, backfillFrameQueue.count)
            let batch = Array(backfillFrameQueue.prefix(count))
            backfillFrameQueue.removeFirst(count)

            for f in batch {
                await backfiller?.ingest(f)
                afterBackfillIngest()
                if !backfilling {
                    backfillFrameQueue.removeAll(keepingCapacity: true)
                    break
                }
            }

            if !backfillFrameQueue.isEmpty {
                await Task.yield()
            }
        }
        backfillDraining = false
    }

    /// Runs after every ingest: once the backfiller reports it has consumed everything, end the
    /// session cleanly rather than waiting for the watchdog.
    private func afterBackfillIngest() {
        guard backfilling, backfiller?.isBackfilling == false else { return }
        exitBackfilling(reason: "HISTORY_COMPLETE")
    }

    /// Is this frame part of the historical offload rather than the live stream?
    ///
    /// Two things here are load-bearing. The type byte sits at a DIFFERENT offset per family, because
    /// the 5/MG envelope is four bytes longer; reading the WHOOP 4 offset on a 5/MG frame misclassifies
    /// every offload frame as live traffic and routes nothing to the backfiller. And the live raw
    /// stream flows continuously and unprompted on this firmware, so it must never re-arm the idle
    /// watchdog: if it did, a session could neither complete nor time out.
    static func isOffloadFrame(_ frame: [UInt8], family: DeviceFamily) -> Bool {
        let typeIndex = family == .whoop5 ? 8 : 4
        guard frame.count > typeIndex else { return false }
        switch frame[typeIndex] {
        case 47, 48, 49, 50, 56: return true   // historical data, event, metadata, console logs
        default: return false                  // live realtime and raw frames
        }
    }

    /// How long the offload may go silent before the session ends.
    ///
    /// Generous on purpose. The unstoppable live raw flood eats airtime, so genuine offload frames
    /// arrive in bursts with multi-second lulls between chunks, and a short watchdog cut sessions short
    /// mid-drain. Longer means more records drained per session, and ending early is cheap anyway
    /// because the durable trim cursor means the next session resumes exactly where this one stopped.
    static let backfillIdleTimeoutSeconds = 60

    private func armBackfillTimeout() {
        backfillTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.backfiller?.timeoutFired()
            self.exitBackfilling(reason: "timeout")
        }
        backfillTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.backfillIdleTimeoutSeconds), execute: item)
    }

    /// Tear down the offload session and report its outcome honestly.
    ///
    /// Deliberately does NOT start live HR afterwards. The periodic offload is the primary metric
    /// source; live HR is opt-in. Between offloads the collector sees only the live raw flood, which
    /// the extractor ignores, and the data arrives with the next offload instead.
    private func exitBackfilling(reason: String) {
        guard backfilling else { return }
        backfilling = false
        state.backfilling = false
        // Start the deep-packet cooldown from this instant, so records the strap flushes in the seconds
        // after the session are attributed to the offload's tail rather than counted as a live stream.
        lastOffloadFrameAt = Date()
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        log("Backfill: session ended — reason=\(reason)")
        // The inactivity nudge is a read-only hook on a completion that was going to happen anyway, so
        // it changes no cadence. Only on a true completion: a timeout or a drop brought no fresh window.
        if reason == "HISTORY_COMPLETE" { maybeBuzzInactivity() }
        // Failures were logged and successes were not, so a strap log could not tell a banking strap
        // from a broken one. Emit the persistence tally whenever anything landed.
        if let bf = backfiller,
           let summary = Backfiller.sessionSummaryLine(rows: bf.sessionRowsPersisted, motion: bf.sessionMotionRows, skinTemp: bf.sessionSkinTempRows, nights: bf.sessionNights) {
            log(summary)
        }
        // Connection test mode: the offload outcome the readout binds to. Gated before any string is
        // built, and it reads the same tallies the summary above does, so it changes no behaviour.
        if TestCentre.active(.connection), let bf = backfiller {
            let rows = bf.sessionRowsPersisted
            let result: String
            if reason == "timeout" {
                result = "stalled (idle timeout, rows=\(rows) so far)"
            } else if reason == "HISTORY_COMPLETE" {
                result = rows > 0
                    ? "complete rows=\(rows) nights=\(bf.sessionNights)"
                    : "empty (console only, no sensor records)"
            } else {
                result = "\(reason) rows=\(rows)"
            }
            state.append(log: "offload result=\(result)", domain: .connection)
        }
        // This session's ingest gate dropped implausibly-dated records, which means the strap has a
        // wandering clock and may have banked similar garbage under an older build whose gate was
        // weaker. Arm a heal pass so the next analysis tick purges it. Deliberately not behind a
        // one-shot flag, since a strap can pollute again.
        if (backfiller?.sessionDroppedImplausible ?? 0) > 0 {
            IntelligenceEngine.requestTimestampReheal()
        }
        // Did THIS session move the strap's trim cursor? A frozen cursor means the strap is refusing to
        // trim, and re-kicking would spin forever burning battery, so the continuation predicate needs
        // this answer. Compare against where the cursor stood when the previous session ended.
        let currentTrim = backfiller?.lastAckedTrim
        let trimAdvanced = currentTrim != nil && currentTrim != lastSessionEndTrim
        lastSessionEndTrim = currentTrim
        // A completion stamps the sync time and clears any error; the idle watchdog surfaces a
        // non-silent one. A drop mid-sync bypasses this path entirely, because the disconnect handler
        // resets the flags directly. That is not a sync failure, and the next connect re-offloads.
        if reason == "HISTORY_COMPLETE" {
            state.lastSyncedAt = Date().timeIntervalSince1970
            // A sync that completed but discarded records must not read as a clean success. The wording
            // separates bytes saved on this device from bytes nothing could preserve, so "saved" is
            // never claimed falsely.
            let archived = state.rejectedFramesThisSession
            let unarchived = state.rejectedFramesUnarchived
            let banking = BLEManager.classifyCompletedOffload(
                decodedChunks: state.decodedChunksThisSession,
                archivedFrames: archived,
                unarchivedFrames: unarchived,
                consoleChunks: state.consoleChunksThisSession,
                rowsPersisted: backfiller?.sessionRowsPersisted ?? 0)
            let bankedSensorRecords = banking.bankedSensorRecords
            let bankedNothing = banking.bankedNothing
            let sustainedEmpty = emptySyncTracker.recordCompletedSync(
                bankedSensorRecords: bankedSensorRecords, consoleOnly: bankedNothing)
            if unarchived > 0 {
                state.lastSyncError = "Synced, but \(archived + unarchived) record(s) couldn't be decoded (unrecognised strap firmware layout), and the on-device archive is full - the \(unarchived) newest weren't preserved. Please share a strap log so the layout can be mapped."
            } else if archived > 0 {
                state.lastSyncError = "Synced, but \(archived) record(s) couldn't be decoded (unrecognised strap firmware layout). The raw bytes were saved on this Mac - please share a strap log so the layout can be mapped."
            } else if bankedNothing {
                // The offload completed but the strap handed over no sensor records at all, in either
                // shape: console output across many chunks, or a near-empty metadata-only completion.
                // Both mean it is not banking history to flash. Escalate to the actionable banner only
                // once that is SUSTAINED, so one empty cycle on an otherwise-healthy strap stays quiet.
                let detail = state.consoleChunksThisSession >= 3
                    ? "console-only across \(state.consoleChunksThisSession) chunks"
                    : "metadata-only, 0 sensor rows persisted"
                log("Backfill: completed but the strap banked no sensor history (\(detail)); consecutive empty syncs = \(emptySyncTracker.consecutiveEmptySyncs).")
                state.lastSyncError = sustainedEmpty
                    ? "Synced, but your strap had no stored history to hand over - only its diagnostic output. This usually means its clock has lost sync, so it isn't saving data to flash. Fully charge it to 100%, then reconnect, and it should start banking again."
                    : nil
            } else {
                state.lastSyncError = nil
            }
            // A 5/MG that reaches a real completion with banked records has proved its history offload
            // works, so drop the experimental note and the empty streak.
            if selectedModel.deviceFamily == .whoop5, bankedSensorRecords {
                whoop5EmptyOffload.reset()
                state.historySyncExperimental = false
            }
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
            // The auto-continue streak is NOT reset here. A completion no longer means "caught up": a
            // strap whose firmware slices a deep offload into many small completions would reset the
            // streak on every slice and never engage the per-connection cap. It is cleared only once
            // the continuation predicate proves we are genuinely caught up, below.
        } else if reason == "timeout" {
            // Separate a real WHOOP 4 "went quiet mid-sync" from a 5/MG whose firmware acknowledges the
            // request and then emits nothing. The 5/MG case is not a failure: live HR is streaming and
            // the history offload is simply not served. Progress means chunks acked, rows persisted, or
            // deep records seen; an empty 5/MG offload has none of the three.
            let bankedThisOffload = state.syncChunksThisSession > 0
                || (backfiller?.sessionRowsPersisted ?? 0) > 0
                || state.deepPacketsThisSession > 0
            if selectedModel.deviceFamily == .whoop5 {
                let crossed = whoop5EmptyOffload.recordOffload(bankedRecords: bankedThisOffload)
                if whoop5EmptyOffload.historyEmpty {
                    state.historySyncExperimental = true
                    state.lastSyncError = nil
                    if crossed {
                        log("Backfill: WHOOP 5/MG offload empty \(whoop5EmptyOffload.consecutiveEmpty)× — history sync is experimental on 5.0; surfacing 'connected, history experimental' (not a sync error) and backing off the bounce loop.")
                    }
                } else {
                    // Either the first empty cycle, which could just be the strap waking its flash, or a
                    // banking offload that has cleared the streak. Both want a clean, error-free state.
                    state.historySyncExperimental = false
                    state.lastSyncError = nil
                }
            } else {
                state.lastSyncError = "Sync interrupted - the strap went quiet. It will retry on the next sync."
            }
        }
        checkStrapLiveness()
        // Chain another offload when the strap is still connected, there is demonstrably more backlog,
        // and the trim is still advancing, rather than tearing down to wait the periodic floor. Fired
        // for a completion as well as a timeout because some straps slice a deep overnight offload into
        // many small completions and would otherwise stall between slices. The predicate's guards are
        // what make that safe: a genuinely caught-up strap returns false and stops, and that else path
        // is also where the streak is cleared.
        if reason == "timeout" || reason == "HISTORY_COMPLETE" {
            maybeAutoContinueBackfill(trimAdvanced: trimAdvanced,
                                      rowsPersisted: backfiller?.sessionRowsPersisted ?? 0)
        }
    }

    /// Decide whether to chain another offload, and fire it if so.
    ///
    /// The "more backlog remains" test needs our persisted frontier, which only the collector can read,
    /// so this hops onto a task. The decision itself stays in the pure predicate; this only gathers
    /// inputs, moves the counter, and re-kicks through the SAME gated entry point so the connection
    /// checks and the already-running check still apply.
    ///
    /// `trimAdvanced` is passed in rather than recomputed because the caller has already advanced the
    /// stored comparison point by the time this task runs.
    private func maybeAutoContinueBackfill(trimAdvanced: Bool, rowsPersisted: Int) {
        // Cheap checks first, so a decision we already know needs no task and no store read.
        guard state.connected, state.bonded else { return }
        let newest = strapNewestTs
        let count = consecutiveAutoContinues
        Task { @MainActor in
            let frontier = await collector?.latestHRSampleTs() ?? nil
            let wallNow = Int(Date().timeIntervalSince1970)
            let stillConnected = state.connected && state.bonded
            guard BackfillContinuation.shouldAutoContinue(
                stillConnected: stillConnected,
                strapNewestTs: newest,
                ourFrontierTs: frontier,
                wallNowUnix: wallNow,
                rowsPersistedThisSession: rowsPersisted,
                lastTrimAdvanced: trimAdvanced,
                consecutiveCount: count) else {
                // Name the stop when the future-clock gate is what ended the chain. Without this line
                // the log simply goes quiet after one pass and an export cannot tell "caught up" from
                // "the range was future-dated and refused". Fires only where the second test would
                // otherwise have continued, so a frozen trim, the cap, or a drop is never misattributed.
                if stillConnected, rowsPersisted > 0, trimAdvanced,
                   count < BackfillContinuation.defaultMaxAutoContinues,
                   BackfillContinuation.isFutureDatedNewest(newest, wallNowUnix: wallNow) {
                    let aheadH = ((newest ?? wallNow) - wallNow) / 3600
                    log("Backfill: not auto-continuing - the strap-reported newest banked record reads \(aheadH)h AHEAD of the wall clock, so the range is future-dated and the strap clock is likely wrong. Stopping after one pass instead of chasing future-dated ranges; the periodic sync keeps draining across connects.")
                }
                // No re-kick, so THIS is the real "done draining" signal: clear the streak so the next
                // deep backlog gets a fresh budget. Cleared here rather than on every completion, so a
                // strap that slices one offload into many completions cannot keep resetting the cap.
                //
                // Except when the CAP itself is what stopped us. Zeroing then would immediately re-arm
                // the cap and let a runaway strap spin again, so leave the streak engaged for the rest
                // of this connection and let the periodic floor take over.
                if count < BackfillContinuation.defaultMaxAutoContinues {
                    consecutiveAutoContinues = 0
                }
                return
            }
            // A real offload may already have restarted in the gap before this task ran. The gated
            // entry point handles that on its own; this just skips the log and counter churn.
            guard !backfilling else { return }
            consecutiveAutoContinues += 1
            log("Backfill: auto-continuing — the trim advanced and the strap is still handing over real records (frontier \(frontier.map(String.init) ?? "?"), strap-reported newest \(newest.map(String.init) ?? "?")); re-kicking offload \(consecutiveAutoContinues)/\(BackfillContinuation.defaultMaxAutoContinues) without waiting the 15-min floor.")
            // This trigger bypasses the periodic floor, which is the whole point. The connection checks
            // and the already-running check still run, and the cap above is the runaway guard.
            requestSync(.autoContinue)
        }
    }

    /// On-device archive for record frames that failed to decode.
    private let rejectedHistoryArchive = RawHistoryArchive()

    /// Durably archive undecodable record frames BEFORE the backfiller acknowledges the chunk.
    ///
    /// Once the strap frees its copy this archive is the user's ONLY remaining copy, and it is also the
    /// corpus a later layout mapping re-ingests. Returning false on a genuine write failure makes the
    /// backfiller hold the cursor so the strap re-sends the chunk, so no data is lost either way.
    /// Frames carry sensor payloads, not identifiers, so nothing identifying is archived.
    private func archiveRejectedFrames(_ frames: [[UInt8]], trim: UInt32, family: DeviceFamily) -> Bool {
        switch rejectedHistoryArchive.archive(frames, trim: trim, family: family) {
        case .written(let count):
            state.rejectedFramesThisSession += count
            return true
        case .capReached(let count):
            // Succeed WITHOUT writing. Wedging the offload over a full archive would be worse than
            // dropping samples we already have plenty of, but it is counted separately so the sync
            // status never claims to have saved bytes it did not.
            state.rejectedFramesUnarchived += count
            log("Backfill: rejected-frame archive is FULL — \(count) frame(s) NOT preserved (acking anyway so the offload can finish)")
            return true
        case .failed:
            log("Backfill: rejected-frame archive FAILED — holding ack so the strap re-sends")
            return false
        }
    }

    /// After an offload, judge whether the strap is stuck: it reports records newer than our frontier
    /// AND our frontier has not moved for the detector's window. Off-wrist or caught up is not stuck.
    /// On a stuck verdict, try the defensive recovery and raise the flag.
    private func checkStrapLiveness() {
        let strapNewest = strapNewestTs
        Task { @MainActor in
            let frontier = await collector?.latestHRSampleTs()
            let front: Int? = frontier ?? nil
            let now = Date().timeIntervalSince1970
            let stuck = stuckDetector.observe(strapNewestTs: strapNewest,
                                              ourFrontierTs: front,
                                              now: now)
            state.strapNeedsReboot = stuck
            if stuck {
                log("Watchdog: behind + frontier frozen — recovery (exit high-freq + SET_CLOCK)")
                send(.exitHighFreqSync, payload: [0x00])
                sendSetClockBothForms()
            }
        }
    }

    /// Should the periodic timer start another offload? Only while connected, bonded, and not already
    /// mid-offload. Deliberately does not consult the once-per-connect latch, which guards the initial
    /// kick rather than the periodic re-trigger.
    static func shouldRunPeriodicBackfill(connected: Bool, bonded: Bool, backfilling: Bool) -> Bool {
        connected && bonded && !backfilling
    }

    /// Classify a completed offload.
    ///
    /// `bankedSensorRecords` means real sensor records arrived, decoded or undecodable-but-archived;
    /// either way the strap's clock is banking to flash. `bankedNothing` means it completed carrying no
    /// sensor records in either shape: console output across several chunks, or a metadata-only
    /// completion that persisted nothing. That second arm matters because a metadata-only completion
    /// used to slip through silently. Whether the banner actually fires is still the streak's decision.
    nonisolated static func classifyCompletedOffload(decodedChunks: Int, archivedFrames: Int,
                                                     unarchivedFrames: Int, consoleChunks: Int,
                                                     rowsPersisted: Int)
        -> (bankedSensorRecords: Bool, bankedNothing: Bool) {
        let bankedSensorRecords = decodedChunks > 0 || archivedFrames > 0 || unarchivedFrames > 0
        let bankedNothing = !bankedSensorRecords && (consoleChunks >= 3 || rowsPersisted == 0)
        return (bankedSensorRecords, bankedNothing)
    }

    // MARK: Realtime stream

    /// A live screen wants the stream: enable notifications, start the heavy burst, and arm the toggle.
    ///
    /// Some firmware acknowledges the realtime toggle but only emits usable samples once the raw
    /// realtime stream is on too, so both go out here. That stream stays scoped to the live screen and
    /// stops on disappear, or it competes with the historical offload for airtime indefinitely.
    public func startRealtime() {
        screenWantsRealtime = true
        state.liveFeedActive = true
        // The user explicitly asked for the full stream, so give the heavy burst another chance even
        // if a marginal-radio fallback had tripped. If the radio still cannot take it the detector
        // simply trips again. This is SCREEN intent only: continuous capture is a passive background
        // want and deliberately does not clear the fallback.
        marginalRadio.reset()
        standardHRFallback = false
        state.standardHRMode = nil
        enableLiveNotifications(reason: "start realtime")
        send(.sendR10R11Realtime, payload: [0x01])
        reconcileRealtime()
        realtimeArmedAt = Date()       // starts the arm-to-drop stopwatch for the marginal-radio detector
    }

    /// The live screen went away. Always stop the heavy burst, which is the battery-hungry part and is
    /// only ever wanted while a screen is up. Whether the lightweight toggle also disarms is the
    /// reconciler's call, so a screen closing while continuous capture is on keeps the R-R stream.
    public func stopRealtime() {
        screenWantsRealtime = false
        state.liveFeedActive = false
        send(.sendR10R11Realtime, payload: [0x00])
        reconcileRealtime()
    }

    /// The continuous-capture preference changed: hold the stream open with no screen visible, or
    /// release it. Also called with an UNCHANGED preference when the overnight-only setting flips,
    /// purely to re-run the reconciler against the fresh window gate.
    public func setKeepRealtimeForData(_ keep: Bool) {
        keepRealtimeForData = keep
        reconcileRealtime()
    }

    /// The continuous-capture half of the want, window-gated. Re-derived at every arm site rather than
    /// cached, so a reconnect outside the window can never arm the flood from a stale value.
    private func continuousCaptureWantsNow(now: Date = Date()) -> Bool {
        guard keepRealtimeForData else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let d = UserDefaults.standard
        return ContinuousHrvSchedule.streamWanted(
            continuousHrv: true,
            overnightOnly: PuffinExperiment.continuousHrvOvernightOnlyEnabled,
            minuteOfDay: minuteOfDay,
            startMin: d.object(forKey: ContinuousHrvSchedule.quietStartKey) as? Int ?? ContinuousHrvSchedule.defaultStartMinutes,
            endMin: d.object(forKey: ContinuousHrvSchedule.quietEndKey) as? Int ?? ContinuousHrvSchedule.defaultEndMinutes)
    }

    /// The single owner of the realtime toggle.
    ///
    /// The stream should be armed while EITHER a screen wants it or continuous capture does. Sending
    /// the toggle only on the edge of that combined want is what makes a live screen closing while the
    /// preference still wants it a no-op, and turning the preference off with no screen open a genuine
    /// disarm. The toggle can only reach a WHOOP 4, whose channels open immediately, or a bonded 5/MG;
    /// otherwise the want is remembered and the post-bond branch arms it.
    private func reconcileRealtime() {
        let want = screenWantsRealtime || continuousCaptureWantsNow()
        wantsRealtime = want
        guard want != realtimeArmed else { return }
        guard selectedModel.deviceFamily == .whoop4 || state.bonded else { return }
        realtimeArmed = want
        send(.toggleRealtimeHR, payload: [want ? 0x01 : 0x00])
    }

    // MARK: Deep-data telemetry

    /// Track what the strap is actually doing with the deep-data flags, and count deep records
    /// honestly.
    ///
    /// Every command response to a config write is the strap acknowledging one flag, so counting them
    /// says whether the sequence was accepted. Deep records arriving OUTSIDE our own offload are NOT a
    /// separate live stream, which is the tempting reading: captures show they appear when a SECOND
    /// client pulls the strap's history, and the burst scales with backlog rather than with wall time.
    /// So they are surfaced as a diagnostic for what they are, another client's backlog reaching us
    /// over a shared channel, and never as a live unlock.
    ///
    /// The cooldown exists because our own offload keeps flushing a few records AFTER the session flag
    /// has flipped false. Without it those trailing records are counted as live on every single sync.
    private func noteWhoop5R22Telemetry(_ frame: [UInt8], duringOffload: Bool) {
        // Deep data is a 5/MG concept. On a WHOOP 4 the same type byte means something else entirely,
        // and counting it gave 4.0 owners a deep-data counter that was pure noise.
        guard selectedModel.deviceFamily == .whoop5 else { return }
        guard frame.count > 10 else { return }
        if frame[8] == 0x24, frame[10] == WhoopCommand.setConfig.rawValue {
            state.r22FlagsAccepted += 1
            let total = Whoop5Config.enableR22Sequence.count
            if state.r22FlagsAccepted == total {
                log("Deep-data: strap ACCEPTED all \(total)/\(total) R22 flags ✓ — keep it on; watching for deep packets.")
            }
        }
        if frame[8] == 0x2F {
            if duringOffload {
                // Banked history, handled by the backfiller. Remember when it landed so the cooldown
                // below can discount the few that dribble in after the session ends.
                lastOffloadFrameAt = Date()
                return
            }
            if let last = lastOffloadFrameAt,
               Date().timeIntervalSince(last) < BLEManager.deepPacketLiveCooldownSeconds {
                return
            }
            state.deepPacketsThisSession += 1
            if state.deepPacketsThisSession == 1 {
                log("Deep-data: type-0x2F received outside our offload — this is historical-offload data (another BLE client pulling the strap's history, or a trailing flush), not a live R22 stream.")
            } else if state.deepPacketsThisSession.isMultiple(of: 50) {
                log("Deep-data: \(state.deepPacketsThisSession) type-0x2F historical-offload frames seen outside our session.")
            }
        }
    }

    /// Re-apply the deep-data flag sequence once per encrypted bond.
    ///
    /// The strap FORGETS these flags across a disconnect, so a sequence sent once from the experimental
    /// screen was silently lost at the next drop and the deep streams reverted to heart rate only,
    /// permanently, with nothing saying so. This puts them on the same re-apply-per-bond footing as the
    /// broadcast-HR flag.
    ///
    /// Preconditions are re-checked here rather than relying on the sender's own guards, so the latch is
    /// only taken when the sequence ACTUALLY went out: a refusal leaves it unset and the keep-alive tick
    /// retries. Silent by design, because this fires on every tick and the sender's refusals would spam.
    private func applyDeepDataIfWanted(reason: String) {
        guard !deepDataApplied,
              PuffinExperiment.deepDataEnabled,
              selectedModel.deviceFamily == .whoop5,
              state.connected, state.encryptedBond, state.worn else { return }
        deepDataApplied = true
        log("Deep-data: auto-applying the enable_r22 sequence (\(reason)) — the strap forgets these flags on every disconnect.")
        enableWhoop5DeepData()
    }

    /// Write the deep-biometric config sequence to a bonded 5/MG, switching on the record types the
    /// strap withholds from a fresh third-party connection.
    ///
    /// Only ever runs while the experiment is opted in and the strap is a bonded, WORN 5/MG. The stream
    /// is on-wrist gated by the firmware, so an off-wrist strap is refused with a hint rather than
    /// silently latched as done. Each flag is one acknowledged write, spaced apart the way the official
    /// app spaces them. Reversible: it only changes which data the strap emits.
    public func enableWhoop5DeepData() {
        guard selectedModel.deviceFamily == .whoop5 else {
            log("Deep-data: needs a WHOOP 5.0/MG strap selected — ignored."); return
        }
        guard PuffinExperiment.deepDataEnabled else {
            log("Deep-data: the deep-data experiment is off — enable it in Settings → Experimental first."); return
        }
        guard state.connected, state.encryptedBond else {
            // These writes go over the encrypted command channel, so the live-HR-only shortcut, where
            // a 5/MG reads as bonded because HR streams while the official app still owns the encrypted
            // link, cannot carry them. Requiring the genuine bond turns a silent failure into a message.
            log("Deep-data: needs the full encrypted bond, not the live-HR-only link. Close the official WHOOP app, put the strap in pairing mode, and bond it to whoopmaxx first — ignored."); return
        }
        guard state.worn else {
            log("Deep-data: the R22 stream is on-wrist only — put the strap ON, then try again."); return
        }
        state.r22FlagsAccepted = 0   // fresh attempt: count this send's acknowledgements from zero
        let frames = Whoop5Config.enableR22Sequence
        log("Deep-data: sending the \(frames.count)-flag enable_r22 sequence (experimental, reversible)…")
        for (i, flag) in frames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80 * i)) { [weak self] in
                guard let self else { return }
                self.send(.setConfig,
                          payload: [0x01] + Whoop5Config.payloadBody(name: flag.name, value: flag.value),
                          writeType: .withResponse)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80 * frames.count + 200)) { [weak self] in
            self?.log("Deep-data: sequence sent. Keep the strap on, let it sync, then share your strap log — we're looking for new deep records (type-0x2F) to start arriving.")
        }
    }

    /// Make a bonded 5/MG advertise its heart rate as a standard BLE sensor, so a bike computer, watch
    /// or gym display can pair to the strap directly during a workout. One persistent device-config
    /// value; opt-in and reversible, and unlike the deep-data flags it is not on-wrist gated. Re-applied
    /// on each connection because the strap forgets it too.
    public func setBroadcastHr(_ on: Bool) {
        guard selectedModel.deviceFamily == .whoop5 else {
            log("Broadcast HR: needs a WHOOP 5.0/MG strap selected — ignored."); return
        }
        guard state.connected, state.bonded else {
            log("Broadcast HR: connect and bond a 5/MG strap first — ignored."); return
        }
        let value: UInt8 = on ? 0x31 : 0x30   // ASCII '1' / '0'
        send(.setDeviceConfig,
             payload: [0x01] + Whoop5Config.deviceConfigBody(name: "whoop_live_hr_in_adv_ind_pkt", value: value),
             writeType: .withResponse)
        log("Broadcast HR: wrote whoop_live_hr_in_adv_ind_pkt=\(on ? "1" : "0")")
    }

    // MARK: Strap name

    /// Read the strap's current advertising name. The reply arrives as a command response and the
    /// router publishes it. Also sent during the connect handshake; this is the manual refresh.
    public func requestAdvertisingName() {
        guard selectedModel.deviceFamily == .whoop4 else {
            log("Strap name: WHOOP 4.0 only — ignored on a 5/MG."); return
        }
        guard state.connected else { log("Strap name: not connected — ignored."); return }
        send(.getAdvertisingNameHarvard, payload: [0x00])
    }

    /// Rename the strap's advertising name over the confirmed command channel. The strap reboots to
    /// apply, so the new name usually appears on the next connect, where the handshake re-reads it.
    /// WHOOP 4 only: a 5/MG uses a different device-config path entirely. Reversible.
    public func renameStrap(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedModel.deviceFamily == .whoop4 else {
            state.renameStatus = "Renaming is WHOOP 4.0 only."
            log("Strap rename: WHOOP 4.0 only — ignored on a 5/MG."); return
        }
        guard state.connected, state.bonded else {
            state.renameStatus = "Connect and pair your strap first."
            log("Strap rename: connect + bond first — ignored."); return
        }
        guard !name.isEmpty else {
            state.renameStatus = "Enter a name first."; return
        }
        state.renameStatus = "Renaming…"
        send(.setAdvertisingNameHarvard,
             payload: WhoopCommand.advertisingNamePayload(name),
             writeType: .withResponse)
        log("Strap rename: wrote advertising name=\(name.debugDescription)")
        // Re-read shortly after, so the card reflects the change if the strap applies it without
        // dropping the link. If it reboots instead, the reconnect handshake re-reads the name anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.requestAdvertisingName()
        }
        // Some firmware never returns the response that clears this status: it just reboots, or
        // swallows the command. Without a fallback the card sits on "Renaming…" forever. A real
        // acknowledgement or the reconnect re-read overwrites this the moment it arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(8)) { [weak self] in
            guard let self, self.state.renameStatus == "Renaming…" else { return }
            self.state.renameStatus = "Rename sent - reconnect your strap to confirm the new name."
            self.log("Strap rename: no ack within 8s — firmware may apply it on reboot/reconnect.")
        }
    }

    // MARK: Keep-alive

    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let s = BLEManager.keepAliveIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(s), repeating: .seconds(s))
        t.setEventHandler { [weak self] in self?.keepAliveFire() }
        t.resume()
        keepAliveTimer = t
    }

    private func keepAliveFire() {
        guard state.connected, didBond else { return }
        enableLiveNotifications(reason: "keepalive")
        // Liveness watchdog: nothing has arrived for a while, so the link stalled. Bouncing it lets the
        // rescan re-bond and resume streaming.
        //
        // A 5/MG already known to serve no history gets a far longer fuse. Its standard HR profile
        // keeps the link genuinely alive, but those packets can lull for minutes when the strap is
        // resting or off-wrist, and an empty offload leaves the data channel quiet, so the short fuse
        // disconnected and rescanned a perfectly healthy link every couple of minutes. A WHOOP 4, where
        // silence really does mean not recording, keeps the tight fuse.
        let bounceFuse: TimeInterval =
            (selectedModel.deviceFamily == .whoop5 && whoop5EmptyOffload.historyEmpty) ? 600 : 120
        if Date().timeIntervalSince(lastDataAt) > bounceFuse {
            log("No data for >\(Int(bounceFuse))s — bouncing link to resume streaming")
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        guard !backfilling else { return }            // never poke the strap mid-offload
        // The deep-data sequence is on-wrist gated, so the attempt at bond time fails whenever the
        // strap was off the wrist at connect, which is the usual case on a charger. Retry until it
        // lands, then latch. Sits AFTER the offload guard so those writes never interleave with a sync.
        applyDeepDataIfWanted(reason: "keepalive")
        // Continuous capture can be overnight-only, which makes the want time-dependent, and nothing
        // else re-evaluates it while the app simply sits connected. A window-close tick stops the heavy
        // burst here and lets the reconciler send the disarm on the edge; a window-open tick re-arms.
        // This runs BEFORE the WHOOP 4 guard below so a 5/MG stream also follows the window edges.
        let captureWantNow = screenWantsRealtime || continuousCaptureWantsNow()
        if wantsRealtime != captureWantNow, keepRealtimeForData, !screenWantsRealtime {
            if captureWantNow {
                log("Continuous HRV: overnight window opened; arming the realtime stream")
            } else {
                send(.sendR10R11Realtime, payload: [0x00])
                log("Continuous HRV: overnight window closed; realtime stream disarmed until tonight")
            }
        }
        reconcileRealtime()
        // The pings below are WHOOP 4 framed and a 5/MG link drops them at the send guard, so skip them
        // outright. Re-subscribing and the bounce fuse above are what keep a 5/MG link healthy.
        guard selectedModel.deviceFamily == .whoop4 else { return }
        // Never re-arm the heavy burst once the marginal-radio fallback has tripped: that would simply
        // re-trigger the drop this tick exists to prevent, and the standard profile carries HR anyway.
        if wantsRealtime && !standardHRFallback {
            realtimeArmed = true   // keep the reconciler's edge tracking in step with this re-arm
            send(.sendR10R11Realtime, payload: [0x01])
            send(.toggleRealtimeHR, payload: [0x01])
        }
        keepAliveTick += 1
        if keepAliveTick % 2 == 0 { send(.getBatteryLevel, payload: []) }
    }

    // MARK: Sync triggers

    private func startBackfillTimer() {
        backfillTimer?.cancel()
        let interval = BLEManager.backfillIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in self?.triggerPeriodicBackfill() }
        t.resume()
        backfillTimer = t
    }

    /// The single gated entry point for every offload kick. Applies the connection gate and the rate
    /// limiter for this trigger, and records the attempt time only when an offload actually started, so
    /// a refused start cannot push the next one out by a full interval.
    func requestSync(_ trigger: BackfillTrigger) {
        guard BLEManager.shouldRunPeriodicBackfill(
            connected: state.connected, bonded: state.bonded, backfilling: backfilling) else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last,
                                       emptyStreak: emptySyncTracker.consecutiveEmptySyncs) else {
            log("Backfill: \(trigger) skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
            return
        }
        if beginBackfill() {
            UserDefaults.standard.set(now, forKey: BLEManager.backfillLastAtKey)
        }
    }

    private func triggerPeriodicBackfill() {
        requestSync(.periodic)
    }

    /// The user tapped sync: kick an offload now, bypassing the periodic floor but still honouring the
    /// connection gate. The screen only enables the control while connected, so this guard is the belt
    /// to that braces.
    public func syncNow() {
        guard state.connected, state.bonded else {
            log("Sync now: no strap connected — ignored.")
            return
        }
        if backfilling {
            log("Sync now: a sync is already in progress.")
            return
        }
        log("Sync now: manual sync requested by user.")
        requestSync(.manual)
    }

    // MARK: Logging and small helpers

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func log(_ s: String) {
        state.append(log: "[\(timestamp())] \(s)")
    }
    private func timestamp() -> String {
        BLEManager.logTimeFormatter.string(from: Date())
    }

    /// One bond-state line for the connection test mode. The gate is read BEFORE the string is built,
    /// so this costs nothing when the mode is off, and it records the transition without touching it.
    private func emitConnectionBondState(_ detail: String) {
        guard TestCentre.active(.connection) else { return }
        state.append(log: "bondState \(detail)", domain: .connection)
    }

    /// A stable integer token for a Bluetooth error.
    ///
    /// Emitting the raw enum value rather than a description keeps the token locale-independent and
    /// free of any free text, which matters because these lines end up in exports users share. An
    /// error from neither CoreBluetooth domain reads as unknown rather than leaking its description.
    private func connErrorToken(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        if let cb = error as? CBError { return "cbError\(cb.code.rawValue)" }
        if let att = error as? CBATTError { return "cbAttError\(att.code.rawValue)" }
        return "code?"
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func preparePeripheral(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        resetCharacteristics()
    }

    private func discoverPrimaryServices(on p: CBPeripheral) {
        p.discoverServices([
            selectedModel.scanService, BLEManager.heartRateService, BLEManager.batteryService,
        ])
    }

    private func resetCharacteristics() {
        cmdCharacteristic = nil
        cmdNotifyCharacteristic = nil
        eventNotifyCharacteristic = nil
        dataNotifyCharacteristic = nil
        heartRateCharacteristic = nil
        batteryCharacteristic = nil
        whoop5NotifyCharacteristics.removeAll()
    }

    /// Scan for one family's service, re-framing the inbound stream for it so a rotation decodes the
    /// strap it actually finds rather than the family we started from.
    ///
    /// With the fallback on, schedule a one-shot rotation to the other family after a short miss. That
    /// is what recovers a reconnect when the persisted preference is stale after an update or a
    /// restore, since a service-filtered scan for the wrong service never finds a strap that is right
    /// there. A discovery or a connect cancels the pending rotation.
    private func startScan(for model: WhoopModel, allowFallback: Bool) {
        cancelScanFallback()
        selectedModel = model
        reassembler = Reassembler(family: model.deviceFamily)
        router.family = model.deviceFamily
        configureCollectorFamily()
        central.stopScan()
        log("Scanning for \(model.displayName)…")
        central.scanForPeripherals(
            withServices: [model.scanService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        guard allowFallback else { return }
        let fallback = model.fallbackScanModel
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.central.isScanning, !self.state.connected else { return }
            self.log("No \(model.displayName) found yet — trying \(fallback.displayName)")
            self.startScan(for: fallback, allowFallback: true)
        }
        scanFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BLEManager.scanFallbackDelaySeconds,
            execute: work
        )
    }

    private func cancelScanFallback() {
        scanFallbackWorkItem?.cancel()
        scanFallbackWorkItem = nil
    }

    private func enableLiveNotifications(reason: String) {
        guard let p = peripheral, p.state == .connected else { return }
        let chars = [
            cmdNotifyCharacteristic,
            eventNotifyCharacteristic,
            dataNotifyCharacteristic,
            heartRateCharacteristic,
            batteryCharacteristic,
        ].compactMap { $0 }
        for c in chars where !c.isNotifying {
            requestNotify(c, on: p, reason: reason)
        }
    }

    private func requestNotify(_ c: CBCharacteristic, on p: CBPeripheral, reason: String) {
        guard c.properties.contains(.notify) || c.properties.contains(.indicate) else {
            log("Notify unavailable \(c.uuid) (\(reason))")
            return
        }
        if c.isNotifying {
            log("Notify already active \(c.uuid) (\(reason))")
            return
        }
        p.setNotifyValue(true, for: c)
        log("Notify requested \(c.uuid) (\(reason))")
    }

    // MARK: Wire payloads

    /// The eight-byte SET_CLOCK payload: seconds then subseconds, both little-endian.
    ///
    /// The payload LENGTH is firmware-specific and load-bearing. Newer WHOOP 4 firmware latches this
    /// form; firmware in the 41.17 family ignores it outright, returns no response, and leaves the RTC
    /// unchanged. A strap that misses the set keeps an invalid clock and stops banking sensor data to
    /// flash entirely, which surfaces as endless console-only syncs and no sleep or recovery at all.
    /// Send a WHOOP 4 through `sendSetClockBothForms()` so whichever form that firmware accepts latches.
    static func setClockPayload(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0]
    }

    /// The legacy nine-byte SET_CLOCK payload the 41.17 firmware family requires.
    ///
    /// On a strap whose RTC was stuck in the past, days of eight-byte sends drew no response at all,
    /// while this form was acknowledged, the clock latched and ticked, and the strap resumed banking.
    /// On newer firmware it is acknowledged but NOT latched, so sending it after the short form is a
    /// no-op there. Both carry the same seconds, so whichever one latches sets the same instant.
    static func setClockPayloadLegacy(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0, 0]
    }

    /// Send SET_CLOCK in every form the WHOOP 4 firmware family is known to accept, each a no-op on the
    /// other. A 5/MG keeps its single hardware-validated short form, because the legacy form is
    /// unverified on that family and this is the write that decides whether it banks anything at all.
    func sendSetClockBothForms() {
        let now = UInt32(Date().timeIntervalSince1970)
        send(.setClock, payload: BLEManager.setClockPayload(now: now))
        if selectedModel.deviceFamily == .whoop4 {
            send(.setClock, payload: BLEManager.setClockPayloadLegacy(now: now))
        }
    }

    /// The newest plausible timestamp in a data-range response: the newest record the strap holds.
    /// Scans little-endian words in the response body and keeps those inside a plausible unix range,
    /// because the exact field offsets vary by firmware and a positional read decodes garbage on the
    /// layouts it was not written for.
    static func dataRangeNewestUnix(from frame: [UInt8],
                                    wallNowUnix: Int = Int(Date().timeIntervalSince1970)) -> Int? {
        rangeTimestamps(in: frame, wallNowUnix: wallNowUnix).max()
    }

    /// Every plausible epoch in a GET_DATA_RANGE reply. THREE things the port's rewrite got wrong and
    /// this exists to pin, each independently enough to break a real strap:
    ///  • STEP BY 1, not 4. The banked-record epochs are not 4-byte aligned to the body start — on a
    ///    real gen4 frame they sit at body offsets ≡ 3 (mod 4) — so a stride-4 scan skips every one of
    ///    them and lands only on whatever 4-aligned word happens to be in range.
    ///  • EXCLUDE THE TRAILING CRC32. The old scan read `frame[7...]`, CRC included, and a u32 that
    ///    straddles the last payload byte into the CRC decoded to 2029 on this user's frame — pure
    ///    coincidence that it fell in range, but it then became `MAX(ts)`.
    ///  • CAP AT wallNow + FUTURE_MARGIN, not a fixed 2030. A banked record cannot post-date the
    ///    offload; anything past that is a mis-set clock or a straddle, never a real newest.
    /// Between them the newest read as 24026 h in the future, which nulls `strapNewestTs`, disables
    /// auto-continue, and hands the offload's ingest gate a garbage session window.
    private static func rangeTimestamps(in frame: [UInt8], wallNowUnix: Int) -> [Int] {
        guard frame.count > 11 else { return [] }          // 7-byte header + at least a CRC + a word
        let body = frame[7 ..< frame.count - 4]             // drop the payload CRC32
        let base = body.startIndex
        var out: [Int] = []
        var i = 0
        while base + i + 4 <= body.endIndex {
            let w = Int(body[base + i]) | Int(body[base + i + 1]) << 8
                | Int(body[base + i + 2]) << 16 | Int(body[base + i + 3]) << 24
            if w >= MIN_PLAUSIBLE_UNIX && w <= wallNowUnix + FUTURE_MARGIN { out.append(w) }
            i += 1                                          // SLIDING — the epochs are not word-aligned
        }
        return out
    }

    /// The OLDEST plausible timestamp in the same response: the start of the strap's stored history.
    /// Together with the newest it gives the banked SPAN, which is the backlog DEPTH at a glance: a
    /// strap holding weeks of unsynced history has a wide span and simply needs time to drain
    /// oldest-first, where a narrow span should clear quickly.
    static func dataRangeOldestUnix(from frame: [UInt8],
                                    wallNowUnix: Int = Int(Date().timeIntervalSince1970)) -> Int? {
        rangeTimestamps(in: frame, wallNowUnix: wallNowUnix).min()
    }

    // MARK: Alarm, buzz, nudges

    /// Arm the strap's own firmware alarm, so it buzzes at `date` even if the app is backgrounded or
    /// force-quit. This is the only alarm path: the strap fires at the fixed time and there is no
    /// light-sleep early-wake layer above it.
    ///
    /// A WHOOP 4 gets a clock set first so its RTC is correct, then the alarm. A 5/MG sends its alarm
    /// body alone, because it maintains its RTC from the connect handshake and the official app does
    /// not re-set the clock on that path either.
    ///
    /// The 5/MG alarm is UNCONFIRMED: arming is acknowledged, but a strap-driven wake actually firing
    /// has never been captured. That is why it is gated behind the experimental opt-in below, and why
    /// the gate lives here rather than in the caller: whatever asks for an alarm, the refusal is the
    /// strap layer's to make, so no caller can accidentally promise a wake that may not happen.
    func armStrapAlarm(at date: Date) {
        // Log the wake time in the user's LOCAL zone. A bare date prints as UTC, so an alarm for seven
        // in the morning in New York logs as eleven and reads like a timezone bug when it is not: the
        // command carries the absolute instant, and the strap fires at it however its RTC is labelled.
        let localFmt = DateFormatter()
        localFmt.dateFormat = "EEE HH:mm zzz"
        if selectedModel.deviceFamily == .whoop5 {
            guard PuffinExperiment.isEnabled else {
                log("Alarm: 5/MG firmware alarm needs the Experimental toggle (unconfirmed) — not armed")
                return
            }
            let wakeMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
            send(.setAlarmTime, payload: AlarmPayload.setAlarmRev4(wakeEpochMs: wakeMs))
            log("Alarm: armed 5/MG rev4 for \(localFmt.string(from: date)) — your local wake time")
            return
        }
        // Clamp rather than trap: an out-of-range date must not crash the app on the way to the strap.
        let epochSec = UInt32(clamping: Int64(date.timeIntervalSince1970))
        sendSetClockBothForms()
        send(.setAlarmTime, payload: WhoopCommand.setAlarmPayload(epochSec: epochSec))
        log("Alarm: armed for \(localFmt.string(from: date)) — your local wake time (sent as UTC epoch \(epochSec))")
        // Read the armed time back, so a strap log carries armed, strap-reports, and fired as one
        // decidable sequence for any future "it did not buzz" report. WHOOP 4 only: the read is
        // allowlisted for a 5/MG but its semantics there are unverified. Log-only, and the router parses
        // the reply defensively and never gates behaviour on it, because the response layout is
        // undocumented and an unparseable reply must stay a log line rather than a decision.
        send(.getAlarmTime, payload: [0x01])
    }

    /// Disarm the firmware alarm. The two families take different body shapes for the same command.
    func disableStrapAlarm() {
        if selectedModel.deviceFamily == .whoop5 {
            send(.disableAlarm, payload: AlarmPayload.disableRev2())
            log("Alarm: disarmed (5/MG rev2)")
            return
        }
        send(.disableAlarm, payload: [0x01])
        log("Alarm: disarmed")
    }

    /// Ask the strap what alarm it currently has armed. The reply lands on the command notify channel
    /// and its raw bytes appear in the log; parsing it is a bonus, not a dependency.
    func getStrapAlarm() {
        send(.getAlarmTime, payload: [0x01])
        log("Alarm: requested current alarm time")
    }

    /// One-shot "buzz the strap now".
    ///
    /// Both writes are ACKNOWLEDGED. A backgrounded shortcut on a busy link can silently drop an
    /// unacknowledged write, which is exactly how a buzz gets logged as sent with no vibration. Every
    /// user-facing one-shot buzz routes through here rather than composing its own write, so that fix
    /// cannot be missed by a new call site. On a 5/MG the send path remaps the haptic opcode and body,
    /// and the alarm command carries its own shape; both are already on that family's allowlist.
    ///
    /// Haptic firing cannot be verified in the simulator, which has no motor. Test on a real strap.
    func buzzStrapOnce() {
        send(.runHapticsPattern, payload: [2, 3, 0, 0, 0], writeType: .withResponse)
        if selectedModel.deviceFamily == .whoop5 {
            send(.runAlarm, payload: AlarmPayload.runAlarmRev2(), writeType: .withResponse)
            log("Buzz: one-shot fired (5/MG maverick buzz + runAlarm rev2, acked)")
            return
        }
        send(.runAlarm, payload: [0x01], writeType: .withResponse)
        log("Buzz: one-shot fired (patternId=2 loops=3 + runAlarm, acked)")
    }

    /// Buzz the current time out on the strap so it can be read off the wrist with no screen: count the
    /// long pulses for the hour on a twelve-hour dial, then count the short pulses and multiply by five
    /// for the minutes.
    ///
    /// Only the SCHEDULE is new here. Each notification buzz is a fixed-length motor pulse and the app
    /// cannot vary the on-time, so a long pulse is two stacked buzzes and a short one is a single buzz,
    /// which the wrist reads as longer against shorter. The encoder never returns an empty list, since
    /// the hour block is always at least one pulse, so every call buzzes something.
    ///
    /// How the pulses actually FEEL can only be judged on a real motor.
    public func buzzTimeNow(at date: Date = Date()) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let pulses = HapticClock.pulses(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
        log("Haptic Clock: buzzing \(pulses.count) pulses for the current time (12h dial).")
        var offsetMs = 0
        for pulse in pulses {
            let loops = pulse.isLong ? 2 : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs)) { [weak self] in
                self?.send(.runHapticsPattern, payload: [2, UInt8(clamping: loops), 0, 0, 0])
            }
            offsetMs += pulse.durationMs + pulse.gapMs
        }
    }

    /// On each natural offload completion, run the sedentary detector over the freshly-arrived gravity
    /// window and buzz the wrist if the user has been seated too long.
    ///
    /// Deliberately a read-only hook on an event that already happens, so no timer changes and the
    /// nudge simply lags the stillness by the offload cadence. All the gating and de-duplication lives
    /// in the detector; this only supplies honest inputs and persists what it returns. The detector
    /// acts only when this offload advanced the newest gravity timestamp, so a replayed sync cannot
    /// re-buzz, and the de-dup state is saved on every run rather than only on a buzz, so a replayed
    /// window cannot re-buzz across a relaunch either.
    private func maybeBuzzInactivity() {
        guard InactivityPrefs.isEnabled() else { return }   // cheap check before any store read
        Task { @MainActor in
            let nowSec = Int(Date().timeIntervalSince1970)
            let from = nowSec - BLEManager.inactivityLookbackSeconds
            let gravity = await collector?.recentGravity(from: from, to: nowSec) ?? []
            guard !gravity.isEmpty else { return }
            if TestCentre.active(.sleep) { state.recordSleepLiveGravity(gravity) }

            let decision = SedentaryDetector.evaluate(
                gravity, state: InactivityPrefs.loadState(),
                config: InactivityPrefs.loadConfig(),
                worn: state.worn, nowSec: nowSec,
                tzOffsetSec: InactivityPrefs.tzOffsetSec(nowSec))
            InactivityPrefs.saveState(decision.nextState)

            if decision.shouldBuzz {
                send(.runHapticsPattern, payload: [2, UInt8(clamping: decision.buzzLoops), 0, 0, 0])
                let mins = Int((decision.bout?.durationS ?? 0) / 60)
                log("Inactivity: nudged after a \(mins)-min sedentary stretch.")
                AppModel.postInactivity(minutes: mins)
            }
        }
    }

    /// Parse a standard heart-rate measurement notification.
    private func parseStandardHR(_ data: [UInt8]) {
        guard let m = StandardHeartRate.parse(data) else {
            log("HR notify parse failed: \(hex(data))")
            return
        }
        let now = Date()
        if lastStandardHRLogAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            lastStandardHRLogAt = now
            let plausibility = (30...220).contains(m.hr) ? "" : " ignored"
            log("HR notify: \(m.hr) bpm\(plausibility), rr=\(m.rr.count)")
        }
        // The standard profile is the RELIABLE source for intervals: the custom realtime stream
        // usually reports none at all, so surface them whenever they are present.
        if !m.rr.isEmpty { state.setRRIntervals(m.rr) }
        // Same for the rate itself: this profile is standard and steady, so let it drive the value
        // whenever it is physiologically plausible and reject the rest as off-wrist noise. Publishing
        // only on a real change keeps a steady resting rate from re-rendering the live view every
        // second for no visible difference.
        if m.hr >= 30 && m.hr <= 220 { state.noteHRSeen() }   // before the change guard — steady must read alive
        if m.hr >= 30 && m.hr <= 220, state.heartRate != m.hr { state.heartRate = m.hr }
        // Record continuously, independent of the realtime stream or which screen is open.
        collector?.ingestStandardHR(hr: m.hr, rr: m.rr, at: Int(Date().timeIntervalSince1970))
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state: \(central.state.rawValue) (5 = poweredOn)")
        // Publish the radio's own state BEFORE the guard below returns. Without it a powered-off or
        // permission-denied radio was invisible to the UI, which then blamed the strap and told the
        // user to charge it for a problem the app already knew the answer to. Only on a real change:
        // resetting churn would otherwise thrash every observer.
        let newRadio: LiveState.RadioState
        switch central.state {
        case .poweredOn:   newRadio = .poweredOn
        case .poweredOff:  newRadio = .poweredOff
        case .unauthorized: newRadio = .unauthorized
        case .unsupported: newRadio = .unsupported
        default:           newRadio = .unknown          // resetting and unknown are transient
        }
        if state.radio != newRadio { state.radio = newRadio }
        guard central.state == .poweredOn else { return }
        Task { @MainActor in await bootstrapStore() }
        if let p = restoredPeripheral {
            log("poweredOn with restored peripheral — reconnecting \(p.identifier)")
            if p.state != .connected {
                central.connect(p, options: nil)
            } else {
                discoverPrimaryServices(on: p)
            }
        } else {
            // Powered-on is SYSTEM-initiated: every Bluetooth toggle and every daemon restart lands
            // here. It must not clear a latched bond-refusal give-up, or each of those events restarts
            // the hammer. It gets one bounded attempt with the give-up intact instead.
            connectFromSystem()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "unknown"
        // Present-scan: collect the strap and return before touching the connect flow. Only reachable
        // while the pairing sheet has explicitly taken the central.
        if isPresentingScan {
            let uuid = peripheral.identifier.uuidString
            if let i = discoveredWhoops.firstIndex(where: { $0.uuid == uuid }) {
                discoveredWhoops[i] = (uuid: uuid, name: name, rssi: RSSI.intValue)   // refresh signal
            } else {
                discoveredWhoops.append((uuid: uuid, name: name, rssi: RSSI.intValue))
            }
            return
        }
        // With a pin set, ignore every other WHOOP and keep scanning. With no pin this is skipped and
        // the first strap discovered wins.
        if let preferred = preferredPeripheralUUID, peripheral.identifier != preferred {
            log("Discovered \(name) (\(peripheral.identifier)) — not the preferred strap; ignoring")
            return
        }
        cancelScanFallback()
        // Persist the family that actually advertised, so the next scan starts on the right service.
        // This is what makes a one-time rotation stick instead of rotating again on every launch.
        UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedWhoopModel")
        log("Discovered \(name) (rssi \(RSSI)) — connecting")
        central.stopScan()
        preparePeripheral(peripheral)
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelScanFallback()
        failedConnectAttempts = 0   // a successful connect clears the backoff ladder
        restoredPeripheral = nil
        preparePeripheral(peripheral)
        // Clear the per-connection bond flag BEFORE publishing the identity below. The downstream
        // re-adoption gate reads that flag at the instant it observes the uuid, and an ordinary connect
        // publish must always read false; only the deliberate post-bond handoff republish carries it
        // true. So this clear has to precede the publish, never follow it.
        state.encryptedBond = false
        connectedPeripheralUUID = peripheral.identifier.uuidString
        state.connected = true
        // A connect succeeded, so clear the stale-bond guide UNLESS we are in a known bond loop. In
        // that loop the strap connects every few seconds before timing out again, so clearing here
        // wiped the guide on every cycle: it flashed for about a second and vanished, and the user
        // could never finish reading it. While tripped, keep it up and clear it only once THIS
        // connection proves healthy by surviving past the loop's window.
        connectGeneration &+= 1
        if postBondLoop.tripped {
            let gen = connectGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + postBondLoop.quickTimeoutWindow + 1) { [weak self] in
                // Clear only if the SAME continuous connection is still up. A reconnect bumps the
                // generation, so a transient loop-cycle connect cannot satisfy this even though
                // CoreBluetooth handed back the same peripheral object. Without the generation the
                // timer could fire during a later cycle's brief connect and wipe the guide anyway.
                guard let self, self.state.connected, self.connectGeneration == gen else { return }
                self.postBondLoop.reset()
                self.state.reconnectGuide = nil
            }
        } else {
            state.reconnectGuide = nil
        }
        lastDataAt = Date()
        log("Connected — discovering services")
        if TestCentre.active(.connection) {
            let nowUnix = Int(Date().timeIntervalSince1970)
            let latencyMs = connectAttemptStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            state.append(log: "connect up gen=\(connectGeneration) "
                + "latencyMs=\(latencyMs.map(String.init) ?? "?") uptimeStart=\(nowUnix)", domain: .connection)
        }
        discoverPrimaryServices(on: peripheral)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        Task { @MainActor in await collector?.flush() }
        // Judge this drop BEFORE the state reset below clears the timestamps the detectors measure
        // against. Feeding them after the reset makes every drop look like it followed nothing, and
        // neither loop is ever detected. The order here is the whole mechanism.
        //
        // Marginal radio: an unintentional, error-bearing drop shortly after we armed the burst. The
        // resulting flag is deliberately NOT cleared below, so it survives the rescan into the next
        // connect, which is the connection that has to skip the arm.
        let timedOut = !intentionalDisconnect && error != nil
        let sinceArm = realtimeArmedAt.map { Date().timeIntervalSince($0) }
        if marginalRadio.connectionEnded(wasArmed: realtimeArmedAt != nil,
                                         secondsSinceArm: sinceArm,
                                         timedOut: timedOut) {
            standardHRFallback = true
            log("Marginal radio: \(marginalRadio.consecutiveArmTimeouts) arm-then-timeout cycles — next connect uses standard-HR mode (0x2A37 only)")
        }
        // Bond loop: same pre-reset read. This one requires the OS to classify the drop specifically as
        // a connection timeout rather than merely as some error, so a one-off radio blip or a different
        // failure is not mistaken for the loop.
        let connTimedOut: Bool = (error as? CBError)?.code == .connectionTimeout
        let sinceBond = bondedAt.map { Date().timeIntervalSince($0) }
        if postBondLoop.connectionEnded(wasBonded: bondedAt != nil,
                                        secondsSinceBond: sinceBond,
                                        timedOut: connTimedOut && !intentionalDisconnect) {
            log("Bond-loop: \(postBondLoop.consecutiveBondTimeouts) bond-then-timeout cycles — surfacing the re-pair guide and pausing auto-reconnect")
            // Surfacing the guide alone left the rescan below running, so the loop kept draining the
            // battery behind a message the user could not act on fast enough. Pause auto-reconnect too:
            // both reconnect paths already skip while this is set, and a user Connect or a genuine bond
            // re-arms it. The bond path itself is untouched, because the bond is real; the stale
            // pairing is the problem, which the guide explains how to clear.
            autoReconnectPausedForBondLoop = true
            bondLoopPausedAt = Date()   // starts the salvage-probe floor for this pause too
            if TestCentre.active(.connection) {
                state.append(log: "reconnect paused=bondLoop (\(postBondLoop.consecutiveBondTimeouts) bond-then-timeout cycles)", domain: .connection)
            }
            if state.reconnectGuide == nil {
                state.reconnectGuide = """
                Your strap keeps connecting and then dropping a second later. This is almost always a stale Bluetooth pairing - usually after a WHOOP firmware update, or the official WHOOP app holding the strap. whoopmaxx works fine once it's re-paired:

                1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
                2. Open System Settings → Bluetooth and Forget your WHOOP if it's listed.
                3. Tap the strap repeatedly until its LEDs flash blue (pairing mode).
                4. Come back here and reconnect.
                """
            }
        }
        bondedAt = nil   // cleared only now that the bond-loop detector above has read it
        state.connected = false
        state.encryptedBond = false   // the next session must re-prove the bond
        state.charging = nil          // a stale charging flag must not outlive the link
        state.strapFirmware = nil     // nor a stale firmware version
        state.clearBiometrics()       // nor a stale heart rate or interval
        state.liveFeedActive = false  // a drop while live is open must not leave a stale stop control
        didBond = false
        whoop5RealtimeArmed = false
        // The strap forgets the realtime toggle across a disconnect and the post-bond branch re-arms
        // it. Clear only what we last SENT: the two intent flags must survive a reconnect, or the
        // stream would not come back on its own.
        realtimeArmed = false
        whoop5SessionStarted = false
        clockRequested = false
        connectHandshakeDone = false
        deepDataApplied = false   // the strap forgets those flags across a drop; re-apply next bond
        realtimeArmedAt = nil     // cleared only now that the marginal-radio detector has read it
        backfillStarted = false
        // A fresh connection earns a fresh budget of chained offloads and starts its trim comparison
        // from scratch, since the previous connection's cursor says nothing about this one.
        consecutiveAutoContinues = 0
        lastSessionEndTrim = nil
        backfilling = false
        state.backfilling = false
        state.syncChunksThisSession = 0
        // A drop mid-sync bypasses the offload exit path entirely, so the counters have to be cleared
        // here as well or a stale non-zero count survives until the next session starts.
        state.rejectedFramesThisSession = 0
        state.rejectedFramesUnarchived = 0
        state.decodedChunksThisSession = 0
        state.consoleChunksThisSession = 0
        state.r22FlagsAccepted = 0
        state.deepPacketsThisSession = 0
        lastOffloadFrameAt = nil   // do not carry a stale cooldown reference into the next session
        // A fresh connection also earns a fresh empty-offload verdict: a strap that served nothing last
        // session may bank this time. The honest flag is per-link, like the counters above.
        whoop5EmptyOffload.reset()
        state.historySyncExperimental = false
        // Tear the session's timers and queues down HERE, not on the next connect. A paused give-up
        // never calls disconnect, so leaving teardown to the next connect leaks a full set of timers
        // and a queued drain per drop, forever, on exactly the strap that drops most.
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        backfillDraining = false
        uploadTimer?.cancel()
        uploadTimer = nil
        backfillTimer?.cancel()
        backfillTimer = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        resetCharacteristics()
        puffinRecorder.flush()   // persist buffered capture frames before the reconnect
        Task { @MainActor in await collector?.flushStandardHR() }
        if autoReconnectPausedForBondLoop {
            // The bond keeps being refused, so stop hammering a strap that cannot bond. The epitaph and
            // the paused hint were already surfaced when the give-up tripped; the user re-arms this by
            // tapping Connect. Nothing is scheduled here on purpose.
            log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ""); auto-reconnect paused (strap keeps refusing to pair; tap Connect once it's free)")
            if TestCentre.active(.connection) {
                state.append(log: "connect down (uptime ends)", domain: .connection)
                state.append(log: "reconnect paused=bondLoop (strap refusing bond)", domain: .connection)
            }
        } else if !intentionalDisconnect {
            log("Disconnected\(error.map { " — \($0.localizedDescription)" } ?? ""); rescanning in 3s")
            connReconnectCount += 1
            if TestCentre.active(.connection) {
                let reason = (error as? CBError)?.code == .connectionTimeout
                    ? "connectionTimeout" : connErrorToken(error)
                state.append(log: "connect down (uptime ends)", domain: .connection)
                state.append(log: "reconnect n=\(connReconnectCount) reason=\(reason)", domain: .connection)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                // A timer already in flight when the give-up trips must not fire an extra attempt, and
                // going through the system entry point means it can never clear the pause either.
                guard let self, !self.intentionalDisconnect, !self.autoReconnectPausedForBondLoop else { return }
                self.connectFromSystem()
            }
        } else {
            log("Disconnected (intentional)")
            connReconnectCount = 0
            if TestCentre.active(.connection) {
                state.append(log: "connect down (intentional)", domain: .connection)
            }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        log("Failed to connect\(error.map { " — \($0.localizedDescription)" } ?? "")")
        if TestCentre.active(.connection) {
            let reason: String
            if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
                reason = "peerRemovedPairing"
            } else {
                reason = connErrorToken(error)
            }
            state.append(log: "reconnect n=\(connReconnectCount) failedConnect reason=\(reason)", domain: .connection)
        }
        // The strap wiped its bond, usually via a firmware update or the official app re-bonding it.
        // The OS keeps re-presenting the now-stale pairing key, so every reconnect fails identically
        // with no recovery and no explanation. The app itself works fine on the new firmware once the
        // stale bond is cleared, so surface the steps instead of failing silently forever.
        if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
            state.reconnectGuide = """
            Your strap's Bluetooth pairing was reset - usually by a WHOOP firmware update, or the official WHOOP app reconnecting. whoopmaxx works fine on the new firmware; you just need to re-pair:

            1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
            2. Open System Settings → Bluetooth and Forget “WHOOP MG” if it's listed.
            3. Tap the strap repeatedly until its LEDs flash blue (pairing mode).
            4. Come back here and reconnect.
            """
            return
        }
        // Any other failure, such as a weak-signal handshake timeout at the edge of range. The
        // disconnect path reschedules a rescan but this callback never did, so the reconnect loop died
        // here until a manual retry. Reschedule with a capped exponential backoff so a strap that is
        // genuinely out of range does not hammer the radio. Nothing is scheduled while the bond-loop
        // pause is in force: the user has to free the strap first.
        guard !intentionalDisconnect, !autoReconnectPausedForBondLoop else { return }
        failedConnectAttempts += 1
        let delay = min(60.0, 3.0 * pow(2.0, Double(failedConnectAttempts - 1)))
        log("Reconnecting in \(Int(delay))s (attempt \(failedConnectAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalDisconnect, !self.autoReconnectPausedForBondLoop else { return }
            self.connectFromSystem()
        }
    }

    /// State restoration: the system relaunched us with a peripheral we owned.
    ///
    /// Store it, and if it is already connected re-discover services immediately so the command
    /// characteristic is re-acquired and notifications are re-routed with no user interaction.
    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first else {
            log("Restore: no peripherals in state dict")
            return
        }
        self.peripheral = p
        self.restoredPeripheral = p
        p.delegate = self
        resetCharacteristics()
        // Re-derive the decode family from the persisted model. Neither the connect path nor the scan
        // runs on a restore, so without this a restored 5/MG decodes its frames with WHOOP 4 framing,
        // which has a different length offset, and produces corrupt or empty data for the whole
        // unattended session until the user happens to tap connect.
        selectedModel = .persisted
        reassembler = Reassembler(family: selectedModel.deviceFamily)
        router.family = selectedModel.deviceFamily
        configureCollectorFamily()
        // Collection only ever runs post-bond, so a restored link was already bonded. Seed those flags
        // now, because the write callback that normally sets them will not fire again on its own.
        state.bonded = true
        state.encryptedBond = true
        didBond = true
        noteGenuineBond(of: p)   // a restored link bonded genuinely, so it is a valid re-adopt target
        // The clock correlation is nil in a fresh process, so it has to be requested again. Reset the
        // latch so the post-restore write callback issues exactly one request.
        clockRequested = false
        // Same for the deep-data flags: this process never sent them, and a restored link may well be
        // the same bond that had them, but there is no way to know. Re-apply rather than assume.
        deepDataApplied = false
        Task { @MainActor in await bootstrapStore() }
        if p.state == .connected {
            state.connected = true
            log("Restored CONNECTED peripheral \(p.identifier) — re-discovering services")
            discoverPrimaryServices(on: p)
        } else {
            state.connected = false
            log("Restored DISCONNECTED peripheral \(p.identifier) — reconnect on poweredOn")
            if central.state == .poweredOn { central.connect(p, options: nil) }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        log("Services discovered: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
        for s in services {
            switch s.uuid {
            case BLEManager.customService:
                peripheral.discoverCharacteristics(
                    [BLEManager.cmdWriteChar, BLEManager.cmdNotifyChar,
                     BLEManager.eventNotifyChar, BLEManager.dataNotifyChar], for: s)
            case BLEManager.heartRateService:
                peripheral.discoverCharacteristics([BLEManager.heartRateChar], for: s)
            case BLEManager.batteryService:
                peripheral.discoverCharacteristics([BLEManager.batteryChar], for: s)
            case BLEManager.whoop5Service:
                // Live HR and battery still arrive over the standard profiles, discovered alongside
                // this. These custom characteristics are what carry the session and the offload.
                log("WHOOP 5/MG detected — discovering puffin characteristics (experimental).")
                peripheral.discoverCharacteristics(
                    [BLEManager.whoop5CmdWriteChar] + BLEManager.whoop5NotifyChars, for: s)
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error {
            log("Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case BLEManager.cmdWriteChar:
                // CoreBluetooth has no explicit bond call: one CONFIRMED write is what triggers
                // just-works bonding. The battery read is chosen because it is benign and read-only, so
                // a bond attempt cannot have a side effect on the strap if it lands but the link dies.
                cmdCharacteristic = c
                seq = seq &+ 1
                let bondFrame = WhoopCommand.getBatteryLevel.frame(seq: seq, payload: [0x00])
                log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
                peripheral.writeValue(Data(bondFrame), for: c, type: .withResponse)
            case BLEManager.whoop5CmdWriteChar:
                // A 5/MG starts a session with a static hello rather than the WHOOP 4 bond write.
                cmdCharacteristic = c
                if let hello = selectedModel.deviceFamily.clientHello {
                    // Written WITH RESPONSE for two reasons: it makes CoreBluetooth run just-works
                    // bonding when the link needs authenticating, and it makes the write callback fire.
                    // That callback is where the link is marked established and the notify
                    // characteristics are subscribed, which the strap refuses until the connection is
                    // encrypted. An unacknowledged write triggered no bonding at all and hung forever
                    // on the pairing handshake.
                    log("WHOOP 5/MG: writing CLIENT_HELLO to fd4b0002 with response (to trigger bonding, experimental).")
                    state.pairingHint = nil   // fresh attempt, so clear any stale pairing guidance
                    peripheral.writeValue(Data(hello), for: c, type: .withResponse)
                }
                // Realtime is armed post-bond, not here. Writing it on an unauthenticated link did
                // nothing at all.
            case BLEManager.cmdNotifyChar,
                 BLEManager.eventNotifyChar,
                 BLEManager.dataNotifyChar,
                 BLEManager.heartRateChar,
                 BLEManager.batteryChar:
                switch c.uuid {
                case BLEManager.cmdNotifyChar: cmdNotifyCharacteristic = c
                case BLEManager.eventNotifyChar: eventNotifyCharacteristic = c
                case BLEManager.dataNotifyChar: dataNotifyCharacteristic = c
                case BLEManager.heartRateChar: heartRateCharacteristic = c
                case BLEManager.batteryChar:
                    batteryCharacteristic = c
                    if c.properties.contains(.read) {
                        peripheral.readValue(for: c)
                    }
                default: break
                }
                requestNotify(c, on: peripheral, reason: "discovery")
            default:
                // The 5/MG notify characteristics. Retain them but do NOT subscribe yet: on an
                // unauthenticated link the strap refuses the subscription, and that refusal also wedges
                // the bond itself, so an eager subscribe here costs the whole session. The write
                // callback subscribes them once the hello write confirms.
                if BLEManager.whoop5NotifyChars.contains(c.uuid) {
                    whoop5NotifyCharacteristics.append(c)
                }
            }
        }
    }

    /// A confirmed write completed. With no error, that means bonding succeeded.
    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Confirmed write failed: \(error.localizedDescription)")
            // Classify by ATT code first, description second. Everything below keys off this one flag:
            // the pairing hint, the give-up, and the stale-pin handoff, so a locale-dependent check
            // here silently disabled all three on every non-English device.
            let insufficient = BLEManager.isInsufficientAuthError(error)
            if TestCentre.active(.connection) {
                state.append(log: insufficient
                    ? "otherCentral bondWrite refused=insufficient (strap likely held by the WHOOP app or a stale pairing; cannot start a fresh encrypted bond)"
                    : "otherCentral bondWrite failed=\(connErrorToken(error))", domain: .connection)
            }
            // A 5/MG first connect: CoreBluetooth will not start a fresh just-works bond against a
            // strap still bonded to the official app, so the hello write fails and the link never
            // authenticates. Surface guidance rather than failing silently.
            if selectedModel.deviceFamily == .whoop5, !didBond, insufficient {
                bondRefusalStreak += 1
                // Surface guidance once refusals are PERSISTENT. A single refusal right after a known
                // good bond is a transient reconnect race, so stay quiet on the first one; from the
                // second, tell the user how to make the strap pairable. Keying this off "has this strap
                // ever bonded" instead wrongly hid the guidance from exactly the users who needed it:
                // those whose strap bonded in a previous session but will not now.
                if bondGiveUp.gaveUp {
                    // A refusal during a paused-state salvage probe must not stomp the paused hint back
                    // to the pairing hint, or the banner flaps once per probe. The streak keeps counting
                    // silently and the give-up stays latched, so no second epitaph is written either.
                    log("WHOOP 5/MG: bond still refused during a paused-state probe (streak \(bondRefusalStreak)) - the give-up stays latched")
                } else if bondRefusalStreak >= 2 {
                    state.pairingHint = "whoopmaxx can see your strap but it's refusing to pair - it's likely still bonded to the official WHOOP app, or your phone is holding an old pairing. To fix it: (1) fully close the WHOOP app, (2) on a 5.0/MG, tap the band repeatedly until the LEDs flash blue (pairing mode), (3) if your strap is listed under iPhone Settings → Bluetooth, tap it and choose Forget This Device, then reconnect in whoopmaxx."
                    log("WHOOP 5/MG: bond refused \(bondRefusalStreak)× with no successful bond — the strap is refusing the encrypted link (WHOOP app holds it, or a stale iOS pairing). Surfacing pairing-mode + forget-device guidance.")
                } else {
                    log("WHOOP 5/MG: bond write refused (insufficient) — retrying once; will surface pairing-mode guidance if it persists.")
                }
                // Feed the same refusal into the give-up. Once it crosses its higher threshold, by which
                // point the pairing hint has had several cycles to be acted on, pause auto-reconnect,
                // write the one-line epitaph, and switch the hint to the honest paused one.
                if bondGiveUp.recordRefusal() {
                    autoReconnectPausedForBondLoop = true
                    bondLoopPausedAt = Date()   // starts the salvage-probe floor
                    let opaque = BondRefusalGiveUp.opaqueId(fromLocalUUID: peripheral.identifier.uuidString)
                    log(BondRefusalGiveUp.epitaphLine(refusals: bondGiveUp.refusals, opaqueId: opaque))
                    state.pairingHint = BondRefusalGiveUp.pausedHint()
                    if TestCentre.active(.connection) {
                        state.append(log: "bond gaveUp refusals=\(bondGiveUp.refusals) id=\(opaque) (auto-reconnect paused)", domain: .connection)
                    }
                }
            }
            // Stale-pin recovery: when the pin points at a strap that keeps refusing but a DIFFERENT
            // strap has bonded fine this run, the connect path drops the working strap and loops
            // forever on the dead pin, so the encrypted bond never turns true and everything gated on
            // it stays dead too. Count refusals on the pinned peripheral and hand the pin over.
            if insufficient, !didBond,
               let pinned = preferredPeripheralUUID, peripheral.identifier == pinned {
                pinnedBondRefusals += 1
                if pinnedBondRefusals >= pinBondRefusalLimit,
                   let working = lastBondedPeripheralUUID, working != pinned {
                    readoptWorkingStrap(working, awayFrom: pinned)
                }
            }
            return
        }

        // A 5/MG: the hello was acknowledged, after just-works bonding if the link needed
        // authenticating, so the link is established. Mark it bonded, which clears the handshake
        // status, and subscribe what the strap refused before the link was encrypted. Do NOT run the
        // WHOOP 4 handshake below: a 5/MG rejects those commands and the send guard drops them anyway.
        if selectedModel.deviceFamily == .whoop5 {
            if !didBond {
                didBond = true
                state.bonded = true
                state.encryptedBond = true   // a genuine encrypted bond, not the live-HR shortcut
                bondedAt = Date()            // starts the bond-to-drop stopwatch
                state.pairingHint = nil
                bondRefusalStreak = 0
                bondGiveUp.reset()
                autoReconnectPausedForBondLoop = false
                bondLoopPausedAt = nil
                noteGenuineBond(of: peripheral)
                emitConnectionBondState("encryptedBond family=whoop5 (CLIENT_HELLO acked)")
                log("WHOOP 5/MG: CLIENT_HELLO acked — link established; subscribing notify chars (experimental).")
            }
            for c in whoop5NotifyCharacteristics where !c.isNotifying {
                requestNotify(c, on: peripheral, reason: "post-bond puffin")
            }
            enableLiveNotifications(reason: "post-bond 5/MG")   // the standard profiles that failed pre-bond
            // Arm realtime once per connection. The keep-alive tick skips a 5/MG entirely, so this is
            // the trigger; opening the live screen later arms it through the ordinary path.
            //
            // RE-DERIVE the want here rather than trusting the stored value, which can be a full
            // keep-alive tick stale: a reconnect just outside the overnight window would otherwise arm
            // the flood from it and stay armed until the next tick noticed.
            let realtimeWantNow = screenWantsRealtime || continuousCaptureWantsNow()
            wantsRealtime = realtimeWantNow
            if realtimeWantNow && !whoop5RealtimeArmed {
                whoop5RealtimeArmed = true
                realtimeArmed = true   // keep the reconciler's edge tracking in step with this arm
                log("WHOOP 5/MG: arming realtime HR (puffin TOGGLE_REALTIME_HR)")
                send(.toggleRealtimeHR, payload: [0x01])
            }
            startKeepAlive()
            // Kick the offload ONCE per connection. This callback re-enters this branch on EVERY
            // confirmed write during the offload, which includes every chunk acknowledgement, so
            // without the latch the offload request goes out again mid-stream and storms the strap.
            // The re-subscribe and the arm above are idempotent and deliberately run on every
            // re-entry; only this block is gated.
            if !whoop5SessionStarted {
                whoop5SessionStarted = true
                connectHandshakeDone = true     // unblocks the offload guard
                log("WHOOP 5/MG: connect handshake done — backfill unblocked")
                if PuffinExperiment.broadcastHrEnabled { setBroadcastHr(true) }
                // Off-wrist is the common case at handshake time and the deep-data stream is on-wrist
                // gated, so this is a first attempt and the keep-alive tick retries once worn.
                applyDeepDataIfWanted(reason: "bond")
                // Clock the strap BEFORE history. An un-clocked 5 discards sensor data outright and its
                // offloads then complete carrying metadata and nothing else, so this ordering is what
                // decides whether history exists at all. The deferral below preserves it.
                send(.setClock, payload: BLEManager.setClockPayload())
                send(.getClock, payload: [])
                log("WHOOP 5/MG: clock synced (set/get) — strap can persist history now")
                log("WHOOP 5/MG: scheduling first historical offload (connect)")
                // Deferred so the subscriptions settle before the offload request. The gated entry
                // point is itself blocked on the handshake latch, so a racing foreground or restore
                // trigger cannot fire it earlier than this.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
                startBackfillTimer()
            }
            return
        }

        if !didBond {
            didBond = true
            state.bonded = true
            state.encryptedBond = true   // a WHOOP 4 confirmed-write bond is always genuine
            bondedAt = Date()            // starts the bond-to-drop stopwatch
            noteGenuineBond(of: peripheral)
            emitConnectionBondState("encryptedBond family=whoop4 (confirmed write acked)")
            log("BONDED (confirmed write acknowledged) — custom channels should now flow")
        }
        // Run the handshake EXACTLY ONCE per connection.
        //
        // This callback re-fires on EVERY confirmed write: the bond write, every offload request, and
        // every chunk acknowledgement. Without this latch those re-entries re-sent hello and SET_CLOCK
        // at the strap DURING an offload and stopped it streaming history. That was the root cause of
        // history never arriving here, while a paced script that ran the sequence once on a stable
        // connection pulled it fine.
        guard !connectHandshakeDone else { return }
        connectHandshakeDone = true
        backfillStarted = true

        // The connect lifecycle: hello, then the strap's own identity and firmware, then the clock,
        // then history. Hello is not strictly required for the strap to serve, which was verified
        // directly, but it is exchanged anyway to keep the sequence faithful to what the strap expects.
        send(.getHelloHarvard)
        send(.getAdvertisingNameHarvard)
        // One-shot firmware read for the devices card. Both are read-only, so send the one this family
        // answers and let the other be ignored rather than branching on a guess.
        switch selectedModel.deviceFamily {
        case .whoop4: send(.reportVersionInfo)
        case .whoop5: send(.getHello)
        }
        sendSetClockBothForms()
        if clockRef == nil && !clockRequested {
            clockRequested = true
            // GET_CLOCK's payload length is firmware-specific exactly the way SET_CLOCK's is: newer
            // firmware answers the empty form and ignores the single zero byte, while the 41.17 family
            // does the reverse. Send both, and let the correlation guard make the second reply a no-op.
            // Without the byte form the correlation never establishes on that firmware, so a lost RTC
            // stays invisible and the clock policy can never fix it. Both ride behind both clock sets
            // above, so the replies reflect the corrected clock.
            send(.getClock, payload: [])
            send(.getClock, payload: [0x00])
        }
        send(.sendR10R11Realtime, payload: [0x00])   // stop the raw flood: it costs airtime and battery
        send(.getDataRange)                          // refresh the stored range for the watchdog
        // Deferred so the clock and range round-trip first and the offload request runs on a settled
        // link. The gated entry point is blocked on the handshake latch, so a racing trigger cannot
        // fire it early.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
        startBackfillTimer()
        startKeepAlive()
        enableLiveNotifications(reason: "post-bond")   // includes the standard HR profile
        // RE-DERIVE the want at arm time, same reasoning as the 5/MG branch: a reconnect outside the
        // overnight window must not arm the flood from a stale stored value, which the keep-alive would
        // then hold armed for another full tick.
        let realtimeWantNow = screenWantsRealtime || continuousCaptureWantsNow()
        wantsRealtime = realtimeWantNow
        if realtimeWantNow {
            if standardHRFallback {
                // This radio repeatedly dropped the link the instant the burst was armed. Skip it
                // entirely; live HR rides the standard profile subscribed just above. Safe either way:
                // if that profile emits, the user gets live HR on a radio that otherwise died, and if
                // it does not, at least the arm-then-die loop stops.
                log("Realtime HR: standard-HR mode (low bandwidth) — skipping R10/R11 arm")
                state.standardHRMode = "Standard HR mode (low bandwidth) - your Bluetooth radio couldn't sustain the full stream; live heart rate via the standard profile."
            } else {
                log("Realtime HR: arming after bond")
                realtimeArmed = true   // keep the reconciler's edge tracking in step with this arm
                send(.sendR10R11Realtime, payload: [0x01])
                send(.toggleRealtimeHR, payload: [0x01])
                realtimeArmedAt = Date()   // starts the arm-to-drop stopwatch
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            log("Notify update failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        lastDataAt = Date()   // feed the liveness watchdog on every notification

        switch characteristic.uuid {
        case BLEManager.heartRateChar:
            parseStandardHR(bytes)
            // A 5/MG has no confirmed-write bond, so once live HR actually streams over the standard
            // profile the link is established in every sense the UI cares about. Without this the UI
            // sits on "connecting" forever while data is visibly flowing.
            if selectedModel.deviceFamily == .whoop5, !state.bonded {
                state.bonded = true
                log("WHOOP 5/MG: live HR streaming — marking the link established (experimental).")
            }
        case BLEManager.batteryChar:
            // 5/MG ONLY. A WHOOP 4's standard battery characteristic is a stub that always reads 100,
            // and it is subscribed, so an unsolicited stub notification reverted a true reading back to
            // full. The real WHOOP 4 value only comes from the proprietary command's response.
            if selectedModel.deviceFamily != .whoop4, let pct = bytes.first {
                state.setBattery(Double(pct))
            }
        case BLEManager.dataNotifyChar,
             BLEManager.cmdNotifyChar,
             BLEManager.eventNotifyChar:
            for frame in reassembler.feed(bytes) {
                if backfilling, BLEManager.isOffloadFrame(frame, family: .whoop4) {
                    // Historical replay is bulk sync traffic, not live traffic. Feed it only to the
                    // offload: parsing every record through the live router updates the UI for no
                    // visible benefit and makes the app feel hung during a long drain.
                    armBackfillTimeout()
                    routeBackfillFrame(frame)
                    // A REAL-TIME physical gesture must still fire mid-offload, since an offload runs
                    // for minutes. The freshness gate is what keeps replayed historical events, which
                    // carry old timestamps, from firing the same gesture again.
                    router.dispatchLiveGestureIfFresh(frame: frame, now: strapClockNow)
                    continue
                }
                router.handle(frame: frame)
                // The command number only lives at this offset for a command or command-response
                // packet. Every other packet type puts something else there: a live data frame has a
                // timestamp whose low byte sweeps every value once every few minutes of streaming, and
                // an event frame has an event number that collides exactly with the data-range command
                // and is sent on every connect. Without this type check those live frames were decoded
                // as range replies, and since the range scan simply looks for any word in a plausible
                // unix range, sensor bytes became a "banked history window".
                //
                // That is not merely a bad log line. It feeds the strap's reported newest, the
                // published range, and the offload's own session markers, where a bogus oldest makes
                // the ingest gate DROP real records that the chunk commit then acknowledges away. This
                // check is purely subtractive: it only narrows when a range is published, and a range
                // that is never published leaves the gate on its absolute fallback.
                if frame.count > 6, frame[4] == 35 || frame[4] == 36,
                   frame[6] == WhoopCommand.getDataRange.rawValue {
                    // Log the raw bytes unconditionally, even when the decode returns nil. The decoded
                    // newest can latch a stale, wrong-epoch field, and telling that apart from a
                    // frame-alignment bug without guessing needs the actual bytes, inspectable straight
                    // from an ordinary log export. The frame is short.
                    let hex = frame.map { String(format: "%02x", $0) }.joined()
                    log("Get Data Range raw frame (for offset analysis): \(hex)")
                    if let newest = BLEManager.dataRangeNewestUnix(from: frame) {
                        strapNewestTs = newest                    // feeds the liveness watchdog
                        // Flag an implausibly future newest right where it lands, so an export shows
                        // WHY the continuation refused to trust the range.
                        let wallNowForSkew = Int(Date().timeIntervalSince1970)
                        if newest > wallNowForSkew + BackfillContinuation.defaultFutureSkewSeconds {
                            log("Strap newest banked record reads \((newest - wallNowForSkew) / 3600)h AHEAD of the wall clock (implausible; strap clock set in the future). Auto-continue will not trust this range.")
                        }
                        // Publish the strap's own banked window to the offload, so its ingest gate can
                        // reject a record dated months outside THIS strap's range, which is how
                        // wandering-clock pollution clears an absolute floor. The newest gives the upper
                        // bound and the oldest below closes the lower one; the gate ignores a half or
                        // malformed window, so setting one before the other is decoded is safe.
                        backfiller?.sessionNewestUnix = newest
                        // Print the newest record the strap actually holds. With the persisted count
                        // this lets one connect distinguish a banked-but-not-yet-reached backlog, where
                        // the newest is last night and the cursor is still grinding, from a night the
                        // strap genuinely never banked.
                        let d = ISO8601DateFormatter()
                        d.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
                        log("Strap newest banked record: \(d.string(from: Date(timeIntervalSince1970: TimeInterval(newest)))) (from data range)")
                        // And the oldest, so one connect shows the full SPAN: the depth an oldest-first
                        // drain has to cover before recent nights land.
                        let oldest = BLEManager.dataRangeOldestUnix(from: frame)
                        if let oldest, oldest < newest {
                            backfiller?.sessionOldestUnix = oldest
                            let spanDays = (newest - oldest) / 86_400
                            log("Strap banked history span: \(d.string(from: Date(timeIntervalSince1970: TimeInterval(oldest)))) → newest (~\(spanDays) day\(spanDays == 1 ? "" : "s") of backlog, drained oldest-first)")
                        }
                        // Bank the window unconditionally, so a clock-drift line can ride every export
                        // rather than only the ones taken with a diagnostic mode switched on.
                        state.setStrapRange(newestUnix: newest, oldestUnix: (oldest.map { $0 < newest } ?? false) ? oldest : nil)
                        if TestCentre.active(.connection) {
                            let line = ConnectionTrace.clockDriftLine(
                                oldestUnix: (oldest.map { $0 < newest } ?? false) ? oldest : nil,
                                newestUnix: newest,
                                wallNowUnix: Int(Date().timeIntervalSince1970))
                            state.append(log: line, domain: .connection)
                        }
                    }
                }
                // Clock correlation runs in both live and offload modes. Once established it unblocks
                // the collector's live persistence and the offload's chunk decode at the same time.
                if clockRef == nil {
                    let parsed = parseFrame(frame)
                    if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                        clockRef = ref
                        collector?.clockRef = ref
                        backfiller?.clockRef = ref
                        log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                        // Set the clock only when the strap's own has drifted or frozen, not blindly on
                        // every connect. Decoding does not depend on it, since that uses the
                        // correlation; setting it only keeps FUTURE timestamps sane.
                        if ClockPolicy.shouldSetClock(deviceClock: ref.device, wallNow: ref.wall) {
                            log("Clock drift detected — issuing SET_CLOCK")
                            sendSetClockBothForms()
                        }
                    }
                }
                if !backfilling {
                    // Live path: ingest synchronously, which is what preserves delegate arrival order.
                    collector?.ingest(frame)
                }
            }
        default:
            // The 5/MG notify characteristics. Reassemble and route with the family-aware pieces so the
            // UI reflects arriving frames; the offload itself uses the same machinery as a WHOOP 4.
            if BLEManager.whoop5NotifyChars.contains(characteristic.uuid) {
                for frame in reassembler.feed(bytes) {
                    let isOffload = backfilling && BLEManager.isOffloadFrame(frame, family: .whoop5)
                    noteWhoop5R22Telemetry(frame, duringOffload: isOffload)
                    if isOffload {
                        // Same policy as a WHOOP 4: keep bulk sync traffic out of the live parser and
                        // let the sliced drain preserve its order.
                        armBackfillTimeout()
                        routeBackfillFrame(frame)
                        router.dispatchLiveGestureIfFresh(frame: frame, now: strapClockNow)
                        continue
                    }
                    router.handle(frame: frame)
                    // Live 5/MG records are deliberately NOT ingested here. The standard heart-rate
                    // profile is already the reliable, continuously-persisted live source for this
                    // family, and decoding heart rate a second time off this stream stored a duplicate
                    // row per beat at a slightly different second, because one is strap time and the
                    // other is receive time. One authoritative live source, not two.
                    puffinRecorder.capture(frame: frame, char: characteristic.uuid)
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Notify enable failed for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            log("Notify \(characteristic.isNotifying ? "active" : "off") \(characteristic.uuid)")
        }
    }
}
