import XCTest
@testable import whoopmaxx

/// 031 — the per-kind rules behind the configurable Lock Screen surfaces.
///
/// The interesting behaviour is not "does a tap log": 028's outbox already covers that. It is that a
/// configuration carries FIELDS THAT DO NOT BELONG TO ITS KIND, because `Edit Widget` keeps every
/// parameter the user has ever set. Switching a widget from Alcohol to Meal leaves `countValue = 2`
/// sitting in the configuration, and writing that through would file a meal as "2 drinks" — a claim
/// the user never made. `IntakeQuickPreset.make` is the filter, so these are its tests.
final class IntakeQuickConfigTests: XCTestCase {

    // MARK: - Field filtering (the reason the type exists)

    func testMealDropsAStaleCountAndMilligrams() {
        let preset = IntakeQuickPreset.make(kind: .meal, form: .pill, countValue: 2,
                                            mealSize: .heavy, amountMg: 200)
        XCTAssertEqual(preset.kind, "meal")
        XCTAssertEqual(preset.sizeOrdinal, 3)
        XCTAssertNil(preset.countValue, "a portion is not a count of discrete things")
        XCTAssertNil(preset.amountMg)
        XCTAssertNil(preset.variant)
    }

    func testWaterDropsAStaleFormAndMilligrams() {
        let preset = IntakeQuickPreset.make(kind: .water, form: .pill, countValue: 1,
                                            mealSize: .light, amountMg: 200)
        XCTAssertEqual(preset.countValue, 1)
        XCTAssertNil(preset.variant)
        XCTAssertNil(preset.amountMg)
        XCTAssertNil(preset.sizeOrdinal)
    }

    func testCaffeineKeepsFormAndMilligramsOnly() {
        let preset = IntakeQuickPreset.make(kind: .caffeine, form: .pill, countValue: 4,
                                            mealSize: .heavy, amountMg: 200)
        XCTAssertEqual(preset.variant, "pill")
        XCTAssertEqual(preset.amountMg, 200)
        // Cups are the legacy caffeine amount (027 moved to milligrams); no new tap writes one.
        XCTAssertNil(preset.countValue)
        XCTAssertNil(preset.sizeOrdinal)
    }

    func testAlcoholKeepsCountOnly() {
        let preset = IntakeQuickPreset.make(kind: .alcohol, form: .drink, countValue: 2,
                                            mealSize: .usual, amountMg: 40)
        XCTAssertEqual(preset.countValue, 2)
        XCTAssertNil(preset.variant)
        XCTAssertNil(preset.amountMg)
        XCTAssertNil(preset.sizeOrdinal)
    }

    // MARK: - Bare stays bare

    func testUnconfiguredPresetCarriesNoAmountAtAll() {
        for kind in IntakeKindChoice.allCases {
            let preset = IntakeQuickPreset.make(kind: kind)
            XCTAssertNil(preset.countValue, "\(kind)")
            XCTAssertNil(preset.amountMg, "\(kind)")
            XCTAssertNil(preset.sizeOrdinal, "\(kind)")
            XCTAssertEqual(preset.caption, "", "\(kind) must draw no amount it was not given")
        }
    }

    func testNonPositiveAmountsAreNotRecorded() {
        XCTAssertNil(IntakeQuickPreset.make(kind: .caffeine, amountMg: 0).amountMg)
        XCTAssertNil(IntakeQuickPreset.make(kind: .caffeine, amountMg: -50).amountMg)
        XCTAssertNil(IntakeQuickPreset.make(kind: .water, countValue: 0).countValue)
        XCTAssertNil(IntakeQuickPreset.make(kind: .alcohol, countValue: -1).countValue)
    }

    // MARK: - Captions

    func testCountCaptionPluralises() {
        XCTAssertEqual(IntakeQuickPreset.make(kind: .water, countValue: 1).caption, "1 glass")
        XCTAssertEqual(IntakeQuickPreset.make(kind: .water, countValue: 2).caption, "2 glasses")
        XCTAssertEqual(IntakeQuickPreset.make(kind: .alcohol, countValue: 1).caption, "1 drink")
        XCTAssertEqual(IntakeQuickPreset.make(kind: .alcohol, countValue: 3).caption, "3 drinks")
    }

    func testCaffeineCaptionCoversEveryCombination() {
        XCTAssertEqual(IntakeQuickPreset.make(kind: .caffeine, form: .pill, amountMg: 200).caption,
                       "200 mg · Pill")
        XCTAssertEqual(IntakeQuickPreset.make(kind: .caffeine, amountMg: 95).caption, "95 mg")
        XCTAssertEqual(IntakeQuickPreset.make(kind: .caffeine, form: .drink).caption, "Drink")
        XCTAssertEqual(IntakeQuickPreset.make(kind: .caffeine).caption, "")
    }

    func testSymbolFollowsFormForCaffeineAndKindOtherwise() {
        XCTAssertEqual(IntakeQuickPreset.make(kind: .caffeine, form: .pill).symbol, "pills")
        XCTAssertEqual(IntakeQuickPreset.make(kind: .caffeine, form: .drink).symbol, "cup.and.saucer")
        XCTAssertEqual(IntakeQuickPreset.make(kind: .caffeine).symbol, "cup.and.saucer")
        XCTAssertEqual(IntakeQuickPreset.make(kind: .meal).symbol, "fork.knife")
        XCTAssertEqual(IntakeQuickPreset.make(kind: .water).symbol, "drop")
        XCTAssertEqual(IntakeQuickPreset.make(kind: .alcohol).symbol, "wineglass")
    }

    // MARK: - The mirrors match the domain

    /// The widget target cannot see `IntakeKind`, so the choice enum duplicates its raw values. If the
    /// two ever diverge, `IntakeStore.drainOutbox` silently leaves those taps in the outbox forever —
    /// no crash, no message, just intake that never arrives. This is the test that catches it.
    func testKindChoiceRawValuesRoundTripThroughTheDomainEnum() {
        for choice in IntakeKindChoice.allCases {
            XCTAssertNotNil(IntakeKind(rawValue: choice.rawValue), "\(choice.rawValue) has no IntakeKind")
        }
        XCTAssertEqual(Set(IntakeKindChoice.allCases.map(\.rawValue)),
                       Set(IntakeKind.allCases.map(\.rawValue)))
    }

    func testFormChoiceRawValuesRoundTripThroughIntakeVariant() {
        for choice in IntakeFormChoice.allCases {
            XCTAssertNotNil(IntakeVariant(rawValue: choice.rawValue))
        }
        XCTAssertEqual(Set(IntakeFormChoice.allCases.map(\.rawValue)),
                       Set(IntakeKind.caffeine.variants.map(\.rawValue)))
    }

    func testMealSizeChoiceOrdinalsRoundTripThroughMealSize() {
        for choice in IntakeMealSizeChoice.allCases {
            XCTAssertEqual(MealSize(rawValue: choice.rawValue)?.label,
                           IntakeQuickPreset.mealCaption(choice))
        }
    }

    // MARK: - Intent hand-off

    /// The preset is what both Lock Screen surfaces fire, so the fields it filtered must survive the
    /// trip into `LogIntakeIntent` — including `sizeOrdinal`, which 028's intent dropped on the floor.
    func testLogIntentCarriesExactlyThePresetsFields() {
        let intent = IntakeQuickPreset.make(kind: .meal, countValue: 9, mealSize: .light).logIntent
        XCTAssertEqual(intent.kind, "meal")
        XCTAssertEqual(intent.sizeOrdinal, 1)
        XCTAssertNil(intent.countValue)

        let coffee = IntakeQuickPreset.make(kind: .caffeine, form: .drink, amountMg: 95).logIntent
        XCTAssertEqual(coffee.kind, "caffeine")
        XCTAssertEqual(coffee.amountMg, 95)
        XCTAssertEqual(coffee.variant, "drink")
        XCTAssertNil(coffee.sizeOrdinal)
    }

    /// The gallery sample must not look like a standing declaration — a preview tile showing "200 mg"
    /// would be an amount the user never set, on a surface that exists to show what a tap will write.
    func testPreviewPresetIsBare() {
        XCTAssertEqual(IntakeQuickPreset.preview.caption, "")
        XCTAssertNil(IntakeQuickPreset.preview.amountMg)
        XCTAssertNil(IntakeQuickPreset.preview.countValue)
        XCTAssertNil(IntakeQuickPreset.preview.sizeOrdinal)
    }
}
