import SwiftUI

/// diagnostics — whether this INSTALL is wired correctly, as opposed to whether the strap is healthy
/// (that is Strap health, and it stays about the strap).
///
/// The screen exists because a build shipped without its App Group and nothing in the app could say
/// so: the widget's writes and the app's reads went to different private stores and both succeeded.
/// Every row here states a fact or says plainly that it has none —
/// nothing falls back to a reassuring default, because a broken install has to look broken.
///
/// All content and every verdict comes from `InstallReport`, which is pure and tested. This file only
/// paints it: neutral ink chrome, semantic color on the STATUS value alone.
struct DiagnosticsScreen: View {
    @EnvironmentObject private var live: LiveState
    @Environment(\.dismiss) private var dismiss

    /// Captured once per presentation rather than observed. These are install facts — a provisioning
    /// entitlement does not change while you are reading about it — and a live-updating diagnostics
    /// screen would be a second moving part in the thing you reach for when parts are moving wrongly.
    ///
    /// Populated in `.task`, not a `@State` default: a default expression re-runs `InstallReport.capture()`
    /// — an impure device + provisioning read — on every re-initialization of this view (the cover's
    /// content closure is rebuilt whenever `MoreScreen` re-renders while presented), discarding all but
    /// the first. `.task` runs once per presented identity. `bugText` is snapshotted alongside so the
    /// ShareLink item is a stored string, not a value recomputed on every `live` publish while open.
    @State private var report: InstallReport?
    @State private var bugText = ""
    @State private var capturedAt = Date()

    var body: some View {
        ZStack {
            WM.Ground.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    WMCoverHeader(title: "Diagnostics", closeLabel: "Close diagnostics") { dismiss() }

                    if let report {
                        ForEach(Array(report.sections(now: capturedAt).enumerated()), id: \.element.title) {
                            index, section in
                            RuleSection(section.title, topGap: index == 0 ? WM.Space.sectionTight
                                                                          : WM.Space.section) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(section.rows.enumerated()), id: \.element.label) {
                                        rowIndex, row in
                                        if rowIndex > 0 { WMRule() }
                                        DiagnosticRow(row: row)
                                    }
                                }
                            }
                        }

                        // The concrete repair, shown only when something is actually broken. The About
                        // screen's fault row points here, so the fix has to LIVE here — a diagnosis with
                        // no repair path strands the user who followed the pointer.
                        if let fix = report.remediation {
                            Text(fix)
                                .font(WMType.caption)
                                .foregroundStyle(WM.Ground.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, WM.Space.section)
                        }

                        shareLink
                    }
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
            }
        }
        .task {
            capturedAt = Date()
            let r = InstallReport.capture()
            report = r
            bugText = r.bugReportText(now: capturedAt, logTail: live.log)
        }
    }

    /// The bug-report export. Until this wave the app had no share surface at all, so a user who hit
    /// something like the App Group failure had nothing to send and no way to describe it.
    private var shareLink: some View {
        ShareLink(item: bugText) {
            // Carries the system share glyph: without it this reads as one more label in a screen made
            // entirely of labels, and the one thing here you can DO looks like another thing you read.
            Label("Share diagnostics", systemImage: "square.and.arrow.up")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, WM.Space.m)
                .contentShape(Rectangle())
        }
        .padding(.top, WM.Space.section)
        .accessibilityHint("Shares this report and the recent strap log")
    }
}

/// One label/value line. Semantic color lands on the VALUE only — the label is chrome and stays ink,
/// per the locked design language (color = data, never decoration).
private struct DiagnosticRow: View {
    let row: InstallReport.Row

    var body: some View {
        HStack {
            Text(row.label)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Spacer()
            Text(row.value)
                .font(WMType.body)
                .foregroundStyle(tint)
        }
        .padding(.vertical, WM.Space.m)
        .accessibilityElement(children: .combine)
    }

    /// `.ok` deliberately gets no color: a screen where every healthy row glows green trains you to
    /// skim past the one that does not.
    private var tint: Color {
        switch row.verdict {
        case .ok:   WM.Ground.inkSecondary
        case .warn: WM.Semantic.warn
        case .bad:  WM.Semantic.bad
        }
    }
}
