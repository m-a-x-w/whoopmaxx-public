import SwiftUI
import StrapStore
import StrapAnalytics

/// Night detail (037) — pushed from Rest's "Night detail" row. The three reads of one night that
/// need its RAW streams, which is why they live one push away from the Rest scroll: the Movement
/// seismograph, "Why you woke" (the arousal forensics) and "Wrist orientation" (the posture lane).
///
/// This wrapper owns the reads and nothing else. The seismograph's tape is read ONCE per night window in
/// `.task(id:)`; the two cluster loaders below read and classify their own streams once per day-view,
/// so no analysis ever runs on a SwiftUI frame. Every gating rule each section had on Rest comes with it
/// unchanged: a section needs a detected session, and past the raw-retention horizon each says the raw
/// signal is gone instead of rendering an absence as a finding. READ-ONLY — nothing here writes.
struct NightDetailScreen: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    /// The night Rest is on — the SAME `RestNight` its hero was built from, so every section here
    /// describes the night the user tapped through from.
    let night: RestNight
    /// That night's detected session (`RestModel.Assembly.lastSession`); nil hides the two clusters.
    let session: CachedSleepSession?
    /// The night's span caption ("Mon 28 – Tue 29"), exactly as Rest's header prints it.
    let subtitle: String?

    @State private var tape: NightTape?
    @State private var tapeLoaded = false

    var body: some View {
        NightDetailContent(
            subtitle: subtitle,
            onBack: { dismiss() },
            movement: NightMovementContent(tape: tape, loaded: tapeLoaded, dayKey: night.dayKey),
            arousals: AnyView(ArousalForensicsLoaded(session: session, dayKey: night.dayKey)),
            posture: AnyView(PostureLoaded(session: session, dayKey: night.dayKey)))
            .toolbar(.hidden, for: .navigationBar)
            .task(id: windowKey) { await loadTape() }
    }

    /// Reload the tape only when the night window changes (a different night pushed).
    private var windowKey: String {
        "\(Int(night.bed?.timeIntervalSince1970 ?? 0))-\(Int(night.wake?.timeIntervalSince1970 ?? 0))"
    }

    @MainActor
    private func loadTape() async {
        tape = nil
        tapeLoaded = false
        guard let bed = night.bed, let wake = night.wake, wake > bed else { tapeLoaded = true; return }
        let start = Int(bed.timeIntervalSince1970)
        let end = Int(wake.timeIntervalSince1970)
        guard let store = await repo.storeHandle() else { tapeLoaded = true; return }
        // The per-epoch motion fallback is keyed by the detected session's startTs — resolve it here on the
        // main actor (`repo.sleeps` is main-actor state) so the background builder needs only the key.
        let motionKey = repo.sleeps.first(where: { $0.effectiveStartTs == start && $0.endTs == end })?.startTs
        // Read + analysis + tape build run OFF the main actor (`NightTape.load`, nonisolated), so the
        // sort/scan/decimate over up to 500k gravity samples never blocks UI — mirrors
        // `ArousalForensicsLoader`.
        tape = await NightTape.load(store: store, strapId: repo.deviceId, computedId: repo.computedDeviceId,
                                    start: start, end: end, motionSessionStart: motionKey)
        tapeLoaded = true
    }
}

// MARK: - Pure content (previewable without a live Repository)

/// The Night detail screen rendered from its parts: back to Rest, the title over the night's span, then
/// Movement, "Why you woke" and "Wrist orientation" in that order. The two clusters arrive as injected
/// views so this stays previewable; each hides itself when its own gate says there is nothing to show.
struct NightDetailContent: View {
    var subtitle: String?
    var onBack: (() -> Void)?
    let movement: NightMovementContent
    var arousals: AnyView?
    var posture: AnyView?

    init(subtitle: String?, onBack: (() -> Void)? = nil, movement: NightMovementContent,
         arousals: AnyView? = nil, posture: AnyView? = nil) {
        self.subtitle = subtitle
        self.onBack = onBack
        self.movement = movement
        self.arousals = arousals
        self.posture = posture
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let onBack {
                    WMBackLink(title: "Rest", action: onBack)
                }
                TabHeader("Night detail", subtitle: subtitle)
                movement
                if let arousals {
                    arousals
                }
                if let posture {
                    posture
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.top, WM.Space.s)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }
}

// MARK: - Loaders

/// Loads + caches the "Why you woke" arousal forensics for the night. It fetches the night's streams and
/// runs `ArousalForensics.classify` ONCE per day-view inside `.task(id:)` (so the classification never
/// re-runs on a SwiftUI frame), then hands the result to the pure section. Hides itself entirely when
/// there is no analyzable session.
private struct ArousalForensicsLoaded: View {
    @EnvironmentObject private var repo: Repository
    let session: CachedSleepSession?
    let dayKey: String?

    @State private var night: ArousalForensicsLoader.Night?

    var body: some View {
        Group {
            if session != nil, let night {
                // `dayKey` is what lets the section know the raw signal behind this ledger has been
                // pruned. Without it the section defaults to nil, `RawHorizon.hasAgedOut` answers
                // false for every night, and a 79-day-old night prints "Slept through — no awakenings
                // over 2 minutes" about a heart rate that no longer exists to have found any in.
                ArousalForensicsSection(arousals: night.arousals, hasSession: true,
                                        capture: night.capture, dayKey: dayKey)
            }
        }
        // Key on the data version + session identity, not just the day: the night's raw HR/skin-temp
        // streams keep backfilling AFTER the session first stages (bumping refreshSeq), and a day-key-only
        // id never re-fires, so the forensics would stay stuck on the partial first classify until midnight.
        .task(id: "\(dayKey ?? "")|\(repo.refreshSeq)|\(session?.startTs ?? 0)") {
            night = nil   // clear first so a new day/session can't briefly render the previous night's
            guard let session, dayKey != nil else { return }
            guard let store = await repo.storeHandle() else { return }
            night = await ArousalForensicsLoader.load(
                session: session,
                store: store,
                strapDeviceId: repo.deviceId,
                computedDeviceId: repo.computedDeviceId,
                family: WhoopModel.persisted.deviceFamily)
        }
    }
}

/// Loads + caches the wrist-orientation read (011 W2.3) for the night. It reads the night's raw gravity
/// and runs `PostureEngine` ONCE per day-view inside `.task(id:)` (so the epoch pass and the clustering
/// never re-run on a SwiftUI frame), then hands the result to the pure section. Hides itself entirely
/// when there is no session, and when the night never held still long enough to tell orientations apart
/// — an absent section, not an em-dash about a night that was never read. Past the raw horizon with
/// nothing banked, the section says the motion is gone (`PostureSection.rawAgedOut`).
private struct PostureLoaded: View {
    @EnvironmentObject private var repo: Repository
    let session: CachedSleepSession?
    let dayKey: String?

    /// The read's OUTCOME, not just its night: the section has to tell "the gravity is gone" from
    /// "the gravity is there and would not cluster", and only the outcome carries that.
    @State private var outcome: PostureLoader.Outcome?
    /// Whether the read has FINISHED. `night` is nil both before the read and when there is nothing to
    /// read, and the aged-out line is exactly the `night == nil` case — so without this the line would
    /// flash on every night during the async gap before its lane arrived.
    @State private var loaded = false

    var body: some View {
        Group {
            // The section is built for any real session, INCLUDING when `night` is nil — that is the
            // aged-out case, and gating on `let night` made the line it renders unreachable by
            // construction. `PostureSection` still draws nothing when the night is simply unreadable
            // inside the horizon, so a strap that recorded no gravity last night is unchanged.
            if session != nil, loaded {
                PostureSection(night: outcome?.night, hadGravity: outcome != .noSamples,
                               dayKey: dayKey)
            }
        }
        // Same id as the forensics loader, and for the same reason: the night's raw gravity keeps
        // backfilling AFTER the session first stages (bumping refreshSeq), and a day-key-only id never
        // re-fires — the lane would stay stuck on the partial first read until midnight.
        .task(id: "\(dayKey ?? "")|\(repo.refreshSeq)|\(session?.startTs ?? 0)") {
            outcome = nil   // clear first so a new day/session can't briefly render the previous night's
            loaded = false
            guard let session, dayKey != nil else { return }
            guard let store = await repo.storeHandle() else { return }
            outcome = await PostureLoader.load(session: session, store: store,
                                               strapDeviceId: repo.deviceId)
            loaded = true
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("NightDetail — light") {
    NightDetailSpecimen(tape: NightTapeSpecimen.tape()).preferredColorScheme(.light)
}

#Preview("NightDetail — dark") {
    NightDetailSpecimen(tape: NightTapeSpecimen.tape()).preferredColorScheme(.dark)
}

#Preview("NightDetail — no movement, light") {
    NightDetailSpecimen(tape: nil).preferredColorScheme(.light)
}

/// The screen with a synthetic seismograph and a quiet, in-horizon "Why you woke" — the two clusters'
/// full state sets live in their own previews and in `HonestyGallery`.
private struct NightDetailSpecimen: View {
    let tape: NightTape?

    var body: some View {
        NavigationStack {
            NightDetailContent(
                subtitle: "Mon 28 \u{2013} Tue 29",
                onBack: {},
                movement: NightMovementContent(tape: tape, loaded: true, dayKey: nil),
                arousals: AnyView(ArousalForensicsSection(arousals: [], hasSession: true,
                                                          capture: nil, dayKey: nil)))
        }
    }
}
#endif
