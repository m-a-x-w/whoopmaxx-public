import XCTest
import StrapStore
import StrapProtocol
@testable import whoopmaxx

/// #938 regression: skin-temp raw→°C must use the strap's ACTUAL family. whoopmaxx registers its single
/// strap as just "WHOOP" (no model string), so `skinTempFamily` must fall back to the PAIRED model
/// (`WhoopModel.persisted`) — NOT a hardcoded `.whoop5`, which fed a WHOOP 4.0's raw-ADC skin temp
/// through the 5/MG `/100` map, producing garbage °C and a deviation that never validated → skin temp
/// read "—" forever on every 4.0.
final class SkinTempFamilyTests: XCTestCase {
    private let key = WhoopModel.persistedKey
    private var saved: String?

    override func setUp() { saved = UserDefaults.standard.string(forKey: key) }
    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func strap(model: String) -> PairedDevice {
        PairedDevice(id: "my-whoop", brand: "WHOOP", model: model, sourceKind: .liveBLE,
                     capabilities: [.hr, .skinTemp], status: .active, addedAt: 0, lastSeenAt: 0)
    }

    /// Registry has no WHOOP-model string → use the paired model (a 4.0 wearer).
    func testFallsBackToPairedWhoop4() {
        UserDefaults.standard.set("WHOOP 4.0", forKey: key)
        XCTAssertEqual(ScoreEngine.skinTempFamily(forOwner: "my-whoop", devices: [strap(model: "WHOOP")]),
                       .whoop4)
    }

    /// Same fallback, 5/MG wearer.
    func testFallsBackToPairedWhoop5() {
        UserDefaults.standard.set("WHOOP 5.0 / MG", forKey: key)
        XCTAssertEqual(ScoreEngine.skinTempFamily(forOwner: "my-whoop", devices: [strap(model: "WHOOP")]),
                       .whoop5)
    }

    /// A registry `model` that positively names a family still wins over the persisted fallback.
    func testPositiveRegistryModelWins() {
        UserDefaults.standard.set("WHOOP 4.0", forKey: key)      // paired as 4.0…
        let dev5 = strap(model: "WHOOP 5.0 / MG")                // …but this row explicitly says 5/MG
        XCTAssertEqual(ScoreEngine.skinTempFamily(forOwner: "my-whoop", devices: [dev5]), .whoop5)
    }
}
