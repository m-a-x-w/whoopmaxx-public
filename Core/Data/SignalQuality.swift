import Foundation

/// Session link-quality grade over LiveState's honest per-session counters (007 F4, pure).
/// Worst-of the three signals below; `reasons` carries a plain-English line per finding so the
/// Strap Health screen never shows a bare "Fair" with no explanation.
enum SignalQuality {

    enum Grade: Int, Comparable, Equatable {
        case good, fair, poor

        static func < (lhs: Grade, rhs: Grade) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Display word for the Signal section headline.
        var label: String {
            switch self {
            case .good: return "Good"
            case .fair: return "Fair"
            case .poor: return "Poor"
            }
        }
    }

    struct Assessment: Equatable {
        let grade: Grade
        /// One plain-voice line per finding, empty when the grade is a clean `.good`.
        let reasons: [String]
    }

    /// A few undecodable frames ride along on any long offload (raw bytes are archived, nothing is
    /// lost) — only a session with MANY starts reading as a real decode problem.
    static let rejectedFairThreshold = 1
    static let rejectedPoorThreshold = 50
    /// One or two link drops per session are ordinary BLE weather; a run of them means the radio /
    /// range / strap is genuinely struggling.
    static let reconnectsFairThreshold = 3
    static let reconnectsPoorThreshold = 6

    /// Grade one session's link quality.
    ///
    /// - Parameters:
    ///   - rejectedFrames: undecodable HISTORICAL_DATA frames this session (archived + unarchived).
    ///   - consoleOnly: a completed offload handed over ONLY console/diagnostic chunks — the #77
    ///     signature of a strap whose clock lost sync (it isn't banking biometrics to flash).
    ///   - reconnects: times the link re-established after the session's first connect.
    static func grade(rejectedFrames: Int, consoleOnly: Bool, reconnects: Int) -> Assessment {
        var grade = Grade.good
        var reasons: [String] = []

        if consoleOnly {
            grade = .poor
            reasons.append("History is arriving as console frames only — the strap's clock has "
                + "likely lost sync and it may not be recording.")
        }
        if rejectedFrames >= Self.rejectedPoorThreshold {
            grade = max(grade, .poor)
            reasons.append("\(rejectedFrames) history frames couldn't be decoded this session.")
        } else if rejectedFrames >= Self.rejectedFairThreshold {
            grade = max(grade, .fair)
            reasons.append("\(rejectedFrames) history "
                + (rejectedFrames == 1 ? "frame" : "frames")
                + " couldn't be decoded this session (raw bytes were kept).")
        }
        if reconnects >= Self.reconnectsPoorThreshold {
            grade = max(grade, .poor)
            reasons.append("The link dropped \(reconnects) times this session.")
        } else if reconnects >= Self.reconnectsFairThreshold {
            grade = max(grade, .fair)
            reasons.append("The link dropped \(reconnects) times this session.")
        }
        return Assessment(grade: grade, reasons: reasons)
    }
}
