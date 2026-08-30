import XCTest
@testable import whoopmaxx

/// The STORAGE half of the read-side App Intent (032): `GlanceCarry.save()` / `load()`, the wire form
/// they move between the app and the widget extension, and the three publish-time rules that decide
/// whether a spoken answer is entitled to name the day a score came from.
///
/// **WHY THIS SUITE EXISTS.** `GlanceAnswerTests` pins the SENTENCES, and it does that by handing
/// `GlanceAnswer.sentence` a record it built in-line — so it never asks where a record comes from, how
/// long one lives, or what a reader finds when there is not one. That gap matters more than it looks,
/// because `GlanceCarry.source` is deliberately TOTAL and its answer for anything it cannot prove is
/// `.unknown`. Every distinct way the record can fail to arrive — never written, written after the
/// publish path's early return, written under a key something else also uses, written and then not
/// decodable — collapses into that one state, and `.unknown` is not a crash and not a wrong number. It
/// is the app hedging, out loud, about a value it actually knows: "Charge 62, as of 9:40. The day it
/// came from isn't recorded." Nothing else in the app changes appearance when this breaks. A suite is
/// the only thing that would notice.
///
/// **WHAT THIS SUITE CANNOT PROVE**, stated here rather than left for a reader to assume otherwise:
///
/// - *That the app and the extension see the same store.* `save()`/`load()` go through
///   `UserDefaults(suiteName: WidgetSnapshot.suiteName)`, and that initialiser hands back a working but
///   PRIVATE store when the App Group entitlement is missing — `WidgetSnapshot.assertGroupProvisioned`
///   documents exactly this, which is why it interrogates the shared CONTAINER instead of inferring
///   provisioning from a successful read. So a green round trip below is evidence about the storage key
///   and the codec, and no evidence whatsoever about provisioning. Cross-process visibility needs two
///   processes and two entitlements; it stays a manual on-device check.
/// - *That `WidgetSnapshot.publish` still calls `GlanceCarry(...).save()` at all.* `publish` is
///   `@MainActor` over a live `AppRoot` (repository, live state, bpm) and cannot be constructed from a
///   test — `WidgetSnapshotTests` records the same limit, for the same function, in its own header. The
///   tests below that reason about publish ORDER therefore MODEL the sequence `publish` performs rather
///   than invoking it. They prove that the order the shipped code uses is the only one that keeps
///   provenance attached to the snapshot it describes; they would not notice a future edit that deleted
///   the write outright.
final class GlanceCarryTests: XCTestCase {

    // MARK: - Fixtures

    /// A synthetic publish instant (2017-07-14), deliberately years away from any stamp a running
    /// install could produce. Every record this suite writes into the live App-Group suite carries it,
    /// so an assertion that fails holding a record stamped near the wall clock did not fail because the
    /// contract broke — see the hazard note on `setUpWithError`.
    private static let publishedAt = Date(timeIntervalSince1970: 1_500_000_000)

    /// The exact wording `GlanceAnswer.score` produces for `.unknown`. Duplicated as a literal on
    /// purpose: the sentence IS the contract at this surface, so reading it back off the implementation
    /// would let a rewording pass unnoticed. `GlanceAnswerTests` spells it out for the same reason.
    private static let hedge = "The day it came from isn't recorded"

    /// A fully-populated published glance — Charge 62 is the number every assertion below reads back.
    /// EVERY field carries a value on purpose: synthesised `Codable` omits a nil optional entirely, so a
    /// fixture holding nils would let `testTheSnapshotWireFormCarriesNoProvenanceField`'s key scan pass
    /// over an encoding that simply had nothing in it. Only `updated` varies, because the rules under
    /// test are all about which publish a record belongs to, never about what the numbers are.
    private func snapshot(updated: Date = GlanceCarryTests.publishedAt) -> WidgetSnapshot {
        WidgetSnapshot(recovery: 62, bpm: 57, batteryPct: 76, bonded: true, updated: updated,
                       effort: 41, rest: 88, hrv: 61, restingHr: 50,
                       chargeBaseline: 58, effortBaseline: 44, restBaseline: 82)
    }

    /// Attached to every assertion that reads back through the LIVE suite, so a flake diagnoses itself
    /// instead of sending the next reader hunting for a codec bug that isn't there.
    private let hostPublishHint =
        "the record read back was not the one written — if the stamp it carries is near the wall clock, "
        + "the test host's own scenePhase publish landed mid-test (see setUpWithError)"

    // MARK: - Suite hygiene

    /// `save()` and `load()` are hard-wired to `WidgetSnapshot.suiteName` — there is no injection point
    /// and adding one would mean a second opinion about where the record lives — so exercising them at
    /// all means writing into the same App-Group defaults a running install publishes to. Both records
    /// are captured here and put back in `tearDown`: the idiom `SkinTempFamilyTests` uses for the live
    /// paired-model key, on the same reasoning (this bundle is hosted, so the app's real defaults are
    /// the ones in reach).
    ///
    /// KNOWN HAZARD, recorded rather than papered over. The host's `.onChange(of: scenePhase) .active`
    /// block is deliberately left unguarded by the test-host guard in `whoopmaxxApp.swift` (the note on
    /// that guard says so, and names it as the first place to look). It fires `root.publishWidget()` and
    /// a `dataDidChange(.idleTick)` whose tail publishes again — either of which rewrites
    /// `wm.widget.carry` on its own schedule. Every record written below therefore carries
    /// `publishedAt`, which no real publish can produce, so an interfering write is identifiable on
    /// sight rather than looking like a broken round trip. The alternative — weakening the assertions to
    /// tolerate a foreign record — would leave nothing being asserted at all.
    private var suite: UserDefaults!
    private var savedCarry: Data?
    private var savedSnapshot: Data?

    override func setUpWithError() throws {
        suite = try XCTUnwrap(UserDefaults(suiteName: WidgetSnapshot.suiteName),
                              "the App-Group suite name resolved to a suite UserDefaults refuses to "
                              + "open — nil/empty/bundle-id/global are the only such names")
        savedCarry = suite.data(forKey: GlanceCarry.storageKey)
        savedSnapshot = suite.data(forKey: WidgetSnapshot.storageKey)
        // Start every test from the never-published state, which is also the state the two "absence"
        // tests below assert against directly.
        suite.removeObject(forKey: GlanceCarry.storageKey)
    }

    override func tearDown() {
        // Best-effort, and guarded: if `setUpWithError` threw, there is nothing to put back and this
        // must not turn a clear failure into a crash.
        guard let suite else { return }
        restore(savedCarry, into: suite, forKey: GlanceCarry.storageKey)
        restore(savedSnapshot, into: suite, forKey: WidgetSnapshot.storageKey)
    }

    private func restore(_ data: Data?, into suite: UserDefaults, forKey key: String) {
        if let data { suite.set(data, forKey: key) } else { suite.removeObject(forKey: key) }
    }

    // MARK: - Wire form

    /// The record a NOTHING-CARRIED publish writes is not an empty one, and that is the hinge the whole
    /// provenance contract turns on. Synthesised `Codable` omits a nil optional rather than writing
    /// null, so `{"updatedUnix":…}` IS the on-disk shape of "both fields nil" — a record whose entire
    /// content is the claim "this publish's scores are the answered day's own". If that shape ever
    /// stopped being written, or stopped decoding, every own-day score in the app would start answering
    /// as unconfirmed while the publish path looked perfectly healthy from every other angle.
    func testANothingCarriedRecordStillHasAWireForm() throws {
        let record = GlanceCarry(updated: Self.publishedAt,
                                 chargeCarriedFrom: nil, restCarriedFrom: nil)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        let stamp = try XCTUnwrap(json["updatedUnix"] as? Int)
        XCTAssertEqual(stamp, GlanceCarry.stamp(Self.publishedAt))
        XCTAssertNil(json["chargeCarriedFrom"], "a nil field is omitted, not written as null")
        XCTAssertNil(json["restCarriedFrom"])
        XCTAssertFalse(json.isEmpty, "a nothing-carried publish encoded to nothing at all")
    }

    /// The reader's side of that shape, written as a LITERAL payload rather than an encode/decode round
    /// trip: these are the bytes an already-installed build left in the App Group, and a round trip
    /// would only ever prove the encoder agrees with itself. What matters is that the minimal payload
    /// resolves `.own` for BOTH scores — stated plainly, with no hedge.
    func testTheMinimalPayloadDecodesToAnOwnDayRecord() throws {
        let decoded = try JSONDecoder().decode(GlanceCarry.self,
                                               from: Data(#"{"updatedUnix":1500000000}"#.utf8))
        XCTAssertNil(decoded.chargeCarriedFrom)
        XCTAssertNil(decoded.restCarriedFrom)
        let snap = snapshot()
        XCTAssertEqual(GlanceCarry.source(for: snap, carry: decoded, \.chargeCarriedFrom), .own)
        XCTAssertEqual(GlanceCarry.source(for: snap, carry: decoded, \.restCarriedFrom), .own)
    }

    /// `updatedUnix` is the one non-optional field, and it has to stay that way. A payload without it is
    /// a record that cannot be tied to any publish, so decoding must FAIL and `load()` must hand back
    /// nil — which reads as `.unknown`, the honest state. The dangerous alternative is a decode that
    /// SUCCEEDS with some default stamp: a zero would at least match no snapshot, but any scheme that
    /// let the stamp be inferred would resolve `.own` for a record that proves nothing about the day.
    func testAPayloadWithoutAStampIsRefused() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(GlanceCarry.self,
                                     from: Data(#"{"chargeCarriedFrom":"Tue"}"#.utf8)),
            "a record with no publish stamp decoded anyway — it would then be compared against some "
            + "default and could resolve as the answered day's own")
    }

    // MARK: - save() / load()

    /// The never-published state, which is also the state of every install that upgraded into a build
    /// carrying the intent and has not published since. `load()` returns nil and the resolver says
    /// `.unknown`; it must never invent a record to stand in for one that was never written.
    func testLoadIsNilWhenTheSuiteHoldsNoRecord() {
        XCTAssertNil(GlanceCarry.load())
        XCTAssertEqual(GlanceCarry.source(for: snapshot(), carry: GlanceCarry.load(),
                                          \.chargeCarriedFrom), .unknown)
    }

    /// The round trip through the real storage key, over all four field shapes a publish can produce.
    /// Both fields are exercised independently because they are read through independent key paths, and
    /// a save that dropped one of them would be invisible in a fixture that only ever set the other.
    func testSaveThenLoadReturnsTheRecordThatWasWritten() throws {
        let shapes = [
            GlanceCarry(updated: Self.publishedAt, chargeCarriedFrom: nil, restCarriedFrom: nil),
            GlanceCarry(updated: Self.publishedAt, chargeCarriedFrom: "Tue", restCarriedFrom: nil),
            GlanceCarry(updated: Self.publishedAt, chargeCarriedFrom: nil, restCarriedFrom: "Mon"),
            GlanceCarry(updated: Self.publishedAt, chargeCarriedFrom: "Tue", restCarriedFrom: "Mon")
        ]
        for written in shapes {
            written.save()
            let read = try XCTUnwrap(GlanceCarry.load(), "save() wrote nothing readable")
            XCTAssertEqual(read, written, hostPublishHint)
        }
    }

    /// ONE record per suite, replaced in place. The publish path writes on every publish point, so the
    /// only thing keeping provenance true is that each write supersedes the last. A store that appended,
    /// or a `load()` that returned the oldest match, would leave a Monday label attached to Thursday's
    /// snapshot — which is a carried-score claim about a day the value did not come from, i.e. worse
    /// than saying nothing.
    func testASecondSaveSupersedesTheFirst() throws {
        GlanceCarry(updated: Self.publishedAt, chargeCarriedFrom: "Tue", restCarriedFrom: "Tue").save()
        let latest = GlanceCarry(updated: Self.publishedAt.addingTimeInterval(900),
                                 chargeCarriedFrom: nil, restCarriedFrom: nil)
        latest.save()
        XCTAssertEqual(try XCTUnwrap(GlanceCarry.load()), latest, hostPublishHint)
    }

    /// A blob under the key that is not a `GlanceCarry` — a torn write, or a future build's shape read
    /// by an older binary out of a shared container both are free to write. `load()` swallows the decode
    /// error by design; what is pinned here is where that lands. `.unknown` is the only acceptable
    /// destination: a zero-stamped stand-in would be compared against a real snapshot (and could, on a
    /// clock this app does not control, match), and a throw would surface as a crash inside an intent
    /// the user invoked by voice from a locked phone.
    func testUndecodableDataLoadsAsNothingRatherThanAsSomething() {
        for junk in [Data("not json".utf8),
                     Data(#"{"updatedUnix":"1500000000"}"#.utf8),   // right key, wrong type
                     Data()] {
            suite.set(junk, forKey: GlanceCarry.storageKey)
            XCTAssertNil(GlanceCarry.load(), "decoded a record out of \(junk.count) junk bytes")
            XCTAssertEqual(GlanceCarry.source(for: snapshot(), carry: GlanceCarry.load(),
                                              \.chargeCarriedFrom), .unknown)
        }
    }

    /// The two App-Group records share a suite ON PURPOSE — `GlanceCarry`'s doc says so, "provisioning
    /// is one problem and not two" — which makes their storage keys the only thing keeping them apart.
    /// A collision would not fail loudly: every publish writes both, so the second write would silently
    /// destroy the first and the symptom would be either a widget with nothing to draw or an answer that
    /// hedges forever. Pinned in both directions, because the publish path writes the snapshot first and
    /// the provenance record second.
    func testTheTwoRecordsShareASuiteWithoutSharingAKey() throws {
        XCTAssertNotEqual(GlanceCarry.storageKey, WidgetSnapshot.storageKey)

        let snap = snapshot()
        let carry = GlanceCarry(updated: snap.updated, chargeCarriedFrom: "Tue", restCarriedFrom: nil)
        snap.save()
        carry.save()
        XCTAssertEqual(try XCTUnwrap(WidgetSnapshot.load()), snap,
                       "the provenance write clobbered the snapshot it describes")
        XCTAssertEqual(try XCTUnwrap(GlanceCarry.load()), carry, hostPublishHint)

        snap.save()
        XCTAssertEqual(try XCTUnwrap(GlanceCarry.load()), carry,
                       "a snapshot write clobbered the provenance record beside it")
    }

    // MARK: - Rule: a nothing-carried record is not the absence of a record

    /// THE RULE THE PUBLISH PATH IS BUILT AROUND, and the one most likely to be optimised away by
    /// someone reading the code six months from now. `WidgetSnapshot.publish` writes a `GlanceCarry`
    /// even when both fields are nil, and its comment says why: "a missing record means 'provenance
    /// unknown' to the reader, so skipping the write on a nothing-carried publish would make an honest
    /// own-day score answer as unconfirmed."
    ///
    /// The skip is tempting exactly because the record looks like it holds nothing. This is what it
    /// costs, measured at the surface the user hears: the same snapshot, the same 62, said two different
    /// ways. Note what does NOT change — the number is spoken either way, because withholding a real
    /// measurement would be its own dishonesty. What the missing record costs is the app's ability to
    /// say the value is today's.
    func testANothingCarriedRecordIsNotTheSameAsNoRecord() {
        let snap = snapshot()
        GlanceCarry(updated: snap.updated, chargeCarriedFrom: nil, restCarriedFrom: nil).save()
        let stated = GlanceAnswer.sentence(reading: .charge, snapshot: snap,
                                           carry: GlanceCarry.load(), now: Self.publishedAt)

        // Exactly the write the "it's all nils, why bother" optimisation would drop.
        suite.removeObject(forKey: GlanceCarry.storageKey)
        let hedged = GlanceAnswer.sentence(reading: .charge, snapshot: snap,
                                           carry: GlanceCarry.load(), now: Self.publishedAt)

        XCTAssertFalse(stated.contains(Self.hedge),
                       "an own-day score with its record present still answered as unconfirmed: \(stated)")
        XCTAssertTrue(hedged.contains(Self.hedge),
                      "the record was gone and the answer claimed the day anyway: \(hedged)")
        XCTAssertTrue(stated.contains("62") && hedged.contains("62"),
                      "the measurement itself must survive both states")
        XCTAssertNotEqual(stated, hedged)
    }

    // MARK: - Rule: written BEFORE the reload gate

    /// The ordering rule, and the reason it is not a detail. `publish` runs:
    ///
    ///     let previous = WidgetSnapshot.load()
    ///     snap.save()                     // the snapshot ALWAYS lands, stamp and all
    ///     GlanceCarry(...).save()         // ← here
    ///     if let previous, previous.sameValues(as: snap) { return }
    ///     WidgetCenter.shared.reloadAllTimelines()
    ///
    /// Move the provenance write below that early return and it stops happening on the COMMON case, not
    /// a rare one: the 15-minute analyze tick republishes the same numbers under a fresher stamp all day
    /// long, which is precisely when `sameValues` is true. The snapshot's stamp advances, the record's
    /// does not, the two no longer describe the same publish — and `source` resolves `.unknown` for a
    /// score that is perfectly well known. The app would spend most of its life hedging, and would look
    /// correct for the few minutes after each publish that actually changed a number.
    ///
    /// Modelled, not invoked: `publish` needs a live `AppRoot` (see this file's header). What is proven
    /// is that the shipped order is the only one that keeps the two records describing one publish.
    func testProvenanceWrittenAfterTheReloadGateWouldStrandItselfOnEveryQuietPublish() throws {
        let firstPublish = snapshot()
        // Fifteen minutes later: identical values, fresher stamp — the analyze tick's steady state.
        let quietPublish = snapshot(updated: Self.publishedAt.addingTimeInterval(900))
        XCTAssertTrue(firstPublish.sameValues(as: quietPublish),
                      "fixture no longer models a publish that returns early at the reload gate")

        // Publish N wrote both records, honestly: the day's own score, nothing carried.
        GlanceCarry(updated: firstPublish.updated,
                    chargeCarriedFrom: nil, restCarriedFrom: nil).save()

        // Publish N+1 saved its snapshot and returned at the gate. THIS is the state a reader would
        // find if the provenance write sat below that return — last publish's record, this publish's
        // snapshot.
        let stranded = try XCTUnwrap(GlanceCarry.load(), hostPublishHint)
        XCTAssertEqual(GlanceCarry.source(for: quietPublish, carry: stranded, \.chargeCarriedFrom),
                       .unknown,
                       "a record from an earlier publish was accepted as this one's")
        XCTAssertTrue(GlanceAnswer.sentence(reading: .charge, snapshot: quietPublish,
                                            carry: stranded, now: quietPublish.updated)
                        .contains(Self.hedge))

        // What ships: the write happens first, so the record moves with every snapshot.
        GlanceCarry(updated: quietPublish.updated,
                    chargeCarriedFrom: nil, restCarriedFrom: nil).save()
        let current = try XCTUnwrap(GlanceCarry.load(), hostPublishHint)
        XCTAssertEqual(GlanceCarry.source(for: quietPublish, carry: current, \.chargeCarriedFrom),
                       .own)
        XCTAssertFalse(GlanceAnswer.sentence(reading: .charge, snapshot: quietPublish,
                                             carry: current, now: quietPublish.updated)
                        .contains(Self.hedge))
    }

    // MARK: - Rule: provenance stays OUT of sameValues

    /// The reason `GlanceCarry` is a sibling record and not two more fields on `WidgetSnapshot`.
    ///
    /// `sameValues` is the gate that decides whether a publish spends one of WidgetKit's rationed
    /// background-refresh reloads, and it works because every field on the snapshot is DRAWN — if one
    /// moves, pixels move, and the reload is earned. Carry provenance is drawn by no glance surface at
    /// all. Monday's Charge 62 is the day's own row; on Tuesday, before a new score lands, the same 62
    /// carries from Monday. The provenance genuinely changed. The widget renders the identical picture.
    /// Folding provenance into the snapshot would make that roll fail `sameValues` and burn a reload for
    /// nothing — every day, at the rollover, on every install.
    ///
    /// Both halves are asserted together on purpose: that the change is REAL (the two records differ)
    /// and that it is INVISIBLE to the gate. Either one alone would be satisfiable by an empty fixture.
    func testACarrySourceRollingOverCannotBurnAReload() {
        let monday = snapshot()
        let tuesday = snapshot(updated: Self.publishedAt.addingTimeInterval(86_400))
        let mondaysProvenance = GlanceCarry(updated: monday.updated,
                                            chargeCarriedFrom: nil, restCarriedFrom: nil)
        let tuesdaysProvenance = GlanceCarry(updated: tuesday.updated,
                                             chargeCarriedFrom: "Mon", restCarriedFrom: nil)

        XCTAssertNotEqual(mondaysProvenance.chargeCarriedFrom, tuesdaysProvenance.chargeCarriedFrom,
                          "fixture no longer models a carry source rolling over")
        XCTAssertNotEqual(mondaysProvenance, tuesdaysProvenance)
        XCTAssertTrue(monday.sameValues(as: tuesday),
                      "the drawn glance changed between two publishes that render the same number")

        // And the provenance is still readable on each side — kept out of the gate, not thrown away.
        XCTAssertEqual(GlanceCarry.source(for: monday, carry: mondaysProvenance, \.chargeCarriedFrom),
                       .own)
        XCTAssertEqual(GlanceCarry.source(for: tuesday, carry: tuesdaysProvenance, \.chargeCarriedFrom),
                       .carried("Mon"))
    }

    /// The structural half of the same rule, aimed at the edit that would undo it. Provenance on the
    /// snapshot is not a behaviour a test can catch after the fact — `sameValues` compares whatever the
    /// struct holds, so the day a carry field is added there the gate quietly changes meaning and every
    /// existing assertion still passes. This one fails instead, and says why.
    func testTheSnapshotWireFormCarriesNoProvenanceField() throws {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot())) as? [String: Any])
        XCTAssertNotNil(json["recovery"],
                        "fixture stopped populating the drawn fields — a key scan over an empty "
                        + "encoding proves nothing")
        for key in json.keys {
            XCTAssertFalse(key.lowercased().contains("carr"),
                           "`\(key)` puts carry provenance on WidgetSnapshot. Every publish whose carry "
                           + "source rolled would then fail `sameValues` and spend a WidgetKit reload on "
                           + "a picture that did not change. Provenance belongs in GlanceCarry.")
        }
    }

    // MARK: - The stamp

    /// `stamp` is the ONE definition of the comparison — used by the initialiser that writes the record
    /// and by the resolver that reads it, so per its doc "the two sides agree by construction". Pinned
    /// across the awkward inputs (a fractional second, an exact second, a pre-epoch date where
    /// truncation toward zero and toward negative infinity disagree, a far-future one) because a drift
    /// between the two sides has no symptom other than every carried answer in the app quietly
    /// degrading to "day unknown".
    func testTheStampIsOneDefinitionUsedByBothSides() {
        for date in [Self.publishedAt,
                     Self.publishedAt.addingTimeInterval(0.734),
                     Date(timeIntervalSince1970: 0),
                     Date(timeIntervalSince1970: -1.5),
                     Date(timeIntervalSince1970: 4_102_444_800)] {
            let record = GlanceCarry(updated: date, chargeCarriedFrom: "Tue", restCarriedFrom: nil)
            XCTAssertEqual(record.updatedUnix, GlanceCarry.stamp(date),
                           "the write and the compare disagreed at \(date)")
            XCTAssertEqual(GlanceCarry.source(for: snapshot(updated: date), carry: record,
                                              \.chargeCarriedFrom), .carried("Tue"),
                           "a record failed to match the snapshot it was written beside, at \(date)")
        }
    }

    /// …and it truncates rather than rounds. Both sides call this function, so the direction is not what
    /// keeps them in step — but the doc states truncation, the record's `updatedUnix` is compared as an
    /// `Int` against a `Date` that has crossed a JSON boundary as a `Double`, and a half-second of
    /// rounding introduced on one side only is the specific shape the drift would take.
    func testTheStampTruncatesRatherThanRounds() {
        XCTAssertEqual(GlanceCarry.stamp(Date(timeIntervalSince1970: 1_500_000_000.9)),
                       1_500_000_000)
    }

    // MARK: - What the record actually holds

    /// The record stores a RENDERED label, never a `yyyy-MM-dd` key. `WidgetPublish` maps
    /// `f.chargeCarriedFrom` through `TodayModel.shortDayLabel` — the same function behind Today's
    /// "carried · Tue" caption — precisely so the screen and the spoken answer cannot name a day
    /// differently, and because the widget extension compiles no `Core/`, so `DayKey` is not reachable
    /// on the reading side to parse one back.
    ///
    /// The two halves are composed here rather than asserted apart: the label the publish path derives
    /// is the exact string the sentence speaks, unchanged. The negative matters as much — a regression
    /// that forwarded the raw key would compile, store, load and round-trip perfectly, and would be
    /// audible only as "carried from 2026-08-11".
    func testTheStoredLabelIsTheOneTodayDraws() {
        let sourceKey = "2026-08-11"
        let label = TodayModel.shortDayLabel(sourceKey)
        XCTAssertNotEqual(label, sourceKey, "shortDayLabel failed to parse the key and passed it through")

        let snap = snapshot()
        let line = GlanceAnswer.sentence(
            reading: .charge, snapshot: snap,
            carry: GlanceCarry(updated: snap.updated, chargeCarriedFrom: label, restCarriedFrom: nil),
            now: Self.publishedAt)
        XCTAssertTrue(line.contains("carried from \(label)"), line)
        XCTAssertFalse(line.contains(sourceKey),
                       "a raw day key reached the spoken answer: \(line)")
    }
}
