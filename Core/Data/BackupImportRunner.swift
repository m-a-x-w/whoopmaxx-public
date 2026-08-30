import Foundation
import Combine
import UniformTypeIdentifiers

/// Drives one backup import through `BackupImport` (the sibling importer packet's typed
/// result: imported / needsRelaunch / failure) and publishes a UI-shaped phase. The restore runs
/// detached — a whole-file copy + integrity check can take tens of seconds on a big library — with
/// the security-scoped access bracketed around it, as the importer's contract requires.
///
/// TWO ROUTES IN, deliberately (013):
///  • `handle(_:)` — pick, stage, replace, in one call. FIRST RUN's route, and unchanged: a first run
///    has an empty store, so there is nothing to compare a backup against and nothing to lose.
///  • `beginReview(_:)` → `replace()` / `cancel()` — the More screen's route, where the store is the
///    user's whole history. `BackupImport.inspect` (Gates 1–4c) runs first and STOPS, holding the
///    staged file while the confirm block shows what is in it against what is on the device now.
///    Nothing outside a temp directory is written until `replace()`, and `cancel()` deletes the
///    staging rather than leaving a ~675 MB extraction behind.
@MainActor
final class BackupImportRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case importing
        /// The importer's normal success: the backup landed; it takes effect on the next launch.
        case needsRelaunch
        /// Reserved by the importer for a future in-process swap; handled for completeness.
        case imported
        case failed(String)
    }

    /// The half AHEAD of `Phase`: staging and verifying the picked file, then holding it while the
    /// user decides. nil whenever no file is under review.
    ///
    /// A SEPARATE published value rather than two more `Phase` cases, on purpose. `Phase` describes
    /// the DESTRUCTIVE half's outcome, and it has a second consumer — `FirstRun.ImportStep` switches
    /// over it and imports straight through — so widening it would change the meaning of a screen
    /// this seam has no business changing. The two lifecycles are also genuinely different now: a
    /// review can be abandoned, a replacement cannot.
    enum Review: Equatable {
        /// Gates 1–4c are running. The live database has not been touched, and cannot be from here.
        case inspecting
        /// Staged and verified. NOTHING happens until `replace()`; `cancel()` deletes the staging.
        case confirming(BackupImport.Inspection.Staged)
        /// Gates 1–4c refused the file (damaged, foreign, or written by a newer build). There is no
        /// staged database behind this case — which is why a refusal structurally cannot offer a
        /// Replace: there is nothing to replace anything with.
        case refused(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// The file currently under review, if any — see `Review`.
    @Published private(set) var review: Review?

    /// What was in the file the user AGREED to replace their data with, kept from the confirm through
    /// to the receipt so a landed import can SHOW what landed instead of leaving the user to infer it
    /// from the app not crashing. nil until `replace()`, and cleared again if the replacement failed —
    /// a receipt for a restore that never landed would be a lie.
    @Published private(set) var replaced: BackupImport.Inspection.Summary?

    /// The picked file behind the current review. Held only so the security-scoped access can be
    /// bracketed around the SECOND half too: for a `.wmbak` / `.zip` the staged database is our own
    /// temp copy, but a legacy plain-SQLite is staged in place and Gate 6 reads the user's own file.
    private var picked: URL?

    /// Shared quit-to-apply copy — the import only takes effect once the store handles reopen.
    static let relaunchInstruction =
        "To load it, quit whoopmaxx — swipe it away in the app switcher — then open it again."

    /// What the file picker offers: `.wmbak` (whoopmaxx's own container), plus plain `.zip` for a
    /// renamed backup.
    static let allowedTypes: [UTType] = [
        UTType(filenameExtension: "wmbak") ?? .zip,
        .zip,
    ]

    func handle(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            phase = .failed("Couldn't open that file. \(error.localizedDescription)")
        case .success(let url):
            guard phase != .importing else { return }
            phase = .importing
            Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                let outcome = BackupImport.restore(from: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
                await MainActor.run {
                    switch outcome {
                    case .imported:            self.phase = .imported
                    case .needsRelaunch:       self.phase = .needsRelaunch
                    case .failure(let reason): self.phase = .failed(reason)
                    }
                }
            }
        }
    }

    // MARK: - Confirm before replace

    /// Stage and verify the picked file (Gates 1–4c) and STOP, so the user can be shown what is in it
    /// before anything of theirs is replaced. Detached, like the restore: extracting a big store and
    /// quick_checking it takes seconds.
    func beginReview(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            review = .refused("Couldn't open that file. \(error.localizedDescription)")
        case .success(let url):
            // One file under review at a time. The row that opens the picker is inert while a review
            // is open, so this is belt-and-braces — but a second inspection would orphan the first
            // one's staging, and the whole point of `discard()` is that nothing else cleans it up.
            guard phase != .importing, !isReviewing else { return }
            picked = url
            review = .inspecting
            Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                // No `toDatabaseAt:` — the default IS the app's own store, which is exactly the file a
                // restore from here would replace, so the space refusal is sized against the right one.
                let inspection = BackupImport.inspect(from: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
                await MainActor.run {
                    switch inspection {
                    case .refused(let reason): self.review = .refused(reason)
                    case .ready(let staged):   self.review = .confirming(staged)
                    }
                }
            }
        }
    }

    /// Run the DESTRUCTIVE half (Gates 5–9) over the staging the user has just been shown and agreed
    /// to. Reachable only from `.confirming`, which is the only state that carries a staged file.
    ///
    /// Gates 1–4c are deliberately NOT re-run: `beginReview` already staged and verified this exact
    /// file, and re-extracting a ~675 MB store to reach the same verdict is the cost the split exists
    /// to avoid. The staging is discarded on the way out — Gate 8 reads `settings.json` /
    /// `wm-settings.json` out of it during the call, so it can only go afterwards, which is exactly
    /// what `BackupImport.restore(from:toDatabaseAt:)` does with its own `defer`.
    func replace() {
        guard case .confirming(let staged) = review, phase != .importing else { return }
        let url = picked
        picked = nil
        review = nil
        replaced = staged.summary
        phase = .importing
        Task.detached(priority: .userInitiated) {
            defer { staged.discard() }
            let scoped = url?.startAccessingSecurityScopedResource() ?? false
            // The path resolution `BackupImport.restore(from:)` does for the one-shot route, repeated
            // here because the staged entry point takes the destination explicitly (it is injected so
            // the gates are testable against a throwaway DB) and has no path-resolving twin.
            let outcome: BackupImport.ImportResult
            do {
                let dbPath = try StorePaths.defaultDatabasePath()
                outcome = BackupImport.restore(staged: staged, toDatabaseAt: dbPath)
            } catch {
                outcome = .failure("Couldn't locate the whoopmaxx database. \(error.localizedDescription)")
            }
            if scoped, let url { url.stopAccessingSecurityScopedResource() }
            await MainActor.run {
                switch outcome {
                case .imported:      self.phase = .imported
                case .needsRelaunch: self.phase = .needsRelaunch
                case .failure(let reason):
                    self.phase = .failed(reason)
                    self.replaced = nil   // nothing landed; there is no receipt to show
                }
            }
        }
    }

    /// Abandon the review. THE cleanup path: without the `discard()` a cancelled confirm strands a
    /// whole extracted store (~675 MB at the documented steady state) in temp until the OS reclaims
    /// it. Safe from any state, and safe to call twice.
    func cancel() {
        if case .confirming(let staged) = review { staged.discard() }
        review = nil
        picked = nil
    }

    /// A file is staged or being staged — the picker must stay shut and `beginReview` must decline.
    private var isReviewing: Bool {
        switch review {
        case .inspecting, .confirming: return true
        case .refused, .none:          return false
        }
    }
}

/// The confirm block's numbers: what is in the picked file, what is on this device now, and what
/// replacing one with the other costs.
///
/// Pure and value-typed so the consequence line can be pinned in BOTH directions by a unit test — a
/// line that always shows is as wrong as one that never does, and the whole point of the confirm is
/// that it is a comparison rather than an "are you sure".
///
/// Every field is a MEASUREMENT or an admission that there wasn't one (013 decision 9). A nil in the
/// summary means the container never recorded it, or it could not be read; it renders as exactly
/// that and never becomes a 0.
struct RestoreConfirmCopy: Equatable {

    /// What is in the file: days · range · save date · size, joined with " · ".
    let fileLine: String
    /// The same shape for the device's own history.
    let deviceLine: String
    /// The consequence, or nil when there is none to state. Present only when the device holds days
    /// this file's range does not cover, AND both sides were actually read.
    let lossLine: String?
    /// How many CACHED device days fall outside the file's range — a floor, not a total, whenever the
    /// cache's old end truncates (see `lossLine`). 0 whenever `lossLine` is nil.
    let daysLost: Int

    /// - Parameters:
    ///   - file: what `BackupImport.inspect` read off the staged file.
    ///   - deviceDays: the day keys the repository publishes (012 decision 1 — the same answer every
    ///     other screen reads, never a second query), or nil when that cache has not loaded yet.
    ///     "Not loaded" is not "no days" and must never be printed as a zero.
    ///
    ///     That cache is `Repository.refresh(days: 120)`'s TRAILING WINDOW, not the whole store —
    ///     `dailyMetric` is never pruned, so a long-standing user holds far more days than it carries.
    ///     Everything below therefore treats it as a LOWER BOUND on the device's history and says
    ///     "at least" wherever it cannot prove otherwise. The alternative — a second, wider read of
    ///     the store just for this block — is the divergence 012 decision 1 exists to prevent, and it
    ///     would put a fresh query in front of the one destructive action in the app.
    init(file: BackupImport.Inspection.Summary, deviceDays: [String]?) {
        fileLine = Self.summaryLine(file)
        deviceLine = Self.deviceSummaryLine(deviceDays)

        // DISTINCT days on both sides, or the comparison means nothing: the file's `dayCount` is a
        // `COUNT(DISTINCT day)`. `Repository.days` is already one row per day (`mergeDaily` keys by
        // day), so this dedupe changes no shipped number — it makes the property belong to THIS type
        // instead of being an assumption about its caller.
        guard let device = deviceDays.map({ Array(Set($0)).sorted() }), !device.isEmpty else {
            lossLine = nil
            daysLost = 0
            return
        }

        // Zero days is a real reading of a real file (an empty or partial backup summarises honestly),
        // and it is the worst case there is: everything on the device goes and nothing replaces it.
        // Stated WITHOUT a count on purpose — "everything" is exact whatever the cache can see, where
        // any number here would be the window's floor dressed as a total.
        if file.dayCount == 0 {
            daysLost = device.count
            lossLine = "This backup holds no days. Everything on this device will be lost, and nothing replaces it."
            return
        }
        // Anything else needs the file's own range. Unreadable counts already say so on the file line;
        // inventing a comparison out of them is precisely what decision 9 forbids.
        guard let earliest = file.earliestDay, let latest = file.latestDay else {
            lossLine = nil
            daysLost = 0
            return
        }
        // Day keys are `yyyy-MM-dd`, so lexicographic order IS chronological order (DayKey's format is
        // chosen for exactly this) — no date parsing, and no timezone to get wrong.
        let after = device.filter { $0 > latest }.count
        let before = device.filter { $0 < earliest }.count
        daysLost = after + before
        // EXACT, or a floor. The cache truncates at its OLD end only (it runs to today), so a day the
        // count could have missed is necessarily older than `device.first`. Days NEWER than the file
        // are all inside the window exactly when the file's last day is — that is the ordinary case
        // (a recent backup restored over a live store) and it gets to state a plain number. Days
        // OLDER than the file's first can never be bounded from a window that starts after them, so
        // that arm always says "at least". A floor printed as a total is a number the app did not
        // measure — and it under-reports, which is the dangerous direction here.
        let exact = before == 0 && device.first.map { latest >= $0 } == true
        if daysLost == 0 {
            lossLine = nil                      // the file covers the whole span the cache holds
        } else if exact {
            lossLine = "The \(Self.days(daysLost)) since this backup will be lost."
        } else if before == 0 {
            lossLine = "At least \(Self.days(daysLost)) on this device \(daysLost == 1 ? "is" : "are") newer than this backup and will be lost."
        } else {
            lossLine = "At least \(Self.days(daysLost)) on this device \(daysLost == 1 ? "is" : "are") outside this backup's range and will be lost."
        }
    }

    /// One file's line, also used ALONE as the post-import receipt: the same numbers the user agreed
    /// to, shown back to them once the restore has landed.
    static func summaryLine(_ file: BackupImport.Inspection.Summary) -> String {
        var parts: [String] = [file.dayCount.map { days($0) } ?? "days not recorded"]
        // MIN/MAX are NULL on an empty `dailyMetric`, which is honest rather than missing: zero days,
        // and no range to name. The day count above has already said so.
        if let earliest = file.earliestDay, let latest = file.latestDay {
            parts.append(earliest == latest ? earliest : "\(earliest) to \(latest)")
        }
        parts.append(file.createdAtUTC.map { "saved " + calendarDay(of: $0) } ?? "save date not recorded")
        parts.append(file.sizeBytes.map { byteLabel($0) } ?? "size not recorded")
        return parts.joined(separator: " · ")
    }

    /// The device side, over the repository's recent-history window (see `init`). A nil day list is
    /// that cache before its first publish — "not read yet", which is a different answer from "no
    /// days" and is never rendered as a number.
    private static func deviceSummaryLine(_ deviceDays: [String]?) -> String {
        guard let deviceDays else { return "not read yet" }
        let device = Set(deviceDays)
        guard let earliest = device.min(), let latest = device.max() else { return days(0) }
        return days(device.count) + " · " + (earliest == latest ? earliest : "\(earliest) to \(latest)")
    }

    /// "1 day" / "231 days" — a measured count always travels with its noun.
    private static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    /// The calendar day out of a manifest's `createdAtUTC` ("2026-08-05T09:30:00Z" → "2026-08-05"), by
    /// TRUNCATION rather than by parsing and re-formatting. The manifest records a UTC instant;
    /// re-rendering it in the device's zone would print a date the file does not claim. A stamp we
    /// cannot split is shown verbatim rather than dropped — it is still what the file recorded.
    private static func calendarDay(of iso: String) -> String {
        guard let t = iso.firstIndex(of: "T") else { return iso }
        return String(iso[iso.startIndex..<t])
    }

    /// Locale-aware file size. `.file` is the count style the OS itself uses, so the number matches
    /// what the user sees beside the same backup in Files.
    private static func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
