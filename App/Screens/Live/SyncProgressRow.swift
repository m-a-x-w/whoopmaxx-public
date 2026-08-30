import SwiftUI

/// The Live tab's offload-progress row, shown ONLY while the strap is handing over history: a list-row
/// read (037 row metrics) — "Behind" over an honest chunks-banked caption on the leading side, and
/// on the trailing side how far BEHIND the persisted store frontier is, as a numeral (a compact duration,
/// never a percent — the protocol can't know the strap's total pending). Pure over its inputs (`SyncGap`
/// does the clamping/formatting) so it previews and reads without a live link. Chrome/ink only — sync
/// progress is instrument state, not domain data.
struct SyncProgressRow: View {
    /// Newest persisted sample ts (unix seconds); nil = nothing ever persisted → "first sync".
    let frontierUnix: TimeInterval?
    /// Chunks acked this offload session (`live.syncChunksThisSession`).
    let chunksBanked: Int
    /// Injectable for previews; the live row reads the wall clock.
    var now: Date = Date()

    var body: some View {
        let reading = SyncGap.reading(frontierUnix: frontierUnix,
                                      now: now.timeIntervalSince1970)
        HStack(alignment: .firstTextBaseline, spacing: WM.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Behind")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                Text("syncing · \(chunksBanked) chunk\(chunksBanked == 1 ? "" : "s") banked")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            Spacer(minLength: WM.Space.s)
            headline(reading)
                .wmAnimation(value: reading)
        }
        .frame(minHeight: WM.Space.row + 8)
        .accessibilityElement(children: .combine)
    }

    /// The trailing read: a tabular-numeral duration when genuinely behind; a quiet word state for the
    /// two no-numeral edges (never a fabricated "0m").
    @ViewBuilder
    private func headline(_ reading: SyncGap.Reading) -> some View {
        switch reading {
        case .behind(let duration):
            Text(duration)
                .font(WMType.numeral(26))
                .foregroundStyle(WM.Ground.ink)
                .lineLimit(1)
        case .caughtUp:
            Text("caught up")
                .font(WMType.label)
                .foregroundStyle(WM.Ground.inkSecondary)
        case .firstSync:
            Text("first sync")
                .font(WMType.label)
                .foregroundStyle(WM.Ground.inkSecondary)
        }
    }
}

#Preview("SyncProgressRow — states") {
    let now = Date()
    return VStack(alignment: .leading, spacing: 0) {
        SyncProgressRow(frontierUnix: now.timeIntervalSince1970 - (2 * 86_400 + 4 * 3_600),
                        chunksBanked: 128, now: now)
        WMRule()
        SyncProgressRow(frontierUnix: now.timeIntervalSince1970 - (4 * 3_600 + 12 * 60),
                        chunksBanked: 12, now: now)
        WMRule()
        SyncProgressRow(frontierUnix: now.timeIntervalSince1970 - 60,
                        chunksBanked: 3, now: now)
        WMRule()
        SyncProgressRow(frontierUnix: nil, chunksBanked: 1, now: now)
    }
    .padding(WM.Space.gutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(WM.Ground.ground)
}
