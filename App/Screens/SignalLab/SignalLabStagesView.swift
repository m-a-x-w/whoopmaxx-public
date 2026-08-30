import SwiftUI
import StrapProtocol
import StrapStore
import StrapAnalytics

/// Stages mode — one night's rMSSD split by SLEEP STAGE, drawn as the bar set the rest of the app draws
/// quantities with, and rendered so that a stage the strap did not actually watch shows as ABSENCE rather
/// than as a number.
///
/// WHAT IT ADDS. The app already carries one HRV figure per night. That figure cannot distinguish a night
/// where deep carried the rebound from a night of the same average where deep was flat and a couple of REM
/// blocks did all the lifting. `HRVByStage` (Core/Analysis) splits the SAME five-minute-window estimator by
/// the stored hypnogram's labels; this panel is its only surface.
///
/// ── WHY THIS SURFACE IS MOSTLY ABOUT ABSENCE ────────────────────────────────────────────────────────
///
/// The stored hypnogram is `SleepStagingV2` output, and V2 asserts a stage across spans where no channel had
/// data — its epoch loop skips an unwatched epoch and the tiling that follows stretches the PRECEDING label
/// across the hole, so a segment's `end` is the next staged epoch's start rather than the end of the
/// evidence. On the real 2026-08-09 corpus the night ending 08-02 claims 217 minutes of deep, 176 of which
/// are that stretch. The engine excludes the phantom span, measures 70.3 ms over the 41 real minutes, and
/// hands this view `admittedSec ≈ 2 460` against `claimedSec ≈ 13 020`.
///
/// Two ways to get that wrong, and this view takes neither:
///   • print "deep 70 ms" bare — honest arithmetic, but the reader assumes it speaks for all 217 minutes,
///     which is the app asserting a number it did not measure;
///   • blank it — throwing away 41 minutes of real measurement, and asserting an absence that isn't one.
/// So the qualifying clock travels WITH the value, on its own line, always: every measured bar is followed
/// by "over N of the M labelled <stage>". There is no code path that renders `rmssd` without it.
///
/// And a stage with no number gets NO BAR AT ALL — not a zero-width bar, not a dash, not a track. Its lane
/// holds the reason instead, and each of the four absence verdicts means exactly one thing about THE
/// RECORD (see `absenceLine`). A night where three of four stages are absent shows one bar and three
/// reasons, which is the honest shape of that night.
///
/// ── NEUTRAL INK ─────────────────────────────────────────────────────────────────────────────────────
///
/// Per-stage HRV is a DERIVED signal, not one of the three domains, so the bars are ink — never Charge
/// ember, Effort red-pink or Rest indigo. Colour stays reserved for the domains.
///
/// ── COPY REGISTER ───────────────────────────────────────────────────────────────────────────────────
///
/// rMSSD is the dispersion of successive R-R differences in milliseconds and nothing more. Not a "recovery
/// quality", not a sleep verdict, not a condition. Descriptive and within-user throughout: no comparison to
/// anyone else, no target, no action. Banned from every string in this file, exactly as in `HRVFreqReadout`
/// and `HRVByStage`: impaired, poor, abnormal, apnea, insomnia, hypoxemia, arrhythmia, "consider",
/// "you should", "talk to".
///
/// READ-ONLY: one bounded `rrIntervals` read per night browsed, off the already-stored raw stream under the
/// strap id. No schema change, no writes, no side effects.
struct SignalLabStagesView: View {
    @EnvironmentObject private var repo: Repository

    /// Preview / no-store seam: when set, this report IS the panel (the session list and the store read are
    /// both skipped) and the night stepper is inert. nil in the real app.
    var previewReport: StageHRVReport? = nil

    /// The staged nights available to browse, newest first — CACHED rather than derived inside `body`.
    ///
    /// `repo.sleeps` runs to ~4 000 multi-KB rows, and filtering + sorting it is not something to do three or
    /// four times per render pass (the stepper's two enablement checks and the selection each want it). It is
    /// rebuilt only when the Repository actually republishes, off the main actor, keyed on `refreshSeq` —
    /// which is bumped inside the same guarded block that assigns `sleeps`, so the two cannot drift.
    @State private var nights: [CachedSleepSession] = []
    /// The browsed night, by its DETECTED `startTs` (the session's immutable key) rather than by an index
    /// into `nights`. A refresh that inserts a newer night would slide an index onto a different record
    /// without the user touching anything; a key holds the night the user is actually reading.
    @State private var selectedStart: Int?
    @State private var report: StageHRVReport?
    @State private var loading = false
    /// Bumped per load so a late read can't clobber a newer one.
    @State private var loadGen = 0

    /// Row budget for the night's R-R read. A staged night is at most ~24 h and the store banks ~1.28 R-R
    /// rows per second, so ~110 k rows is the realistic ceiling and this never binds on a real night. It is
    /// here for the pathological one (a mis-detected multi-day window), and when it DOES bind the panel says
    /// so rather than quietly reporting the thinner coverage that a truncated read would produce — the store
    /// reads `ORDER BY ts ASC LIMIT ?`, so a binding limit drops the END of the night, and the stages late in
    /// it would report an absence whose stated reason would be about the record when it was really about
    /// this read. See `StageHRVReport.rrTruncated`.
    private static let rrRowBudget = 200_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WM.Space.l) {
                sourceLine
                if let report {
                    meta(report)
                    bars(report)
                    provenance(report)
                } else if loading {
                    Text("Reading this night's R-R…")
                        .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                } else if !repo.loaded {
                    // Distinct from the empty state on purpose: before the Repository's first publish there
                    // are no sessions to browse YET, which is not the same statement as "the record holds no
                    // staged night" and must not borrow its copy.
                    Text("Reading the record…")
                        .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                } else {
                    Text("No staged night in the record yet. A night appears here once the strap has banked one and the app has staged it.")
                        .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .task(id: repo.refreshSeq) { await refreshNights() }
        // Keyed on the session's identity, so a republish that leaves the browsed night in place does not
        // re-issue the read — only actually moving to another night does.
        .task(id: selectedSession?.startTs) { await load() }
    }

    // MARK: Header source line + night stepper

    private var sourceLine: some View {
        HStack(spacing: WM.Space.xs) {
            Text("HRV by stage").wmOverline(WM.Ground.inkSecondary)
            Spacer(minLength: WM.Space.s)
            if let report {
                Text(report.title).font(WMType.overline).kerning(WMType.overlineTracking)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            // The night stepper, in Rest's glyphs and hit region (`RestScreenContent.stepper`) — chevron.left
            // steps OLDER because `nights` is newest-first, the same direction Rest's back chevron moves.
            // Inert in a preview, where `nights` is empty and the injected report is the only night.
            stepper("chevron.left", "Older night", enabled: canStepBack) { step(+1) }
            stepper("chevron.right", "Newer night", enabled: canStepForward) { step(-1) }
        }
    }

    private func stepper(_ systemName: String, _ label: String, enabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(WMType.icon(.nav))
                .foregroundStyle(enabled ? WM.Ground.ink : WM.Ground.inkTertiary.opacity(0.5))
                // ≥44×44 hit region (HIG); the glyph keeps its size, only the invisible box grows.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: The night's own line (window, what was read)

    private func meta(_ r: StageHRVReport) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text(r.windowLine)
                .font(WMType.caption).foregroundStyle(WM.Ground.inkSecondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if r.lowConfidence {
                // The stager's own flag on this night, carried through rather than restated — a window it
                // kept but is unsure of. It qualifies every span below it, so it belongs above them.
                Text("The stager flagged this night as low confidence, so the stage boundaries under these numbers are its uncertain ones.")
                    .font(WMType.caption).foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if r.rrTruncated {
                Text("The R-R read filled its \(Self.rrRowBudget.formatted())-row budget, so it may not reach the end of this window — a stage late in the night can read as less covered here than the record actually holds.")
                    .font(WMType.caption).foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: The bar set

    private func bars(_ r: StageHRVReport) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.sectionTight) {
            ForEach(r.night.readings, id: \.stage) { reading in
                row(reading, scale: r.scaleMax)
            }
        }
        .padding(.top, WM.Space.s)
    }

    /// One stage. A measured stage gets its numeral, its bar and the clock the bar speaks for; an absent one
    /// gets its reason in the same lane and no bar geometry whatsoever.
    private func row(_ reading: HRVByStage.Reading, scale: Double) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.stageName(reading.stage)).wmOverline(WM.Ground.inkSecondary)
                Spacer(minLength: WM.Space.s)
                // The numeral exists ONLY on `.measured` — `rmssd` is non-nil iff the verdict is `.measured`,
                // and an absent stage prints nothing here rather than an em-dash, which in a column of
                // numbers reads as a measured zero.
                if let rmssd = reading.rmssd {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Self.ms(rmssd)).font(WMType.numeral(28)).monospacedDigit()
                            .foregroundStyle(WM.Ground.ink)
                        Text("ms").font(WMType.overline).foregroundStyle(WM.Ground.inkTertiary)
                    }
                }
            }
            if let rmssd = reading.rmssd {
                WMTrackBar(segments: [(fraction: rmssd / scale, color: WM.Ground.ink)], track: nil)
                    .frame(height: Self.barHeight)
                // THE QUALIFICATION, always, in ink rather than tertiary: it is part of the claim, not a
                // footnote to it. There is no branch of this view that draws the bar above without it.
                Text(Self.admittedLine(reading))
                    .font(WMType.caption).foregroundStyle(WM.Ground.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Self.absenceLine(reading))
                    .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let recordLine = Self.recordLine(reading) {
                Text(recordLine)
                    .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let bandLine = Self.bandLine(reading) {
                Text(bandLine)
                    .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Provenance + what the numbers are

    private func provenance(_ r: StageHRVReport) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            // The one thing this surface must say plainly, per the brief: the boundaries are ours.
            Text("Stage boundaries come from this app's own sleep stager, not from the strap — every number above is only as good as the hypnogram under it. Bars share one scale, 0–\(Self.ms(r.scaleMax)) ms.")
                .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("rMSSD is the dispersion of successive R-R differences, in milliseconds. Each value is the mean of the five-minute-window rMSSDs inside that stage's admitted spans; a window never crosses a span boundary, so two blocks of the same stage hours apart are never differenced against one another.")
                .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A span only contributes when at least \(Self.pct(HRVByStage.minEpochCoverage)) of its whole \(HRVByStage.epochSec)-second epochs hold an in-range R-R, and a stage needs \(HRVByStage.minStageSec / 60) minutes of admitted clock before it gets a number at all. The stager stretches a label across epochs it could not read, so without that bar a stage could report a confident value over hours the strap was not watching.")
                .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Where a spectrum is shown it is read by Lomb-Scargle over that stage's single longest admitted block — never pooled across blocks, whose seams would inject power that is not in the record — and only when that block clears a stricter \(Self.pct(HRVByStage.minBandCoverage)) coverage bar. LF/HF is the ratio of two band powers and nothing more.")
                .font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, WM.Space.s)
    }

    // MARK: Session selection

    /// Rebuild the browsable night list. A session with no `stagesJSON` has no hypnogram to bucket by and is
    /// not a candidate; naps ARE kept, since a staged nap is a real record and its window names it
    /// unambiguously.
    ///
    /// Reads `repo.sleeps` MERGED rather than the computed lane alone, which is what every other night
    /// surface in the app browses. It matters: the demo seed writes its staged sessions under the raw strap
    /// id while `ScoreEngine` writes real ones under the computed id, so a computed-only read would show an
    /// empty panel on a demo-seeded simulator — the only place this surface can be looked at without a strap.
    @MainActor
    private func refreshNights() async {
        guard previewReport == nil else { return }
        let all = repo.sleeps
        nights = await Task.detached(priority: .utility) {
            all.filter { $0.stagesJSON != nil }
                .sorted { $0.effectiveStartTs > $1.effectiveStartTs }
        }.value
    }

    /// Position of the browsed night in `nights`, defaulting to the newest when the key is unset or its
    /// session has left the window.
    private var currentIndex: Int? {
        guard !nights.isEmpty else { return nil }
        if let selectedStart, let i = nights.firstIndex(where: { $0.startTs == selectedStart }) { return i }
        return 0
    }

    private var selectedSession: CachedSleepSession? { currentIndex.map { nights[$0] } }

    private var canStepBack: Bool { (currentIndex ?? 0) + 1 < nights.count }
    private var canStepForward: Bool { (currentIndex ?? 0) > 0 }

    private func step(_ delta: Int) {
        guard let i = currentIndex, nights.indices.contains(i + delta) else { return }
        selectedStart = nights[i + delta].startTs
    }

    // MARK: Load

    @MainActor
    private func load() async {
        if let previewReport { report = previewReport; return }
        guard let session = selectedSession else { report = nil; return }
        loadGen += 1
        let gen = loadGen
        loading = true
        guard let store = await repo.storeHandle() else { loading = false; return }

        let spans = HRVByStage.spans(fromStagesJSON: session.stagesJSON)

        // The read window is the UNION of the session's own window and the extent of its spans, rather than
        // the session window alone. `stagesJSON` is keyed on the DETECTED `startTs` while the displayed
        // window uses `effectiveStartTs` (the user's onset correction, #318), so the two can disagree by
        // hours in either direction; and a wider window costs correctness nothing — `analyze` ignores every
        // row that falls outside every span. Reading too NARROW is the only failure mode available here, and
        // it would look exactly like a stage the strap failed to watch.
        let lo = min(session.startTs, session.effectiveStartTs, spans.map(\.start).min() ?? Int.max)
        let hi = max(session.endTs, spans.map(\.end).max() ?? Int.min)
        guard hi > lo else {
            report = StageHRVReport(session: session, night: HRVByStage.analyze(spans: spans, rr: []),
                                    spanCount: spans.count, rrRows: 0, rrTruncated: false)
            loading = false
            return
        }

        let rr = (try? await store.rrIntervals(deviceId: repo.deviceId, from: lo, to: hi,
                                               limit: Self.rrRowBudget)) ?? []
        // A night is ~30–110 k R-R rows and `analyze` walks every span's windows over them, so it runs OFF
        // the main actor — the same shape the Detection panel builds its report with. It is pure and takes
        // no clock, so nothing about the result depends on where it runs.
        let night = await Task.detached(priority: .utility) {
            HRVByStage.analyze(spans: spans, rr: rr)
        }.value

        guard gen == loadGen else { return }   // a newer night superseded this read
        report = StageHRVReport(session: session, night: night, spanCount: spans.count,
                                rrRows: rr.count, rrTruncated: rr.count >= Self.rrRowBudget)
        loading = false
    }

    // MARK: Copy

    /// Bar thickness. Heavier than a hairline so four of them read as a set, light enough that the numeral
    /// above stays the loudest thing in the row.
    private static let barHeight: CGFloat = 10

    /// The stage's label above its bar.
    static func stageName(_ stage: HRVByStage.Stage) -> String {
        switch stage {
        case .deep:  return "Deep"
        case .rem:   return "REM"
        case .light: return "Light"
        case .wake:  return "Wake"
        }
    }

    /// The stage's name INSIDE a sentence ("…of the 217 min labelled deep"). Not `stageName().lowercased()`:
    /// REM is an initialism and reads as a typo in lower case, so the two forms are declared separately
    /// rather than derived one from the other.
    static func stagePhrase(_ stage: HRVByStage.Stage) -> String {
        stage == .rem ? "REM" : stageName(stage).lowercased()
    }

    /// The clock a measured value speaks for. Never omitted, and it names BOTH numbers whenever they differ
    /// — "over 41 min of the 3 h 37 min labelled deep" is the whole point of the line.
    static func admittedLine(_ r: HRVByStage.Reading) -> String {
        let stage = stagePhrase(r.stage)
        let admitted = WMFormat.duration(seconds: r.admittedSec, style: .spelled)
        guard r.admittedSec < r.claimedSec else {
            return "Over the full \(admitted) labelled \(stage)."
        }
        let claimed = WMFormat.duration(seconds: r.claimedSec, style: .spelled)
        return "Over \(admitted) of the \(claimed) labelled \(stage) — the rest was not watched closely enough to bucket."
    }

    /// Why a stage has no number. One sentence per verdict, each about the RECORD and never about the person,
    /// and each stating the specific quantity that fell short so the reader can check it against the line
    /// below. The `.measured` case is unreachable (`rmssd` is non-nil exactly then) but is spelled out rather
    /// than defaulted, so a new verdict case cannot silently inherit another's sentence.
    static func absenceLine(_ r: HRVByStage.Reading) -> String {
        let stage = stagePhrase(r.stage)
        let claimed = WMFormat.duration(seconds: r.claimedSec, style: .spelled)
        switch r.verdict {
        case .measured:
            return "Not recorded."
        case .notLabelled:
            return "This night's hypnogram never labels \(stage)."
        case .notObserved:
            if r.admittedSec == 0 {
                return "\(claimed) labelled \(stage), none of it watched closely enough to bucket — no span cleared the \(pct(HRVByStage.minEpochCoverage)) epoch-coverage bar."
            }
            let admitted = WMFormat.duration(seconds: r.admittedSec, style: .spelled)
            return "\(claimed) labelled \(stage), of which only \(admitted) cleared the coverage bar — under the \(HRVByStage.minStageSec / 60) minutes a stage number needs."
        case .tooLittleTime:
            return "The hypnogram labels only \(claimed) of \(stage), under the \(HRVByStage.minStageSec / 60) minutes a stage number needs."
        case .tooFewBeats:
            let admitted = WMFormat.duration(seconds: r.admittedSec, style: .spelled)
            return "\(admitted) of \(stage) cleared the coverage bar, but no five-minute window inside it held enough clean beats to difference."
        }
    }

    /// The record behind the row, in one tabular line: how much of the stage's clock was watched at all, and
    /// what survived cleaning. Shown for measured AND absent stages — on an absent one it is the evidence for
    /// the absence, which is the only way a reader can tell a thin record from a short one.
    ///
    /// nil for a stage the hypnogram never labelled. `coverage` is defined as 0 when a stage claims no whole
    /// epoch, and printing that as "0% of its epochs held an in-range R-R" would state a measurement over a
    /// denominator that does not exist — the absence line above already says the whole truth about that row.
    static func recordLine(_ r: HRVByStage.Reading) -> String? {
        guard r.claimedSec > 0 else { return nil }
        var parts = ["\(pct(r.coverage)) of its \(HRVByStage.epochSec)-second epochs held an in-range R-R"]
        if r.windows > 0 { parts.append("\(r.windows) window\(r.windows == 1 ? "" : "s")") }
        if r.cleanBeats > 0 { parts.append("\(r.cleanBeats.formatted()) clean beats") }
        return parts.joined(separator: " · ")
    }

    /// The frequency-domain line, or nil when the stage carries no spectrum. `bands` and `bandSpanSec` are an
    /// all-or-nothing pair in the engine, and this reads them as one: a spectrum without the length of the
    /// record it came from is not interpretable, so neither is shown without the other.
    ///
    /// Band powers are formatted through `HRVFreqReadout.power` (SignalLabHRVView.swift) rather than a second
    /// formatter, so a band cannot print one way on the HRV tab and another way here.
    static func bandLine(_ r: HRVByStage.Reading) -> String? {
        guard let b = r.bands, let span = r.bandSpanSec else { return nil }
        // The em-dashes here are the engine's OWN nils, not this view's: `HRVFreqDomain` returns nil LF (and
        // so nil LF/HF) on a block under `minSpanForLFSec`, which is a band it did not compute rather than a
        // band it computed as zero. Each unit is spelled beside its own value — a single trailing "ms²"
        // would read as if the dimensionless LF/HF ratio carried it too.
        let lf = b.lf.map { "\(HRVFreqReadout.power($0)) ms²" } ?? "—"
        let ratio = b.lfhf.map { String(format: "%.2f", $0) } ?? "—"
        let block = WMFormat.duration(seconds: span, style: .spelled)
        return "LF \(lf) · HF \(HRVFreqReadout.power(b.hf)) ms² · LF/HF \(ratio) · total \(HRVFreqReadout.power(b.totalPower)) ms², over the longest admitted block (\(block))."
    }

    /// Whole milliseconds. rMSSD is reported to the same integer precision the Poincaré readout prints, so
    /// the two tabs cannot appear to disagree about a value they round differently.
    static func ms(_ v: Double) -> String { String(Int(v.rounded())) }

    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}

// MARK: - Pure report model

/// One night's per-stage readings plus the record they were read over — everything the panel draws, built
/// pure so it can be constructed in a preview with no store and no radio.
struct StageHRVReport: Equatable {
    /// The night's name, by the date it ENDS on (a night beginning 23:41 on the 2nd is "the 3rd" to nobody,
    /// so the end date is the one that names it in this app — the same day-key rule `Repository.mergeSleep`
    /// buckets sessions by).
    let title: String
    /// Window, hypnogram segment count and how many R-R rows were read for it.
    let windowLine: String
    let night: HRVByStage.Night
    /// The stager's own uncertainty flag for this session.
    let lowConfidence: Bool
    /// True when the R-R read returned its full row budget and so may not reach the end of the window.
    let rrTruncated: Bool

    init(session: CachedSleepSession, night: HRVByStage.Night, spanCount: Int, rrRows: Int,
         rrTruncated: Bool) {
        self.title = Self.dayLabel(session.endTs)
        self.windowLine = "\(WMFormat.timeOfDay(session.effectiveStartTs)) → \(WMFormat.timeOfDay(session.endTs))"
            + " · \(spanCount) hypnogram segment\(spanCount == 1 ? "" : "s")"
            + " · \(rrRows.formatted()) R-R rows read"
        self.night = night
        self.lowConfidence = session.lowConfidence
        self.rrTruncated = rrTruncated
    }

    /// The preview / test seam: a report over an already-analysed night, with its strings supplied.
    init(title: String, windowLine: String, night: HRVByStage.Night,
         lowConfidence: Bool = false, rrTruncated: Bool = false) {
        self.title = title
        self.windowLine = windowLine
        self.night = night
        self.lowConfidence = lowConfidence
        self.rrTruncated = rrTruncated
    }

    /// The shared bar scale: the next whole 10 ms at or above the largest measured value, floored at 10 ms.
    ///
    /// Rounded UP to a step rather than set to the maximum itself, so the longest bar is not automatically
    /// full width — a bar that always fills its lane reads as a ceiling the value hit, which is a claim
    /// nothing here makes. The scale is printed beside the bars, because a bar length is only readable
    /// against a stated axis.
    var scaleMax: Double {
        let m = night.readings.compactMap(\.rmssd).max() ?? 0
        return Swift.max(10, (m / 10).rounded(.up) * 10)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEdMMM"); return f
    }()

    static func dayLabel(_ ts: Int) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

// MARK: - Synthetic nights (previews / no-store)

extension SignalLabStagesView {

    /// A deterministic synthetic night, analysed through the REAL engine rather than hand-built, so a preview
    /// cannot show a combination of value and verdict that `HRVByStage` would never produce. Shaped after the
    /// real 2026-08-02 record: a deep block the strap watched, a much longer deep block it did not (the V2
    /// stretch), well-covered REM and light, and a wake total too short to carry a number.
    ///
    /// Between the two variants all four absence verdicts and both measured shapes are on screen:
    /// `.measured` over its full claim (light, REM), `.measured` over a fraction of it (deep, 41 min admitted
    /// of 217 claimed — the qualified bar this whole surface exists for), `.tooLittleTime` (wake, 3 minutes
    /// labelled in total), `.notObserved` (deep, in the `phantomOnly` variant) and `.notLabelled` (wake, same
    /// variant). `.tooFewBeats` is not reachable from a synthetic lane laid at a clean 1 Hz — it needs a span
    /// that clears epoch coverage while its windows fail the clean-beat floor, which only a real noisy record
    /// produces.
    ///
    /// - Parameter phantomOnly: drop the 41-minute real deep block AND the wake fragments, leaving deep with
    ///   only the unwatched stretch and wake unlabelled — the two pure-absence rows.
    static func syntheticReport(phantomOnly: Bool = false) -> StageHRVReport {
        let start = 1_760_000_000                     // fixed origin, so previews are stable
        var spans: [HRVByStage.Span] = []
        var rr: [RRInterval] = []

        /// Lay beats at exactly 1 Hz across `[from, to)` with a sway of amplitude `jitter` ms, which is what
        /// makes one stage's rMSSD differ from another's.
        ///
        /// The constants are chosen against the frozen cleaner rather than picked for looks. Base 1000 ms
        /// ± ≤130 stays well inside `HRVAnalyzer`'s [300, 2000] range filter; the 0.833 rad/beat step puts a
        /// beat at most ~9 % from the median of its four neighbours, comfortably under Malik's 20 % ectopic
        /// threshold, so NOTHING is rejected and every 5-minute window clears both the 20-clean-beat floor
        /// and the 35 % rejected-fraction ceiling. Whole-second timestamps one apart mean no pair straddles a
        /// dropout either, so `rmssdExcludingSplices` keeps every difference. rMSSD lands at
        /// `jitter · √2 · sin(0.4167)` ≈ 0.57 · jitter.
        func beats(_ from: Int, _ to: Int, jitter: Double) {
            var t = from
            var i = 0
            while t < to {
                rr.append(RRInterval(ts: t, rrMs: Int((1000 + jitter * sin(Double(i) / 1.2)).rounded())))
                t += 1
                i += 1
            }
        }

        func span(_ from: Int, _ minutes: Int, _ stage: HRVByStage.Stage) -> (Int, Int) {
            let end = from + minutes * 60
            spans.append(HRVByStage.Span(start: from, end: end, stage: stage))
            return (from, end)
        }

        var t = start
        // Light onset — fully watched.
        let l1 = span(t, 42, .light); beats(l1.0, l1.1, jitter: 70); t = l1.1
        // The deep the strap actually read (41 min on the real night). In the `phantomOnly` variant the same
        // clock is labelled light instead, so the night keeps its length and only deep's evidence goes away.
        if phantomOnly {
            let l = span(t, 41, .light); beats(l.0, l.1, jitter: 70); t = l.1
        } else {
            let d1 = span(t, 41, .deep); beats(d1.0, d1.1, jitter: 130); t = d1.1
        }
        // REM — fully watched.
        let r1 = span(t, 38, .rem); beats(r1.0, r1.1, jitter: 95); t = r1.1
        // A wake fragment. Together with `w2` below this totals 3 minutes — under the 5-minute floor, so wake
        // is `.tooLittleTime`: the hypnogram never gave it enough clock, whatever its coverage.
        if !phantomOnly {
            let w1 = span(t, 1, .wake); beats(w1.0, w1.1, jitter: 40); t = w1.1
        }
        // More light.
        let l2 = span(t, 55, .light); beats(l2.0, l2.1, jitter: 70); t = l2.1
        // THE PHANTOM: 176 minutes labelled deep, with R-R only in the first and last three minutes — the
        // shape V2's tiling produces when it stretches a label across epochs no channel could read. 12 of its
        // 352 epochs hold a beat, so it is refused at the 60 % bar and contributes nothing.
        let p = span(t, 176, .deep)
        beats(p.0, p.0 + 180, jitter: 130)
        beats(p.1 - 180, p.1, jitter: 130)
        t = p.1
        // A second wake fragment, still under the floor in total.
        if !phantomOnly {
            let w2 = span(t, 2, .wake); beats(w2.0, w2.1, jitter: 40); t = w2.1
        }
        // Closing REM.
        let r2 = span(t, 22, .rem); beats(r2.0, r2.1, jitter: 95); t = r2.1

        let night = HRVByStage.analyze(spans: spans, rr: rr)
        let line = "\(WMFormat.timeOfDay(start)) → \(WMFormat.timeOfDay(t))"
            + " · \(spans.count) hypnogram segments · \(rr.count.formatted()) R-R rows read"
        return StageHRVReport(title: StageHRVReport.dayLabel(t), windowLine: line, night: night)
    }
}

// MARK: - Previews

#Preview("Signal Lab · Stages (phantom deep) — light") {
    StagesPreviewHost(report: SignalLabStagesView.syntheticReport()).preferredColorScheme(.light)
}

#Preview("Signal Lab · Stages (phantom deep) — dark") {
    StagesPreviewHost(report: SignalLabStagesView.syntheticReport()).preferredColorScheme(.dark)
}

// Deep with NOTHING but the unwatched stretch: the row must render with no bar, no numeral and no dash —
// only the reason. This is the pair that proves absence does not fall back to a zero.

#Preview("Signal Lab · Stages (deep unobserved) — light") {
    StagesPreviewHost(report: SignalLabStagesView.syntheticReport(phantomOnly: true))
        .preferredColorScheme(.light)
}

#Preview("Signal Lab · Stages (deep unobserved) — dark") {
    StagesPreviewHost(report: SignalLabStagesView.syntheticReport(phantomOnly: true))
        .preferredColorScheme(.dark)
}

private struct StagesPreviewHost: View {
    let report: StageHRVReport
    private let root = AppRoot()

    var body: some View {
        VStack {
            SignalLabStagesView(previewReport: report)
                .padding(WM.Space.gutter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
        .environmentObject(root.repo)
    }
}
