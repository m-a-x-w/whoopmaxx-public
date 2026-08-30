import SwiftUI
import UniformTypeIdentifiers

/// The DATA section of More: one-way `.wmbak` backup import, the databases previous imports replaced,
/// the autobackup folder, and "Back up now".
///
/// It owns ALL of that state — the import runner, both `.fileImporter`s, the folder dialog and the
/// last-backup stamp — so MoreScreen carries none of it. That also confines the `AppRoot` observation
/// this section needs purely to call `backupNow()` (AppRoot republishes `bpm` at ~1 Hz, P7 / T2.19).
struct DataSection: View {
    @EnvironmentObject private var root: AppRoot

    // `wm.backup.lastMs` is written by WmFolderBackup after every snapshot; reading it via
    // @AppStorage keeps the caption live without a refresh seam.
    @StateObject private var importer = BackupImportRunner()
    @State private var showImportPicker = false
    @State private var showFolderPicker = false
    @State private var confirmingFolder = false
    @State private var folderLabel: String? = WmFolderBackup.folderLabel()
    @State private var backingUp = false
    @State private var backupFailed = false
    /// The databases previous imports replaced (`whoopmaxx-replaced-*`, Gate 5). Held in state and
    /// refreshed on appear and after a delete — NEVER read from `body`: this section re-renders off
    /// AppRoot's ~1 Hz `bpm` republish, and a directory listing per frame would be a filesystem hit for
    /// a number that changes only when the user imports or deletes.
    @State private var replacedStores: [ReplacedStores.Entry] = []
    @State private var showReplacedStores = false
    @AppStorage(WmFolderBackup.lastKey) private var lastBackupMs = 0
    /// Stamped by the LAUNCH CATCH-UP when its snapshot was refused — that path has no return value to
    /// show, so a repeatedly-failing autobackup would otherwise be invisible behind a stale "Last: …".
    @AppStorage(WmFolderBackup.lastFailKey) private var lastFailMs = 0

    var body: some View {
        RuleSection("Data") {
            VStack(spacing: 0) {
                importRow
                // Only rendered when there IS one. A row reading "Previous databases · 0" would be
                // chrome for a state with nothing behind it, and the count on it is only ever the
                // length of a list that was actually enumerated (013 decision 9).
                if !replacedStores.isEmpty {
                    WMRule()
                    previousDatabasesRow
                }
                WMRule()
                backupFolderRow
                WMRule()
                backupNowRow
            }
            .onAppear { refreshReplacedStores() }
            .sheet(isPresented: $showReplacedStores) {
                PreviousDatabasesSheet(entries: replacedStores, onDelete: deleteReplacedStore)
            }
        }
    }

    // MARK: - Import

    /// One-way `.wmbak` backup import: pick → BackupImportRunner → the confirm block → the destructive
    /// half. Picking a file NO LONGER restores it (013): `beginReview` stages and verifies it and
    /// stops, `ReplaceConfirmBlock` shows what is in it against what is on the device now, and only a
    /// tap on Replace reaches `BackupImport.restore(staged:)`. The needsRelaunch result shows the
    /// receipt plus the quit-to-apply instruction inline.
    private var importRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showImportPicker = true
            } label: {
                HStack {
                    Text("Import backup")
                        .font(WMType.body)
                        .foregroundStyle(importRowBusy ? WM.Ground.inkTertiary : WM.Ground.ink)
                    Spacer()
                    Text(importTrailing)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(importRowBusy)
            .padding(.vertical, WM.Space.m)
            .fileImporter(isPresented: $showImportPicker,
                          allowedContentTypes: BackupImportRunner.allowedTypes) { result in
                importer.beginReview(result)
            }
            .onChange(of: importer.phase) { _, phase in
                // A landed restore unlinked the database this process still holds open, so the app must
                // stop here. Leaving the More screen usable behind an inline "Imported." caption meant
                // every subsequent write went into the deleted inode and was discarded by the relaunch.
                // The receipt travels ALONG WITH the flag instead of rendering here. This same edge
                // replaces the whole window with `RelaunchWall`, tearing this screen and the runner
                // down — so a receipt drawn in this VStack could never be seen by anyone. The wall
                // shows it, because the wall is the only surface alive on the other side of this line.
                if phase == .needsRelaunch { root.markStoreSwapped(receipt: importer.replaced) }
            }

            if let review = importer.review {
                reviewBlock(review)
            }

            if let note = importNote {
                Text(note)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, WM.Space.m)
            }
        }
    }

    /// The row is inert while a file is being staged, while one is waiting on the confirm, and while
    /// the replacement runs — three states, one answer, so the label colour and the disabled flag can
    /// never disagree (and a second pick can never orphan the first pick's staging).
    private var importRowBusy: Bool {
        importer.phase == .importing || importer.review != nil
    }

    private var importTrailing: String {
        if case .inspecting = importer.review { return "Reading…" }
        switch importer.phase {
        case .importing: return "Importing…"
        case .imported:  return "Imported"
        default:         return ""
        }
    }

    /// The confirm-before-replace block, rendered IN PLACE inside `RuleSection("Data")` — no card and
    /// no sheet: the comparison and its two actions sit directly under the row
    /// that opened the picker.
    @ViewBuilder
    private func reviewBlock(_ review: BackupImportRunner.Review) -> some View {
        switch review {
        case .inspecting:
            Text("Reading the backup…")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .padding(.bottom, WM.Space.m)
        case .confirming(let staged):
            ReplaceConfirmBlock(copy: RestoreConfirmCopy(file: staged.summary,
                                                         deviceDays: deviceDayKeys),
                                onReplace: { importer.replace() },
                                onCancel: { importer.cancel() })
                .padding(.bottom, WM.Space.m)
        case .refused(let reason):
            RestoreRefusedBlock(reason: reason, onCancel: { importer.cancel() })
                .padding(.bottom, WM.Space.m)
        }
    }

    /// The device's own day keys, from the repository's published cache — the SAME answer every other
    /// screen reads, never a second query over the store (012 decision 1). nil until that cache has
    /// published, so the confirm says "not read yet" rather than printing a zero it never measured.
    ///
    /// That cache is `refresh(days: 120)`'s trailing window, NOT the whole store — `dailyMetric` is
    /// never pruned, so a long-standing user has more days than this carries. `RestoreConfirmCopy`
    /// treats it as a lower bound and says "at least" wherever it cannot prove otherwise, and the
    /// caption under the device reading names the bound. A wider read just for this block would be a
    /// second answer to a question the app already answers, in front of its one destructive action.
    ///
    /// Read THROUGH `root` rather than via a `@EnvironmentObject var repo: Repository`, so this
    /// section keeps the single environment dependency its type doc describes (and so MoreScreen's
    /// own preview, which injects only `root`, keeps working). A nested ObservableObject is not
    /// observed through its parent, so this does not itself trigger a re-render — but the value is
    /// read fresh on every pass, and this section already re-renders off AppRoot's ~1 Hz `bpm`
    /// republish, so the confirm cannot sit on a stale count.
    private var deviceDayKeys: [String]? {
        root.repo.loaded ? root.repo.days.map(\.day) : nil
    }

    private var importNote: String? {
        switch importer.phase {
        case .needsRelaunch: return "Imported. " + BackupImportRunner.relaunchInstruction
        case .failed(let message): return message
        case .idle, .importing, .imported: return nil
        }
    }

    // MARK: - Previous databases

    /// The rollback the design already provided and nothing surfaced (013 decision 4). Every import
    /// snapshots the database it replaced to a `whoopmaxx-replaced-*` file beside the live store, and
    /// no reader existed — so those copies accumulated invisibly, a whole store each, in a directory
    /// with no `UIFileSharingEnabled` behind it. This row is the admission that they are there.
    ///
    /// The caption is a measurement on both halves: how many were enumerated, and what they cost on
    /// disk including the `-wal`/`-shm` siblings Gate 5 copied alongside each one.
    private var previousDatabasesRow: some View {
        Button {
            showReplacedStores = true
        } label: {
            HStack {
                Text("Previous databases")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                Spacer()
                Text(previousDatabasesCaption)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                WMDisclosure()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, WM.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the databases your imports replaced, where you can delete them")
    }

    /// "2 · 1.1 GB". The count is the length of the enumerated list, so it is always measured; the size
    /// says it could not be read rather than summing the entries it managed to stat and passing that
    /// off as a total (`ReplacedStores.totalBytes` is nil-if-any-nil for exactly that reason).
    private var previousDatabasesCaption: String {
        let size = ReplacedStores.totalBytes(replacedStores).map(replacedSizeLabel)
        return "\(replacedStores.count) · \(size ?? "size not recorded")"
    }

    /// Re-read the list. Synchronous on purpose and cheap: a directory listing plus an attribute read
    /// for a handful of files (never a store open), through the same seam the sheet renders from — so
    /// the row's caption and the list behind it cannot disagree.
    private func refreshReplacedStores() {
        replacedStores = ReplacedStores.entries()
    }

    /// The one destructive control this wave adds, reached ONLY from the sheet's second tap. Never
    /// automatic, never on a timer, never "keep the newest N" (013 decision 4): the app must not be
    /// what removes the only copy of the data an import replaced.
    private func deleteReplacedStore(_ entry: ReplacedStores.Entry) {
        ReplacedStores.delete(entry)
        refreshReplacedStores()
    }

    // MARK: - Backup

    /// The autobackup destination. Choosing a folder IS the opt-in (WmFolderBackup stores a
    /// security-scoped bookmark and the on-launch catch-up takes over); tapping with a folder set
    /// offers change / stop.
    private var backupFolderRow: some View {
        Button {
            if folderLabel == nil {
                showFolderPicker = true
            } else {
                confirmingFolder = true
            }
        } label: {
            HStack {
                Text("Backup folder")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                Spacer()
                Text(folderLabel ?? "Choose…")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, WM.Space.m)
        .fileImporter(isPresented: $showFolderPicker,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                WmFolderBackup.saveFolder(url)
                folderLabel = WmFolderBackup.folderLabel()
            }
        }
        .confirmationDialog("Backup folder", isPresented: $confirmingFolder,
                            titleVisibility: .visible) {
            Button("Choose a different folder") { showFolderPicker = true }
            Button("Stop automatic backups", role: .destructive) {
                WmFolderBackup.clearFolder()
                folderLabel = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Daily snapshots are written into this folder and the newest \(WmFolderBackup.keepCount) are kept. Existing snapshots are never deleted when you stop.")
        }
    }

    /// Write one `.wmbak` snapshot now (needs a chosen folder). The caption is the last-backup
    /// stamp WmFolderBackup writes to `wm.backup.lastMs`.
    private var backupNowRow: some View {
        Button {
            runBackupNow()
        } label: {
            HStack {
                Text("Back up now")
                    .font(WMType.body)
                    .foregroundStyle(folderLabel != nil && !backingUp
                                     ? WM.Ground.ink : WM.Ground.inkTertiary)
                Spacer()
                Text(backupCaption)
                    .font(WMType.caption)
                    .foregroundStyle(backupFailed || lastFailMs > lastBackupMs
                                     ? WM.Semantic.bad : WM.Ground.inkTertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(folderLabel == nil || backingUp)
        .padding(.vertical, WM.Space.m)
    }

    private var backupCaption: String {
        if backingUp { return "Backing up…" }
        if backupFailed { return "Backup failed — check the folder" }
        if lastFailMs > lastBackupMs { return "Last automatic backup failed — tap to retry" }
        guard lastBackupMs > 0 else { return "Never backed up" }
        let date = Date(timeIntervalSince1970: Double(lastBackupMs) / 1000)
        return "Last: " + Self.lastBackupFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func runBackupNow() {
        guard !backingUp else { return }
        backingUp = true
        backupFailed = false
        // The WAL-checkpoint + snapshot write live on `AppRoot.backupNow()` — the SAME entry point the
        // launch catch-up job uses, so this row and the automatic backup can't drift apart.
        Task {
            backupFailed = !(await root.backupNow())
            backingUp = false
        }
    }

    private static let lastBackupFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - The confirm

/// The comparison the user confirms against: what is in the picked file, what is on the device now,
/// and what replacing one with the other costs. Restore is the only irreversible action in the app,
/// and this block is the last place it can still be stopped — so it is not an "are you sure", it is
/// two readings side by side (013 decision 1).
///
/// Values in, closures out: it renders exactly the strings `RestoreConfirmCopy` is unit-tested on,
/// and it previews in both themes without an `AppRoot`.
private struct ReplaceConfirmBlock: View {
    let copy: RestoreConfirmCopy
    let onReplace: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Replace all data?")
                .font(WMType.label)
                .foregroundStyle(WM.Ground.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, WM.Space.s)

            reading("This file", copy.fileLine)
            reading("On this device now", copy.deviceLine)
                .padding(.top, WM.Space.s)
            // The device figures come from the repository's recent-history window, not the whole
            // store, so the reading above is a floor. Saying so here is what lets it sit beside a
            // whole-file total without the pair reading as a like-for-like comparison it isn't.
            Text("Device figures cover the app's recent-history cache. Anything older is replaced too.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            // Always true, and stated whether or not the numbers behind the next line could be read.
            Text("Everything on this device is replaced.")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, WM.Space.m)
            // The measured consequence. Absent when the file covers everything the device holds — a
            // line that always shows is as wrong as one that never does.
            if let lossLine = copy.lossLine {
                Text(lossLine)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WM.Space.xs)
            }

            WMPrimaryButton("Replace", action: onReplace)
                .accessibilityHint("Replaces every day on this device with the contents of this file. This can't be undone.")
                .padding(.top, WM.Space.l)
            RestoreCancelButton(action: onCancel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One reading: an overline naming the side, the measured line beneath it. Type hierarchy does the
    /// work — no card, no rule, no colour (colour is data only).
    private func reading(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).wmOverline()
            Text(value)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A file Gates 1–4c would not open — damaged, foreign, or written by a newer build than this one.
/// There is no staged database behind this state, so there is nothing to replace anything WITH, and
/// no Replace affordance is rendered at all: only the reason and a way out.
private struct RestoreRefusedBlock: View {
    let reason: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Can't restore this backup")
                .font(WMType.label)
                .foregroundStyle(WM.Ground.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, WM.Space.s)
            // The importer's own refusal copy, verbatim — every gate already names what is wrong and,
            // where it matters, says the current data was left untouched.
            Text(reason)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            RestoreCancelButton(action: onCancel)
                .padding(.top, WM.Space.s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The way out of both blocks. Plain ink-secondary text at the HIG tap height — the shape FirstRun's
/// "Start fresh" uses, so the escape from a destructive prompt never reads as an action.
private struct RestoreCancelButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Cancel")
                .font(WMType.label)
                .foregroundStyle(WM.Ground.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previous databases

/// The databases previous imports replaced: each one's date, what it costs on disk, and a two-step
/// delete. Newest first, with the newest named as what it is — the rollback for the most recent import.
///
/// Values in, closures out (the `ReplaceConfirmBlock` idiom), so it previews in both themes with no
/// filesystem behind it and every number it prints is one `ReplacedStores` measured.
private struct PreviousDatabasesSheet: View {
    let entries: [ReplacedStores.Entry]
    let onDelete: (ReplacedStores.Entry) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The row whose Delete has been TAPPED but not yet confirmed — step one of the two. nil means no
    /// dialog is up, which is also how the dialog reports its own Cancel.
    @State private var pendingDelete: ReplacedStores.Entry?

    var body: some View {
        ZStack {
            WM.Ground.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    WMCoverHeader(title: "Previous databases",
                                  closeLabel: "Close previous databases") { dismiss() }
                    // What these files ARE, said plainly and before any of them can be deleted.
                    Text("Each import keeps a copy of the database it replaced. Nothing here is ever removed automatically — on this device these are the only copies of what those imports replaced.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, WM.Space.m)

                    if entries.isEmpty {
                        Text("No previous databases. Importing a backup keeps a copy of the database it replaces here.")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, WM.Space.section)
                    } else {
                        list
                        locationFooter
                    }
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
            }
        }
        // Step two. The dialog is the ONLY route from the row's Delete to `onDelete`, and it names what
        // the file is before it goes (013 decision 6 — the single destructive control in this wave, and
        // it is two taps).
        .confirmationDialog("Delete this database?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { entry in
            Button("Delete", role: .destructive) { onDelete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(Self.deleteMessage(entry, isRollback: entry == rollback))
        }
    }

    // MARK: - Rows

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                row(entry, isRollback: entry == rollback)
                if entry.id != entries.last?.id { WMRule() }
            }
        }
        .padding(.top, WM.Space.section)
    }

    /// One preserved database. Type hierarchy carries it — no card, no rule per row beyond the hairline
    /// separators, and no colour on the Delete (colour is data only; the destructive weight
    /// belongs in the dialog's copy, not in a red label the eye learns to skip).
    private func row(_ entry: ReplacedStores.Entry, isRollback: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WM.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(entry))
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.caption(entry, isRollback: isRollback))
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: WM.Space.s)
            // Deliberately NOT inside an `.accessibilityElement(children: .combine)` row: combining
            // would swallow the only control on the screen.
            Button {
                pendingDelete = entry
            } label: {
                Text("Delete")
                    .font(WMType.label)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .frame(minHeight: 44)          // HIG tap height
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete the database from \(Self.title(entry))")
            .accessibilityHint("Asks to confirm first. This can't be undone.")
        }
        .padding(.vertical, WM.Space.s)
    }

    /// Where they live, verbatim. 013 defers a one-tap rollback on purpose — it is a second write path
    /// into the live database and needs its own gates — so naming the location IS the recovery route:
    /// it is the only thing that turns "a copy exists" into something a user can act on.
    @ViewBuilder
    private var locationFooter: some View {
        if let directory = entries.first?.url.deletingLastPathComponent().path {
            Text("whoopmaxx doesn't restore from these — replacing the live database runs the same checks an import does. They sit beside the live database, at \(directory).")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, WM.Space.section)
        }
    }

    /// The newest, and only when the whole list could be ordered — see `ReplacedStores.rollback`.
    private var rollback: ReplacedStores.Entry? { ReplacedStores.rollback(of: entries) }

    // MARK: - Copy

    /// The date the snapshot's name records, or — when the name carries no readable timestamp — the raw
    /// name itself. Never a substitute date invented from the file's mtime.
    private static func title(_ entry: ReplacedStores.Entry) -> String {
        entry.created.map(stampFormatter.string(from:)) ?? entry.name
    }

    /// Size, plus whatever else is true of this row: that its date could not be read, and that it is the
    /// copy standing behind the most recent import.
    private static func caption(_ entry: ReplacedStores.Entry, isRollback: Bool) -> String {
        var parts = [entry.sizeBytes.map(replacedSizeLabel) ?? "size not recorded"]
        if entry.created == nil { parts.append("date not recorded") }
        if isRollback { parts.append("rollback for the most recent import") }
        return parts.joined(separator: " · ")
    }

    /// Step two's message: what this file is, what it is FOR, and that there is nothing behind it.
    private static func deleteMessage(_ entry: ReplacedStores.Entry, isRollback: Bool) -> String {
        var text = entry.created
            .map { "This is the database whoopmaxx replaced on " + stampFormatter.string(from: $0) + "." }
            ?? "This is a database a previous import replaced."
        if isRollback {
            text += " It is the rollback for the most recent import."
        }
        return text + " Deleting it is permanent, and it is the only copy on this device."
    }

    /// Absolute date + time in the device's zone. Built once (the `BuzzHistoryScreen.dayFormatter`
    /// precedent) and localized, so the reading matches the user's clock rather than the POSIX shape the
    /// file name is written in.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMdjm")
        return f
    }()
}

/// Locale-aware file size — `.file` is the count style the OS itself uses, so these numbers match what
/// the user sees beside the same bytes anywhere else. (`RestoreConfirmCopy` keeps its own private twin
/// for the confirm's file line; it is a pure value type with no view behind it.)
private func replacedSizeLabel(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

// MARK: - Previews

// The confirm block cannot be reached in the simulator: it needs a real `.wmbak` for the picker to
// open, and the sim has none. These two previews ARE its visual verification (013 §Verification);
// the numbers behind them are pinned separately by `Tests/BackupConfirmTests.swift`.

#Preview("Restore confirm — light") {
    RestoreConfirmSpecimen().preferredColorScheme(.light)
}

#Preview("Restore confirm — dark") {
    RestoreConfirmSpecimen().preferredColorScheme(.dark)
}

private struct RestoreConfirmSpecimen: View {
    /// A `.wmbak` that predates the device's newest days — the case the consequence line exists for.
    private let file = BackupImport.Inspection.Summary(
        sizeBytes: 536_870_912, dayCount: 199,
        earliestDay: "2026-01-04", latestDay: "2026-07-21", sleepSessionCount: 191,
        formatVersion: 2, schemaVersion: 26, appVersion: "1.3.0 (18)",
        createdAtUTC: "2026-08-05T09:30:00Z")

    /// The repository's cached window as it really is: 120 days, 2026-04-10 → 2026-08-07, of which 17
    /// are past the file's last day. The file's own 199 days reach back before the window — which is
    /// exactly why the two readings carry the caption that says so.
    private var deviceDays: [String] {
        let cal = Calendar(identifier: .gregorian)
        guard let from = cal.date(from: DateComponents(year: 2026, month: 4, day: 10)) else { return [] }
        return (0...119).compactMap { cal.date(byAdding: .day, value: $0, to: from) }.map(DayKey.local)
    }

    var body: some View {
        ScrollView {
            RuleSection("Data", topGap: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ReplaceConfirmBlock(copy: RestoreConfirmCopy(file: file, deviceDays: deviceDays),
                                        onReplace: {}, onCancel: {})
                    WMRule().padding(.vertical, WM.Space.l)
                    RestoreRefusedBlock(
                        reason: "This backup was written by a newer version of whoopmaxx. It carries store schema 27; this app reads schema 26, so it doesn't have the migrations the file needs. Update whoopmaxx, then import it again. Your current data was left untouched.",
                        onCancel: {})
                }
            }
            .padding(WM.Space.gutter)
        }
        .background(WM.Ground.ground)
    }
}

// The previous-databases list, in both themes. The sim CAN reach the ROW — `--seed-demo --tab more`
// shows it — but only an install that has actually imported something has anything behind it, so the
// list itself is specimened here. The readings it renders, including the degraded ones (a name whose
// timestamp will not parse, a size that will not read, and the rollback claim withheld from a set that
// cannot be ordered), are pinned by `Tests/ReplacedStoresTests.swift`.

#Preview("Previous databases — light") {
    PreviousDatabasesSpecimen().preferredColorScheme(.light)
}

#Preview("Previous databases — dark") {
    PreviousDatabasesSpecimen().preferredColorScheme(.dark)
}

private struct PreviousDatabasesSpecimen: View {
    /// Two snapshots as an install that has imported twice really holds them: full stores, newest
    /// first, the newest carrying the rollback line. The URLs are never touched — the sheet reads their
    /// names and their directory, nothing else.
    private var entries: [ReplacedStores.Entry] {
        [entry(stamp: "2026-08-05-093000", bytes: 574_619_648),
         entry(stamp: "2026-06-18-201412", bytes: 498_073_600)]
    }

    private func entry(stamp: String, bytes: Int) -> ReplacedStores.Entry {
        let name = ReplacedStores.namePrefix + stamp + "." + ReplacedStores.nameExtension
        let url = URL(fileURLWithPath: "/Library/Application Support/OpenWhoop/" + name)
        return ReplacedStores.Entry(url: url,
                                    created: ReplacedStores.created(fromName: name),
                                    sizeBytes: bytes)
    }

    var body: some View {
        PreviousDatabasesSheet(entries: entries, onDelete: { _ in })
    }
}
