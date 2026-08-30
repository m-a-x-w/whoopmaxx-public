import SwiftUI

/// Terminal screen shown for the rest of the process once a restore has swapped the database.
///
/// `BackupImport` Gate 6 unlinks the live DB and its WAL/SHM before dropping the backup in, and nothing
/// tears down the open `DatabasePool`s — that is precisely why the importer returns `.needsRelaunch`
/// (see the relaunch-model note on `BackupImport`). Until this existed, both import call sites left the
/// app fully usable behind a passive caption: First Run even offered a "Finish" button straight into the
/// shell. Anything the user then did — a journal tag, a weed session, a manual workout, a habit log, a
/// strap sync — was written into the deleted inode and discarded by the relaunch, while the dashboard
/// showed pre-restore state under the words "Your history is in."
///
/// So this deliberately has NO forward affordance. The only way out is the force-quit the copy asks for,
/// which is exactly the state transition the restore needs. Backgrounding without quitting leaves the
/// wall up on resume, which is correct.
struct RelaunchWall: View {
    /// What landed, when the caller had it to hand over. THE RECEIPT LIVES HERE rather than beside the
    /// import row in Settings, because the edge that would render it there is the same edge that
    /// replaces the window with this view — see `AppRoot.restoreReceipt`. nil (First Run's route) reads
    /// exactly as this screen always has.
    var receipt: BackupImport.Inspection.Summary?

    /// The receipt line this screen shows, or nil when there is nothing to show.
    ///
    /// A pure seam rather than an inline `if let`, so a test can pin that the summary reaches THIS
    /// surface. That is the property the first version got wrong: the receipt was rendered beside the
    /// import row, which this view replaces, and a green test asserted its text while no user could reach
    /// it. Testing the string is not the same as testing where it lands.
    static func receiptLine(_ receipt: BackupImport.Inspection.Summary?) -> String? {
        receipt.map { RestoreConfirmCopy.summaryLine($0) }
    }

    /// Laid out like First Run (the wordmark on the top line, the 34pt title well below it, then the
    /// copy) because it is the same kind of surface: a full window outside the tab shell.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WMWordmark()
                .padding(.top, WM.Space.l)

            Text("Your history is in.")
                .font(FirstRun.titleFont)
                .foregroundStyle(WM.Ground.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, WM.Space.sectionLoose + WM.Space.m)

            if let line = Self.receiptLine(receipt) {
                Text(line)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WM.Space.s)
            }

            Text(BackupImportRunner.relaunchInstruction)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, WM.Space.m)

            Text("whoopmaxx has to reopen to read the restored database. Nothing you do here would be saved until it does.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, WM.Space.l)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WM.Space.gutter)
        .background(WM.Ground.ground.ignoresSafeArea())
        // No dismiss gesture, no navigation, no button — see the type doc.
    }
}

#Preview("Relaunch wall — light") {
    RelaunchWall(receipt: nil).preferredColorScheme(.light)
}

#Preview("Relaunch wall — dark") {
    RelaunchWall(receipt: nil).preferredColorScheme(.dark)
}
