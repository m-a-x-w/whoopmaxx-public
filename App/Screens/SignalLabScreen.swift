import SwiftUI
import StrapProtocol
import StrapStore
import StrapAnalytics

/// Signal Lab — a raw-sensor oscilloscope that lays the strap's signals bare (from More → Signal Lab,
/// an immersive full-screen cover like Breathe). Four modes: a HISTORY scrubber across every stored raw
/// channel on ONE time axis, an HRV Poincaré panel, a workout-DETECTION replay, and one night's HRV split
/// by sleep STAGE. (A real-time sweep lives on the Live tab.)
///
/// READ-ONLY: it only reads `LiveState` and the existing StrapStore raw-sample readers under the raw
/// strap id (`Repository.deviceId` = "my-whoop"). No schema change, no persistence, no writes. Reads are
/// always BOUNDED — the window→(read strategy, sample budget) decision lives in `SignalLabMath`.
struct SignalLabScreen: View {
    @EnvironmentObject private var root: AppRoot
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable {
        case history = "History", hrv = "HRV", detection = "Detection", stages = "Stages"
    }

    @State private var mode: Mode = .history
    @State private var unit: SignalLabMath.ScopeUnit = .physical
    @State private var history = ScopeHistory()
    @State private var loading = false
    /// Bumped per load so a late read can't clobber a newer one.
    @State private var loadGen = 0

    /// Preview seam: an injected synthetic history so the HISTORY scope renders with NO store. When set,
    /// the Repository read is skipped entirely.
    var previewHistory: ScopeHistory? = nil

    init(initialMode: Mode = .history, previewHistory: ScopeHistory? = nil) {
        _mode = State(initialValue: initialMode)
        self.previewHistory = previewHistory
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WM.Ground.ground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: WM.Space.l) {
                header
                switch mode {
                case .history:
                    historyBody
                case .hrv:
                    SignalLabHRVView()
                    Spacer(minLength: 0)
                case .detection:
                    SignalLabDetectionView()
                    Spacer(minLength: 0)
                case .stages:
                    SignalLabStagesView()
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.top, WM.Space.section)
            .padding(.bottom, WM.Space.l)

            closeButton
        }
        .task(id: mode) {
            if mode == .history { await ensureLoaded() }
        }
        // Arm the strap's R10/R11 realtime burst for the life of this cover. HRV's comet and the live
        // HISTORY readout both claim to be LIVE-first, but the burst is armed only by the Live tab — so
        // opened from More with no Live tab underneath, the live source never receives a beat and the
        // comet sits on "Collecting live beats…". Ref-counted (`startRealtimeHR`/`stopRealtimeHR`), so
        // this composes with the Live tab rather than fighting it; the WHOOP 4 connect handshake resets
        // the stream OFF, so re-assert on every (re)bond exactly as the Live tab does.
        .onAppear { root.startRealtimeHR() }
        .onDisappear { root.stopRealtimeHR() }
        .onChange(of: live.bonded) { _, bonded in
            guard bonded else { return }
            root.rearmRealtimeIfWanted()
        }
    }

    // MARK: Header (title + segmented mode + unit toggle)

    private var header: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            // The units toggle rides the TITLE line, not the tab line, because the tab line ran out of room.
            // Measured at the shipped type (SF Pro Medium 13pt / semibold 11pt + 0.88 tracking): the four tab
            // words are 175.5pt plus 48pt of WM.Space.l gaps = 223.5pt, and [PHYSICAL | RAW] is another
            // 103.7pt plus the 36pt sectionLoose gap — 363pt against the 313pt a 393pt-wide iPhone leaves
            // once the 20pt gutters and the 40pt close-X lane are taken. With three tabs it fit by 9pt; with
            // "Stages" it does not. The tab labels are `.fixedSize()` and refuse to compress, so the overflow
            // would have landed entirely on the toggle and truncated it to "PHY…". On the title line the same
            // toggle sits beside a ~90pt word with room to spare, and the tab row gets the full width.
            //
            // The row is pinned to the toggle's own 40pt tap height whether or not the toggle is showing, so
            // the tab strip does not hop 16pt up and down as the user moves between History and the other
            // three modes.
            HStack(spacing: WM.Space.m) {
                Text("Signal Lab").font(WMType.title).foregroundStyle(WM.Ground.ink)
                Spacer(minLength: WM.Space.m)
                // The [Physical | Raw] units toggle applies to the raw-channel HISTORY scope only — the HRV
                // panel is ms-native, the Detection panel is bpm/verdicts, and the Stages panel is ms + clock.
                if mode == .history { unitToggle }
            }
            .frame(minHeight: 40)
            segmented(Mode.allCases.map { ($0, $0.rawValue) }, selection: $mode)
        }
        .padding(.trailing, 40)   // clear the close X
    }

    /// The [ Physical | Raw ] units toggle — the ink-underline word idiom (Live's raw/5s switch).
    private var unitToggle: some View {
        HStack(spacing: WM.Space.m) {
            unitWord("Physical", .physical)
            unitWord("Raw", .raw)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Units")
    }

    private func unitWord(_ label: String, _ u: SignalLabMath.ScopeUnit) -> some View {
        let active = unit == u
        return Button { unit = u } label: {
            Text(label).wmOverline(active ? WM.Ground.ink : WM.Ground.inkTertiary)
                .overlay(alignment: .bottom) {
                    if active { Rectangle().fill(WM.Ground.ink).frame(height: 1).offset(y: 3) }
                }
                .frame(minHeight: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// A neutral-ink segmented control (SF Pro medium, ink underline on the active segment).
    private func segmented<T: Hashable>(_ options: [(T, String)], selection: Binding<T>) -> some View {
        HStack(spacing: WM.Space.l) {
            ForEach(options, id: \.0) { value, label in
                let active = selection.wrappedValue == value
                Button { selection.wrappedValue = value } label: {
                    VStack(spacing: 3) {
                        Text(label).font(WMType.label)
                            .lineLimit(1).fixedSize()   // each tab on one line at intrinsic width — no wrap/hyphenation
                            .foregroundStyle(active ? WM.Ground.ink : WM.Ground.inkTertiary)
                        Rectangle().fill(active ? WM.Ground.ink : Color.clear).frame(height: 1.5)
                    }
                    .frame(minHeight: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    /// Floats over the content in the ZStack's top-trailing corner rather than sitting in a title row
    /// (the title shares its line with the mode tabs), so it's a bare `WMCloseButton`. The header's
    /// `.padding(.trailing, 40)` reserves the lane this occupies.
    private var closeButton: some View {
        WMCloseButton { dismiss() }
            .padding(.trailing, WM.Space.s)
            .padding(.top, WM.Space.xs)
            .accessibilityLabel("Close Signal Lab")
    }

    // MARK: History

    @ViewBuilder
    private var historyBody: some View {
        if loading && history.isEmpty {
            VStack { Spacer(); Text("Reading stored channels…")
                .font(WMType.body).foregroundStyle(WM.Ground.inkTertiary); Spacer() }
                .frame(maxWidth: .infinity)
        } else {
            SignalLabHistoryView(history: history, unit: $unit, onReload: handleReload)
        }
    }

    // MARK: Load (bounded reads)

    /// Default: the last ~6 h of stored data ending at the newest HR sample (else now).
    @MainActor
    private func ensureLoaded() async {
        if let preview = previewHistory { history = preview; return }
        guard history.isEmpty, !loading else { return }
        guard let store = await repo.storeHandle() else { return }
        let to = await repo.latestHRSampleTs() ?? Int(Date().timeIntervalSince1970)
        await load(store: store, from: to - 6 * 3600, to: to)
    }

    /// Reload when a zoom/pan moves the visible window outside the loaded span, or crosses the HR
    /// raw↔bucket resolution threshold. Reads a window ~1.5× the visible span (bounded), clamped so it
    /// can't run past the newest sample.
    private func handleReload(_ visible: ClosedRange<Double>) {
        guard previewHistory == nil else { return }
        let vspan = max(1, visible.upperBound - visible.lowerBound)
        let pad = vspan * 0.25
        let from = Int(visible.lowerBound - pad)
        let to = Int(min(visible.upperBound + pad, history.loadedEnd))
        let covered = Double(from) >= history.loadedStart - 1 && Double(to) <= history.loadedEnd + 1
        let loadedSpan = Int(history.loadedEnd - history.loadedStart)
        // Compare LIKE-FOR-LIKE: the HR strategy `load` WILL use — keyed off the PROSPECTIVE READ span
        // `to - from`, exactly as `load` derives its own `hrStrategy` from `windowSeconds = to - from` —
        // vs the strategy the current history was loaded with (its own read span, `loadedSpan`). The old
        // code keyed the first term off the VISIBLE span (`vspan`), which is padded by ±25% before the
        // read: near the 1h raw↔bucket threshold `hrRead(vspan)=raw` never equalled the loaded
        // `hrRead(loadedSpan≈padded)=buckets`, so `sameStrategy` was permanently false and every
        // gesture-settle re-issued all 8 bounded store reads even when the visible window was already
        // fully covered by identical data. `to - from` matches `load`'s classification, so a covered
        // window now short-circuits.
        let sameStrategy = SignalLabMath.hrRead(windowSeconds: max(1, to - from))
            == SignalLabMath.hrRead(windowSeconds: max(1, loadedSpan))
        guard !(covered && sameStrategy), to > from else { return }
        Task { @MainActor in
            guard let store = await repo.storeHandle() else { return }
            await load(store: store, from: from, to: to)
        }
    }

    /// Owns ONLY the view-side load state: the stale-load stamp, the `loading` flag and the publish.
    /// The eight bounded store reads live in `ScopeHistoryLoader` (off-main).
    @MainActor
    private func load(store: StrapStore, from: Int, to: Int) async {
        guard to > from else { return }
        loadGen += 1
        let gen = loadGen
        loading = true
        let h = await ScopeHistoryLoader.load(store: store, deviceId: repo.deviceId,
                                              family: WhoopModel.persisted.deviceFamily,
                                              from: from, to: to)
        guard gen == loadGen else { return }   // a newer load superseded this one
        history = h
        loading = false
    }
}

// MARK: - Previews

#Preview("Signal Lab · History — light") {
    SignalLabSpecimen(mode: .history).preferredColorScheme(.light)
}

#Preview("Signal Lab · History — dark") {
    SignalLabSpecimen(mode: .history).preferredColorScheme(.dark)
}

private struct SignalLabSpecimen: View {
    let mode: SignalLabScreen.Mode
    private let root = AppRoot()

    var body: some View {
        // A synthetic history so HISTORY renders with no store.
        SignalLabScreen(initialMode: mode, previewHistory: .synthetic())
            .environmentObject(root)
            .environmentObject(root.repo)
            .environmentObject(root.workoutRepo)
            .environmentObject(root.live)
    }
}
