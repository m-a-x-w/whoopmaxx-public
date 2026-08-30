import Foundation
import StrapStore

/// What this install can actually do, as opposed to what it was built to do.
///
/// Exists because the two are not the same and the gap is silent. A sideload shipped with no App Group
/// entitlement and every widget tap was dropped for two waves: `UserDefaults(suiteName:)` returns a
/// working PRIVATE store when the entitlement is absent, so the writes succeeded, the reads came back
/// empty, and nothing raised an error on either side. Nothing in the app could have told you.
///
/// Split deliberately: `capture()` reads the world once, everything else is a pure function of the
/// captured values. The verdicts are the part worth testing and they must be testable without a
/// device, a strap, or a provisioned container.
public struct InstallReport: Equatable {

    /// How alarmed to be. Drives semantic color ONLY — chrome stays neutral ink (design language).
    public enum Verdict: Equatable { case ok, warn, bad }

    public struct Row: Equatable {
        public let label: String
        public let value: String
        public let verdict: Verdict
    }

    public struct Section: Equatable {
        public let title: String
        public let rows: [Row]
    }

    // MARK: - Captured facts

    // Install.
    public var groupProvisioned: Bool
    public var resolvedGroup: String
    public var snapshotUpdated: Date?
    public var outboxPending: Int
    public var outboxDropped: Int
    // Data.
    public var schemaVersion: Int
    public var lastBackupMs: Int
    public var lastFailureMs: Int
    // Build.
    public var version: String
    public var build: String
    public var profileExpiry: Date?
    /// The device/OS block for the bug report, captured with everything else so `bugReportText`
    /// never has to reach back to the device a second time (see finding: double IOSDiagnostics read).
    public var deviceSummary: [String]

    public init(groupProvisioned: Bool, resolvedGroup: String, snapshotUpdated: Date?,
                outboxPending: Int, outboxDropped: Int, schemaVersion: Int,
                lastBackupMs: Int, lastFailureMs: Int, version: String, build: String,
                profileExpiry: Date?, deviceSummary: [String] = []) {
        self.groupProvisioned = groupProvisioned
        self.resolvedGroup = resolvedGroup
        self.snapshotUpdated = snapshotUpdated
        self.outboxPending = outboxPending
        self.outboxDropped = outboxDropped
        self.schemaVersion = schemaVersion
        self.lastBackupMs = lastBackupMs
        self.lastFailureMs = lastFailureMs
        self.version = version
        self.build = build
        self.profileExpiry = profileExpiry
        self.deviceSummary = deviceSummary
    }

    // MARK: - Thresholds
    //
    // Named, because a bare `7 * 86_400` in a conditional is a number nobody can argue with later.

    /// A snapshot older than this means the app has not run recently enough to keep the widget honest.
    static let staleSnapshot: TimeInterval = 2 * 3600
    /// The autobackup catches up on launch, so a week without one means launches are not happening.
    static let staleBackup: TimeInterval = 7 * 86_400
    /// A sideload dies when the profile does, and re-signing is a manual errand — say so early.
    static let expiringSoon: TimeInterval = 7 * 86_400

    // MARK: - Capture

    /// Read every fact once. The only impure entry point.
    ///
    /// `@MainActor` because `IOSDiagnostics.capture()` reads main-actor UIKit state; the annotation
    /// makes that requirement a compile-time fact rather than a runtime trap for a future off-main
    /// caller. The IOSDiagnostics snapshot is taken ONCE here and its summary carried on the report,
    /// so a later `bugReportText` neither re-reads embedded.mobileprovision nor re-queries the device.
    @MainActor
    public static func capture() -> InstallReport {
        let info = Bundle.main.infoDictionary
        let ios = IOSDiagnostics.capture()
        let provisioned = WidgetSnapshot.isGroupProvisioned
        return InstallReport(
            groupProvisioned: provisioned,
            resolvedGroup: AppGroup.resolved,
            snapshotUpdated: WidgetSnapshot.load()?.updated,
            // Only meaningful when the App Group resolves; on a broken install these read a phantom
            // private store that answers 0, so they are captured but NOT trusted in `installRows`.
            outboxPending: provisioned ? IntakeOutbox.pending().count : 0,
            outboxDropped: provisioned ? IntakeOutbox.droppedCount() : 0,
            schemaVersion: StrapStoreInfo.schemaVersion,
            lastBackupMs: WmFolderBackup.lastBackupMs,
            lastFailureMs: WmFolderBackup.lastFailureMs,
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            profileExpiry: ios.sideloadExpiry,
            deviceSummary: ios.summaryLines())
    }

    // MARK: - Rows (pure)

    /// The screen's whole content, as data.
    ///
    /// Every row states a fact or says plainly that it has none. None of them fall back to a
    /// reassuring default when a value is missing — a broken install has to LOOK broken here, which is
    /// the entire reason the screen exists.
    public func sections(now: Date) -> [Section] {
        [Section(title: "Install", rows: installRows(now: now)),
         Section(title: "Data", rows: dataRows(now: now)),
         Section(title: "Build", rows: buildRows(now: now))]
    }

    private func installRows(now: Date) -> [Row] {
        var rows: [Row] = [
            Row(label: "Widget link",
                value: groupProvisioned ? "ok" : "unavailable",
                verdict: groupProvisioned ? .ok : .bad)
        ]

        // "Never" is a real answer and a different one from "a long time ago" — a fresh install that
        // has not published yet is fine; one that has never published after weeks of use is not.
        if let updated = snapshotUpdated {
            let age = now.timeIntervalSince(updated)
            rows.append(Row(label: "Last published",
                            value: Self.relative(updated, now: now),
                            verdict: age > Self.staleSnapshot ? .warn : .ok))
        } else {
            rows.append(Row(label: "Last published", value: "never", verdict: .warn))
        }

        // Anything waiting is worth a look; anything DROPPED is data the user logged and lost, which is
        // the worst outcome this app has, so it never gets folded into the same phrase.
        //
        // Gated on provisioning. Without the App Group the outbox lives in an unreachable private
        // store that answers 0 to everything — the exact reassuring lie this screen exists to refuse.
        // Reporting "0 waiting / ok" on a broken install would make the row that promises never to
        // invent a comforting default do precisely that.
        if groupProvisioned {
            var outbox = "\(outboxPending) waiting"
            if outboxDropped > 0 { outbox += " · \(outboxDropped) dropped" }
            rows.append(Row(label: "Outbox",
                            value: outbox,
                            verdict: outboxDropped > 0 ? .bad : (outboxPending > 0 ? .warn : .ok)))
        } else {
            rows.append(Row(label: "Outbox", value: "unreadable — App Group missing", verdict: .bad))
        }

        // Only shown when it is NOT the id the build asked for. On a healthy install this row is noise;
        // on a re-signed one it is the whole explanation.
        if resolvedGroup != AppGroup.declared {
            rows.append(Row(label: "Group id", value: resolvedGroup, verdict: .warn))
        }
        return rows
    }

    private func dataRows(now: Date) -> [Row] {
        var rows = [Row(label: "Database", value: "schema \(schemaVersion)", verdict: .ok)]

        // A failure NEWER than the last success is the case that matters: "3 days ago" would be true
        // and would still be hiding the fact that the last attempt did not work.
        if lastFailureMs > lastBackupMs {
            rows.append(Row(label: "Last backup", value: "last attempt failed", verdict: .bad))
        } else if lastBackupMs > 0 {
            let date = Date(timeIntervalSince1970: Double(lastBackupMs) / 1000)
            rows.append(Row(label: "Last backup",
                            value: Self.relative(date, now: now),
                            verdict: now.timeIntervalSince(date) > Self.staleBackup ? .warn : .ok))
        } else {
            rows.append(Row(label: "Last backup", value: "never", verdict: .bad))
        }
        return rows
    }

    private func buildRows(now: Date) -> [Row] {
        var rows = [Row(label: "Version", value: "\(version) (\(build))", verdict: .ok)]

        // No profile is the normal case for a simulator or App Store build — absence is not a fault,
        // so the row is simply absent too rather than reporting a scary unknown.
        if let expiry = profileExpiry {
            let remaining = expiry.timeIntervalSince(now)
            rows.append(Row(label: "Profile expires",
                            value: remaining <= 0 ? "expired" : Self.relative(expiry, now: now),
                            verdict: remaining <= 0 ? .bad
                                : (remaining <= Self.expiringSoon ? .warn : .ok)))
        }
        return rows
    }

    /// The concrete repair for a broken install, or nil when nothing is wrong. Surfaced at the
    /// Diagnostics screen — the destination the About-screen fault row points to — because a
    /// diagnosis with no repair path strands the user who followed the pointer.
    public var remediation: String? {
        groupProvisioned ? nil
            : "This build was installed without its App Group, so widgets can't read your data and "
            + "anything you log from one can't reach the app. Reinstall a build packaged by "
            + "scripts/build-ipa.sh — a plain unsigned build drops the entitlement."
    }

    // MARK: - Share payload

    /// The body of a bug report: the rows above, the device/OS capture, and the strap log tail.
    ///
    /// The log needs no scrubbing here — `LiveState.redactPii` runs on every line as it is appended, so
    /// what is in `log` is already masked. This path deliberately adds none of its own: a second,
    /// different redaction would be a second thing to keep correct.
    public func bugReportText(now: Date, logTail: [String]) -> String {
        var out = ["whoopmaxx diagnostics", "generated \(Self.isoFormatter.string(from: now))", ""]
        for section in sections(now: now) {
            out.append(section.title.uppercased())
            for row in section.rows { out.append("  \(row.label): \(row.value)") }
            out.append("")
        }
        out.append("DEVICE")
        out.append(contentsOf: deviceSummary.map { "  \($0)" })
        out.append("")
        out.append("STRAP LOG (\(logTail.count) lines)")
        // An empty log is normal — a fresh launch that has not connected yet has nothing to say, and a
        // report is still worth sending without it.
        out.append(contentsOf: logTail.isEmpty ? ["  (empty)"] : logTail.map { "  \($0)" })
        return out.joined(separator: "\n")
    }

    // MARK: - Formatting

    /// Locale-aware relative phrasing, shared by every time-valued row so they cannot drift apart.
    static func relative(_ date: Date, now: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// Hoisted like `relativeFormatter`: `ISO8601DateFormatter()` construction is not free, and a
    /// per-call allocation compounds with any caller that regenerates the report.
    private static let isoFormatter = ISO8601DateFormatter()
}
