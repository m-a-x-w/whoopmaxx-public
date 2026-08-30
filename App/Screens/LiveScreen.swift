import SwiftUI
import StrapAnalytics
import StrapProtocol

/// live — the realtime instrument (screen contract): huge live bpm numeral under a LIVE
/// overline, the zone-colored live bar stream, live-HRV / stress / battery signal cells, and the strap
/// panel (the screen's one contained surface) with a reconnect affordance.
///
/// The Strap section is also where the pipeline says what state it is in (012 P2): the `SyncStatus`
/// ladder's one line under the panel, a Reconnect button that goes disabled when the radio can't act,
/// and the runtime estimate `BatteryEstimator` was already computing with nobody reading it.
struct LiveScreen: View {
    @EnvironmentObject private var root: AppRoot
    @EnvironmentObject private var workoutRepo: WorkoutRepository
    /// The manual-workout recorder — observed DIRECTLY (its `activeWorkout` is its own `@Published`,
    /// which a nested-object read through `root` would not see).
    @EnvironmentObject private var workout: WorkoutSessionController
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var liveActivity: LiveActivityController
    @EnvironmentObject private var profile: ProfileStore

    /// Headline mode: raw per-packet HR (default) or a 5s median. Persisted — an instrument
    /// remembers how you set it.
    @AppStorage("wm.live.smooth5s") private var smooth5s = false
    /// Which strap the R-R is coming from, read from the same key the pairing pickers write
    /// (`selectedWhoopModel`, the StrapHealth / Experimental idiom) — `BLEManager.selectedModel` is
    /// private. Only the honesty caveat below the Signals row branches on it.
    @AppStorage(WhoopModel.persistedKey) private var modelRaw: String = WhoopModel.whoop4.rawValue

    /// Pushes the workouts list in the Live tab's NavigationStack (AppShell wraps each tab in one).
    @State private var showWorkoutsList = false
    /// The Signals row's readouts for the CURRENT R-R window, recomputed once per packet in
    /// `sampleSignals()` rather than in `body` — the cleaning pipeline is O(n) and body runs on every
    /// LiveState publish, not only on a new beat.
    @State private var signals = LiveSignalsReadout.idle
    /// The stress band shown beside Live HRV, or nil (em-dash) until enough readings exist to compare
    /// against. Never a bare SI number — see `LiveSignalsReadout.StressBand`.
    @State private var stressBand: LiveSignalsReadout.StressBand?
    /// The rolling within-session SI reference the band is taken against, oldest dropped first.
    /// Cleared on disconnect so a stale distribution can't outlive the link.
    @State private var siHistory: [Double] = []
    /// Whether this tab is the visible one. AppShell keeps every tab mounted, so an `onChange` on a
    /// LiveState publisher keeps firing off-tab; the same rule the 1 Hz sampler below follows.
    @State private var visible = false
    /// The 1 Hz shared-HR-stream sampler, tied to the Live tab's appear/disappear (see below). A raw
    /// `.onReceive(Timer…)` stays subscribed while the view is in the render graph — and AppShell keeps
    /// every tab mounted — so it would keep firing on Today/Rest/Data/More, churning LiveState.hrStream
    /// (and every observer) at 1 Hz off-tab. A cancellable task stops the moment the tab is deselected.
    @State private var samplerTask: Task<Void, Never>?

    var body: some View {
        // 012 P2's trap: LiveState publishes at packet rate and this screen is expensive to re-render,
        // so the pipeline ladder is resolved ONCE per body pass and threaded into the Strap section —
        // never called again per subview. `now` is passed in because `SyncStatus` is pure (012
        // decision 2); the wall clock is read here, the same way `SyncProgressRow` reads it.
        let status = SyncStatus.resolve(radio: live.radio,
                                        bonded: live.bonded,
                                        backfilling: live.backfilling,
                                        strapNeedsReboot: live.strapNeedsReboot,
                                        historySyncExperimental: live.historySyncExperimental,
                                        frontierUnix: live.persistedFrontierUnix,
                                        frontierLoaded: live.frontierLoaded,
                                        now: Date().timeIntervalSince1970)
        // Explicit `return` (the modifier chain below carries a `#if DEBUG` member) — unchanged from
        // before the Signals rework, which used it for the same reason.
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                // The always-on live instrument. While a workout records, the session block below owns
                // the stream, so hide the standalone one to avoid two identical strips.
                if workout.activeWorkout == nil {
                    LiveHRStream(hrMax: profile.hrMax)
                        .padding(.top, WM.Space.section)
                }

                LiveWorkoutSession()

                RuleSection("Signals") {
                    signalsRow
                }

                RuleSection("Recent workouts") {
                    recentWorkouts
                }

                RuleSection("Strap") {
                    strapSection(status: status)
                }

                RuleSection("Lock Screen") {
                    pinControl
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.top, WM.Space.l)
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .background(WM.Ground.ground)
        .navigationDestination(isPresented: $showWorkoutsList) {
            WorkoutsListScreen()
        }
        #if DEBUG
        // Deep-link the workouts list / detail / add sheet for UI work + screenshots (sim has no BLE).
        .task {
            if DebugFlags.workoutsList || DebugFlags.workoutDetail || DebugFlags.manualWorkout {
                showWorkoutsList = true
            }
        }
        #endif
        // Realtime lifecycle (the original LiveView port): the strap only emits realtime HR after an
        // explicit arm — and the WHOOP 4 connect handshake turns the stream OFF — so arm while
        // this tab is visible, re-arm on every (re)bond, drop the want on leave.
        .onAppear {
            visible = true
            sampleSignals()   // the row is honest the instant the tab shows, not one beat later
            root.startRealtimeHR()
            root.ble.refreshBattery()
            // ONE 1 Hz sampler for the shared live-HR stream ring, owned at the Live-tab root so history
            // stays continuous across the standalone↔in-workout stream swap. Cancelled on disappear so it
            // never runs while another tab is showing (mirroring the disarmed realtime feed).
            samplerTask?.cancel()
            samplerTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    live.sampleHRStream()
                }
            }
        }
        .onDisappear {
            visible = false
            root.stopRealtimeHR()
            samplerTask?.cancel()
            samplerTask = nil
        }
        // Resample off the MONOTONIC packet counter, not `live.rr`: two consecutive identical R-R
        // packets (common at rest) leave the Equatable `rr` unchanged, so an `onChange(of: live.rr)`
        // would silently drop the repeat beat (the SignalLab comet's rule).
        .onChange(of: live.rrPacketSeq) { _, _ in
            guard visible else { return }
            sampleSignals()
        }
        .onChange(of: live.connected) { _, connected in
            // A disconnect can span hours, and the band is a comparison against RECENT readings — a
            // stale distribution must not outlive the link, the same rule `clearBiometrics()` applies
            // to every other live buffer.
            guard !connected else { return }
            siHistory.removeAll()
            stressBand = nil
            signals = LiveSignalsReadout.signals(live.rrRecent)
        }
        .onChange(of: live.bonded) { _, bonded in
            guard bonded else { return }
            root.rearmRealtimeIfWanted()
            root.ble.refreshBattery()
        }
    }

    // MARK: - Header

    /// LIVE overline + the 96pt display numeral. Default shows the RAW per-packet strap rate —
    /// live means live; the needle moves with every packet. The overline row's quiet toggle opts
    /// into a 5s median for a steadier read. Falls back to the smoothed `root.bpm` (which can
    /// briefly outlive the raw value across a hiccup), then an em-dash when no source.
    private var header: some View {
        // P7: `bpmText` walks the live window (smoothedBpm) — evaluate it ONCE per body pass and reuse it for
        // the Text, its font/color branches, the animation key, and the a11y label (it was read 5×).
        let text = bpmText
        return VStack(alignment: .leading, spacing: WM.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Live").wmOverline()
                Spacer(minLength: WM.Space.m)
                smoothToggle
            }
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.s) {
                // A 96pt em-dash reads as a glitchy white bar; the no-signal placeholder sits
                // smaller and quieter, and the live numeral arrives at full instrument size.
                Text(text)
                    .font(WMType.display(text == "—" ? 56 : 96))
                    .foregroundStyle(text == "—" ? WM.Ground.inkTertiary : WM.Ground.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .wmAnimation(value: text)
                Text("bpm")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text == "—" ? "No live heart rate" : "\(text) beats per minute")
        }
    }

    private var bpmText: String {
        let value = smooth5s
            ? root.smoothedBpm(over: 5) ?? live.heartRate ?? root.bpm
            : live.heartRate ?? root.bpm
        return value.map(String.init) ?? "—"
    }

    /// The raw / 5s-smooth mode switch: two overline words, active in ink with an underline
    /// (the More screen's picker idiom, shrunk to an eyebrow).
    private var smoothToggle: some View {
        HStack(spacing: WM.Space.m) {
            smoothWord("raw", active: !smooth5s) { smooth5s = false }
            smoothWord("5s", active: smooth5s) { smooth5s = true }
        }
        .wmAnimation(value: smooth5s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate display")
        .accessibilityValue(smooth5s ? "5 second smooth" : "raw")
        .accessibilityHint("Switches between raw and smoothed live heart rate")
    }

    private func smoothWord(_ label: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .wmOverline(active ? WM.Ground.ink : WM.Ground.inkTertiary)
                .overlay(alignment: .bottom) {
                    if active {
                        Rectangle()
                            .fill(WM.Ground.ink)
                            .frame(height: 1)
                            .offset(y: 3)
                    }
                }
                // ≥44×44 hit region (HIG): the word + underline keep their size, centered in an
                // invisible box that carries the tap.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Signals

    /// Live HRV · Stress · Battery, plus the spot reading's own honesty caveat. The two R-R cells share
    /// one window and one gate, so they can never contradict each other about the same beats.
    private var signalsRow: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            HStack(alignment: .top, spacing: WM.Space.m) {
                SignalCell(label: "Live HRV", value: signals.hrv.value, unit: signals.hrv.unit,
                           fillsWidth: true)
                SignalCell(label: "Stress",
                           value: stressBand?.label ?? LiveSignalsReadout.noValue,
                           fillsWidth: true)
                SignalCell(label: "Battery", value: batteryText,
                           unit: live.batteryPct == nil ? nil : "%", fillsWidth: true)
            }
            // Shown only while a band is actually on screen: the word is a WITHIN-USER comparison and
            // must never read as an absolute scale. Baevsky's SI is dimensionless and this app banks no
            // personal SI baseline, so this session's own recent readings are the only honest frame.
            if stressBand != nil {
                Text("Stress is banded against your own recent readings, not an absolute scale.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The frozen package's own caveat, verbatim (`SpotHrvReading.caveatFor`): a short spot
            // capture is not the overnight baseline, and a 5/MG's optical R-R is noisier than a 4.0's.
            Text(SpotHrvReading.caveatFor(hrvSource))
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// R-R provenance for the caveat. A 5/MG derives beat-to-beat intervals from the optical pulse
    /// waveform; a 4.0 hands over electrical R-R over the standard profile, which is the package's
    /// `.chestStrap` case (see `SpotHrvReading.Source`).
    private var hrvSource: SpotHrvReading.Source {
        (WhoopModel(rawValue: modelRaw) ?? .whoop4).deviceFamily == .whoop5 ? .opticalPPG : .chestStrap
    }

    /// Recompute the Signals readouts for the current R-R window and advance the stress reference.
    /// Called on appear and on every R-R packet while this tab is visible — never from `body`.
    private func sampleSignals() {
        let fresh = LiveSignalsReadout.signals(live.rrRecent)
        signals = fresh
        guard let si = fresh.stressIndex else { stressBand = nil; return }
        // Band against the readings that came BEFORE this one, then bank it — a reading is never
        // compared against itself.
        stressBand = LiveSignalsReadout.stressBand(si: si, reference: siHistory)
        siHistory.append(si)
        if siHistory.count > LiveSignalsReadout.stressReferenceLimit {
            siHistory.removeFirst(siHistory.count - LiveSignalsReadout.stressReferenceLimit)
        }
    }

    private var batteryText: String {
        live.batteryPct.map { String(Int($0.rounded())) } ?? "—"
    }

    // MARK: - Recent workouts

    /// A one-row preview of the newest workout that pushes the full list. Reads the shared
    /// `workoutRepo.workouts` cache so Live and Today never disagree.
    private var recentWorkouts: some View {
        Button { showWorkoutsList = true } label: {
            HStack(spacing: WM.Space.m) {
                if let last = workoutRepo.workouts.first {
                    VStack(alignment: .leading, spacing: WM.Space.xs) {
                        Text(WorkoutSource.displaySport(last.sport))
                            .font(WMType.body)
                            .foregroundStyle(WM.Ground.ink)
                        Text("\(WorkoutFormat.relativeDay(last.startTs)) · \(WorkoutFormat.duration(last))")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                    }
                } else {
                    Text("No workouts yet")
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
                Spacer()
                Text(workoutRepo.workouts.count > 1 ? "All \(workoutRepo.workouts.count)" : "Open")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                WMDisclosure()
            }
            .contentShape(Rectangle())
            .padding(.vertical, WM.Space.s)
        }
        .buttonStyle(.plain)
        // Combine the children so VoiceOver speaks the visible sport / when · duration / "All N" summary
        // (an explicit label would override + drop it, as Today's lastWorkoutRow already avoids).
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens your workouts")
    }

    // MARK: - Strap

    /// The Strap section: offload progress while an offload runs, the panel, then the ONE resolved
    /// pipeline line and the strap's runtime estimate.
    ///
    /// `status.line` deliberately does NOT inherit the `live.backfilling` gate above it. That gate
    /// belongs to `SyncProgressRow`, which is a PROGRESS row — and leaving it as the app's only reader
    /// of the frontier was 012 finding 5: the gap was visible only while data was already arriving, so
    /// the state a user actually lives in (strap on the charger for three days, nothing syncing) had no
    /// representation anywhere. The line sits directly under the panel so a radio problem reads as the
    /// reason the Reconnect button above it is dead (012 decision 4).
    private func strapSection(status: SyncStatus.State) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            // Offload progress: visible ONLY while the strap hands over history. Standard
            // appear/disappear idiom (.opacity under wmAnimation, Reduce Motion aware).
            if live.backfilling {
                SyncProgressRow(frontierUnix: live.persistedFrontierUnix,
                                chunksBanked: live.syncChunksThisSession)
                    .transition(.opacity)
            }
            strapPanel
            // The ladder's answer, in the words the ladder owns — no second opinion derived here, so
            // Today and Live can never word the same pipeline state differently (012 decision 1).
            // nil only when the strap is caught up, which is the state with nothing to say.
            if let line = status.line {
                Text(line)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The runtime estimate `BatteryEstimator` was already computing off the live SoC ring and
            // that NOTHING in App/ read (012 finding 4 — a rendering gap, not a missing engine). Shown
            // only when there is an estimate, and worded exactly as Strap Health words the same
            // estimator's output ("~4.5 days left"), so the two surfaces can't phrase it differently.
            if let estimate = live.batteryEstimate {
                Text("Battery \(BatteryEstimator.label(hours: estimate.remainingHours)) left")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .wmAnimation(WMMotion.transition, value: live.backfilling)
    }

    /// The strap panel: advertising name once the firmware reports it, connection dot, battery bar,
    /// status caption, and a reconnect button when the link is down. `connect()` is the USER-initiated
    /// BLEManager entry (it re-arms a bond-loop give-up on an explicit retry); on the simulator
    /// (no BLE) it logs and returns — a graceful no-op.
    ///
    /// That no-op is why the button is DISABLED on `live.radio.problem != nil`: `connect()` bails
    /// unless the radio is powered on, so with Bluetooth off (or permission denied, or no BLE at all)
    /// it was a control that provably did nothing, sitting next to a "Disconnected" label blaming the
    /// strap. It stays VISIBLE and goes dim rather than disappearing (012 decision 4) — hiding it would
    /// make the radio problem invisible again, which is the exact defect `RadioState` was added to fix.
    /// The reason renders beneath the panel, as the ladder's `.radio` line.
    private var strapPanel: some View {
        StrapPanel(name: live.advertisingName ?? "WHOOP",
                   connected: live.connected,
                   batteryPct: live.batteryPct.map { Int($0.rounded()) },
                   stateText: strapStateText) {
            if !live.connected {
                Button("Reconnect") { root.ble.connect() }
                    .font(WMType.label)
                    .tint(WM.Ground.ink)
                    .disabled(live.radio.problem != nil)
            }
        }
    }

    private var strapStateText: String {
        var text = live.connectionStatusLabel
        if live.charging == true { text += " · charging" }
        return text
    }

    // MARK: - Lock Screen (Live Activity, manual pin)

    /// Pin / stop the live-HR Live Activity by hand. Starting needs the system switch on, a live link,
    /// and a heart rate to show; stopping is always available while one is running. (Auto-start on
    /// connect is the opt-in toggle in More → Glances.)
    ///
    /// Running state reads from the filled glyph plus an Effort status dot — the wording itself stays
    /// neutral ink, for the reason spelled out on the row below.
    @ViewBuilder
    private var pinControl: some View {
        let running = liveActivity.isRunning
        let hasHR = live.heartRate != nil || root.bpm != nil
        let canStart = liveActivity.systemEnabled && live.connected && hasHR

        VStack(alignment: .leading, spacing: 0) {
            Button {
                if running { root.stopLiveActivity() } else { root.pinLiveActivity() }
            } label: {
                HStack(spacing: WM.Space.m) {
                    Image(systemName: running ? "bolt.heart.fill" : "bolt.heart")
                        .font(.system(size: 15))
                    Text(running ? "Pinned to Lock Screen — Stop" : "Pin live HR to Lock Screen")
                        .font(WMType.body)
                    Spacer()
                    // Running state as a STATUS MARKER, not as a coloured control. This row used to
                    // paint its whole label — glyph AND the interactive wording "Pinned to Lock
                    // Screen — Stop" — in `WM.Domain.effort.color`, which is the one thing the
                    // language forbids: colour is data, chrome stays neutral ink (and
                    // Tokens.swift's domain block says the same). The tint is not wrong in kind —
                    // live HR genuinely IS the Effort domain, which is why the Live Activity this
                    // button creates paints its own heart glyph red-pink (Widgets/WMLiveActivity)
                    // and why an effort-tinted marker belongs here at all — it just cannot be the
                    // paint on a control's wording, where it reads as an accent rather than as data.
                    // So the state moves to a 6pt dot in the sanctioned marker idiom
                    // (HealthMonitorScreen: "a status, never an accent"), which is the same split
                    // LiveWorkoutSession already draws one section up: tinted "Recording" caption,
                    // ink Stop button. It sits AFTER the `Spacer` so arriving/leaving never nudges
                    // the glyph or the label, and `.fill` beats the inherited `foregroundStyle`.
                    if running {
                        Circle()
                            .fill(WM.Domain.effort.color)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)   // the label already says "Pinned"
                    }
                }
                // Ink whenever the control can act, tertiary when it cannot — deliberately the same
                // predicate as `.disabled` below, so a dim row always means an inert row. `running`
                // is on the ink side even once `canStart` has gone false (strap dropped while the
                // activity is still pinned): Stop is live in that state, and dimming an armed
                // control would misreport it.
                .foregroundStyle(running || canStart ? WM.Ground.ink : WM.Ground.inkTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!running && !canStart)
            .padding(.vertical, WM.Space.m)
            .accessibilityHint(running ? "Stops the live heart-rate Live Activity"
                               : "Shows live heart rate on the Lock Screen")

            if !liveActivity.systemEnabled {
                Text("Turn on Live Activities for whoopmaxx in Settings to use this.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, WM.Space.m)
            } else if !running && !canStart {
                Text("Connect the strap and wait for a live reading to pin it.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, WM.Space.m)
            }
        }
    }
}

/// The Live tab's Signals readouts, pure and static so both honesty gates are testable without a view
/// host (the `LiveActivityDecision` idiom).
///
/// Live HRV runs the canonical spot pipeline rather than a hand-rolled mean of successive differences:
/// range filter (300–2000 ms) → Malik ectopic rejection → splice-safe (n-1) RMSSD → the 0.35
/// rejected-fraction gate. `HRVAnalyzer.swift:215-226` measured what the shortcut costs on real data —
/// differencing across a removed beat inflated nightly avgHrv by 4.8%–37.5% (mean 18.7%), and
/// night-dependently (r = 0.725 old vs new), so a personal baseline cannot absorb it. The cell will
/// therefore read LOWER on noisy windows and show an em-dash more often. That is the fix.
///
/// Stress is Baevsky's Stress Index, which is dimensionless and swings hard over 60 beats, so it is
/// only ever shown as a band against the user's own recent readings, never as a bare number.
///
/// Health-framing register (decision 5): descriptive, within-user, no condition name, no
/// probability, no call to action. Banned from every string here: thermoregulation, vasodilation,
/// impaired, poor, abnormal, apnea, insomnia, hypoxemia, arrhythmia, "consider", "you should",
/// "talk to".
enum LiveSignalsReadout {

    /// The "no value" glyph. An honest em-dash beats a plausible-looking number, always.
    static let noValue = "—"

    /// One `SignalCell`'s two strings: the numeral and the small caption beside it.
    struct Cell: Equatable {
        let value: String
        /// The unit ("ms") when there IS a value; otherwise the reason there isn't one.
        let unit: String?
    }

    /// Everything the Signals row derives from one R-R window.
    struct Signals: Equatable {
        let hrv: Cell
        /// Baevsky SI for this window, or nil when the window failed the same gate the HRV cell uses.
        let stressIndex: Double?
    }

    /// Nothing measured yet: what the row shows before the first packet and after a disconnect.
    static let idle = Signals(hrv: Cell(value: noValue, unit: nil), stressIndex: nil)

    /// Bands are a comparison, so they need something to compare against: readings banked before the
    /// first band is offered — roughly a minute of beats at strap cadence.
    static let stressReferenceMin = 45
    /// Cap on the rolling reference, oldest dropped first.
    static let stressReferenceLimit = 180

    /// Both readouts for one raw R-R window (ms, capture order).
    ///
    /// Stress rides the SAME gate as the HRV cell by construction: a window too noisy to report an
    /// RMSSD is too noisy to band, and two cells disagreeing about one window is exactly what a signals
    /// row must not do.
    static func signals(_ rrMs: [Int]) -> Signals {
        // Off strap / no beats yet: a bare em-dash. "0/20 clean" would be counting a window that does
        // not exist.
        guard !rrMs.isEmpty else { return idle }
        switch SpotHrvReading.compute(rrMs) {
        case .reading(let rmssdMs, _, _, _):
            return Signals(hrv: Cell(value: String(Int(rmssdMs.rounded())), unit: "ms"),
                           stressIndex: StressIndex.stressIndex(rawRR: rrMs.map(Double.init)))
        case .insufficient(_, let needed, _):
            // `SpotHrvReading` reports clean: 0 on BOTH refusal paths — the analyzer returns an empty
            // result once the rejected-fraction gate trips, even though beats survived — so re-derive
            // the true survivor count instead of printing a zero nothing measured. The two refusals are
            // different facts: not enough beats yet, vs enough beats but most of the window discarded.
            let clean = HRVAnalyzer.cleanRR(rrMs.map(Double.init)).count
            return Signals(hrv: Cell(value: noValue,
                                     unit: clean >= needed ? "too noisy" : "\(clean)/\(needed) clean"),
                           stressIndex: nil)
        }
    }

    /// Where this SI sits against the user's own recent readings.
    enum StressBand: Equatable {
        case low, typical, high

        var label: String {
            switch self {
            case .low:     return "Low"
            case .typical: return "Typical"
            case .high:    return "High"
            }
        }
    }

    /// Band `si` against `reference` — the readings that came before it, which must NOT include `si`
    /// itself. The typical core runs p20…p80 rather than the quartiles on purpose: SI over a 60-beat
    /// window moves every beat, and a narrow core would flip the word on the screen every second.
    /// nil below `stressReferenceMin` readings — an em-dash, not a guess at a distribution.
    static func stressBand(si: Double, reference: [Double]) -> StressBand? {
        guard reference.count >= stressReferenceMin else { return nil }
        let sorted = reference.sorted()
        if si < quantile(sorted, 0.20) { return .low }
        if si > quantile(sorted, 0.80) { return .high }
        return .typical
    }

    /// Nearest-rank quantile over an ALREADY-SORTED, non-empty series — no interpolation, so the same
    /// readings always give the same edge.
    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        let last = sorted.count - 1
        return sorted[min(last, max(0, Int((q * Double(last)).rounded())))]
    }
}

#Preview("Live — light") {
    LiveScreenSpecimen().preferredColorScheme(.light)
}

#Preview("Live — dark") {
    LiveScreenSpecimen().preferredColorScheme(.dark)
}

private struct LiveScreenSpecimen: View {
    private let root = AppRoot()

    var body: some View {
        LiveScreen()
            .environmentObject(root)
            .environmentObject(root.repo)
            .environmentObject(root.workoutRepo)
            .environmentObject(root.workout)
            .environmentObject(root.live)
            .environmentObject(root.profile)
            .environmentObject(root.liveActivity)
    }
}
