import XCTest
@testable import whoopmaxx

/// The verdicts are the only judgment the Diagnostics screen makes, and the screen exists precisely
/// because a broken install used to look identical to a working one. So the cases worth pinning are
/// the ones where a missing value could quietly render as a reassuring default.
final class InstallReportTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A fully healthy install: everything present, nothing stale.
    private func healthy() -> InstallReport {
        InstallReport(groupProvisioned: true,
                      resolvedGroup: AppGroup.declared,
                      snapshotUpdated: now.addingTimeInterval(-240),
                      outboxPending: 0,
                      outboxDropped: 0,
                      schemaVersion: 41,
                      lastBackupMs: Int(now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1000),
                      lastFailureMs: 0,
                      version: "1.8.0",
                      build: "35",
                      profileExpiry: now.addingTimeInterval(30 * 86_400),
                      deviceSummary: ["Device: iPhone14,2", "iOS: Version 26.3"])
    }

    private func row(_ report: InstallReport, _ label: String) -> InstallReport.Row? {
        report.sections(now: now).flatMap(\.rows).first { $0.label == label }
    }

    // MARK: - The failure this screen was built for

    func testUnprovisionedGroupReadsAsBad() throws {
        var report = healthy()
        report.groupProvisioned = false

        let link = try XCTUnwrap(row(report, "Widget link"))
        XCTAssertEqual(link.value, "unavailable")
        XCTAssertEqual(link.verdict, .bad)
    }

    func testHealthyGroupSaysOk() throws {
        let link = try XCTUnwrap(row(healthy(), "Widget link"))
        XCTAssertEqual(link.value, "ok")
        XCTAssertEqual(link.verdict, .ok)
    }

    /// A re-signer can grant an id other than the declared one. That is survivable — resolution handles
    /// it — but it should be visible, and it must NOT be shown on a normal install.
    func testRewrittenGroupIdIsShownOnlyWhenItDiffers() {
        XCTAssertNil(row(healthy(), "Group id"), "declared id needs no explanation")

        var report = healthy()
        report.resolvedGroup = "group.ABCDE12345.com.whoopmaxx.app"
        XCTAssertEqual(row(report, "Group id")?.verdict, .warn)
    }

    // MARK: - Missing values must not read as fine

    func testNeverPublishedIsItsOwnAnswer() throws {
        var report = healthy()
        report.snapshotUpdated = nil

        let published = try XCTUnwrap(row(report, "Last published"))
        XCTAssertEqual(published.value, "never")
        XCTAssertEqual(published.verdict, .warn)
    }

    func testStaleSnapshotWarnsButFreshOneDoesNot() {
        var report = healthy()
        report.snapshotUpdated = now.addingTimeInterval(-(InstallReport.staleSnapshot + 60))
        XCTAssertEqual(row(report, "Last published")?.verdict, .warn)

        report.snapshotUpdated = now.addingTimeInterval(-(InstallReport.staleSnapshot - 60))
        XCTAssertEqual(row(report, "Last published")?.verdict, .ok)
    }

    func testNeverBackedUpIsBadNotAbsent() throws {
        var report = healthy()
        report.lastBackupMs = 0

        let backup = try XCTUnwrap(row(report, "Last backup"))
        XCTAssertEqual(backup.value, "never")
        XCTAssertEqual(backup.verdict, .bad)
    }

    /// The case a relative timestamp alone would hide: a recent SUCCESS followed by a FAILURE still
    /// reads "yesterday" while the last attempt actually failed.
    func testFailureNewerThanSuccessOvertakesTheTimestamp() throws {
        var report = healthy()
        report.lastFailureMs = report.lastBackupMs + 1000

        let backup = try XCTUnwrap(row(report, "Last backup"))
        XCTAssertEqual(backup.value, "last attempt failed")
        XCTAssertEqual(backup.verdict, .bad)
    }

    func testOlderFailureDoesNotOvertakeANewerSuccess() {
        var report = healthy()
        report.lastFailureMs = report.lastBackupMs - 1000
        XCTAssertEqual(row(report, "Last backup")?.verdict, .ok)
    }

    // MARK: - Outbox

    /// Dropped entries are logs the user made and lost — never folded into the same verdict as merely
    /// waiting ones.
    func testDroppedOutbreaksOutbidsPending() throws {
        var report = healthy()
        report.outboxPending = 3
        report.outboxDropped = 2

        let outbox = try XCTUnwrap(row(report, "Outbox"))
        XCTAssertEqual(outbox.value, "3 waiting · 2 dropped")
        XCTAssertEqual(outbox.verdict, .bad)
    }

    func testPendingAloneWarns() throws {
        var report = healthy()
        report.outboxPending = 1

        let outbox = try XCTUnwrap(row(report, "Outbox"))
        XCTAssertEqual(outbox.value, "1 waiting")
        XCTAssertEqual(outbox.verdict, .warn)
    }

    func testEmptyOutboxIsOk() {
        XCTAssertEqual(row(healthy(), "Outbox")?.value, "0 waiting")
        XCTAssertEqual(row(healthy(), "Outbox")?.verdict, .ok)
    }

    // MARK: - Profile expiry

    func testExpiredProfileIsBad() throws {
        var report = healthy()
        report.profileExpiry = now.addingTimeInterval(-3600)

        let expiry = try XCTUnwrap(row(report, "Profile expires"))
        XCTAssertEqual(expiry.value, "expired")
        XCTAssertEqual(expiry.verdict, .bad)
    }

    func testExpiringSoonWarns() {
        var report = healthy()
        report.profileExpiry = now.addingTimeInterval(InstallReport.expiringSoon - 3600)
        XCTAssertEqual(row(report, "Profile expires")?.verdict, .warn)
    }

    /// No profile at all is the simulator / App Store case. Absence is not a fault, so there is no row
    /// rather than an alarming unknown.
    func testNoProfileMeansNoRow() {
        var report = healthy()
        report.profileExpiry = nil
        XCTAssertNil(row(report, "Profile expires"))
    }

    // MARK: - Share payload

    func testBugReportCarriesEveryRowAndSurvivesAnEmptyLog() {
        let text = healthy().bugReportText(now: now, logTail: [])

        for label in ["Widget link", "Outbox", "Database", "Last backup", "Version"] {
            XCTAssertTrue(text.contains(label), "report is missing the \(label) row")
        }
        XCTAssertTrue(text.contains("(empty)"), "an empty log is normal and must not break the report")
        XCTAssertTrue(text.contains("STRAP LOG (0 lines)"))
    }

    func testBugReportIncludesTheLogTail() {
        let text = healthy().bugReportText(now: now, logTail: ["12:00:01 connected", "12:00:02 hr 58"])
        XCTAssertTrue(text.contains("12:00:02 hr 58"))
        XCTAssertTrue(text.contains("STRAP LOG (2 lines)"))
    }

    // MARK: - broken-install honesty (the reassuring-default hole)

    func testOutboxIsUnreadableNotZeroOnAnUnprovisionedInstall() {
        var report = healthy()
        report.groupProvisioned = false
        // The captured counts are phantom (a private per-process store answers 0), so the row must
        // NOT say "0 waiting / ok" — that is the reassuring lie this screen exists to refuse.
        let outbox = row(report, "Outbox")
        XCTAssertEqual(outbox?.verdict, .bad)
        XCTAssertFalse(outbox?.value.contains("0 waiting") ?? true)
        XCTAssertTrue(outbox?.value.contains("App Group") ?? false)
    }

    func testHealthyInstallStillReportsRealOutbox() {
        var report = healthy()
        report.outboxPending = 2
        XCTAssertEqual(row(report, "Outbox")?.value, "2 waiting")
        XCTAssertEqual(row(report, "Outbox")?.verdict, .warn)
    }

    func testRemediationIsPresentOnlyWhenBroken() {
        XCTAssertNil(healthy().remediation)
        var broken = healthy()
        broken.groupProvisioned = false
        XCTAssertTrue(broken.remediation?.contains("build-ipa.sh") ?? false,
                      "the concrete repair must be surfaced where the About row points")
    }

    func testBugReportUsesTheCapturedDeviceSummaryNotASecondProbe() {
        let text = healthy().bugReportText(now: now, logTail: [])
        XCTAssertTrue(text.contains("Device: iPhone14,2"))
        XCTAssertTrue(text.contains("iOS: Version 26.3"))
    }
}
