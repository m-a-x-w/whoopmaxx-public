import Foundation
import Combine

/// Minimal user profile backing the score engine (age / sex / body metrics / HRmax override / step
/// scale). UserDefaults-backed under the SAME `profile.*` keys the original ProfileStore used, so a restored
/// backup settings.json (BackupSettings.apply, W4) lands directly on these fields.
@MainActor
final class ProfileStore: ObservableObject {
    @Published var age: Int { didSet { d.set(age, forKey: K.age) } }
    @Published var sex: String { didSet { d.set(sex, forKey: K.sex) } }          // "male" | "female" | "nonbinary"
    @Published var weightKg: Double { didSet { d.set(weightKg, forKey: K.weight) } }
    @Published var heightCm: Double { didSet { d.set(heightCm, forKey: K.height) } }
    /// 0 = auto-estimate from age (Tanaka).
    @Published var hrMaxOverride: Int { didSet { d.set(hrMaxOverride, forKey: K.hrMax) } }
    /// Step-calibration divisor (#139): counter ticks per real step for the @57 motion counter.
    @Published var stepTicksPerStep: Double {
        didSet { d.set(min(max(stepTicksPerStep, 0.5), 30.0), forKey: K.stepScale) }
    }

    /// Effective HRmax: the override when set, else Tanaka (208 − 0.7 × age).
    var hrMax: Int { hrMaxOverride > 0 ? hrMaxOverride : Int(208.0 - 0.7 * Double(age)) }

    private let d = UserDefaults.standard
    private enum K {
        static let age = "profile.age", sex = "profile.sex", weight = "profile.weightKg"
        static let height = "profile.heightCm", hrMax = "profile.hrMaxOverride"
        static let stepScale = "profile.stepTicksPerStep"
    }

    init() {
        age = d.object(forKey: K.age) as? Int ?? 30
        sex = d.string(forKey: K.sex) ?? "male"
        weightKg = d.object(forKey: K.weight) as? Double ?? 75
        heightCm = d.object(forKey: K.height) as? Double ?? 178
        hrMaxOverride = d.object(forKey: K.hrMax) as? Int ?? 0
        stepTicksPerStep = min(max(d.object(forKey: K.stepScale) as? Double ?? 1.0, 0.5), 30.0)
    }
}
