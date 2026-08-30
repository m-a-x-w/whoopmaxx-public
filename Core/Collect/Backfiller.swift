// Derived from ParthJadhav/noop, PolyForm Noncommercial License 1.0.0, Copyright 2026 NoopApp.
// Required Notice: Copyright 2026 NoopApp (https://github.com/ParthJadhav/noop)
// Terms: https://polyformproject.org/licenses/noncommercial/1.0.0 — see ../../LICENSE.

import Foundation
import StrapProtocol
import StrapStore
import StrapAnalytics

// MARK: - BackfillStoreWriting

/// Everything one offloaded chunk must have banked BEFORE the strap is told it may erase that chunk.
///
/// The strap's flash is the only copy of banked history until the ack goes out, so these three writes are
/// the durable half of the safe-trim invariant: decoded rows, the opt-in raw frames, and the continuation
/// cursor all land first; the ack is what frees the strap's copy, and it comes afterwards.
///
/// Deliberately a plain async protocol — no `@MainActor`, no `Sendable` constraint. The production store
/// is an actor and the test double is a bare final class, and both satisfy the same three requirements
/// without either one growing isolation it does not want.
///
/// Write-only on the cursor, and a `cursor(_:)` READ requirement must never be added here. `strap_trim`
/// is a forensic breadcrumb; nothing gates on the stored value. A read-back invites a
/// `newTrim > storedCursor` guard, and `0xFFFFFFFF` is a LEGITIMATE terminal value the strap sends once
/// its flash cursor is exhausted (see `noCursorLine`), so that guard would refuse every chunk from a
/// fully drained strap and the offload would never advance again. Spin detection is in-memory, compares
/// with `!=`, and lives in `BLEManager`; `StuckStrapDetector` keys on the persisted-HR frontier instead.
/// `StrapStore.cursor(_:)` still exists for the callers that legitimately read it.
protocol BackfillStoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
    func setCursor(_ name: String, _ value: Int) async throws
}

extension StrapStore: BackfillStoreWriting {}

// MARK: - Backfiller

/// The historical-offload state machine: accumulate the frames a strap streams between its own markers,
/// bank them, then confirm the chunk so the strap may reuse that flash.
///
/// The class exists to hold exactly one ordering:
///
///   decode -> insert (decoded durable) -> enqueueRawBatch (raw durable, opt-in)
///          -> setCursor(strap_trim) -> archive rejects -> ackTrim
///
/// Only the ack frees the strap's copy, so it is last and every failure above it returns without acking.
/// A chunk we refuse to ack is re-offered on the next offload, and the replay is harmless because the
/// store dedupes by timestamp. A chunk we ack but failed to bank is gone from the only device that had
/// it, permanently and silently. Nothing here ever waits on a network.
@MainActor
final class Backfiller {
    /// (parsed frames, deviceClockRef, wallClockRef, sessionOldestUnix?, sessionNewestUnix?) -> Streams.
    /// The trailing pair is the strap's own GET_DATA_RANGE window for THIS sync, or nil while the range
    /// is unknown, in which case the extractor falls back to its absolute plausibility floor.
    typealias Extractor = ([ParsedFrame], Int, Int, Int?, Int?) -> Streams

    // ── injected sinks ──────────────────────────────────────────────────────────

    private let store: BackfillStoreWriting
    /// Confirms one HISTORY_END to the strap. Carries both the trim cursor (the first u32 of end_data,
    /// which is what lands in `strap_trim`) and the whole 8-byte end_data, because the high-freq-sync ack
    /// form echoes those bytes verbatim. A mangled echo makes the strap re-offer the same chunk forever.
    private let ackTrim: (_ trim: UInt32, _ endData: [UInt8]) -> Void
    private let extract: Extractor
    /// Research toggle, default OFF. With it off no raw frames are kept: the decoded streams are still
    /// durable and the trim is still acked, because decoded rows are the product of record. With it on,
    /// raw becomes part of the durability contract and a failed enqueue holds the ack.
    private let enableRawCapture: Bool
    /// Strap log. Everything written here is a user-visible diagnostic, never control flow.
    private let log: ((String) -> Void)?
    /// Durably sets aside record frames this build cannot decode, BEFORE the ack frees the strap's copy.
    /// Returns true once the bytes are safe (written, or the archive cap was reached — either way the
    /// chunk may be acked) and false on a genuine write failure, which holds the ack so the strap
    /// re-sends. nil outside production, where archiving is skipped entirely.
    private let rejectedSink: ((_ frames: [[UInt8]], _ trim: UInt32, _ family: DeviceFamily) -> Bool)?
    /// Per-chunk outcome: (decoded biometric rows, was console-only). Lets the session tell a strap that
    /// banks nothing apart from console chatter from one that is simply caught up.
    private let onChunk: ((_ decoded: Bool, _ console: Bool) -> Void)?
    /// Connection & Sync test mode. `connectionActive` is one UserDefaults bool and is checked BEFORE any
    /// diagnostic line is built, so an offload pays nothing at all when the mode is off. Both default
    /// inert so tests and previews take the untraced path.
    private let connectionActive: () -> Bool
    private let connectionLog: ((String) -> Void)?
    /// Banks the strap's historical record-layout version so the export's clock-drift line is
    /// firmware-aware on every export, not only in Connection mode. Called unconditionally once per
    /// distinct layout per session: this is observability, so it is not behind the test-mode gate.
    private let firmwareLayout: ((Int) -> Void)?

    // ── link-scoped state ───────────────────────────────────────────────────────

    /// Device id offloaded chunks persist under. Mutable so a strap switch re-attributes the very next
    /// chunk instead of freezing the id captured at construction.
    ///
    /// A different strap means a different respiration channel, so the rolling judge is thrown away: a
    /// degenerate verdict latched from the previous strap would suppress a genuine waveform the new one
    /// emits. The session-range markers go with it, because a window describes ONE strap's banked flash
    /// and reusing it gates the new strap's records against a stranger's dates. Re-assigning the SAME id
    /// is a no-op, which matters because the caller re-asserts the id on every connect.
    var deviceId: String {
        didSet {
            guard deviceId != oldValue else { return }
            respJudge = RespChannelGate.RollingJudge()
            sessionOldestUnix = nil
            sessionNewestUnix = nil
        }
    }

    /// Strap-RTC to wall correlation, set once GET_CLOCK answers. Historical records carry their own real
    /// time, so this is a fallback input, not a precondition — see `finishChunk`.
    var clockRef: ClockRef?

    /// The strap's own oldest/newest banked-record markers from the GET_DATA_RANGE reply for the CURRENT
    /// connection. A record dated months outside a window the strap itself reports is wandering-clock
    /// pollution even when it clears the absolute floor, so the extractor's gate rejects it. Both stay nil
    /// until the range is known, and the gate then falls back to the absolute floor alone.
    var sessionOldestUnix: Int?
    var sessionNewestUnix: Int?

    /// The markers as the ingest gate actually receives them.
    ///
    /// A gate that can DROP records has to fail asymmetrically on purpose. The lower bound is the half
    /// that earns its keep: it catches a record dated far before the window the strap published. The upper
    /// bound catches nothing the extractor's absolute future-margin check does not already catch, but a
    /// `newest` that latched a wrong-epoch value would make it reject every genuinely RECENT record —
    /// silent loss of exactly the data the user cares most about. Clamping the ceiling to at least
    /// wall-now makes that impossible while leaving the floor intact.
    ///
    /// A window whose LOWER bound is itself in the future is VOIDED, not clamped, and that distinction is
    /// the subtle one. These markers are raw strap-RTC values, but the extractor rebases each record into
    /// the wall epoch once the clock offset exceeds a day. A strap whose RTC runs ahead therefore leaves
    /// the window sitting in the future while the records it judges are correctly pulled back to now — so
    /// a clamped window would reject the entire offload, which `finishChunk` still acks, freeing the
    /// strap's only copy. Falling back to the absolute floor here loses a defence; clamping loses the data.
    var gateSessionBounds: (oldest: Int?, newest: Int?) {
        guard let oldest = sessionOldestUnix, let newest = sessionNewestUnix else {
            return (sessionOldestUnix, sessionNewestUnix)
        }
        let now = Int(Date().timeIntervalSince1970)
        guard oldest <= now + FUTURE_MARGIN else { return (nil, nil) }
        return (oldest, Swift.max(newest, now))
    }

    /// True while an offload session is running. The caller polls this to decide when the session is over.
    private(set) var isBackfilling = false

    /// Frames accumulated for the chunk currently being built.
    private var chunk: [[UInt8]] = []
    /// Whether frames are being accumulated at all.
    private var chunkOpen = false
    /// Strap family for this offload. Drives both frame parsing (WHOOP 5/MG records sit 4 bytes further
    /// in) and the end_data slice the ack needs. Captured at `begin` rather than at init so it is right
    /// even when the Backfiller was built before the strap identified itself.
    private var family: DeviceFamily = .whoop4

    // ── per-session tallies and once-per-session latches ────────────────────────

    /// Success-side observability. Failures were always logged (decoded-to-zero); successes never were, so
    /// a strap log could not distinguish a strap that banks from one that is broken. Reset in `begin`,
    /// read at session end.
    private(set) var sessionRowsPersisted = 0
    private(set) var sessionMotionRows = 0
    /// Skin-temp samples banked this session. WHOOP 4.0 carries skin temp (and the raw SpO2 channel) only
    /// in its full DSP sleep records, so a strap banking HR/RR-only records reports zero here on an
    /// otherwise healthy sync. Surfacing it makes "skin temp never appears" self-diagnosing.
    private(set) var sessionSkinTempRows = 0
    private var sessionNightKeys: Set<Int> = []
    var sessionNights: Int { sessionNightKeys.count }

    /// Records the extractor dropped this session for an implausible own-timestamp. Observability only —
    /// the gate already kept them out of the store — but a clock-broken strap banking fewer rows than
    /// expected is otherwise invisible.
    private(set) var sessionDroppedImplausible = 0

    /// Distinct layout versions reported this session on a HEALTHY sync, so a shared strap log always
    /// reveals what firmware emits rather than only speaking up when decode fails.
    private var loggedLayoutVersions: Set<Int> = []
    /// Layouts this build has no field map for, reported once each so the log names the gap without spam.
    private var loggedUnmappedVersions: Set<Int> = []
    private var loggedNoCursor = false
    private var loggedFutureRtc = false
    /// Full-record dumps emitted this session, bounded by `Spo2ReTrace.maxSamples`. Session-scoped so the
    /// budget spans chunks rather than resetting every ~50 records.
    private var spo2Dumped = 0

    // ── state that deliberately outlives a session ──────────────────────────────

    /// The trim of the last chunk this Backfiller durably banked AND acked. NOT reset in `begin`: it is a
    /// cross-session high-water mark, and the auto-continue spin detector compares it against the trim the
    /// previous session ended on to answer "did the offload actually move the strap's cursor?". Resetting
    /// it per session makes "advanced" always true and the auto-continue loop re-kicks forever.
    private(set) var lastAckedTrim: UInt32?

    /// Running respiration-degeneracy verdict. Spans chunks by design: high-freq-sync closes a chunk every
    /// ~50 records, permanently under the judge's 60-sample floor, so a chunk-local judgement can never rule.
    ///
    /// Its lifetime is the INSTANCE, not the session, and that is not an oversight. An undecided judge
    /// admits up to `minSamples - 1` rows before it can rule, so the reset cadence sets the residual leak.
    /// Real strap logs show dozens of connection cycles a day, which at per-session reset would re-admit
    /// roughly 1,500 degenerate rows daily; held for the instance the leak is bounded at under 60 rows
    /// total. Never persisted — a stored verdict could not self-heal across a firmware update or a strap swap.
    private var respJudge = RespChannelGate.RollingJudge()

    init(store: BackfillStoreWriting,
         deviceId: String,
         ackTrim: @escaping (_ trim: UInt32, _ endData: [UInt8]) -> Void,
         enableRawCapture: Bool = false,
         log: ((String) -> Void)? = nil,
         rejectedSink: ((_ frames: [[UInt8]], _ trim: UInt32, _ family: DeviceFamily) -> Bool)? = nil,
         onChunk: ((_ decoded: Bool, _ console: Bool) -> Void)? = nil,
         connectionActive: @escaping () -> Bool = { false },
         connectionLog: ((String) -> Void)? = nil,
         firmwareLayout: ((Int) -> Void)? = nil,
         extract: @escaping Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2,
                                                                    sessionOldestUnix: $3, sessionNewestUnix: $4) }) {
        self.store = store
        self.deviceId = deviceId
        self.ackTrim = ackTrim
        self.enableRawCapture = enableRawCapture
        self.log = log
        self.rejectedSink = rejectedSink
        self.onChunk = onChunk
        self.connectionActive = connectionActive
        self.connectionLog = connectionLog
        self.firmwareLayout = firmwareLayout
        self.extract = extract
    }

    /// Emit one Connection & Sync line iff the mode is on. `build()` is an autoclosure so the string is
    /// never constructed when the mode is off, which is the normal case on every user's device.
    private func emitConnection(_ build: @autoclosure () -> String) {
        guard connectionActive(), let connectionLog else { return }
        connectionLog(build())
    }

    // MARK: - Session lifecycle

    /// Arm for a new offload session.
    ///
    /// `chunkOpen` starts TRUE. High-freq-sync begins streaming records immediately and then sends one
    /// HISTORY_START followed by repeated HISTORY_ENDs, so waiting for a START before accumulating throws
    /// away every record that arrives ahead of it.
    func begin(family: DeviceFamily) {
        // The range markers survive an ordinary re-trigger and are cleared only at a FAMILY boundary.
        // They are published exactly once per connection, by the GET_DATA_RANGE reply inside the connect
        // handshake, and that handshake then defers the first offload by about 1.5 s while the range
        // round-trips in far less. Clearing them here unconditionally therefore discarded them moments
        // after they arrived and before the offload they were fetched for, and nothing re-requests the
        // range: every later trigger routes through this same method. The gate then silently ran on
        // (nil, nil) for every real sync.
        //
        // A family switch is different in kind. `.getDataRange` is not in the puffin allowlist, so a
        // WHOOP 5/MG never receives a range reply at all — a WHOOP 4's latched `oldest` would gate the
        // 5/MG's deep backlog and discard it, and `finishChunk` acks regardless of how many records the
        // gate dropped. Accepted cost: the first offload after switching BACK to a family also clears
        // markers that connection had just published, so that one sync runs on the absolute floor. That is
        // inert rather than lossy and self-corrects on the next connect. Stamping the publishing family
        // instead does not work: the range reply lands about a second BEFORE this method learns the new
        // family, so the stamp would name the previous one.
        if family != self.family {
            sessionOldestUnix = nil
            sessionNewestUnix = nil
        }
        self.family = family
        isBackfilling = true
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = true
        sessionRowsPersisted = 0
        sessionMotionRows = 0
        sessionSkinTempRows = 0
        sessionNightKeys.removeAll(keepingCapacity: true)
        loggedNoCursor = false
        loggedFutureRtc = false
        sessionDroppedImplausible = 0
        // Both version latches are per-SESSION, matching what their docs promise. Per-launch instead would
        // report an unmapped firmware once and then never again for the rest of the process.
        loggedLayoutVersions.removeAll(keepingCapacity: true)
        loggedUnmappedVersions.removeAll(keepingCapacity: true)
        spo2Dumped = 0
    }

    /// The strap went silent mid-offload. Drop the open chunk and do NOT ack: those frames were never
    /// banked, so the strap must keep its copy and re-offer them. Acking here would trim exactly the
    /// records just discarded.
    func timeoutFired() {
        isBackfilling = false
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = false
    }

    // MARK: - Frame ingest

    /// The only two packet-type bytes `classifyHistoricalMeta` can answer anything but `.other` for:
    /// 49 METADATA, and 56 PUFFIN_METADATA which the WHOOP 5/MG envelope aliases onto the same name.
    /// Narrowed to `UInt8` once here rather than per frame, because the puffin constant is an `Int` and a
    /// cross-module narrowing carries a precondition that has no business on a per-frame path.
    private nonisolated static let metadataTypeByte: UInt8 = 49
    private nonisolated static let puffinMetadataTypeByte = UInt8(PuffinPacketType.puffinMetadata)

    /// Feed one raw frame into the state machine. May persist and ack.
    func ingest(_ frame: [UInt8]) async {
        // Classify on ONE byte before paying for a whole-frame parse. An offload is about 99.9% type-47
        // record data, and `classifyHistoricalMeta` reads exactly two things out of a parsed frame before
        // answering `.other` for all of them — so every record used to buy a full schema decode (payload
        // CRC32, ten field reads, a dictionary build) on the main actor purely to be appended verbatim.
        //
        // This is identical, not merely close. A type byte that is neither 49 nor 56 cannot produce the
        // METADATA type name, so it could only ever have reached `.other`; a frame too short to hold the
        // byte already reached `.other` through the parser's failure path. Either way the outcome was
        // exactly the append below.
        //
        // The offset differs by family because the puffin envelope is 4 bytes longer: the inner record
        // starts at frame[4] on WHOOP 4.0 and frame[8] on WHOOP 5/MG. Reading frame[4] on a puffin frame
        // misclassifies every METADATA as record data, and the offload then never sees a START or an END —
        // it accumulates forever and acks nothing.
        //
        // This decides who pays for a parse, never who is believed. The forgery gate inside
        // `classifyHistoricalMeta` is untouched: a forged END still has to carry type 49/56, still takes
        // the full parse and is still rejected on its CRC. Nothing here can route a frame to `.end`, so it
        // cannot invent an ack or advance a trim.
        let typeIndex = family == .whoop5 ? 8 : 4
        guard frame.count > typeIndex,
              frame[typeIndex] == Backfiller.metadataTypeByte
                  || frame[typeIndex] == Backfiller.puffinMetadataTypeByte
        else {
            if chunkOpen { chunk.append(frame) }
            return
        }
        switch classifyHistoricalMeta(parseFrame(frame, family: family)) {
        case .start:
            // A new burst is declared. Whatever was accumulated belongs to a burst the strap has moved on
            // from and was never acked, so it will be re-offered; dropping it here only avoids committing
            // a partial.
            isBackfilling = true
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = true
        case .end(let unix, let trim):
            await finishChunk(unix: unix, trim: trim, endFrame: frame)
        case .complete:
            // The backlog is fully handed over. This is the flag the caller polls to leave the session.
            isBackfilling = false
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = false
        case .other:
            if chunkOpen { chunk.append(frame) }
        }
    }

    // MARK: - Pure helpers

    /// The 8-byte end_data the ack echoes: metadata.data[10:18]. metadata.data starts at frame[7] on
    /// WHOOP 4.0 (after type, seq, cmd) and frame[11] on WHOOP 5/MG, so the slice is frame[17:25] or
    /// frame[21:29]. The trim cursor is the first u32 of that slice. nil when the frame is too short to
    /// hold the field, which a real HISTORY_END never is — this guards a malformed frame from producing a
    /// truncated echo the strap would refuse.
    static func endData(from frame: [UInt8], family: DeviceFamily) -> [UInt8]? {
        let start = family == .whoop5 ? 21 : 17
        guard frame.count >= start + 8 else { return nil }
        return Array(frame[start..<(start + 8)])
    }

    /// What one chunk actually banked. `rows` counts biometric rows only — battery and event frames are
    /// housekeeping, and counting them lets a housekeeping-only offload masquerade as banking history,
    /// which forces the empty-banking warning off when the user most needs it.
    ///
    /// `ppgHr` is added separately because the store's insert counts carry no ppgHr field, while a
    /// WHOOP 5/MG v26 optical record decodes to ppgHr ALONE and is persisted. Leaving it out tallies zero
    /// rows for a whole v26 offload, and the caught-up END then fires the alarming "no banked history,
    /// fully charge it" line at a strap that just banked real PPG-derived HR. This is the DECODED count
    /// rather than the deduped inserted count, so a pure re-sync of already-stored v26 records slightly
    /// over-reports: harmless for choosing the message, a cosmetic imprecision on the row total.
    nonisolated static func chunkTally(
        counts: (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int),
        ppgHr: Int = 0,
        timestamps: [Int]
    ) -> (rows: Int, motion: Int, nights: Set<Int>) {
        let rows = counts.hr + counts.rr + counts.spo2 + counts.skinTemp + counts.resp + counts.gravity + ppgHr
        return (rows, counts.gravity, Set(timestamps.map { $0 / 86400 }))
    }

    /// The one-line session summary. nil when nothing persisted, so a caught-up or console-only session
    /// stays quiet and the empty-banking diagnostics get to speak instead of being drowned by a "0 rows" line.
    nonisolated static func sessionSummaryLine(rows: Int, motion: Int, skinTemp: Int, nights: Int) -> String? {
        guard rows > 0 else { return nil }
        return "Backfill: session persisted \(rows) rows (\(motion) with motion, \(skinTemp) skin-temp) across \(nights) night(s)."
    }

    /// The trim=0xFFFFFFFF sentinel line. The value means two different things depending on whether this
    /// run already banked anything. On the first end of a fresh offload it is "no valid flash cursor" — a
    /// clock or charge state on the strap. But auto-continuation re-kicks the offload after a run that DID
    /// persist rows, and the next end then carries the same sentinel to mean "caught up, nothing past the
    /// last trim". Emitting the alarming charge-the-strap guidance there frightened users whose strap had
    /// just synced perfectly, so the message is picked by `rowsPersisted`. Pure so a fixture can pin both arms.
    nonisolated static func noCursorLine(rowsPersisted: Int) -> String {
        if rowsPersisted > 0 {
            return "Backfill: reached the end of available history (trim=0xFFFFFFFF) - caught up after persisting \(rowsPersisted) row(s) this run. Nothing more to offload."
        }
        return "Backfill: strap reported no flash cursor (trim=0xFFFFFFFF) - it has no banked history to offload. This is a clock/charge state on the strap, not a decode problem; fully charge it and reconnect so it starts banking."
    }

    /// How far ahead of the wall clock a HISTORY_END's own timestamp may sit before the strap RTC is
    /// called corrupt. A genuine offload is always PAST-dated because it is banked history. One day is
    /// generous on purpose so ordinary skew or a timezone confusion never trips it.
    nonisolated static let futureRtcToleranceSeconds = 86_400

    /// Is this HISTORY_END timestamp an implausible future date, i.e. a corrupt strap RTC? Both arguments
    /// are unix seconds in the same wall domain. Pure so a fixture can pin the boundary.
    nonisolated static func isCorruptFutureRtc(endUnix: Int, wallNowUnix: Int) -> Bool {
        endUnix > wallNowUnix + futureRtcToleranceSeconds
    }

    /// The recovery hint for a future-dated strap RTC. Names the cause plainly (the strap's clock, not an
    /// app bug) and gives the fix, because the symptom the user sees is days of missing history.
    nonisolated static func futureRtcLine(endUnix: Int, wallNowUnix: Int) -> String {
        let aheadDays = max(0, (endUnix - wallNowUnix)) / 86_400
        return "Backfill: the strap reported a record dated about \(aheadDays) day(s) in the FUTURE - its clock (RTC) is corrupt, not a whoopmaxx problem. Those records can't be filed onto the right day. Fully charge the strap to 100% and reconnect so it re-syncs its clock; if it persists, forget and re-pair the strap."
    }

    // MARK: - Chunk commit

    /// The decode result for one chunk, produced off the main actor. Value types only, so the detached
    /// task never has to capture `self`.
    private struct DecodedChunk {
        let parsed: [ParsedFrame]
        let decoded: Streams
        let rejected: [[UInt8]]
    }

    /// Commit one HISTORY_END and confirm it to the strap.
    ///
    /// `chunkOpen` STAYS TRUE across this. High-freq-sync sends ONE HISTORY_START and then a HISTORY_END
    /// roughly every 50 records, so closing the chunk after the first end stops accumulation dead and the
    /// rest of the offload is acked away empty. An END with no accumulated frames is still acked — that is
    /// how a caught-up strap advances its cursor.
    private func finishChunk(unix: UInt32, trim: UInt32, endFrame: [UInt8]) async {
        // No end_data means no echo the strap would accept, so there is nothing to confirm and nothing to
        // gain from banking against a token we cannot return.
        guard let endData = Backfiller.endData(from: endFrame, family: family) else { return }

        noteFutureRtc(endUnix: Int(unix), trim: trim)

        // Snapshot and clear so frames arriving during the awaits below land in the NEXT chunk instead of
        // being committed twice under this token.
        let frames = chunk
        chunk.removeAll(keepingCapacity: true)

        // Rejects are collected during decode but archived LAST, after the cursor write. The archive is
        // append-only, so archiving before a step that can return-without-acking would duplicate every
        // line when the strap re-sends the chunk.
        var rejectsToArchive: [[UInt8]] = []

        if !frames.isEmpty {
            // Type-47 records carry their OWN real-unix timestamp, which the extractor uses directly, so a
            // historical chunk does not need GET_CLOCK to have answered. With no correlation yet, an
            // identity ref makes the offset math a no-op and the chunk still decodes to correct wall time.
            // The correlation is only genuinely required for realtime frames, which are stamped in the
            // strap's own epoch and never appear here.
            let ref = clockRef ?? { let now = Int(Date().timeIntervalSince1970); return ClockRef(device: now, wall: now) }()

            // The heavy work runs OFF the main actor: N frame parses, the extractor, and the reject
            // classifier's second pass. On the main actor a long offload froze the UI outright (tens of
            // thousands of parses for a single import). Everything captured here is a value type or the
            // injected closure, deliberately never `self` — capturing self would either reintroduce the
            // main-actor hops this exists to remove or fail isolation outright. Every store write, tally
            // and the ack sequence stay on the main actor below, in order, so the safe-trim ordering holds.
            let fam = family
            let dev = ref.device, wall = ref.wall
            let (oldest, newest) = gateSessionBounds
            let extractFn = extract   // the injected seam tests override; production is extractHistoricalStreams
            let d = await Task.detached(priority: .utility) { () -> DecodedChunk in
                let parsed = frames.map { parseFrame($0, family: fam) }
                let decoded = extractFn(parsed, dev, wall, oldest, newest)
                let rejected = rejectedHistoricalRecords(frames, family: fam)
                return DecodedChunk(parsed: parsed, decoded: decoded, rejected: rejected)
            }.value

            reportLayout(parsed: d.parsed, frames: frames)

            var decoded = d.decoded

            // Drop a degenerate raw-respiration channel BEFORE it reaches the store. On the WHOOP 4.0 v24
            // layout the field mapped as raw respiration is an optical MODE REGISTER, not a waveform: it
            // held two distinct values across 1.4M real rows, cost about 16% of a 442 MB store to record
            // one bit per row, and yielded a finite RRV on none of 16,730 real epochs.
            //
            // Through the SESSION-scoped judge rather than the chunk-local predicate. A high-freq-sync
            // chunk is ~50 records, under the gate's 60-sample floor, so the chunk-local form could never
            // rule and the gate never fired once — a real store written by a build that already carried it
            // still held 67,559 respiration rows carrying exactly two distinct values. The judge
            // accumulates the same distinctness evidence across chunks, rules once it clears the floor, and
            // latches permanently the first time it sees a genuine waveform, so a firmware that emits real
            // respiration is never suppressed.
            respJudge.dropIfDegenerate(&decoded)

            reportChunkShape(frames: frames, decoded: decoded, rejected: d.rejected, trim: trim)

            // The durable ladder. Returning here holds the ack, so the strap keeps this chunk and
            // re-delivers it; nothing further down the ladder has run.
            guard await bank(decoded: decoded, frames: frames, ref: ref, trim: trim) else { return }
            rejectsToArchive = d.rejected
        }

        // The sentinel report is deliberately AFTER the persist block. A strap with a bad clock or flash
        // can emit records on the SAME 0xFFFFFFFF end, so `sessionRowsPersisted` must already include this
        // end's own rows before the message is picked — otherwise a records-bearing no-cursor end tells the
        // user their strap has no banked history while it is actively banking. Once per session; the ack
        // still proceeds below either way.
        if trim == 0xFFFFFFFF, !loggedNoCursor {
            loggedNoCursor = true
            log?(Backfiller.noCursorLine(rowsPersisted: sessionRowsPersisted))
            emitConnection(ConnectionTrace.noCursorLine())
        }

        // Continuation cursor. Acking before this lets the strap trim past records the cursor never
        // recorded, so a reconnect can replay or skip an unknown span. Holding the ack instead costs one
        // re-sent chunk.
        do { try await store.setCursor("strap_trim", Int(trim)) } catch {
            log?("Backfill: failed to write strap_trim cursor (trim=\(trim)): \(error) - holding ack so the strap re-sends this chunk; history won't advance until the cursor write succeeds.")
            return
        }

        // Archive the undecodable records. Last of the durable steps so any EARLIER failure returns before
        // this runs and a re-sent chunk cannot duplicate lines in an append-only archive. Still ahead of
        // the ack, because once the strap trims, this archive is the only surviving copy of an unmapped
        // firmware's records. A genuine write failure holds the ack: setCursor is idempotent on the re-run
        // and the decoded/raw re-inserts dedupe, so the replay costs nothing.
        if !rejectsToArchive.isEmpty, let rejectedSink {
            guard rejectedSink(rejectsToArchive, trim, family) else {
                log?("Backfill: rejected-frame archive failed (trim=\(trim)) - holding ack so the strap re-sends.")
                return
            }
        }

        // Everything this chunk carried is durable. Only now may the strap be told it can reuse the flash.
        ackTrim(trim, endData)
        lastAckedTrim = trim
    }

    /// Persist one chunk's decoded rows and, when the research toggle is on, its raw frames. Returns false
    /// once a failure has been logged, and the caller must then hold the ack: an acked chunk we failed to
    /// bank exists nowhere, because the ack is what lets the strap erase its own copy.
    private func bank(decoded: Streams, frames: [[UInt8]], ref: ClockRef, trim: UInt32) async -> Bool {
        // Decoded rows first: they are the product of record, and a failure here means nothing else in the
        // ladder has run yet, so the whole chunk is cleanly re-sent next session.
        let counts: (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
        do { counts = try await store.insert(decoded, deviceId: deviceId) } catch {
            // Re-delivery is safe because inserts dedupe by timestamp. The log line exists because a silent
            // return here is the "live HR works but history never advances" report with nothing to confirm it.
            log?("Backfill: failed to persist decoded rows (trim=\(trim)): \(error) - holding ack so the strap re-sends this chunk; history won't advance until the write succeeds.")
            return false
        }

        let tally = Backfiller.chunkTally(counts: counts, ppgHr: decoded.ppgHr.count,
                                          timestamps: decoded.gravity.map(\.ts) + decoded.hr.map(\.ts)
                                              + decoded.ppgHr.map(\.ts))
        sessionRowsPersisted += tally.rows
        sessionMotionRows += tally.motion
        sessionSkinTempRows += counts.skinTemp
        sessionNightKeys.formUnion(tally.nights)

        // Running totals per chunk, so a Connection report shows the offload ADVANCING rather than only its
        // final outcome — a stalled sync and a slow one look identical from the end state.
        emitConnection("offload progress trim=\(trim) chunkRows=\(tally.rows) "
            + "sessionRows=\(sessionRowsPersisted) sessionMotion=\(sessionMotionRows) nights=\(sessionNights)")

        // Raw frames only when the research toggle is on. With it off there is nothing to persist and
        // decoded alone justifies the ack. With it on, raw is part of the contract, so a failed enqueue
        // holds the ack exactly like a failed insert.
        guard enableRawCapture else { return true }
        let meta = RawBatchMeta(
            batchId: "hist-\(deviceId)-\(trim)",
            deviceId: deviceId,
            clockRef: ref,
            capturedAt: Int(Date().timeIntervalSince1970),
            startTs: ref.wall,
            endTs: ref.wall,
            frameCount: frames.count,
            byteSize: frames.reduce(0) { $0 + $1.count })
        do { try await store.enqueueRawBatch(meta, frames: frames) } catch {
            log?("Backfill: failed to enqueue raw batch (trim=\(trim)): \(error) - holding ack so the strap re-sends this chunk; raw capture must be durable before the trim advances.")
            return false
        }
        return true
    }

    // MARK: - Diagnostics

    /// A HISTORY_END carries the strap's own clock. Banked history is always past-dated, so an end dated
    /// days into the future can only be a corrupt RTC, and it is the earliest visible tell — earlier than
    /// the per-record drops. Surfaced once per session with the fix; the ack still proceeds, because the
    /// ingest gate already keeps the badly-dated rows out of the store and refusing to ack would only wedge
    /// the offload. The 0xFFFFFFFF sentinel is not a date at all, so it is excluded rather than reported as
    /// a corrupt clock.
    private func noteFutureRtc(endUnix: Int, trim: UInt32) {
        guard trim != 0xFFFFFFFF, !loggedFutureRtc else { return }
        let wallNow = Int(Date().timeIntervalSince1970)
        guard Backfiller.isCorruptFutureRtc(endUnix: endUnix, wallNowUnix: wallNow) else { return }
        loggedFutureRtc = true
        log?(Backfiller.futureRtcLine(endUnix: endUnix, wallNowUnix: wallNow))
    }

    /// What firmware layout this strap actually emits, plus the bounded raw-record dump.
    private func reportLayout(parsed: [ParsedFrame], frames: [[UInt8]]) {
        // Report the layout on a HEALTHY sync too. The unmapped-version path below only fires for layouts
        // this build cannot decode, so a normal log never revealed which firmware the strap actually emits
        // — and that is the first thing anyone needs when a decode goes wrong.
        if let v = parsed.lazy.compactMap({ $0.parsed["hist_version"]?.intValue }).first,
           loggedLayoutVersions.insert(v).inserted {
            log?("Backfill: historical records use layout v\(v)")
            firmwareLayout?(v)
            emitConnection({
                let decodable = parsed.contains {
                    $0.parsed["heart_rate"] != nil || $0.parsed["gravity_x"] != nil
                        || $0.parsed["ppg_waveform"] != nil
                }
                return ConnectionTrace.firmwareLine(version: v, decodable: decodable)
            }())
        }

        // While Connection mode is on, dump a few complete records plus their mapped raw SpO2 channels so
        // an offline pass can settle whether the strap banks a COMPUTED SpO2 percentage or only the red/IR
        // ADC this build already decodes. Bounded across the whole session, and only records with a decoded
        // timestamp spend the budget — the strap's console frames carry nothing to correlate. Records are
        // dumped whether or not they carry SpO2 channels, so "the strap banks nothing here" is provable
        // rather than merely unobserved. Never surfaced as a user-facing number: an unverified SpO2 reading
        // would be a fabricated vital sign.
        if spo2Dumped < Spo2ReTrace.maxSamples, connectionActive(), let connectionLog {
            for (raw, p) in zip(frames, parsed) where spo2Dumped < Spo2ReTrace.maxSamples {
                guard let unix = p.parsed["unix"]?.intValue else { continue }
                connectionLog(Spo2ReTrace.recordLine(
                    frame: raw,
                    version: p.parsed["hist_version"]?.intValue,
                    unix: unix,
                    red: p.parsed["spo2_red"]?.intValue,
                    ir: p.parsed["spo2_ir"]?.intValue,
                    skinRaw: p.parsed["skin_temp_raw"]?.intValue))
                spo2Dumped += 1
            }
        }

        // A record whose firmware layout has no field map bails out of decode entirely: no HR, no R-R, and
        // crucially no gravity, so sleep can never be computed from it even though the offload "completes"
        // and acks. Surface each such version once so the user's log names the gap.
        //
        // "Decoded nothing" has to test every mapped layout's signature field, because they differ: v18
        // emits heart_rate, v25 emits gravity_x with no per-second HR at all (it is PPG-derived), v26 emits
        // ppg_waveform and likewise no HR. Testing heart_rate alone flagged perfectly healthy v25/v26
        // straps as unmapped.
        for p in parsed {
            guard let v = p.parsed["hist_version"]?.intValue,
                  p.parsed["heart_rate"] == nil,
                  p.parsed["gravity_x"] == nil,
                  p.parsed["ppg_waveform"] == nil,
                  !loggedUnmappedVersions.contains(v) else { continue }
            loggedUnmappedVersions.insert(v)
            log?("Historical records use firmware layout v\(v), which whoopmaxx doesn't decode yet - no motion data, so sleep can't be computed from the strap. Please report this.")
        }
    }

    /// Tell the session what this chunk actually was, and log the two shapes a user has to be able to
    /// distinguish: harmless console chatter, and records this build could not read.
    private func reportChunkShape(frames: [[UInt8]], decoded: Streams, rejected: [[UInt8]], trim: UInt32) {
        // The extractor already dropped records whose own timestamp was implausible, before they could be
        // filed onto the wrong day. Report it once the session has seen at least one, so the log explains
        // why a clock-broken strap banks fewer rows than expected. Observability only.
        if decoded.droppedImplausible > 0 {
            let wasZero = sessionDroppedImplausible == 0
            sessionDroppedImplausible += decoded.droppedImplausible
            if wasZero {
                log?("Backfill: dropped record(s) with an implausible timestamp (trim=\(trim)) - the strap's clock is wrong (records dated far in the past or future), so those samples were skipped rather than misfiled onto the wrong day. Fully charge and reconnect the strap so its clock re-syncs.")
            }
        }

        // Did this chunk decode BIOMETRIC rows, and was it console-only? Judged on biometric streams alone:
        // `decoded.isEmpty` also counts battery and event housekeeping as "decoded", which lets a
        // battery-only offload look like a banking one and silently defeats the empty-banking warning the
        // user needs when their strap has stopped recording.
        let decodedSensor = !(decoded.hr.isEmpty && decoded.rr.isEmpty && decoded.spo2.isEmpty
            && decoded.skinTemp.isEmpty && decoded.resp.isEmpty && decoded.gravity.isEmpty
            && decoded.steps.isEmpty && decoded.sleepState.isEmpty && decoded.ppgHr.isEmpty)
        onChunk?(decodedSensor, !decodedSensor && rejected.isEmpty)

        // No rows and no genuine rejects is pure console output. Say so calmly: users kept reporting this
        // as data loss, and the alarming wording was the reason.
        if decoded.isEmpty && rejected.isEmpty {
            log?("Backfill: \(frames.count) frame(s) this chunk carried no sensor records (strap console/diagnostic output) - normal, nothing to persist (trim=\(trim)).")
        }
        // Report genuine rejects whenever there are any, INCLUDING a partly-decoded chunk. Only the
        // all-empty case used to be observable, so good rows arriving alongside undecodable ones got
        // archived with no log line at all.
        guard !rejected.isEmpty else { return }
        log?("Backfill: \(rejected.count) undecodable sensor record(s) of \(frames.count) frame(s) (trim=\(trim)) - archiving raw bytes before ack (CRC/unmapped layout).")
        // Hex-dump a sample so an unmapped firmware's record layout can be reconstructed from a user's log.
        // The WHOLE frame, not a 64-byte prefix: v25/v26 records run to about 84 bytes and the truncated
        // tail is exactly where the unmapped motion and HR fields sit. Only ever fires for firmware this
        // build cannot decode.
        for (i, f) in rejected.prefix(8).enumerated() {
            let hex = f.map { String(format: "%02x", $0) }.joined()
            log?("Backfill: rejected frame[\(i)] \(f.count)B: \(hex)")
        }
    }
}
