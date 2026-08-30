import SwiftUI
import StrapAnalytics
import StrapProtocol
import StrapStore

/// live — the realtime instrument (037, Live): the "Live" header over the connection state with the
/// Raw / 5 s toggle trailing → the bpm hero in Effort on its five-segment zone line → the 60-bar stream
/// (or, while a workout records, the session block that carries it) → HRV / Stress / Battery readouts →
/// Start workout (primary) and Breathe (secondary) → the latest workouts → the strap → the Lock Screen
/// Live Activity switch.
///
/// The Strap section is also where the pipeline says what state it is in (012 P2): the `SyncStatus`
/// ladder's one line under the strap, a Reconnect button that goes disabled when the radio can't act,
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
    @Environment(\.appActions) private var appActions

    /// Headline mode: raw per-packet HR (default) or a 5s median. Persisted — an instrument
    /// remembers how you set it.
    @AppStorage("wm.live.smooth5s") private var smooth5s = false
    /// Which strap the R-R is coming from, read from the same key the pairing pickers write
    /// (`selectedWhoopModel`, the StrapHealth / Experimental idiom) — `BLEManager.selectedModel` is
    /// private. Only the honesty caveat under the readouts branches on it.
    @AppStorage(WhoopModel.persistedKey) private var modelRaw: String = WhoopModel.whoop4.rawValue

    /// Pushes the workouts list in the Live tab's NavigationStack (AppShell wraps each tab in one).
    @State private var showWorkoutsList = false
    /// Pushes one of the recent workouts straight to its detail.
    @State private var openedWorkout: WorkoutRef?
    /// The sport picker behind "Start workout".
    @State private var showingStartPicker = false
    /// The Breathe cover behind the secondary button (Breathe moved here from More).
    @State private var showingBreathe = false
    /// The readouts' HRV + stress index for the CURRENT R-R window, recomputed once per packet in
    /// `sampleSignals()` rather than in `body` — the cleaning pipeline is O(n) and body runs on every
    /// LiveState publish, not only on a new beat.
    @State private var signals = LiveSignalsReadout.idle
    /// The stress band shown beside HRV, or nil (em-dash) until enough readings exist to compare
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
    /// every tab mounted — so it would keep firing on the other tabs, churning LiveState.hrStream
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
        // P7: the headline walks the live window (smoothedBpm) — evaluate it ONCE per body pass and hand
        // it to the numeral, its subtitle, the zone line and the spoken reading.
        let bpm = headlineBpm
        // Explicit `return` (the modifier chain below carries a `#if DEBUG` member).
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TabHeader("Live", subtitle: live.connectionStatusLabel) {
                    smoothToggle
                }

                hero(bpm: bpm)
                    .padding(.top, WM.Space.sectionTight)

                // The always-on stream. While a workout records, the session block owns the stream, so
                // the standalone one steps aside rather than drawing two identical strips.
                Group {
                    if workout.activeWorkout == nil {
                        LiveHRStream()
                    } else {
                        LiveWorkoutSession()
                    }
                }
                .padding(.top, WM.Space.sectionTight)

                readouts
                    .padding(.top, WM.Space.sectionTight)

                actions
                    .padding(.top, WM.Space.sectionTight)

                recentWorkouts
                    .padding(.top, WM.Space.section - WM.Space.m)

                RuleSection("Strap") {
                    strapSection(status: status)
                }

                lockScreenRow
                    .padding(.top, WM.Space.section)
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.top, WM.Space.s)   // same header seat as Today / Rest / Log
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .background(WM.Ground.ground)
        .navigationDestination(isPresented: $showWorkoutsList) {
            WorkoutsListScreen()
        }
        .navigationDestination(item: $openedWorkout) { ref in
            WorkoutDetailScreen(row: ref.row, backLabel: "Live")
        }
        .sheet(isPresented: $showingStartPicker) { StartWorkoutSheet() }
        .fullScreenCover(isPresented: $showingBreathe) { BreatheScreen() }
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
            sampleSignals()   // the readouts are honest the instant the tab shows, not one beat later
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

    // MARK: - Header + hero

    /// The headline rate. Default is the RAW per-packet strap rate — live means live; the needle moves
    /// with every packet. The header's Raw / 5 s toggle opts into a 5s median for a steadier read. Falls
    /// back to the smoothed `root.bpm` (which can briefly outlive the raw value across a hiccup), then
    /// nil when there is no source.
    private var headlineBpm: Int? {
        smooth5s
            ? root.smoothedBpm(over: 5) ?? live.heartRate ?? root.bpm
            : live.heartRate ?? root.bpm
    }

    private static let smoothOptions: [(value: Bool, name: String)] = [(false, "Raw"), (true, "5 s")]

    /// The raw / 5s-smooth mode switch, as word tabs in the header's trailing slot.
    private var smoothToggle: some View {
        WMTextTabs(options: Self.smoothOptions, selection: $smooth5s, size: 13, spacing: WM.Space.m,
                   label: "Heart rate display")
            .accessibilityHint("Switches between raw and 5-second smoothed live heart rate")
    }

    /// The bpm numeral in Effort with its %-of-max reading, over the zone line. No reading → an em-dash
    /// in tertiary ink, "No live signal." as the reading, and a resting line with no dot.
    private func hero(bpm: Int?) -> some View {
        let hrMax = profile.hrMax
        let reading: String = bpm.map { Self.percentOfMax($0, hrMax: hrMax) }
            .map { "\($0)% of max \(hrMax)" } ?? "No live signal."
        let spoken: String = bpm.map { Self.spokenReading($0, hrMax: hrMax) } ?? "No live heart rate"
        return VStack(alignment: .leading, spacing: 18) {
            HeroReadout(value: bpm.map(String.init) ?? "—",
                        title: "bpm",
                        subtitle: reading,
                        color: bpm == nil ? WM.Ground.inkTertiary : WM.Domain.effort.color,
                        size: 128)
                .accessibilityLabel(spoken)
            LiveZoneLine(bpm: bpm, hrMax: hrMax)
        }
    }

    private static func percentOfMax(_ bpm: Int, hrMax: Int) -> Int {
        Int((Double(bpm) / Double(max(hrMax, 1)) * 100).rounded())
    }

    /// One spoken reading for the hero: the rate, then the zone the line shows it in.
    private static func spokenReading(_ bpm: Int, hrMax: Int) -> String {
        let zone = EffortZoneRamp.index(bpm: bpm, hrMax: hrMax)
        return "\(bpm) beats per minute, \(EffortZoneRamp.name(zone)), "
            + EffortZoneRamp.rangeText(zone, hrMax: hrMax)
    }

    // MARK: - Readouts

    /// HRV · Stress · Battery, plus the spot reading's own honesty caveat. HRV and Stress share one
    /// window and one gate, so they can never contradict each other about the same beats.
    private var readouts: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            HStack(alignment: .top, spacing: WM.Space.m) {
                SignalCell(label: "HRV", value: signals.hrv.value, unit: signals.hrv.unit,
                           valueSize: 24, fillsWidth: true)
                SignalCell(label: "Stress",
                           value: stressBand?.label ?? LiveSignalsReadout.noValue,
                           valueSize: 24, fillsWidth: true)
                SignalCell(label: "Battery", value: batteryText,
                           unit: live.batteryPct == nil ? nil : "%", valueSize: 24, fillsWidth: true)
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

    /// Recompute the readouts for the current R-R window and advance the stress reference.
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

    // MARK: - Actions

    /// Start workout (the sport sheet) while nothing records, with the just-saved confirmation under it,
    /// then Breathe, which opens the paced-breathing cover.
    private var actions: some View {
        VStack(spacing: 6) {
            if workout.activeWorkout == nil {
                WMPrimaryButton("Start workout") { showingStartPicker = true }
                if let last = workout.justEndedWorkout {
                    Text(savedText(last))
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, WM.Space.xs)
                }
            }
            WMSecondaryButton("Breathe", systemImage: "wind") { showingBreathe = true }
                .accessibilityHint("Opens a guided paced-breathing session")
        }
    }

    private func savedText(_ row: WorkoutRow) -> String {
        var parts = ["Saved · \(WorkoutSource.displaySport(row.sport))", WorkoutFormat.duration(row)]
        if let s = WorkoutFormat.strainText(row.strain) { parts.append("Effort \(s)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Workouts

    /// The newest two workouts as rows that push their detail, under a "Workouts" label whose "All N"
    /// action pushes the full list. Reads the shared `workoutRepo.workouts` cache (newest first) so Live
    /// and Today never disagree. With none yet, one row still opens the list — the only place a workout
    /// can be added by hand.
    private var recentWorkouts: some View {
        let all = workoutRepo.workouts
        let recent = all.prefix(2).map { WorkoutRef(row: $0) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Workouts")
                    .wmOverline()
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: WM.Space.m)
                if !all.isEmpty {
                    Button { showWorkoutsList = true } label: {
                        Text("All \(all.count)")
                            .font(WMType.label)
                            .foregroundStyle(WM.Ground.inkSecondary)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("All \(all.count) workouts")
                }
            }
            .frame(minHeight: 44)

            if recent.isEmpty {
                WMNavRow(title: "No workouts yet",
                         subtitle: "Start one above, or add one by hand",
                         hint: "Opens your workouts",
                         titleColor: WM.Ground.inkTertiary) { showWorkoutsList = true }
            } else {
                ForEach(recent) { ref in
                    WMNavRow(title: WorkoutSource.displaySport(ref.row.sport),
                             subtitle: recentSubtitle(ref.row),
                             hint: "Opens this workout") { openedWorkout = ref }
                    if ref.id != recent.last?.id {
                        WMRule()
                    }
                }
            }
        }
    }

    /// "Yesterday · 52 min · Effort 11" (+ "Detected" for a strap-detected bout).
    private func recentSubtitle(_ row: WorkoutRow) -> String {
        var parts = [WorkoutFormat.relativeDay(row.startTs), WorkoutFormat.duration(row)]
        if let s = WorkoutFormat.strainText(row.strain) { parts.append("Effort \(s)") }
        if WorkoutSource.classify(row.source) == .detected { parts.append("Detected") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Strap

    /// The Strap section: the strap row (name, state, battery line) with the runtime estimate and
    /// Reconnect under it, then the ONE resolved pipeline line, offload progress while an offload runs,
    /// and the way into Strap health.
    ///
    /// `status.line` deliberately does NOT inherit the `live.backfilling` gate. That gate belongs to
    /// `SyncProgressRow`, which is a PROGRESS row — and leaving it as the app's only reader of the
    /// frontier was 012 finding 5: the gap was visible only while data was already arriving, so the
    /// state a user actually lives in (strap on the charger for three days, nothing syncing) had no
    /// representation anywhere. The line sits directly under the strap row so a radio problem reads as
    /// the reason the Reconnect button above it is dead (012 decision 4).
    private func strapSection(status: SyncStatus.State) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
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
            // Offload progress: visible ONLY while the strap hands over history. Standard
            // appear/disappear idiom (.opacity under wmAnimation, Reduce Motion aware).
            if live.backfilling {
                SyncProgressRow(frontierUnix: live.persistedFrontierUnix,
                                chunksBanked: live.syncChunksThisSession)
                    .transition(.opacity)
            }
            WMNavRow(title: "Strap health",
                     subtitle: "Battery, capture and signal",
                     hint: "Opens strap health") { appActions.openStrapHealth() }
        }
        .wmAnimation(WMMotion.transition, value: live.backfilling)
    }

    /// The strap row: advertising name once the firmware reports it, connection dot, state caption,
    /// battery numeral and line, the runtime estimate, and Reconnect when the link is down. `connect()`
    /// is the USER-initiated BLEManager entry (it re-arms a bond-loop give-up on an explicit retry); on
    /// the simulator (no BLE) it logs and returns — a graceful no-op.
    ///
    /// The estimate is the one `BatteryEstimator` was already computing off the live SoC ring and that
    /// NOTHING in App/ read (012 finding 4 — a rendering gap, not a missing engine). Shown only when there
    /// is one, and worded exactly as Strap Health words the same estimator's output ("~4.5 days left"),
    /// so the two surfaces can't phrase it differently.
    ///
    /// Reconnect is DISABLED on `live.radio.problem != nil`: `connect()` bails unless the radio is
    /// powered on, so with Bluetooth off (or permission denied, or no BLE at all) it was a control that
    /// provably did nothing, sitting next to a "Disconnected" label blaming the strap. It stays VISIBLE
    /// and goes dim rather than disappearing (012 decision 4) — hiding it would make the radio problem
    /// invisible again, which is the exact defect `RadioState` was added to fix. The reason renders
    /// beneath the strap row, as the ladder's `.radio` line.
    private var strapPanel: some View {
        StrapPanel(name: live.advertisingName ?? "WHOOP",
                   connected: live.connected,
                   batteryPct: live.batteryPct.map { Int($0.rounded()) },
                   stateText: strapStateText) {
            if let estimate = live.batteryEstimate {
                Text("Battery \(BatteryEstimator.label(hours: estimate.remainingHours)) left")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            if !live.connected {
                WMSecondaryButton("Reconnect", systemImage: "arrow.clockwise",
                                  enabled: live.radio.problem == nil, fillsWidth: false) {
                    root.ble.connect()
                }
            }
        }
    }

    private var strapStateText: String {
        var text = live.connectionStatusLabel
        if live.charging == true { text += " · charging" }
        return text
    }

    // MARK: - Lock Screen (Live Activity, manual pin)

    /// Pin / stop the live-HR Live Activity by hand, as a switch bound to whether one is running.
    /// Starting needs the system switch on, a live link, and a heart rate to show; stopping is always
    /// available while one is running. (Auto-start on connect is the opt-in toggle in Settings.)
    ///
    /// The switch goes inert only when flipping it could do nothing — not running AND unable to start —
    /// so a dim switch always means an inert one; while running it stays live even once the strap drops
    /// (stopping still works, and dimming an armed control would misreport it). The caption says why it
    /// can't start when it can't.
    private var lockScreenRow: some View {
        let running = liveActivity.isRunning
        let hasHR = live.heartRate != nil || root.bpm != nil
        let canStart = liveActivity.systemEnabled && live.connected && hasHR
        let caption: String
        if !liveActivity.systemEnabled {
            caption = "Turn on Live Activities for whoopmaxx in Settings to use this."
        } else if !running && !canStart {
            caption = "Connect the strap and wait for a live reading to pin it."
        } else {
            caption = "Shows live bpm on the Lock Screen and in the Dynamic Island while connected."
        }
        return WMSettingToggle(label: "Live heart rate on Lock Screen",
                               isOn: Binding(get: { liveActivity.isRunning },
                                             set: { on in
                                                 if on { root.pinLiveActivity() } else { root.stopLiveActivity() }
                                             }),
                               caption: caption)
            .disabled(!running && !canStart)
            .accessibilityHint(running ? "Stops the live heart-rate Live Activity"
                               : "Shows live heart rate on the Lock Screen")
    }
}

/// The Live tab's HRV and Stress readouts, pure and static so both honesty gates are testable without a
/// view host (the `LiveActivityDecision` idiom).
///
/// Live HRV runs the canonical spot pipeline rather than a hand-rolled mean of successive differences:
/// range filter (300–2000 ms) → Malik ectopic rejection → splice-safe (n-1) RMSSD → the 0.35
/// rejected-fraction gate. `HRVAnalyzer.swift:215-226` measured what the shortcut costs on real data —
/// differencing across a removed beat inflated nightly avgHrv by 4.8%–37.5% (mean 18.7%), and
/// night-dependently (r = 0.725 old vs new), so a personal baseline cannot absorb it. The readout will
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

    /// One readout's two strings: the numeral and the small caption beside it.
    struct Cell: Equatable {
        let value: String
        /// The unit ("ms") when there IS a value; otherwise the reason there isn't one.
        let unit: String?
    }

    /// Everything the readouts derive from one R-R window.
    struct Signals: Equatable {
        let hrv: Cell
        /// Baevsky SI for this window, or nil when the window failed the same gate the HRV readout uses.
        let stressIndex: Double?
    }

    /// Nothing measured yet: what the readouts show before the first packet and after a disconnect.
    static let idle = Signals(hrv: Cell(value: noValue, unit: nil), stressIndex: nil)

    /// Bands are a comparison, so they need something to compare against: readings banked before the
    /// first band is offered — roughly a minute of beats at strap cadence.
    static let stressReferenceMin = 45
    /// Cap on the rolling reference, oldest dropped first.
    static let stressReferenceLimit = 180

    /// Both readouts for one raw R-R window (ms, capture order).
    ///
    /// Stress rides the SAME gate as the HRV readout by construction: a window too noisy to report an
    /// RMSSD is too noisy to band, and two readouts disagreeing about one window is exactly what this
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
