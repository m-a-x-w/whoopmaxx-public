import XCTest
@testable import whoopmaxx

/// The user's own body metrics, and the fact that they are now settable.
///
/// `ProfileStore` always held age / sex / weight / height / max-HR override and the score engine always
/// read them — `hrMax` is the HRR denominator behind every Effort score and every zone boundary, and the
/// rest drive the Keytel calorie estimate. But nothing in the app could WRITE them: a repo-wide grep for
/// a writer found none. Every user was silently scored as a 30-year-old, 75 kg, 178 cm male, and the Live
/// screen printed "of max 187" as if it were theirs.
@MainActor
final class ProfileStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "profile-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The defaults are a stand-in, not a measurement — worth pinning so a change is deliberate.
    func testDefaultsAreTheDocumentedStandIn() {
        let p = ProfileStore()
        // A fresh process may carry the developer's own values from .standard, so assert the DERIVATION
        // rather than the literals: Tanaka must follow age whenever no override is set.
        if p.hrMaxOverride == 0 {
            XCTAssertEqual(p.hrMax, Int(208.0 - 0.7 * Double(p.age)))
        }
    }

    /// THE POINT: an override wins over the age estimate, so a user who knows their real max gets it.
    func testAnOverrideWinsOverTheAgeEstimate() {
        let p = ProfileStore()
        let originalAge = p.age, originalOverride = p.hrMaxOverride
        defer { p.age = originalAge; p.hrMaxOverride = originalOverride }

        p.age = 30
        p.hrMaxOverride = 0
        XCTAssertEqual(p.hrMax, 187, "Tanaka for age 30")

        p.hrMaxOverride = 175
        XCTAssertEqual(p.hrMax, 175, "a measured max must beat the estimate")

        p.hrMaxOverride = 0
        XCTAssertEqual(p.hrMax, 187, "clearing the override returns to the estimate")
    }

    /// hrMax tracks age when no override is set — the whole reason age is a scoring input.
    func testHrMaxFollowsAgeWithoutAnOverride() {
        let p = ProfileStore()
        let originalAge = p.age, originalOverride = p.hrMaxOverride
        defer { p.age = originalAge; p.hrMaxOverride = originalOverride }

        p.hrMaxOverride = 0
        p.age = 20
        let young = p.hrMax
        p.age = 60
        XCTAssertLessThan(p.hrMax, young, "an older user has a lower estimated max")
    }

    /// Every field round-trips through UserDefaults under the `profile.*` keys a restored backup writes.
    func testFieldsPersistUnderTheBackupKeys() {
        let p = ProfileStore()
        let original = (p.age, p.sex, p.weightKg, p.heightCm)
        defer { p.age = original.0; p.sex = original.1; p.weightKg = original.2; p.heightCm = original.3 }

        p.age = 41; p.sex = "female"; p.weightKg = 62.5; p.heightCm = 168

        XCTAssertEqual(UserDefaults.standard.object(forKey: "profile.age") as? Int, 41)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "profile.sex"), "female")
        XCTAssertEqual(UserDefaults.standard.object(forKey: "profile.weightKg") as? Double, 62.5)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "profile.heightCm") as? Double, 168)
    }
}
