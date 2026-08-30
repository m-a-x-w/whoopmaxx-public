import Foundation

/// A bounded window during which raw frames are kept.
///
/// Deliberately never open-ended. It expires on its own deadline rather than waiting to be closed,
/// so a stop callback that never arrives — a crash, a dropped connection — cannot leak raw capture
/// for the rest of the session.
struct RawCaptureWindow {
    static let minSeconds: TimeInterval = 1
    static let maxSeconds: TimeInterval = 300
    static func clamp(_ s: TimeInterval) -> TimeInterval { min(max(s, minSeconds), maxSeconds) }

    /// Monotonic deadline; nil while closed.
    private var deadline: TimeInterval?

    /// Open through the deadline instant itself, so a frame arriving exactly on it is kept.
    func isActive(at t: TimeInterval) -> Bool {
        guard let deadline else { return false }
        return t <= deadline
    }

    mutating func open(at t: TimeInterval, duration: TimeInterval) {
        deadline = t + Self.clamp(duration)
    }

    mutating func close() { deadline = nil }
}
