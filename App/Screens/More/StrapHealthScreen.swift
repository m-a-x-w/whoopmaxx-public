import SwiftUI

/// strap health — the strap's own vitals (007 F4), a full-screen cover from More → Strap
/// (mirroring Breathe / Body Clock). Open editorial sections on ground:
///   • StrapPanel — the one contained surface: connection dot, name, battery bars, state caption.
///   • Name — rename the strap's BLE advertising name (WHOOP 4.0 only; the strap reboots to apply).
///   • Time check — buzz the current time on the wrist (Haptic Clock #460); double-tap does the same.
///   • Battery — hero % + "~Xd left" runtime estimate + the 7-day persisted-SoC trend.
///   • Capture — 7 worn-waking coverage bars + the reported gap rows ("Tue 13:05–15:40 · 2h 35m").
///     Gaps are permanent facts (the strap trims acked history) — informational, never a re-sync.
///   • Signal — session link-quality grade + reconnects / rejected / console counters.
///   • Sync status caption.
/// Chrome stays neutral ink; semantic color marks STATUSES only (grade dot, battery bars).
///
/// P7: the screen itself observes NO LiveState — the live-fed pieces (strap panel, charging
/// badge, signal counters, sync caption) are isolated into small leaf subviews below, mirroring
/// RestScreen's `WakeWindowArmed`, so per-BLE-event publish churn (~1 Hz HR, the #755 offload
/// stamp storm) re-renders those rows only, never the whole scroll body.
struct StrapHealthScreen: View {
    @EnvironmentObject private var model: StrapHealthModel
    @EnvironmentObject private var repo: Repository

    @Environment(\.dismiss) private var dismiss
    @State private var showBuzz = false

    var body: some View {
        ZStack {
            WM.Ground.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    StrapPanelLive(batteryPct: model.batteryNowPct.map { Int($0.rounded()) })
                        .padding(.top, WM.Space.sectionTight)

                    StrapHealthContent(
                        batteryPct: model.batteryNowPct,
                        estimateLabel: model.estimateLabel,
                        trend: model.trend,
                        capture: model.capture,
                        nameSection: AnyView(StrapNameLive()),
                        timeCheck: AnyView(TimeCheckLive()),
                        chargingBadge: AnyView(ChargingBadgeLive()),
                        signal: AnyView(SignalSectionLive(reconnects: model.reconnects)),
                        syncCaption: AnyView(SyncCaptionLive()))

                    buzzHistoryLink
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
            }
        }
        // Keyed on the repository's diff-guarded change counter: the store-backed sections
        // (battery trend, capture bars, gap list) re-read when a completed backfill lands while
        // the cover is open — a plain `.task` ran once per presentation and went stale. refresh()
        // is diff-guarded, so an unchanged pass publishes nothing.
        .task(id: repo.refreshSeq) { await model.refresh() }
        .sheet(isPresented: $showBuzz) { BuzzHistoryScreen() }
    }

    /// A deliberately low-key link (caption ink, bottom of the screen) into the buzz-history sheet — the
    /// "why did the band buzz" record. Present but not prominent, per its quiet-by-design placement.
    private var buzzHistoryLink: some View {
        Button { showBuzz = true } label: {
            Text("Buzz history")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, WM.Space.sectionLoose)
        .accessibilityHint("Shows why the strap recently buzzed")
    }

    // MARK: - Header (title + ink close)

    private var header: some View {
        WMCoverHeader(title: "Strap Health", closeLabel: "Close strap health") { dismiss() }
    }
}

// MARK: - Live-fed leaf views (P7 — each observes LiveState so ONLY it re-renders per BLE event)

/// The strap panel header: name / connection dot / state caption are live; the battery % is the
/// model's published value (store-fallback + live mirror).
private struct StrapPanelLive: View {
    @EnvironmentObject private var live: LiveState
    let batteryPct: Int?

    var body: some View {
        StrapPanel(name: live.advertisingName ?? "WHOOP",
                   connected: live.connected,
                   batteryPct: batteryPct,
                   stateText: live.connectionStatusLabel)
    }
}

/// The Name section — rename the strap's BLE advertising name (WHOOP 4.0 / Harvard only; the strap
/// reboots to apply). Live-observing (name + link + rename status); the rename itself calls
/// `root.ble.renameStrap`, whose ack lands on `live.renameStatus` (a 5/MG has no Harvard name command,
/// so the control is hidden there and the caption says why). Family is read from the same AppStorage
/// key the pickers write (`selectedWhoopModel`, mirroring `WhoopModel.persisted`) so the section reacts
/// without reaching into `BLEManager.selectedModel` (private). The BLEManager guards are authoritative —
/// `canRename` only spares the user a dead-end tap.
private struct StrapNameLive: View {
    @EnvironmentObject private var root: AppRoot
    @EnvironmentObject private var live: LiveState
    @AppStorage(WhoopModel.persistedKey) private var modelRaw: String = WhoopModel.whoop4.rawValue

    @State private var editing = false
    @State private var draft = ""

    private var isWhoop4: Bool {
        (WhoopModel(rawValue: modelRaw) ?? .whoop4).deviceFamily == .whoop4
    }
    /// connected + bonded are the same gates `renameStrap` enforces before it will write.
    private var canRename: Bool { isWhoop4 && live.connected && live.bonded }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(live.advertisingName ?? "WHOOP")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1)
                Spacer(minLength: WM.Space.s)
                if isWhoop4 {
                    Button("Rename") {
                        live.renameStatus = nil          // fresh attempt — drop any prior ack
                        draft = live.advertisingName ?? ""
                        editing = true
                    }
                    // .plain (not the automatic style) so the label honours foregroundStyle ink
                    // rather than the ambient system-accent tint — chrome stays neutral ink.
                    .buttonStyle(.plain)
                    .font(WMType.label)
                    .foregroundStyle(canRename ? WM.Ground.ink : WM.Ground.inkTertiary)
                    .disabled(!canRename)
                    .accessibilityLabel("Rename strap")
                }
            }

            // Status precedence: a live rename ack beats the static family/link hints.
            if let status = live.renameStatus {
                caption(status)
            } else if !isWhoop4 {
                caption("Renaming is available on WHOOP 4.0 straps.")
            } else if !canRename {
                caption("Connect and pair your strap to rename it.")
            }
        }
        .alert("Rename strap", isPresented: $editing) {
            TextField("Strap name", text: $draft)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { }
            // renameStrap trims and rejects an empty/whitespace name itself (surfacing a status),
            // so no need to gate the alert button — which can't be reliably disabled anyway.
            Button("Rename") { root.ble.renameStrap(draft) }
        } message: {
            Text("Your WHOOP 4.0 reboots to apply the new name.")
        }
        // renameStatus is a never-cleared app-wide value (set by BLEManager/FrameRouter, reset
        // nowhere). Wipe it as the section appears so a stale ack from an earlier session can't
        // shadow the live family/link hint or reappear on every reopen; it repopulates live only
        // while the user is actually renaming this session.
        .onAppear { live.renameStatus = nil }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Time check section — buzz the current time on the wrist (Haptic Clock #460). Live-observing
/// (the link gate); the trigger funnels through `HabitBuzzScheduler.buzzTimeCheck`, the same path the
/// strap's double-tap gesture takes, so the two can't stack overlapping pulse sequences. Disabled ink
/// (not hidden) when disconnected — the buzz is a BLE write, so no link means no buzz.
private struct TimeCheckLive: View {
    @EnvironmentObject private var root: AppRoot
    @EnvironmentObject private var live: LiveState

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            Button("Buzz the time") {
                root.buzz.buzzTimeCheck(label: "Time check")
            }
            // .plain so the label honours foregroundStyle ink, not the system accent — the
            // Rename button's idiom (chrome stays neutral ink).
            .buttonStyle(.plain)
            .font(WMType.body)
            .foregroundStyle(live.connected ? WM.Ground.ink : WM.Ground.inkTertiary)
            .disabled(!live.connected)
            .accessibilityLabel("Buzz the current time on the strap")

            Text("Long buzzes count the hour, short buzzes count five minutes each. Double-tapping the strap does the same.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Battery section's "Charging" overline — shown only on a KNOWN charging state.
private struct ChargingBadgeLive: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        if live.charging == true {
            Text("Charging").wmOverline()
        }
    }
}

/// The Signal section over the live per-session counters (+ the model's reconnect count).
private struct SignalSectionLive: View {
    @EnvironmentObject private var live: LiveState
    let reconnects: Int

    var body: some View {
        let rejected = live.rejectedFramesThisSession + live.rejectedFramesUnarchived
        StrapSignalSection(
            quality: SignalQuality.grade(
                rejectedFrames: rejected,
                consoleOnly: live.decodedChunksThisSession == 0 && live.consoleChunksThisSession > 0,
                reconnects: reconnects),
            reconnects: reconnects,
            rejectedFrames: rejected,
            consoleChunks: live.consoleChunksThisSession,
            hasSession: live.decodedChunksThisSession > 0 || live.consoleChunksThisSession > 0
                || rejected > 0 || reconnects > 0 || live.connected)
    }
}

/// The sync status caption: in-flight beats stale error beats last-success.
private struct SyncCaptionLive: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        SyncCaption(text: syncText)
    }

    private var syncText: String {
        if live.backfilling { return "Syncing strap history…" }
        if let err = live.lastSyncError { return "Last sync ended early: \(err)" }
        if let at = live.lastSyncedAt {
            let rel = Self.syncFormatter.localizedString(
                for: Date(timeIntervalSince1970: at), relativeTo: Date())
            return "Last synced \(rel)."
        }
        return "No sync yet this session."
    }

    private static let syncFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - Content (pure)

/// The section stack over plain values, previewable without a store or a live link. The live-fed
/// pieces arrive as injected subviews (the RestScreen idiom) so this body never observes LiveState;
/// previews inject pure stand-ins.
struct StrapHealthContent: View {
    let batteryPct: Double?
    let estimateLabel: String?
    let trend: [StrapHealthModel.BatteryPoint]
    let capture: [StrapHealthModel.DayCapture]
    /// The Name section body — the rename affordance (live-observing in the app; omitted in previews).
    var nameSection: AnyView? = nil
    /// The Time check section body — the Haptic Clock trigger (live-observing; omitted in previews).
    var timeCheck: AnyView? = nil
    /// The Battery hero's "Charging" overline (live-observing in the app; nil/static in previews).
    var chargingBadge: AnyView? = nil
    /// The whole Signal section body (live counters in the app; a pure `StrapSignalSection` in previews).
    let signal: AnyView
    /// The sync status caption (live in the app; a pure `SyncCaption` in previews).
    let syncCaption: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let nameSection {
                RuleSection("Name") {
                    nameSection
                }
            }
            if let timeCheck {
                RuleSection("Time check") {
                    timeCheck
                }
            }
            RuleSection("Battery") {
                batterySection
            }
            RuleSection("Capture") {
                captureSection
            }
            RuleSection("Signal") {
                signal
            }
            syncCaption
                .padding(.top, WM.Space.section)
        }
    }

    // MARK: Battery

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.xs) {
                Text(batteryPct.map { String(format: "%.0f", $0) } ?? "—")
                    .font(WMType.display(64))
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("%")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                Spacer(minLength: WM.Space.s)
                VStack(alignment: .trailing, spacing: WM.Space.xs) {
                    if let chargingBadge {
                        chargingBadge
                    }
                    if let estimateLabel {
                        Text("\(estimateLabel) left")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkSecondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            if trend.count >= 2 {
                // The charge domain — literally the strap's charge level here — colors the data
                // marks; chrome (axes, grid) stays caption ink inside BandChart.
                // `.day` — one mark per banked daily reading, which is what this trend is. Stated
                // rather than defaulted: the unit sets the bar WIDTH, and a wrong one here would draw
                // hairlines over a mostly-empty plot without failing anything (017).
                BandChart(points: trend.map { ($0.date, $0.soc) }, band: nil,
                          domain: .charge, height: 140, unit: .day)
                Text("Battery level over the last \(StrapHealthModel.windowDays) days — the last reading banked each day.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The battery trend builds as the strap reports charge over a few days of wear.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Capture

    /// Every reported gap across the window, one row each, oldest first.
    private var gapRows: [GapRow] {
        capture.flatMap { day in
            day.gaps.map { gap in
                GapRow(id: "\(day.day)|\(gap.start)",
                       label: "\(day.weekday) \(StrapHealthFormat.timeSpan(gap.start, gap.end))",
                       duration: StrapHealthFormat.duration(seconds: gap.durationS))
            }
        }
    }

    private struct GapRow: Identifiable {
        let id: String
        let label: String
        let duration: String
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            // Seven worn-waking coverage columns (the bar motif): ink fill on a rule track,
            // weekday captions underneath. Coverage isn't a score domain, so the bars stay ink.
            // A nil coverage (today before 08:00 — the window hasn't started) draws the bare
            // track and says so, distinct from a genuine 0 % capture failure.
            HStack(alignment: .bottom, spacing: WM.Space.s) {
                ForEach(capture) { day in
                    VStack(spacing: WM.Space.xs) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(WM.Ground.rule)
                                .frame(width: 18, height: 44)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(WM.Ground.ink)
                                .frame(width: 18,
                                       height: max((day.coverage ?? 0) > 0 ? 2 : 0,
                                                   44 * (day.coverage ?? 0)))
                        }
                        Text(day.weekday)
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.coverage.map {
                        "\(day.weekday): \(Int(($0 * 100).rounded()))% capture coverage"
                    } ?? (day.preHistory
                          ? "\(day.weekday): before setup, nothing recorded"
                          : "\(day.weekday): capture window hasn't started yet"))
                }
            }

            if !capture.isEmpty, capture.allSatisfy({ $0.preHistory }) {
                // Nothing in this window predates the install, so there is no coverage to report and
                // nothing was lost. Saying "no gaps in the last 7 days" would imply 7 days were graded.
                Text("No capture history yet — grading starts after your first day of wear.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            } else if gapRows.isEmpty {
                Text("No capture gaps while worn in the last \(StrapHealthModel.windowDays) days.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(gapRows) { row in
                        HStack {
                            Text(row.label)
                                .font(WMType.body)
                                .foregroundStyle(WM.Ground.ink)
                            Spacer()
                            Text(row.duration)
                                .font(WMType.caption)
                                .foregroundStyle(WM.Ground.inkSecondary)
                        }
                        .padding(.vertical, WM.Space.s)
                        .accessibilityElement(children: .combine)
                        if row.id != gapRows.last?.id {
                            WMRule()
                        }
                    }
                }
                Text("Over 15 minutes without heart-rate capture while worn. The strap trims sent history, so a gap can't be re-synced later.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Signal section (pure)

/// The Signal section body over plain values — the live wrapper feeds it in the app; previews
/// construct it directly.
struct StrapSignalSection: View {
    let quality: SignalQuality.Assessment
    let reconnects: Int
    let rejectedFrames: Int
    let consoleChunks: Int
    /// False until this session has actually decoded something from a strap. `SignalQuality.grade`
    /// starts at `.good` and only ever downgrades, so with zero evidence it returned a green "Good" and
    /// the copy asserted "frames are decoding cleanly and the link is holding steady this session" — on
    /// an install that had never connected to anything.
    var hasSession: Bool = true

    private var gradeColor: Color {
        guard hasSession else { return WM.Ground.inkTertiary }
        switch quality.grade {
        case .good: return WM.Semantic.good
        case .fair: return WM.Semantic.warn
        case .poor: return WM.Semantic.bad
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            HStack(spacing: WM.Space.s) {
                // Semantic status dot — a status, never an accent.
                Circle()
                    .fill(gradeColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(hasSession ? quality.grade.label : "No data yet")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(hasSession ? "Signal quality: \(quality.grade.label)"
                                           : "Signal quality: no data yet")

            Text(!hasSession
                 ? "Nothing has synced yet this session — connect the strap and the link quality will "
                   + "be graded here."
                 : (quality.reasons.isEmpty
                    ? "Frames are decoding cleanly and the link is holding steady this session."
                    : quality.reasons.joined(separator: " ")))
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: WM.Space.sectionLoose) {
                SignalCell(label: "Reconnects", value: "\(reconnects)")
                SignalCell(label: "Rejected", value: "\(rejectedFrames)", unit: "frames")
                SignalCell(label: "Console", value: "\(consoleChunks)", unit: "chunks")
            }
        }
    }
}

/// The sync status caption's shared styling (live wrapper + previews).
struct SyncCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Formatting (pure)

/// Locale-aware time-span / duration strings for the gap rows. Static + pure — a naming layer over
/// `WMFormat`.
enum StrapHealthFormat {

    /// "13:05–15:40" (or "1:05–3:40 PM" under a 12-hour locale) from unix seconds.
    static func timeSpan(_ start: Int, _ end: Int) -> String {
        "\(WMFormat.timeOfDay(start))–\(WMFormat.timeOfDay(end))"
    }

    /// "2h 35m" / "45m" from seconds (minute-floored; the gap threshold is 15 min, so a
    /// sub-minute duration can never reach a row).
    static func duration(seconds: Int) -> String {
        WMFormat.duration(seconds: seconds, style: .compact)
    }
}

// MARK: - Previews

#Preview("Strap health — light") {
    ScrollView {
        StrapHealthContent(
            batteryPct: 41, estimateLabel: "~2.1 days",
            trend: StrapHealthSpecimen.trend,
            capture: StrapHealthSpecimen.capture,
            signal: AnyView(StrapSignalSection(
                quality: SignalQuality.grade(rejectedFrames: 0, consoleOnly: false, reconnects: 1),
                reconnects: 1, rejectedFrames: 0, consoleChunks: 2)),
            syncCaption: AnyView(SyncCaption(text: "Last synced 4 min ago.")))
            .padding(.horizontal, WM.Space.gutter)
    }
    .background(WM.Ground.ground)
    .preferredColorScheme(.light)
}

#Preview("Strap health — poor link, dark") {
    ScrollView {
        StrapHealthContent(
            batteryPct: 12, estimateLabel: "~9h",
            trend: StrapHealthSpecimen.trend,
            capture: StrapHealthSpecimen.capture,
            signal: AnyView(StrapSignalSection(
                quality: SignalQuality.grade(rejectedFrames: 3, consoleOnly: true, reconnects: 4),
                reconnects: 4, rejectedFrames: 3, consoleChunks: 18)),
            syncCaption: AnyView(SyncCaption(text: "Last sync ended early: strap went quiet mid-sync.")))
            .padding(.horizontal, WM.Space.gutter)
    }
    .background(WM.Ground.ground)
    .preferredColorScheme(.dark)
}

/// Deterministic preview fixtures (no store / live link needed).
private enum StrapHealthSpecimen {
    static let trend: [StrapHealthModel.BatteryPoint] = {
        let day0 = Calendar.current.startOfDay(for: Date())
        let socs: [Double] = [96, 78, 61, 43, 100, 82, 63]
        return socs.enumerated().map { i, soc in
            StrapHealthModel.BatteryPoint(
                date: Calendar.current.date(byAdding: .day, value: i - 6, to: day0)!,
                soc: soc)
        }
    }()

    static let capture: [StrapHealthModel.DayCapture] = {
        let labels = ["Wed", "Thu", "Fri", "Sat", "Sun", "Mon", "Tue"]
        let gapStart = Int(Date().timeIntervalSince1970) - 2 * 86_400
        return labels.enumerated().map { i, label in
            StrapHealthModel.DayCapture(
                day: "2026-07-\(9 + i)", weekday: label, preHistory: false,
                coverage: [1.0, 0.97, 0.92, 1.0, 0.78, 1.0, 0.64][i],
                gaps: i == 4 ? [GapScan.Gap(start: gapStart, end: gapStart + 9_300)] : [])
        }
    }()
}
