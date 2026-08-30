import SwiftUI

/// The Live tab's offload-progress stat row, shown ONLY while the strap is handing over history:
/// a SignalCell-shaped read of how far BEHIND the persisted store frontier is (a compact duration,
/// never a percent — the protocol can't know the strap's total pending) plus an honest chunks-banked
/// caption. Pure over its inputs (`SyncGap` does the clamping/formatting) so it previews and reads
/// without a live link. Chrome/ink only — sync progress is instrument state, not domain data.
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
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text("Behind").wmOverline()
            headline(reading)
                .wmAnimation(value: reading)
            Text("syncing · \(chunksBanked) chunk\(chunksBanked == 1 ? "" : "s") banked")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    /// The big line: a tabular-numeral duration when genuinely behind; a quiet word state for the
    /// two no-numeral edges (never a fabricated "0m").
    @ViewBuilder
    private func headline(_ reading: SyncGap.Reading) -> some View {
        switch reading {
        case .behind(let duration):
            Text(duration)
                .font(WMType.numeral(28))
                .foregroundStyle(WM.Ground.ink)
                .lineLimit(1)
        case .caughtUp:
            Text("caught up")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
        case .firstSync:
            Text("first sync")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
        }
    }
}

#Preview("SyncProgressRow — states") {
    let now = Date()
    return VStack(alignment: .leading, spacing: WM.Space.section) {
        SyncProgressRow(frontierUnix: now.timeIntervalSince1970 - (2 * 86_400 + 4 * 3_600),
                        chunksBanked: 128, now: now)
        SyncProgressRow(frontierUnix: now.timeIntervalSince1970 - (4 * 3_600 + 12 * 60),
                        chunksBanked: 12, now: now)
        SyncProgressRow(frontierUnix: now.timeIntervalSince1970 - 60,
                        chunksBanked: 3, now: now)
        SyncProgressRow(frontierUnix: nil, chunksBanked: 1, now: now)
    }
    .padding(WM.Space.gutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(WM.Ground.ground)
}
