import Foundation
import StrapProtocol
import StrapStore

/// App-layer bridge that pulls one night's raw gravity from the store and runs `PostureEngine.analyze`
/// ONCE for a Rest day-view — the twin of `ArousalForensicsLoader`. Pure orchestration on top of
/// existing read APIs: NO StrapStore schema change, NO migration, and nothing written back.
///
/// The Rest screen caches the returned read per day-view (see `PostureLoaded`'s `.task(id:)`), so the
/// clustering never runs on a SwiftUI frame.
///
/// Framing register (011 decision 5): descriptive, within-user, no condition name, no probability, no
/// call-to-action. Banned from every string this type and its surfaces produce — *thermoregulation,
/// vasodilation, impaired, poor, abnormal, apnea, insomnia, hypoxemia, arrhythmia, "consider", "you
/// should", "talk to"*. And it never names a body position: a wrist is not a torso (see
/// `PostureEngine`).
enum PostureLoader {

    /// Cap on the gravity read, matching `NightTape.load`'s — a night of 1 Hz gravity is ~30,000 rows,
    /// so this only ever bounds a pathological window.
    static let gravityLimit = 500_000

    /// One night's orientation read: the tape and its cross-tab against the staged spans.
    struct Night: Equatable, Sendable {
        let read: PostureEngine.Night
        /// Per-orientation stage mix; EMPTY when the night carries no stage timeline to cross against
        /// (the surface then drops that block rather than showing empty bars).
        let mix: [PostureEngine.StageMix]

        var start: Int { read.start }
        var end: Int { read.end }
    }

    /// What a read found — and specifically, WHY it found nothing when it found nothing.
    ///
    /// The distinction exists because the Rest screen makes a factual claim off it: past the 28-day raw
    /// horizon it says the night's wrist motion "is no longer stored". That is true of `.noSamples` and
    /// false of `.unreadable`, where the gravity is still on disk and merely would not cluster. Folding
    /// both into a nil let the screen blame retention for a limit of the analysis.
    enum Outcome: Equatable {
        case read(Night)
        /// Gravity WAS banked for this window; the night could not be clustered from it — too little
        /// held still, or no orientation the night returned to.
        case unreadable
        /// No gravity rows at all: pruned past `SampleRetention.retentionDays`, or never banked.
        case noSamples

        /// The night, when there is one — so callers that only want to draw a tape stay simple.
        var night: Night? {
            if case .read(let n) = self { return n }
            return nil
        }
    }

    /// Read one detected session's wrist orientations.
    ///
    /// - Parameters:
    ///   - session: the night to read. Its `effectiveStartTs`…`endTs` is the window — the same onset
    ///     the hypnogram above the tape is drawn from, so the two lanes line up. (`startTsAdjusted`
    ///     has no producer in this app, so this is `startTs` on every stored row today.)
    ///   - store: an open StrapStore (from `Repository.storeHandle()`).
    ///   - strapDeviceId: the strap/import lane the RAW gravity lives under (`Repository.deviceId`) —
    ///     NOT the computed sibling, which holds no raw stream.
    /// - Returns: `.read` with the night, `.unreadable` when gravity was banked but would not cluster,
    ///   or `.noSamples` when the store held none at all. The last two both hide the section, but only
    ///   `.noSamples` may be described as data that is no longer stored.
    static func load(session: CachedSleepSession,
                     store: StrapStore,
                     strapDeviceId: String) async -> Outcome {
        let start = session.effectiveStartTs
        let end = session.endTs
        guard end > start else { return .noSamples }
        let gravity = (try? await store.gravitySamples(deviceId: strapDeviceId, from: start, to: end,
                                                       limit: gravityLimit)) ?? []
        // WHY EMPTINESS IS REPORTED SEPARATELY FROM UNREADABILITY. A nil read used to mean five
        // different things at once — degenerate window, no gravity banked, too little of it, never held
        // still long enough, no orientation returned to — and the Rest screen turned every one of them
        // past the 28-day horizon into "its wrist motion is no longer stored". On a night whose gravity
        // IS still on disk and simply would not cluster, that sentence is false in the confident way:
        // it blames retention for a limit of the analysis. Only an empty read is an absence.
        guard !gravity.isEmpty else { return .noSamples }
        guard let read = PostureEngine.analyze(gravity: gravity, start: start, end: end) else {
            return .unreadable
        }
        // The stage timeline is already on the session row — no second read. Absent/malformed JSON
        // decodes to [], which `stageMix` answers with [] and the surface answers by dropping the
        // cross-tab entirely.
        let stages = SleepStage.decode(session.stagesJSON)
        return .read(Night(read: read, mix: PostureEngine.stageMix(night: read, stages: stages)))
    }
}
