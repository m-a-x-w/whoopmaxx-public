// Derived from ParthJadhav/noop, PolyForm Noncommercial License 1.0.0, Copyright 2026 NoopApp.
// Required Notice: Copyright 2026 NoopApp (https://github.com/ParthJadhav/noop)
// Terms: https://polyformproject.org/licenses/noncommercial/1.0.0 — see ../../LICENSE.

import Foundation
import StrapProtocol
import StrapStore

/// Keep-newest trim shared by every buffer here. Dropping from the front is deliberate: when a
/// bound is hit the strap is still streaming, and the samples worth surviving are the recent ones.
private func keepNewest<T>(_ rows: inout [T], cap: Int) {
    guard rows.count > cap else { return }
    rows.removeFirst(rows.count - cap)
}

/// The two durable writes the Collector performs, narrowed to a seam a test can stand in front of.
/// `StrapStore` is an actor, so it can be neither subclassed nor otherwise substituted; without a
/// protocol here the buffer-cap and drain tests would need a real database on disk.
///
/// NOT `@MainActor`, on purpose. An async requirement is witnessed from any isolation, so both the
/// store actor and a plain non-isolated double conform; annotating the protocol would instead drag
/// every write onto the main actor, which is the one place a multi-table insert must not run.
protocol StoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
}

/// This empty extension is load-bearing: it is what lets the production call site hand a real
/// `StrapStore` to `Collector(store:)`. Removing it as unreferenced breaks BLEManager, not this file.
extension StrapStore: StoreWriting {}

/// How long collected data may live only in RAM, and how much of it may pile up there.
struct CollectorPolicy {
    /// Buffered frames that trip a drain.
    var maxFrames: Int
    /// Age of the open batch, in seconds, that trips a drain regardless of count. A resting strap
    /// can go minutes without producing `maxFrames`, and without this those frames would reach the
    /// database only when something else happened to force a flush.
    var maxInterval: TimeInterval
    /// Ceiling on the frame buffer, honoured whether or not a clock correlation exists. Two ways an
    /// install climbs to it: GET_CLOCK never answers, so nothing is timestampable and nothing can
    /// drain; or the store keeps throwing, and every failed drain hands its frames back while
    /// ingest keeps appending. The cadence rule bounds neither. At roughly 60 bytes a frame this is
    /// about a quarter of a megabyte, far above the ~64-frame steady state, so only a stuck install
    /// ever reaches it.
    var maxPreClockFrames: Int
    /// The same ceiling for the standard HR/RR buffers. 0x2A37 notifies about once a second for as
    /// long as the link is up, unlock or no unlock, and a failed write puts its rows back, so an
    /// unbounded buffer plus a few hours of store trouble ends in a jetsam kill.
    var maxStandardSamples: Int
    /// Buffered standard rows that trip a write.
    var maxStandardRows: Int
    /// Seconds a partial standard batch may wait before it is written anyway. A sparse stream (off
    /// wrist, resting, phone locked) never reaches `maxStandardRows`, and those readings would
    /// otherwise be lost the moment the process ends.
    var maxStandardInterval: TimeInterval

    /// Spelled out rather than synthesized so a caller that only has an opinion about cadence can
    /// still construct one: the memberwise init would force every buffer bound to be restated.
    init(maxFrames: Int, maxInterval: TimeInterval, maxPreClockFrames: Int = 4096,
         maxStandardSamples: Int = 8192, maxStandardRows: Int = 30,
         maxStandardInterval: TimeInterval = 30) {
        self.maxFrames = maxFrames
        self.maxInterval = maxInterval
        self.maxPreClockFrames = maxPreClockFrames
        self.maxStandardSamples = maxStandardSamples
        self.maxStandardRows = maxStandardRows
        self.maxStandardInterval = maxStandardInterval
    }

    static let `default` = CollectorPolicy(maxFrames: 64, maxInterval: 30, maxPreClockFrames: 4096)
}

/// Buffers reassembled frames and drains them: parse, correlate against the strap clock, insert the
/// decoded rows, then queue the raw copy.
///
/// Decoded lands before raw is queued, never the reverse. Raw is an outbox under a retention sweep;
/// if it were banked first and the decoded insert then failed, the sweep would eventually delete the
/// only surviving record of those samples.
@MainActor
final class Collector {
    /// The two paths that may have at most one auto-spawned task alive at a time.
    private enum Lane { case frames, standard }

    private let store: StoreWriting
    /// The same object as `store` whenever it really is a `StrapStore`. Stats, prune and the gravity
    /// read are occasional and specific; putting them in `StoreWriting` would make every test double
    /// implement four methods it has nothing to say about.
    private let concreteStore: StrapStore?
    /// Device id newly written rows are filed under. Settable because switching straps has to
    /// re-attribute the very next drain; a value frozen at construction would file the new strap's
    /// samples under the old one until the app was killed.
    var deviceId: String
    private let policy: CollectorPolicy
    /// False by default, meaning no raw frame is ever persisted and the install is decoded-only.
    /// Injected so a test can drive the raw path without changing what ships.
    private let enableRawCapture: Bool
    private let now: () -> Int
    private let monotonic: () -> TimeInterval

    /// Correlation between strap time and wall time. Until it arrives a frame cannot be given a real
    /// timestamp, so frames wait rather than being written under a guessed one.
    var clockRef: ClockRef?
    /// Envelope family for the live decode. The 4.0 and puffin envelopes put records at different
    /// offsets, so the wrong choice yields plausible garbage rather than a decode failure.
    var family: DeviceFamily = .whoop4

    private var rawCapture = RawCaptureWindow()
    private var buffer: [[UInt8]] = []
    /// Standard 0x2A37 HR/RR. Recorded for the whole connection, independent of the custom realtime
    /// stream and of whichever screen is open.
    private var stdHR: [HRSample] = []
    private var stdRR: [RRInterval] = []
    private var batchStartedAt: TimeInterval
    /// When the open standard batch got its first row; nil while both buffers are empty. Set only on
    /// the empty-to-non-empty edge, so the batch ages from its oldest row instead of sliding forward
    /// with each arrival and never coming due.
    private var stdBatchStartedAt: TimeInterval?
    /// One-shot timer that writes a partial standard batch once it has waited out the interval.
    private var stdDeadline: Task<Void, Never>?
    private var lanesInFlight: Set<Lane> = []

    var bufferedCount: Int { buffer.count }

    init(store: StoreWriting, deviceId: String,
         policy: CollectorPolicy = .default,
         enableRawCapture: Bool = false,
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
         // Uptime rather than wall time. An NTP correction, a timezone change or a user setting the
         // clock back all step `Date()`, and a backward step would stall the cadence trigger and
         // stretch a raw window's expiry. Uptime pauses in deep sleep, which costs nothing here
         // because neither deadline runs then either.
         monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store
        self.deviceId = deviceId
        self.policy = policy
        self.enableRawCapture = enableRawCapture
        self.now = now
        self.monotonic = monotonic
        self.batchStartedAt = monotonic()
        self.concreteStore = store as? StrapStore
    }

    /// Run `body` unless this lane already has a task running. The running drain took and cleared its
    /// buffer before its first await, so whatever arrives meanwhile belongs to the next batch anyway
    /// and a second task would only contend for the same store.
    private func coalesced(_ lane: Lane, _ body: @escaping @MainActor () async -> Void) {
        guard lanesInFlight.insert(lane).inserted else { return }
        Task { @MainActor in
            defer { self.lanesInFlight.remove(lane) }
            await body()
        }
    }

    // MARK: - Store reads

    /// Storage summary for the UI. nil, not zeroes, when there is no concrete store or the read
    /// throws: "0 rows" is a claim about an empty database and would be a different, wrong fact.
    func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        guard let s = concreteStore else { return nil }
        return try? await s.storageStats()
    }

    /// Newest persisted HR timestamp, the frontier the stuck-strap watchdog measures against. nil
    /// when unknown, so the watchdog can tell "nothing recorded yet" apart from "recorded at zero".
    func latestHRSampleTs() async -> Int? {
        guard let s = concreteStore else { return nil }
        return try? await s.latestHRSampleTs(deviceId: deviceId)
    }

    /// Motion over `[from, to]` for the inactivity reminder, read here because the Collector is what
    /// holds the concrete store.
    func recentGravity(from: Int, to: Int, limit: Int = 100_000) async -> [GravitySample] {
        guard let s = concreteStore else { return [] }
        return (try? await s.gravitySamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    /// Apply retention, returning how many rows actually went away.
    ///
    /// Two policies, because two different things grow. `pruneRaw` bounds the raw outbox, which on a
    /// decoded-only install is empty and deletes nothing. `SampleRetention` bounds the decoded
    /// tables, which is where the file size really accumulates: hundreds of megabytes over a couple
    /// of weeks if nothing sweeps them.
    ///
    /// A backstop for the periodic sweep rather than a duplicate of it. The periodic job ticks only
    /// while the process lives, so an install that is never foregrounded would never sweep at all;
    /// background entry, which such an install hits constantly, arrives here. The sweep is
    /// day-granular and capped per run, so calling it from both places costs a few index seeks when
    /// nothing is due.
    @discardableResult
    func prune() async -> Int {
        guard let s = concreteStore else { return 0 }
        let raw = (try? await s.pruneRaw(now: now(),
                                         keepWindowSeconds: PrunePolicy.keepWindowSeconds,
                                         maxUnsyncedBytes: PrunePolicy.maxUnsyncedBytes)) ?? 0
        guard let path = try? StorePaths.defaultDatabasePath() else { return raw }
        let id = deviceId
        // Detached: the sweep is a multi-table delete across a large file and would hold the UI for
        // however long that takes if it ran here.
        let outcome = await Task.detached(priority: .utility) {
            SampleRetention.sweep(databaseAt: path, deviceId: id)
        }.value
        return raw + outcome.rowsDeleted
    }

    // MARK: - Custom realtime frames

    /// Take one reassembled frame. Synchronous so frames keep the order the BLE delegate delivered
    /// them in; the drain this may trip runs afterwards.
    func ingest(_ frame: [UInt8]) {
        buffer.append(frame)
        // Trimmed here, ahead of the clock guard and ahead of any drain, because this is the only
        // bound that holds while `clockRef` is nil AND the only one that holds while the store is
        // failing, since a failed drain hands its whole snapshot back. Moving it below the guard is
        // the exact regression the buffer-cap test pins.
        keepNewest(&buffer, cap: policy.maxPreClockFrames)
        guard clockRef != nil else { return }   // nothing can be timestamped yet
        let aged = monotonic() - batchStartedAt
        guard buffer.count >= policy.maxFrames || aged >= policy.maxInterval else { return }
        coalesced(.frames) { await self.flush() }
    }

    /// Decode and persist everything buffered. Does nothing when empty or before a clock correlation.
    func flush() async {
        guard let ref = clockRef, !buffer.isEmpty else { return }
        // Buffer taken and cleared before the first await, so frames arriving during the decode and
        // the insert accumulate into the next batch instead of being written a second time.
        let frames = buffer
        buffer.removeAll(keepingCapacity: true)
        // Answer the raw question now, against the window as it stood when these frames were taken.
        // An on-demand window expires on its own deadline and `endRawCapture` drains at or after
        // that moment, so a check made after the awaits below sees a shut window and discards
        // precisely the tail the window existed to record.
        let persistRaw = enableRawCapture || rawCapture.isActive(at: monotonic())

        // Decoding a whole batch is pure and CPU-bound; done here it would parse the live frame
        // flood on the UI's actor. Only the insert and the bookkeeping have to come back.
        //
        // Everything captured is a Sendable value copy. Capturing `self`, `ref` or `policy` would
        // pull main-actor state across the hop and fail to compile.
        let fam = family
        let device = ref.device
        let wallRef = ref.wall
        var streams = await Task.detached(priority: .utility) { () -> Streams in
            let parsed = frames.map { parseFrame($0, family: fam) }
            return extractStreams(parsed, deviceClockRef: device, wallClockRef: wallRef)
        }.value
        // Stays even though it changes nothing today: `extractStreams` decodes the realtime, event
        // and command-response routes only and never fills `resp`. It is what stops a later decoder
        // change from quietly admitting the mode-register rows the backfill path already refuses.
        RespChannelGate.dropIfDegenerate(&streams)

        do {
            try await store.insert(streams, deviceId: deviceId)
        } catch {
            // Back at the FRONT: whatever arrived during the awaits is already appended behind this,
            // so index 0 is what keeps arrival order. Return without touching the cadence stamp or
            // the outbox, because this batch is not durable and anything that treats it as durable
            // is how rows come to exist nowhere.
            buffer.insert(contentsOf: frames, at: 0)
            return
        }
        // Only a drain that landed restarts the interval. Advancing this on failure would silence
        // the time trigger for the whole outage, leaving the frame count as the only way out.
        batchStartedAt = monotonic()

        guard persistRaw else { return }
        let wall = now()
        let stamps = streams.hr.map(\.ts) + streams.rr.map(\.ts)
            + streams.events.map(\.ts) + streams.battery.map(\.ts)
        let meta = RawBatchMeta(
            batchId: UUID().uuidString, deviceId: deviceId, clockRef: ref, capturedAt: wall,
            startTs: stamps.min() ?? wall, endTs: stamps.max() ?? wall,
            frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count })
        // Swallowed on purpose: raw is a research convenience, and the rows that matter are already
        // committed above.
        try? await store.enqueueRawBatch(meta, frames: frames)
    }

    // MARK: - Standard 0x2A37 HR/RR (continuous recording)

    /// Take one standard Heart-Rate-Measurement reading. These carry wall-clock time already, so
    /// they need no correlation and record from the first connection onward.
    func ingestStandardHR(hr: Int, rr: [Int], at ts: Int) {
        let wasEmpty = stdHR.isEmpty && stdRR.isEmpty
        // Physiological bands. While the optical sensor is unlocked or the strap is off the wrist the
        // characteristic still reports, with zeroes and wild values that nothing downstream could
        // tell apart from a real beat.
        if (30...220).contains(hr) { stdHR.append(HRSample(ts: ts, bpm: hr)) }
        stdRR.append(contentsOf: rr.filter { (250...3000).contains($0) }
            .map { RRInterval(ts: ts, rrMs: $0) })
        keepNewest(&stdHR, cap: policy.maxStandardSamples)
        keepNewest(&stdRR, cap: policy.maxStandardSamples)
        // Re-checked rather than assumed: a reading whose HR is out of band and whose intervals are
        // all rejected contributes nothing, and stamping it would arm a deadline over empty buffers.
        if wasEmpty, !stdHR.isEmpty || !stdRR.isEmpty { startStandardBatch() }
        maybeFlushStandardHR()
    }

    /// The rule on its own: enough rows, or any rows that have waited out the interval. Pure and
    /// static so it can be checked without a store, a clock or a task.
    nonisolated static func shouldFlushStandard(rows: Int, waited: TimeInterval?,
                                                maxRows: Int, maxInterval: TimeInterval) -> Bool {
        // Zero rows is nothing to write however long the deadline says it waited; otherwise a strap
        // that simply is not streaming would earn a pointless store write every interval.
        guard rows > 0 else { return false }
        if rows >= maxRows { return true }
        // No stamp means the buffers were empty at the last look. That reads as "the time bound does
        // not apply", never as "has waited forever".
        guard let waited else { return false }
        return waited >= maxInterval
    }

    /// Stamp the open batch and arm its deadline.
    private func startStandardBatch() {
        stdBatchStartedAt = monotonic()
        armStandardDeadline()
    }

    /// Arm the one-shot deadline for the open batch. Without it these buffers move only when a
    /// reading arrives, so the moment the stream goes sparse a batch under the row count sits in RAM
    /// until the process ends. The size clamp never addressed that; this is the durability half.
    private func armStandardDeadline() {
        stdDeadline?.cancel()
        let wait = policy.maxStandardInterval
        stdDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.maybeFlushStandardHR()
        }
    }

    /// Write the standard buffers if either bound says so. Cheap and idempotent; called from every
    /// ingest and from the deadline.
    private func maybeFlushStandardHR() {
        let waited = stdBatchStartedAt.map { monotonic() - $0 }
        guard Collector.shouldFlushStandard(rows: stdHR.count + stdRR.count, waited: waited,
                                            maxRows: policy.maxStandardRows,
                                            maxInterval: policy.maxStandardInterval) else { return }
        coalesced(.standard) { await self.flushStandardHR() }
    }

    /// Persist the buffered standard HR/RR, handing the rows back if the write fails.
    func flushStandardHR() async {
        // Cancelled before the snapshot, not after. A reading arriving while the insert is in flight
        // finds empty buffers, opens a fresh batch and arms its own deadline; cancelling further down
        // would kill that new deadline and strand the new batch until the next reading.
        stdDeadline?.cancel()
        stdDeadline = nil
        guard !stdHR.isEmpty || !stdRR.isEmpty else { stdBatchStartedAt = nil; return }
        let hr = stdHR
        let rr = stdRR
        stdHR.removeAll(keepingCapacity: true)
        stdRR.removeAll(keepingCapacity: true)
        stdBatchStartedAt = nil
        do {
            try await store.insert(Streams(hr: hr, rr: rr), deviceId: deviceId)
        } catch {
            stdHR.insert(contentsOf: hr, at: 0)
            stdRR.insert(contentsOf: rr, at: 0)
            // Bound the overshoot the hand-back just created, in case BLE now goes quiet and nothing
            // else comes along to trim.
            keepNewest(&stdHR, cap: policy.maxStandardSamples)
            keepNewest(&stdRR, cap: policy.maxStandardSamples)
            // Re-stamped, because these rows are an open batch again: unstamped and undeadlined they
            // would never be retried if no further reading arrives to drive the check.
            startStandardBatch()
        }
    }

    // MARK: - Backup barrier

    /// Persist everything buffered so a backup taken straight afterwards actually contains it.
    /// Checkpointing the WAL only writes out what SQLite has already been handed; it knows nothing
    /// about rows still in these buffers, so without this a full flush window of just-recorded HR and
    /// R-R is missing from every snapshot, and only shows up on restore.
    ///
    /// Returns false while a failed write has left rows buffered, so the caller can refuse to ship an
    /// incomplete snapshot instead of writing one that looks fine. Frames still waiting on a clock
    /// correlation deliberately do not count: nothing can persist them yet, and counting them would
    /// block backups forever on a strap whose GET_CLOCK never answers.
    func drainForBackup() async -> Bool {
        await flushStandardHR()
        await flush()
        let standardStuck = !stdHR.isEmpty || !stdRR.isEmpty
        let framesStuck = clockRef != nil && !buffer.isEmpty
        return !standardStuck && !framesStuck
    }

    // MARK: - On-demand raw capture

    /// Open a bounded window so the next drains also persist raw frames while the research toggle is
    /// off. `RawCaptureWindow` clamps the duration and expires on its own deadline, so a stop that
    /// never arrives cannot leave capture running.
    func beginRawCapture(seconds: TimeInterval) {
        rawCapture.open(at: monotonic(), duration: seconds)
    }

    /// Drain first, close second. Closing first would discard exactly the frames the window was
    /// opened for, because `flush` decides the raw question from the window's state at snapshot time.
    func endRawCapture() async {
        await flush()
        rawCapture.close()
    }
}
