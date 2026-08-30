import Foundation
import StrapAnalytics

/// The diagnostics modes: which are on, when each was turned on, and what the guided capture asked.
///
/// One namespace for everything new here. The older experimental flags keep their original keys and
/// are read where they already live — moving them would silently reset a setting for anyone who had
/// turned one on.
public enum TestCentre {

    private static let activePrefix = "testcentre.active."
    private static let startedPrefix = "testcentre.startedAt."
    private static let guidedTargetPrefix = "testcentre.target."
    private static let answersPrefix = "testcentre.answers."
    private static let migratedKey = "testcentre.migrated.v1"

    private static let master = TestDomain.master

    /// The gate every emitter checks first.
    ///
    /// It has to be nearly free, because it is called on the BLE and analytics paths for every line
    /// that might be logged — so it is `nonisolated` and costs a boolean read when the mode is off.
    public nonisolated static func active(_ d: TestDomain) -> Bool {
        if d == .universal { return anyActive }
        if UserDefaults.standard.bool(forKey: activePrefix + master.id) { return true }
        return UserDefaults.standard.bool(forKey: activePrefix + d.id)
    }

    /// Whether any real mode is on — what the "diagnostics are on" banner reads, and what the
    /// universal traces ride.
    public nonisolated static var anyActive: Bool {
        TestDomain.allCases.contains {
            $0 != .universal && UserDefaults.standard.bool(forKey: activePrefix + $0.id)
        }
    }

    @MainActor public static func activate(_ d: TestDomain) {
        UserDefaults.standard.set(true, forKey: activePrefix + d.id)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: startedPrefix + d.id)
    }

    @MainActor public static func deactivate(_ d: TestDomain) {
        UserDefaults.standard.set(false, forKey: activePrefix + d.id)
    }

    public static func startedAt(_ d: TestDomain) -> Date? {
        let t = UserDefaults.standard.double(forKey: startedPrefix + d.id)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// How many nights or days the guided capture is collecting; 0 when unset.
    public static func guidedTarget(_ d: TestDomain) -> Int {
        UserDefaults.standard.integer(forKey: guidedTargetPrefix + d.id)
    }

    @MainActor public static func setGuidedTarget(_ count: Int, for d: TestDomain) {
        UserDefaults.standard.set(count, forKey: guidedTargetPrefix + d.id)
    }

    public static func answers(_ d: TestDomain) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: answersPrefix + d.id),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }

    @MainActor public static func setAnswers(_ m: [String: String], for d: TestDomain) {
        guard let data = try? JSONEncoder().encode(m) else { return }
        UserDefaults.standard.set(data, forKey: answersPrefix + d.id)
    }

    // MARK: - Rows drained, all time

    private static let cumulativeDrainedKey = "testcentre.cumulativeDrainedRows"

    /// Fold one session's drained rows into the running total.
    ///
    /// It accrues whether or not any mode is on, because the question it answers — has this install
    /// EVER drained anything — spans sessions. The per-session count resets on every reconnect, so a
    /// strap caught in a restart loop looked like it had never made progress even while rows were
    /// landing.
    public nonisolated static func noteDrainedRows(_ rows: Int) {
        guard rows > 0 else { return }
        let d = UserDefaults.standard
        d.set(d.integer(forKey: cumulativeDrainedKey) + rows, forKey: cumulativeDrainedKey)
    }

    public nonisolated static func cumulativeDrainedRows() -> Int {
        UserDefaults.standard.integer(forKey: cumulativeDrainedKey)
    }

    /// Stamp the one-time migration guard.
    ///
    /// Deliberately a no-op beyond the stamp. The older toggles are advanced experimental flags
    /// rather than mode activations, so there is nothing to seed from them — and they are read
    /// through their own accessors, in place. Nothing is moved and no key is ever deleted.
    @MainActor public static func migrate() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedKey)
    }
}
