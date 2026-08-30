import XCTest
@testable import whoopmaxx

/// 030 Track C — the configurable score widget.
///
/// The Lock Screen accessory families used to hardwire Charge. They now render whichever `GlanceReading`
/// the user picked in Edit Widget, resolved by `GlanceAccessory`. That resolver is a pure function of
/// (reading, snapshot), which is the whole reason it exists as its own type: the SwiftUI views around it
/// cannot be asserted on in a unit bundle, but every decision worth pinning happens here.
///
/// TWO THINGS ARE PINNED, and they are the two things that would ship a lie.
///
/// 1. ABSENCE. The live bug this wave fixed was `Gauge(value: Double(snap.recovery ?? 0), in: 0...100)` —
///    an empty ring drawn at zero, indistinguishable from a measured Charge of 0. `nil` in, `nil` out,
///    everywhere, with no zero substituted anywhere along the way.
/// 2. THE MIGRATION. `StaticConfiguration` → `AppIntentConfiguration` under the same widget kind means
///    the system re-renders already-placed widgets with a DEFAULT-INITIALISED intent. If that default is
///    ever changed from `.charge`, every widget already on a user's Lock Screen silently starts showing a
///    different number — a regression no test elsewhere would catch.
final class GlanceWidgetConfigTests: XCTestCase {

    /// A snapshot with every reading present, so an absent result can only come from the resolver.
    private let full = WidgetSnapshot(recovery: 82, bpm: 58, batteryPct: 84, bonded: true,
                                      updated: Date(timeIntervalSince1970: 1_800_000_000),
                                      effort: 47, rest: 71)

    /// A snapshot with nothing measured — a fresh install, or a strap that has never synced.
    private let none = WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false,
                                      updated: Date(timeIntervalSince1970: 1_800_000_000),
                                      effort: nil, rest: nil)

    // MARK: - The migration

    /// An already-placed widget must keep drawing what it drew. WidgetKit hands existing placements a
    /// default-initialised `GlanceWidgetConfigIntent` after the configuration-type change, so the default
    /// IS the migration behaviour.
    ///
    /// Turns red: change `@Parameter(default:)` on `reading` to anything but `.charge`.
    func testADefaultInitialisedIntentStillMeansCharge() {
        XCTAssertEqual(GlanceWidgetConfigIntent().reading, .charge,
                       "an already-placed widget re-renders with the default intent — it must stay Charge")
    }

    /// …and the default reading resolved against a real snapshot is the Charge tile, not merely an enum
    /// case that happens to be named for it.
    func testTheDefaultReadingResolvesToTheChargeTile() {
        let a = GlanceAccessory.make(reading: GlanceWidgetConfigIntent().reading, snapshot: full)
        XCTAssertEqual(a.label, "Charge")
        XCTAssertEqual(a.value, "82")
        XCTAssertEqual(a.compact, "82")
        XCTAssertFalse(a.isAbsent)
    }

    // MARK: - Absence, for every reading

    /// THE BUG, pinned for all five readings at once. Nothing may substitute a zero for a missing
    /// measurement — not the figure, not the compact figure, and above all not the gauge fraction, which
    /// is what actually drew the false ring.
    ///
    /// Turns red: reintroduce any `?? 0` in `GlanceAccessory.make`.
    func testEveryAbsentReadingResolvesToAbsenceAndNeverToZero() {
        for reading in GlanceReading.allCases {
            let a = GlanceAccessory.make(reading: reading, snapshot: none)
            XCTAssertTrue(a.isAbsent, "\(reading) must read as absent on an empty snapshot")
            XCTAssertNil(a.value, "\(reading) must not invent a figure: \(String(describing: a.value))")
            XCTAssertNil(a.compact, "\(reading) must not invent a compact figure")
            XCTAssertNil(a.gauge, "\(reading) must draw NO fill when absent — this is the live bug")
            // The name always survives, because that is what an absent tile renders instead of a number.
            XCTAssertFalse(a.label.isEmpty)
            XCTAssertFalse(a.abbreviation.isEmpty)
            XCTAssertFalse(a.symbol.isEmpty)
        }
    }

    /// A measured ZERO is a different thing from a missing one, and both must survive the round trip. If
    /// absence were ever encoded as 0 this test and the one above could not both pass.
    func testAMeasuredZeroIsStillReportedAsAMeasurement() {
        let zero = WidgetSnapshot(recovery: 0, bpm: nil, batteryPct: nil, bonded: true,
                                  updated: Date(timeIntervalSince1970: 1_800_000_000))
        let a = GlanceAccessory.make(reading: .charge, snapshot: zero)
        XCTAssertFalse(a.isAbsent, "a Charge of 0 was measured — it is not absence")
        XCTAssertEqual(a.value, "0")
        XCTAssertEqual(a.gauge, 0, "…and it legitimately draws an empty ring")
    }

    // MARK: - Scaled vs unscaled

    /// Heart rate has no maximum anywhere in this codebase, so it can never be a proportion of one. It is
    /// present-but-unscaled: a figure with no gauge — the third state the circular accessory draws.
    ///
    /// Turns red: give `.heartRate` a gauge by inventing a ceiling for it.
    func testHeartRateIsPresentButCarriesNoGauge() {
        let a = GlanceAccessory.make(reading: .heartRate, snapshot: full)
        XCTAssertFalse(a.isAbsent)
        XCTAssertEqual(a.value, "58 bpm")
        XCTAssertEqual(a.compact, "58", "the ring label carries the unit, so the centre must not repeat it")
        XCTAssertNil(a.gauge, "there is no maximum heart rate in this app to make 58 a fraction of")
    }

    /// The three scores and battery DO share the 0–100 axis, so they carry a fill.
    func testTheScaledReadingsCarryAFractionOfTheirOwnAxis() {
        for (reading, expected) in [(GlanceReading.charge, 0.82), (.effort, 0.47),
                                    (.rest, 0.71), (.battery, 0.84)] {
            let a = GlanceAccessory.make(reading: reading, snapshot: full)
            let gauge = try? XCTUnwrap(a.gauge)
            XCTAssertEqual(gauge ?? -1, expected, accuracy: 0.001, "\(reading)")
        }
    }

    // MARK: - The supporting caption

    /// The rectangular accessory's caption OMITS absent readings rather than dashing them. The layout this
    /// replaced printed "HR — · Effort —" on a fresh install: two labels and two em-dashes arranged
    /// exactly like a row of figures.
    ///
    /// Turns red: emit a placeholder for a nil reading in `GlanceAccessory.context`.
    func testTheCaptionOmitsAbsentReadingsInsteadOfDashingThem() {
        let ctx = GlanceAccessory.context(for: .charge, snapshot: none)
        XCTAssertTrue(ctx.isEmpty, "nothing is measured, so there is nothing to caption: \(ctx)")

        for line in GlanceAccessory.context(for: .charge, snapshot: full) {
            XCTAssertFalse(line.contains("\u{2014}"), "no em-dash may stand in for a figure: \(line)")
            XCTAssertFalse(line.contains("--"), line)
        }
    }

    /// The caption never repeats the headline's own reading, and keeps the order the hardwired layout
    /// used — so the default Charge configuration reproduces exactly the caption it drew before.
    func testTheCaptionExcludesTheHeadlineAndKeepsTheOldOrder() {
        let ctx = GlanceAccessory.context(for: .charge, snapshot: full)
        XCTAssertEqual(ctx, ["HR 58 bpm", "Effort 47"],
                       "the default Charge config must reproduce the old hardwired caption exactly")
        XCTAssertEqual(ctx.count, 2, "the default limit is two supporting readings: \(ctx)")
        XCTAssertTrue(ctx[0].contains("58"), "live heart rate led the old layout: \(ctx)")
        XCTAssertTrue(ctx[1].contains("47"), "…then Effort: \(ctx)")
        XCTAssertFalse(ctx.joined().contains("82"), "the headline's own value must not repeat: \(ctx)")
    }

    /// A partially-measured snapshot drops only the missing readings — the caption gets shorter, it does
    /// not acquire holes.
    func testAPartialSnapshotShortensTheCaptionRatherThanHolingIt() {
        let partial = WidgetSnapshot(recovery: 82, bpm: nil, batteryPct: nil, bonded: true,
                                     updated: Date(timeIntervalSince1970: 1_800_000_000),
                                     effort: 47, rest: nil)
        let ctx = GlanceAccessory.context(for: .charge, snapshot: partial)
        XCTAssertEqual(ctx.count, 1, "only Effort is measurable beside Charge here: \(ctx)")
        XCTAssertTrue(ctx[0].contains("47"), ctx[0])
    }

    // MARK: - Battery glyph

    /// The battery symbol follows the level, and an UNKNOWN level is not drawn as half — that would be a
    /// measurement. One mapping, shared by the footer strip and the battery accessory.
    func testAnUnknownBatteryLevelIsNotDrawnAsAnyParticularLevel() {
        let unknown = GlanceAccessory.batterySymbol(nil)
        XCTAssertNotEqual(unknown, GlanceAccessory.batterySymbol(50), "unknown must not read as half")
        XCTAssertNotEqual(unknown, GlanceAccessory.batterySymbol(100))
        XCTAssertNotEqual(unknown, GlanceAccessory.batterySymbol(0))
    }
}
