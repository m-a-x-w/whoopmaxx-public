import XCTest
@testable import whoopmaxx

/// The Data wall's score vocabulary, the search that must survive renaming it, and the honest-labeling
/// captions that qualify the numbers beside it.
///
/// The app's score names are pinned as Charge / Effort / Rest, and every other surface obeys:
/// `ScoreColumn` draws the CHARGE / EFFORT overlines off `WM.Domain`, the Today hero and
/// `ChargeDetailScreen` read the same `d.recovery`, and the Live workout screen already labels a
/// `StrainScorer` value "Effort". The Data wall was the one place still printing the WHOOP words, so the
/// identical number carried two different names depending on which tab the user was on.
final class MetricCatalogVocabularyTests: XCTestCase {

    private func def(_ key: String) -> MetricDef? { MetricCatalog.all.first { $0.key == key } }

    func testScoreMetricsUseTheAppsOwnVocabulary() throws {
        XCTAssertEqual(try XCTUnwrap(def("recovery")).label, "Charge")
        XCTAssertEqual(try XCTUnwrap(def("strain")).label, "Effort")
    }

    /// The keys are internal (`MetricDef.==` and one preview lookup) and never persisted, so they stay —
    /// renaming them would be churn with no user-visible effect. Pinned so a later cleanup does not
    /// "finish the job" and silently break the preview lookup.
    func testKeysAreUnchanged() {
        XCTAssertNotNil(def("recovery"))
        XCTAssertNotNil(def("strain"))
    }

    /// THE REGRESSION the rename would otherwise cause: `DataScreen` filters on the label, so a user
    /// searching the WHOOP vocabulary they arrived with would find nothing.
    func testOldVocabularyStillFindsTheRenamedMetrics() throws {
        let charge = try XCTUnwrap(def("recovery"))
        let effort = try XCTUnwrap(def("strain"))

        for query in ["recovery", "Recovery", "rcv"] {
            XCTAssertTrue(charge.searchAliases.contains { MetricCatalog.fuzzyMatch(query: query, in: $0) },
                          "\"\(query)\" must still reach Charge")
        }
        for query in ["strain", "Strain", "strn"] {
            XCTAssertTrue(effort.searchAliases.contains { MetricCatalog.fuzzyMatch(query: query, in: $0) },
                          "\"\(query)\" must still reach Effort")
        }
    }

    /// And the new names must match directly, without needing an alias.
    func testNewVocabularyMatchesTheLabel() throws {
        XCTAssertTrue(MetricCatalog.fuzzyMatch(query: "charge", in: try XCTUnwrap(def("recovery")).label))
        XCTAssertTrue(MetricCatalog.fuzzyMatch(query: "effort", in: try XCTUnwrap(def("strain")).label))
    }

    /// Aliases are opt-in: every other metric already carries its real name, so none should need one.
    func testOnlyTheRenamedMetricsCarryAliases() {
        let withAliases = Set(MetricCatalog.all.filter { !$0.searchAliases.isEmpty }.map(\.key))
        XCTAssertEqual(withAliases, ["recovery", "strain"])
    }

    // MARK: - SpO2: a capability label, never a promise

    /// The health-framing words banned from every new surface (011 decision 5, taken from
    /// `RhythmScreener`): descriptive, within-user, no condition name, no probability, no
    /// call-to-action.
    private static let bannedHealthWords = ["thermoregulation", "vasodilation", "impaired", "poor",
                                            "abnormal", "apnea", "insomnia", "hypoxemia",
                                            "arrhythmia", "consider", "you should", "talk to"]

    /// THE REGRESSION. The SpO2 note used to read "Estimate. Uncalibrated, from the strap's raw red/IR
    /// pulse-ox signal during sleep." — the shape of a metric that is about to populate. It never can:
    /// the raw stream is a sample-and-hold register (76 distinct (red, ir) pairs over 6.2 days,
    /// `d_red == d_ir` in 99.9996 % of consecutive pairs), and the real estimator ported over that week
    /// puts 0 of 1750 windows inside the 85–100 band. So the note states the capability instead, and
    /// must carry none of the vocabulary that implies a value is being derived here.
    func testSpo2NoteStatesTheCapabilityAndPromisesNoValue() throws {
        let spo2 = try XCTUnwrap(def("spo2"))
        let note = try XCTUnwrap(spo2.note).lowercased()

        for promise in ["estimate.", "estimated from", "uncalibrated", "pulse-ox", "during sleep"] {
            XCTAssertFalse(note.contains(promise),
                           "the SpO2 note must not imply a value is coming: \"\(promise)\"")
        }
        XCTAssertTrue(note.contains("no oxygen percentage can be read"),
                      "the note must say plainly that the number cannot be produced")
        XCTAssertTrue(note.contains("nothing is estimated here"),
                      "and that nothing was invented in its place")
    }

    /// Decision 5's banned list is not SpO2-specific — it applies to every honest-labeling caption, so a
    /// later note cannot reintroduce condition language through the side door. Scanning the whole
    /// catalog (rather than one string) is what makes that hold for the notes not yet written.
    func testNoCatalogNoteUsesBannedHealthVocabulary() {
        let notes = MetricCatalog.all.compactMap(\.note)
        XCTAssertTrue(notes.contains { $0.lowercased().contains("oxygen") },
                      "the SpO2 capability label must be among the strings this scan covers")

        for metric in MetricCatalog.all {
            let note = (metric.note ?? "").lowercased()
            for word in Self.bannedHealthWords {
                XCTAssertFalse(note.contains(word),
                               "\(metric.key)'s note must not contain \"\(word)\"")
            }
        }
    }

    /// And the capability label must NOT become a suppression. An `spo2Pct` on the raw "my-whoop" lane
    /// came from a WHOOP cloud export, is a genuinely measured value, and `Spo2Heal` is scoped strictly
    /// to the computed lane so it never clears one — the catalog has to keep reading, charting and
    /// printing it. The over-correction this pins against is nulling `read` alongside the copy.
    func testAnImportedSpo2ValueStillRenders() throws {
        let spo2 = try XCTUnwrap(def("spo2"))
        let imported = Fixtures.dailyMetric(day: "2026-07-20", spo2Pct: 96.4)
        let unread = Fixtures.dailyMetric(day: "2026-07-21")

        XCTAssertEqual(spo2.read(imported, MetricSeriesSet()), 96.4)
        XCTAssertNil(spo2.read(unread, MetricSeriesSet()),
                     "a night the strap could not read stays empty — no fabricated 85.0")

        let series = spo2.series(days: [unread, imported], series: MetricSeriesSet())
        XCTAssertEqual(series.count, 1, "the empty day is skipped, never charted as a zero")
        XCTAssertEqual(spo2.string(for: series[0].value), "96.4")
    }
}
