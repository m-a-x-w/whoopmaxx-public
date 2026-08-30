import SwiftUI

/// strap health — the strap's own vitals (007 F4), a full-screen cover. `AppShell` presents it for
/// `AppActions.openStrapHealth` (Today's strap chip, Live's strap row) and Settings › Strap presents it
/// from its first row. Top to bottom (the 037 layout):
///   • Header — the strap's name over its connection state and firmware, with the ink close.
///   • Battery — a `HeroReadout` "82 %" with the runtime estimate ("~2.1 days left") or "Charging" as
///     its reading, a `.hero` `LineScale` of the charge, then the 7-day persisted-SoC line.
///   • Capture — one row per day: weekday, a `.compact` bar scale of worn-waking coverage, the %.
///     Then the reported gap rows ("Tue 13:05–15:40 · 2h 35m"). Gaps are permanent facts (the strap
///     trims acked history) — informational, never a re-sync.
///   • Signal — the session link-quality grade + reconnects / rejected / console counters, and the sync
///     status caption.
///   • Rows — Buzz the time (Haptic Clock #460), Rename strap (WHOOP 4.0; the strap reboots to apply),
///     Buzz history.
/// Chrome stays neutral ink; semantic color marks STATUSES only (grade dot, a low battery).
///
/// P7: the screen itself observes NO LiveState — the live-fed pieces (header, battery hero, signal
/// counters, sync caption, time check, rename) are isolated into small leaf subviews below, mirroring
/// RestScreen's `WakeWindowArmed`, so per-BLE-event publish churn (~1 Hz HR, the #755 offload stamp
/// storm) re-renders those rows only, never the whole scroll body.
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
                    StrapHeaderLive(onClose: { dismiss() })

                    StrapHealthContent(
                        hero: AnyView(BatteryHeroLive(batteryPct: model.batteryNowPct,
                                                      estimateLabel: model.estimateLabel)),
                        trend: model.trend,
                        capture: model.capture,
                        signal: AnyView(SignalSectionLive(reconnects: model.reconnects)),
                        syncCaption: AnyView(SyncCaptionLive()),
                        timeCheck: AnyView(TimeCheckLive()),
                        rename: AnyView(StrapNameLive()),
                        onBuzzHistory: { showBuzz = true })
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
        .sheet(isPresented: $showBuzz) {
            BuzzHistoryScreen()
                .presentationCornerRadius(WM.Radius.sheet)
        }
    }
}

// MARK: - Live-fed leaf views (P7 — each observes LiveState so ONLY it re-renders per BLE event)

/// The cover's header: the strap's advertising name (WHOOP 4.0 reads it back at connect; "Strap health"
/// until then, and on straps that never report one) over the shared connection label and, once the
/// handshake has reported it, the firmware version.
private struct StrapHeaderLive: View {
    @EnvironmentObject private var live: LiveState
    let onClose: () -> Void

    var body: some View {
        WMCoverHeader(title: live.advertisingName ?? "Strap health",
                      subtitle: subtitle,
                      closeLabel: "Close strap health",
                      onClose: onClose)
    }

    private var subtitle: String {
        guard let firmware = live.strapFirmware else { return live.connectionStatusLabel }
        return "\(live.connectionStatusLabel) · firmware \(firmware)"
    }
}

/// The battery hero with its live "Charging" reading. The % and the estimate are the model's published
/// values (store fallback + live mirror); only `charging` comes off LiveState.
private struct BatteryHeroLive: View {
    @EnvironmentObject private var live: LiveState
    let batteryPct: Double?
    let estimateLabel: String?

    var body: some View {
        StrapBatteryHero(batteryPct: batteryPct, estimateLabel: estimateLabel,
                         charging: live.charging == true)
    }
}

/// Rename the strap's BLE advertising name (WHOOP 4.0 / Harvard only; the strap reboots to apply).
/// Live-observing (name + link + rename status); the rename itself calls `root.ble.renameStrap`, whose
/// ack lands on `live.renameStatus` (a 5/MG has no Harvard name command, so the row is inert there and
/// its subtitle says why). Family is read from the same AppStorage key the pickers write
/// (`selectedWhoopModel`, mirroring `WhoopModel.persisted`) so the row reacts without reaching into
/// `BLEManager.selectedModel` (private). The BLEManager guards are authoritative — `canRename` only
/// spares the user a dead-end tap.
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
        WMNavRow(title: "Rename strap",
                 subtitle: statusCaption,
                 hint: canRename ? "Opens a field for the new name. The strap reboots to apply it." : nil,
                 titleColor: canRename ? WM.Ground.ink : WM.Ground.inkTertiary,
                 showsDisclosure: canRename) {
            live.renameStatus = nil          // fresh attempt — drop any prior ack
            draft = live.advertisingName ?? ""
            editing = true
        }
        .disabled(!canRename)
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
        // nowhere). Wipe it as the row appears so a stale ack from an earlier session can't
        // shadow the live family/link hint or reappear on every reopen; it repopulates live only
        // while the user is actually renaming this session.
        .onAppear { live.renameStatus = nil }
    }

    /// Status precedence: a live rename ack beats the static family/link hints; a strap that can be
    /// renamed right now needs no caption.
    private var statusCaption: String? {
        if let status = live.renameStatus { return status }
        if !isWhoop4 { return "Renaming is available on WHOOP 4.0 straps." }
        if !canRename { return "Connect and pair your strap to rename it." }
        return nil
    }
}

/// Buzz the current time on the wrist (Haptic Clock #460). Live-observing (the link gate); the trigger
/// funnels through `HabitBuzzScheduler.buzzTimeCheck`, the same path the strap's double-tap gesture
/// takes, so the two can't stack overlapping pulse sequences. Disabled ink (not hidden) when
/// disconnected — the buzz is a BLE write, so no link means no buzz. It acts in place: no disclosure.
private struct TimeCheckLive: View {
    @EnvironmentObject private var root: AppRoot
    @EnvironmentObject private var live: LiveState

    var body: some View {
        WMNavRow(title: "Buzz the time",
                 subtitle: "Long buzzes count the hour, short buzzes count five minutes each. Double-tapping the strap does the same.",
                 hint: live.connected ? "Buzzes the current time on the strap"
                                      : "Connect the strap to buzz the time",
                 titleColor: live.connected ? WM.Ground.ink : WM.Ground.inkTertiary,
                 showsDisclosure: false) {
            root.buzz.buzzTimeCheck(label: "Time check")
        }
        .disabled(!live.connected)
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
    /// The battery hero (live "Charging" in the app; a pure `StrapBatteryHero` in previews).
    let hero: AnyView
    let trend: [StrapHealthModel.BatteryPoint]
    let capture: [StrapHealthModel.DayCapture]
    /// The Signal section body (live counters in the app; a pure `StrapSignalSection` in previews).
    let signal: AnyView
    /// The sync status caption (live in the app; a pure `SyncCaption` in previews).
    let syncCaption: AnyView
    /// The "Buzz the time" row (live-observing in the app; omitted in previews).
    var timeCheck: AnyView? = nil
    /// The "Rename strap" row (live-observing in the app; omitted in previews).
    var rename: AnyView? = nil
    /// Opens the buzz-history sheet; nil hides the row.
    var onBuzzHistory: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
                .padding(.top, WM.Space.l)
            batteryTrend
                .padding(.top, WM.Space.sectionTight)
            RuleSection("Capture · worn while awake", topGap: WM.Space.sectionTight) {
                captureSection
            }
            RuleSection("Signal", topGap: WM.Space.sectionTight) {
                VStack(alignment: .leading, spacing: WM.Space.m) {
                    signal
                    syncCaption
                }
            }
            actionRows
                .padding(.top, WM.Space.sectionTight)
        }
    }

    // MARK: Battery

    @ViewBuilder
    private var batteryTrend: some View {
        if trend.count >= 2 {
            VStack(alignment: .leading, spacing: WM.Space.s) {
                // A neutral inkSecondary trace: battery is the strap's own state, not one of the three
                // score domains, so it takes no domain color (037). `.day` — one point per banked
                // daily reading, which is what this trend is. Stated rather than defaulted: the unit sets how a
                // point is binned, and a wrong one here would misplace every reading without failing
                // anything (017). Zero stays in view: a battery line read against its own min…max would
                // turn a 5-point dip into a cliff.
                BandChart(points: trend.map { ($0.date, $0.soc) }, band: nil,
                          domain: .charge, height: 120, unit: .day, includesZero: true,
                          lineColor: WM.Ground.inkSecondary)
                Text("Battery level over the last \(StrapHealthModel.windowDays) days — the last reading banked each day.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("The battery trend builds as the strap reports charge over a few days of wear.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder
    private var captureSection: some View {
        // Built once per pass, then read three times below.
        let gaps = gapRows
        VStack(alignment: .leading, spacing: 0) {
            ForEach(capture) { day in
                captureRow(day)
            }

            Group {
                if !capture.isEmpty, capture.allSatisfy({ $0.preHistory }) {
                    // Nothing in this window predates the install, so there is no coverage to report and
                    // nothing was lost. Saying "no gaps in the last 7 days" would imply 7 days were graded.
                    Text("No capture history yet — grading starts after your first day of wear.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                } else if gaps.isEmpty {
                    Text("No capture gaps while worn in the last \(StrapHealthModel.windowDays) days.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                } else {
                    VStack(alignment: .leading, spacing: WM.Space.s) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(gaps) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.label)
                                        .font(WMType.body)
                                        .foregroundStyle(WM.Ground.ink)
                                    Spacer(minLength: WM.Space.s)
                                    Text(row.duration)
                                        .font(WMType.label)
                                        .foregroundStyle(WM.Ground.inkSecondary)
                                }
                                .padding(.vertical, WM.Space.s)
                                .frame(minHeight: WM.Space.row)
                                .accessibilityElement(children: .combine)
                                if row.id != gaps.last?.id {
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
            .padding(.top, WM.Space.m)
        }
    }

    /// One day of worn-waking coverage: weekday, a `.compact` bar scale, the %. Coverage isn't a score
    /// domain, so the bar stays secondary ink. A nil coverage (today before 08:00 — the window hasn't
    /// started — or a day before setup) draws the bare track and a dash, distinct from a genuine 0 %
    /// capture failure.
    private func captureRow(_ day: StrapHealthModel.DayCapture) -> some View {
        HStack(spacing: WM.Space.m) {
            Text(day.weekday)
                .font(WMType.label)
                .foregroundStyle(WM.Ground.inkTertiary)
                .frame(width: 48, alignment: .leading)
            LineScale(value: day.coverage, color: WM.Ground.inkSecondary, style: .compact, showsDot: false)
            Text(day.coverage.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(WMType.numeral(15))
                .foregroundStyle(day.coverage == nil ? WM.Ground.inkTertiary : WM.Ground.ink)
                .frame(width: 44, alignment: .trailing)
        }
        .frame(minHeight: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.coverage.map {
            "\(day.weekday): \(Int(($0 * 100).rounded()))% capture coverage"
        } ?? (day.preHistory
              ? "\(day.weekday): before setup, nothing recorded"
              : "\(day.weekday): capture window hasn't started yet"))
    }

    // MARK: Rows

    /// Buzz the time / Rename strap / Buzz history — whichever the caller supplied, hairline-separated.
    @ViewBuilder
    private var actionRows: some View {
        VStack(spacing: 0) {
            if let timeCheck {
                timeCheck
            }
            if let rename {
                if timeCheck != nil { WMRule() }
                rename
            }
            if let onBuzzHistory {
                if timeCheck != nil || rename != nil { WMRule() }
                // The "why did the band buzz" record — habit reminders, smart-alarm wakes, inactivity
                // nudges, test buzzes and time checks.
                WMNavRow(title: "Buzz history",
                         subtitle: "Habits, smart alarm, nudges, time checks",
                         hint: "Shows why the strap recently buzzed",
                         action: onBuzzHistory)
            }
        }
    }
}

// MARK: - Battery hero (pure)

/// The battery reading as the Line language's hero: "82 %" with its name and reading trailing, the
/// charge as a `.hero` `LineScale` beneath. Neutral ink until the level matters — warn under 31 %, bad
/// under 15 %, the thresholds `StrapPanel` uses on Live, so the same strap never reads two ways.
struct StrapBatteryHero: View {
    let batteryPct: Double?
    let estimateLabel: String?
    let charging: Bool

    /// "Charging", the runtime estimate, or both — nil when neither is known.
    private var reading: String? {
        let parts = [charging ? "Charging" : nil, estimateLabel.map { "\($0) left" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var levelColor: Color {
        guard let batteryPct else { return WM.Ground.ink }
        switch batteryPct {
        case ..<15: return WM.Semantic.bad
        case ..<31: return WM.Semantic.warn
        default:    return WM.Ground.ink
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.l) {
            HeroReadout(value: batteryPct.map { String(format: "%.0f", $0) } ?? "—",
                        unit: batteryPct == nil ? nil : "%",
                        title: "Battery",
                        subtitle: reading,
                        color: levelColor)
            LineScale(value: batteryPct.map { $0 / 100 }, color: levelColor, style: .hero)
        }
    }
}

// MARK: - Signal section (pure)

/// The Signal section body over plain values — the live wrapper feeds it in the app; previews
/// construct it directly. Four readouts in a row (the grade, reconnects, rejected frames, console
/// chunks), then the grade's reasons in a sentence.
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
            HStack(alignment: .top, spacing: WM.Space.m) {
                gradeCell
                SignalCell(label: "Reconnects", value: "\(reconnects)", valueSize: 24, fillsWidth: true)
                SignalCell(label: "Rejected", value: "\(rejectedFrames)", unit: "frames",
                           valueSize: 24, fillsWidth: true)
                SignalCell(label: "Console", value: "\(consoleChunks)", unit: "chunks",
                           valueSize: 24, fillsWidth: true)
            }

            Text(!hasSession
                 ? "Nothing has synced yet this session — connect the strap and the link quality will "
                   + "be graded here."
                 : (quality.reasons.isEmpty
                    ? "Frames are decoding cleanly and the link is holding steady this session."
                    : quality.reasons.joined(separator: " ")))
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The grade in `SignalCell`'s shape, plus the semantic status dot the counters don't carry. "—"
    /// before there is a session to grade.
    private var gradeCell: some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text("Signal").wmOverline()
            HStack(alignment: .center, spacing: 6) {
                // Semantic status dot — a status, never an accent.
                Circle()
                    .fill(gradeColor)
                    .frame(width: 6, height: 6)
                Text(hasSession ? quality.grade.label : "—")
                    .font(WMType.numeral(24))
                    .foregroundStyle(hasSession ? WM.Ground.ink : WM.Ground.inkTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasSession ? "Signal quality: \(quality.grade.label)"
                                       : "Signal quality: no data yet")
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
            hero: AnyView(StrapBatteryHero(batteryPct: 82, estimateLabel: "~4.5 days", charging: false)),
            trend: StrapHealthSpecimen.trend,
            capture: StrapHealthSpecimen.capture,
            signal: AnyView(StrapSignalSection(
                quality: SignalQuality.grade(rejectedFrames: 0, consoleOnly: false, reconnects: 1),
                reconnects: 1, rejectedFrames: 0, consoleChunks: 2)),
            syncCaption: AnyView(SyncCaption(text: "Last synced 4 min ago.")),
            onBuzzHistory: {})
            .padding(.horizontal, WM.Space.gutter)
    }
    .background(WM.Ground.ground)
    .preferredColorScheme(.light)
}

#Preview("Strap health — low, poor link, dark") {
    ScrollView {
        StrapHealthContent(
            hero: AnyView(StrapBatteryHero(batteryPct: 12, estimateLabel: "~9h", charging: true)),
            trend: StrapHealthSpecimen.trend,
            capture: StrapHealthSpecimen.capture,
            signal: AnyView(StrapSignalSection(
                quality: SignalQuality.grade(rejectedFrames: 3, consoleOnly: true, reconnects: 4),
                reconnects: 4, rejectedFrames: 3, consoleChunks: 18)),
            syncCaption: AnyView(SyncCaption(text: "Last sync ended early: strap went quiet mid-sync.")),
            onBuzzHistory: {})
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
                coverage: [1.0, 0.97, 0.92, 1.0, 0.78, 1.0, nil][i],
                gaps: i == 4 ? [GapScan.Gap(start: gapStart, end: gapStart + 9_300)] : [])
        }
    }()
}
