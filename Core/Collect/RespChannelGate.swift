import Foundation
import StrapProtocol

/// INGEST-SIDE gate for the raw respiration channel: drop a chunk's `resp` rows when they carry no
/// information, before they are ever written to the store.
///
/// WHY. `whoop_protocol.json` maps HISTORICAL_DATA (type 47) layout v24 offset 80 as
/// `resp_rate_raw` — its own note already conceding "raw; resp rate computed server-side". On real
/// hardware it is not a waveform at all: a 17-day / 442 MB user store holds 1,433,848 respSample rows
/// carrying exactly TWO distinct values — 3073 (0x0C01) ×1,426,101 and 2817 (0x0B01) ×7,747. Little-endian
/// that is a constant 0x01 low-byte tag with a high byte toggling 12↔11 in ~29-second bursts roughly every
/// 19 minutes, 97.4% of them inside a sleep session and at a mean HR of 54.5 bpm vs 74.9 outside. It is a
/// duty-cycled optical measurement/calibration mode register, sitting exactly where the neighbouring
/// `led_drive_1@76` / `led_drive_2@78` / `signal_quality@82` registers imply — the same sibling pattern the
/// repo already mapped as `status_word_1@77` / `status_word_2@79` on the WHOOP 5 v18 layout. Its true
/// information content is one bit per row.
///
/// The cost of persisting it is not one bit per row. In that same store the `respSample` b-tree is 36.11 MB
/// and its `sqlite_autoindex_respSample_1` (forced by the non-INTEGER `(deviceId, ts)` primary key) another
/// 36.25 MB — 72.36 MB, 16.35% of the whole database, ~50.5 bytes per recorded bit. And downstream it is
/// worse than useless: replaying `SleepStaging.respRateAndRRV` over the real per-epoch windows of all 21
/// stored sleep sessions yields a finite RRV on 0 of 16,730 epochs, while its mere PRESENCE used to
/// suppress the RR-RSA fallback that recovers one on 99.92% of them (see `SleepStaging.respChannelUsable`).
///
/// SHAPE OF THE GATE. Deliberately a DISTINCTNESS test, not a strap-model or layout blocklist: a firmware
/// or layout that ever emits a genuine respiration waveform has many ADC levels and sails through with no
/// further change, so the code self-heals rather than needing a follow-up wave. The `minSamples` floor
/// keeps a tiny chunk (a handful of records that legitimately happen to share a value) from being judged.
/// The sibling channels in the same records — 508 distinct skin-temp values, 163 distinct SpO₂ red, 146
/// distinct HR — prove the offsets and the decoder are fine; only @80 is degenerate.
enum RespChannelGate {
    /// Fewer samples than this and a repeated value proves nothing, so the chunk is left alone.
    static let minSamples = 60
    /// A channel with at most this many distinct raw values cannot produce a peak-picked breathing rate.
    /// Mirrors `SleepStaging.respMinDistinctRawLevels` (3) from the other side of the same threshold.
    static let maxDegenerateLevels = 2

    /// True when `resp` is large enough to judge AND carries ≤ `maxDegenerateLevels` distinct raw values.
    static func isDegenerate(_ resp: [RespSample]) -> Bool {
        if resp.count < minSamples { return false }
        var levels: Set<Int> = []
        for s in resp {
            levels.insert(s.raw)
            if levels.count > maxDegenerateLevels { return false }   // short-circuits on a real waveform
        }
        return true
    }

    /// CHANNEL-GLOBAL judge for ingest paths whose chunks are too small to judge on their own.
    ///
    /// WHY THIS EXISTS. `isDegenerate` is CHUNK-LOCAL: its `minSamples` floor makes it return false for any
    /// chunk under 60 samples. The only path that carries resp at all is the BACKFILL path
    /// (`extractHistoricalStreams` is the sole producer of `RespSample`; `extractStreams`, which the live
    /// `Collector` uses, never appends one) — and there a chunk is NOT the bulk offload the floor assumes.
    /// High-freq-sync sends one HISTORY_START then repeated HISTORY_ENDs, closing a chunk every ~50 records
    /// (`Backfiller.finishChunk`), permanently under the floor. So the gate returned false on every chunk
    /// and never fired at all.
    ///
    /// Measured on the real 2026-07-30 backup: 67,559 `respSample` rows carrying exactly two distinct raw
    /// values (3073 ×67,128 / 2817 ×431), 13.85% of the file, written by a build that already carried the
    /// gate. Splitting the hrSample timeline by resp presence yields exactly two runs with no holes across
    /// ~1,350 consecutive chunks — i.e. not one chunk was ever judged degenerate.
    ///
    /// RETRACTION, because the first diagnosis of this is in the commit history and is wrong. That store's
    /// missing 4-hour resp PREFIX was read as "large backfill chunks → the gate fired → zero rows", which
    /// would mean the gate worked on some paths. It cannot be: the run boundary is clean and no chunk ever
    /// tripped the floor. The prefix is absent because `StoreMaintenance.purgeDegenerateRespSamplesIfNeeded`
    /// ran once around that instant and issued a whole-table `DELETE FROM respSample`. Do not re-derive the
    /// two-path theory from the earlier commits — there is one resp ingest path, and the gate never fired
    /// on it at all.
    ///
    /// SHAPE. Fold distinctness ACROSS chunks:
    ///  - ≥ 3 distinct levels at ANY point → `.genuine`, permanently, and nothing is ever dropped again;
    ///  - `minSamples` seen with ≤ `maxDegenerateLevels` → `.degenerate`, and later chunks are dropped.
    ///
    /// A `.degenerate` verdict is NOT terminal for the evidence. Every chunk keeps folding into `levels`,
    /// so a channel that later starts emitting a real waveform flips to `.genuine` and is never suppressed
    /// again. That matters on a real sequence: a firmware update makes `resp_rate_raw@80` a true waveform,
    /// but the strap still holds days of PRE-update records and offloads oldest-first, so the degenerate
    /// evidence necessarily arrives BEFORE the genuine data. A terminal latch would drop the good rows and
    /// then ack them away. This is the self-healing distinctness property the type doc promises, and it is
    /// the reason the verdict is never persisted either — a stored `.degenerate` would survive a firmware
    /// update or a strap swap with nothing able to clear it.
    ///
    /// SCOPE IS THE OWNER'S LIFETIME. An `.undecided` judge admits up to `minSamples - 1` rows before it
    /// can rule, so the owner's reset cadence sets the residual leak. `Backfiller` holds one for the
    /// instance's life (≈ per launch) rather than resetting per offload session: the real store logs 26
    /// connections in 19 h, so a per-session judge would still bank ~1,500 rows/day versus ≤ 59 total.
    /// It IS reset on a strap change, where the prior strap's verdict says nothing about the new one.
    struct RollingJudge {
        enum Verdict: Equatable { case undecided, degenerate, genuine }

        private(set) var verdict: Verdict = .undecided
        /// Distinct raw levels seen while `.undecided`. Never grows past `maxDegenerateLevels + 1` — the
        /// insert loop latches `.genuine` the moment it would.
        private var levels: Set<Int> = []
        private var seen = 0

        init() {}

        /// True when this chunk's rows should be dropped, folding it into the running verdict first.
        mutating func shouldDrop(_ resp: [RespSample]) -> Bool {
            if verdict == .genuine { return false }           // terminal: a real waveform, never re-judged
            // An empty chunk is not evidence in either direction (a console-only chunk carries no resp),
            // so it must not advance `seen` — but it also must not un-latch a standing verdict.
            if resp.isEmpty { return verdict == .degenerate }
            seen += resp.count
            // Keep folding levels EVEN WHEN ALREADY `.degenerate`. The latch stops rows, not evidence:
            // a firmware that starts emitting a real waveform must still be able to flip this, and its
            // pre-update records necessarily arrive first (see the type doc).
            for s in resp {
                levels.insert(s.raw)
                if levels.count > maxDegenerateLevels {
                    verdict = .genuine
                    return false
                }
            }
            if verdict == .degenerate { return true }
            guard seen >= minSamples else { return false }   // not enough evidence yet; admit the rows
            verdict = .degenerate
            return true
        }

        /// `dropIfDegenerate`'s stateful twin: blank `streams.resp` in place once the channel is judged
        /// degenerate, and keep folding evidence until it can be.
        mutating func dropIfDegenerate(_ streams: inout Streams) {
            if shouldDrop(streams.resp) { streams.resp = [] }
        }
    }

    /// Blank `streams.resp` in place when the chunk's respiration channel is degenerate; no-op otherwise.
    /// `StreamStore.insert` already skips its INSERT loop on an empty array, so the rows are simply never
    /// written and the returned `counts.resp` honestly reports 0.
    ///
    /// CHUNK-LOCAL — correct only where a chunk is big enough to judge (the bulk backfill path). Small-chunk
    /// ingest must use `RollingJudge` instead; see its doc for why.
    static func dropIfDegenerate(_ streams: inout Streams) {
        if isDegenerate(streams.resp) { streams.resp = [] }
    }
}
