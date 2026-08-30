import Foundation

/// Which area a test-mode capture is exercising.
public enum TestDomain: String, CaseIterable, Sendable, Codable {
    /// Always present under any active mode — the preamble plus the derived traces.
    case universal
    case sleep
    case connection
    case workouts
    case display
    /// `import` is a reserved word, so the raw value is spelled out.
    case dataImport
    case steps
    case notifications
    case battery
    case recovery
    case hrv
    case sources
    case stress
    case longevity
    /// Log everything.
    case master

    /// Stable wire id — it appears in log tags, in an export's manifest and in an issue label, so
    /// it must survive a rename of the case. `dataImport` spells out as "import", the word Swift
    /// would not let the case itself be.
    public var id: String { self == .dataImport ? "import" : rawValue }

    /// The issue label a diagnostics deep link applies to itself.
    public var githubLabel: String { self == .master ? "test:all" : "test:\(id)" }
}

/// A question asked at the end of a guided capture.
public struct Question: Sendable, Codable, Equatable {
    /// Stable key, stored in the capture's questionnaire map. Renaming the prompt must not
    /// orphan answers already recorded against it.
    public let id: String
    public let prompt: String
    public enum Kind: String, Sendable, Codable { case yesNo, text, time, choice }
    public let kind: Kind
    /// Only meaningful for `.choice`; empty otherwise.
    public let choices: [String]

    public init(id: String, prompt: String, kind: Kind, choices: [String] = []) {
        self.id = id; self.prompt = prompt; self.kind = kind; self.choices = choices
    }
}

/// Diagnostic lines about the strap's clock and firmware.
public enum ConnectionTrace {

    /// Below this a reported time is the RTC's own epoch, meaning the clock was never set.
    public static let rtcEpochCeilingUnix = 63_072_000
    /// How far behind the wall clock the newest record may sit before it is called a fault.
    public static let behindToleranceDefault = 48 * 3_600

    /// The shared clock verdict.
    ///
    /// Deliberately ONE function used by every trace, so the universal line and the connection
    /// line can never disagree about what counts as a clock fault — two diagnostics contradicting
    /// each other is worse than either being absent.
    static func clockVerdict(aheadSeconds: Int, newestUnix: Int,
                             futureToleranceSeconds: Int, behindToleranceSeconds: Int) -> String {
        if aheadSeconds > futureToleranceSeconds { return " FUTURE-DATED (strap clock ahead of wall)" }
        if newestUnix < rtcEpochCeilingUnix {
            return " RTC-EPOCH (strap clock reads 1970/71, never set; charge to 100% and reconnect so it latches)"
        }
        if aheadSeconds < -behindToleranceSeconds {
            return " CLOCK-WARNING (newest banked record \(-aheadSeconds / 86_400)d behind wall; "
                + "strap clock reset or history stale)"
        }
        return " clockOk"
    }

    public static func clockDriftLine(oldestUnix: Int?,
                                      newestUnix: Int,
                                      wallNowUnix: Int,
                                      futureToleranceSeconds: Int = 120,
                                      behindToleranceSeconds: Int = behindToleranceDefault) -> String {
        let aheadSeconds = newestUnix - wallNowUnix
        var line = "clockDrift newest=\(isoDate(newestUnix)) wall=\(isoDate(wallNowUnix)) "
            + "newestVsWall=\(signed(aheadSeconds))s"
        if let oldestUnix {
            // TRUNCATED, unlike UniversalTrace's rounded span — a known inconsistency between the
            // two lines, kept because changing either would move a value people have quoted in
            // reports. A window a minute shy of three days reads 2 here and 3 there.
            line += " oldest=\(isoDate(oldestUnix)) spanDays=\(max(0, newestUnix - oldestUnix) / 86_400)"
        }
        return line + clockVerdict(aheadSeconds: aheadSeconds, newestUnix: newestUnix,
                                   futureToleranceSeconds: futureToleranceSeconds,
                                   behindToleranceSeconds: behindToleranceSeconds)
    }

    /// Says outright when a layout produced nothing, rather than reporting a version and leaving
    /// the reader to infer that no data came out of it.
    public static func firmwareLine(version: Int, decodable: Bool) -> String {
        "firmware layout=v\(version) \(decodable ? "decodable" : "UNMAPPED (no motion/HR decoded)")"
    }

    public static func noCursorLine() -> String {
        "offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)"
    }

    static func isoDate(_ unix: Int) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime,
                           .withSpaceBetweenDateAndTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    static func signed(_ n: Int) -> String { n >= 0 ? "+\(n)" : "\(n)" }
}

/// The clock line every capture carries, whatever domain it is testing.
public enum UniversalTrace {
    public static func clockDriftLine(newestUnix: Int,
                                      wallNowUnix: Int,
                                      oldestUnix: Int? = nil,
                                      firmwareLayout: Int? = nil,
                                      futureToleranceSeconds: Int = 120,
                                      behindToleranceSeconds: Int = ConnectionTrace.behindToleranceDefault) -> String {
        let aheadSeconds = newestUnix - wallNowUnix
        var line = "strapClock newest=\(ConnectionTrace.isoDate(newestUnix)) "
            + "wall=\(ConnectionTrace.isoDate(wallNowUnix)) "
            + "newestVsWall=\(ConnectionTrace.signed(aheadSeconds))s"
        if let oldestUnix, oldestUnix < newestUnix {
            // ROUNDED to the nearest day, unlike the connection line's truncation: a window a
            // minute shy of three days should read three, not two.
            let spanDays = max(0, Int((Double(newestUnix - oldestUnix) / 86_400).rounded()))
            line += " oldest=\(ConnectionTrace.isoDate(oldestUnix)) spanDays=\(spanDays)"
        }
        line += firmwareLayout.map { " firmware=v\($0)" } ?? " firmware=unknown"
        return line + ConnectionTrace.clockVerdict(aheadSeconds: aheadSeconds, newestUnix: newestUnix,
                                                   futureToleranceSeconds: futureToleranceSeconds,
                                                   behindToleranceSeconds: behindToleranceSeconds)
    }
}

/// Reads the strap's own tagged log tail back into human-facing answers.
///
/// Parsing a log rather than holding structured state, because the log is what a user can actually
/// export and attach to a report — a readout derived from anything else could not be checked
/// against what they sent.
public enum ConnectionReadout {

    public static func uptimeLabel(taggedTail: [String], nowUnix: Int) -> String {
        // Walked BACKWARD: the newest relevant line wins, and a "connect down" after a start
        // means the session is over regardless of what came before it.
        for line in taggedTail.reversed() {
            if line.contains("connect down") { return "not connected" }
            if let start = intField(line, key: "uptimeStart=") {
                return durationLabel(max(0, nowUnix - start))
            }
        }
        return "not connected"
    }

    /// The highest reconnect count seen, not the last.
    ///
    /// The counter resets on a fresh connection, so taking the last line would report 0 for a
    /// session that reconnected a dozen times and then settled.
    public static func reconnectCount(taggedTail: [String]) -> Int {
        var maxN = 0
        for line in taggedTail where line.contains("reconnect ") {
            if let n = intField(line, key: "n=") { maxN = max(maxN, n) }
        }
        return maxN
    }

    public static func lastOffloadResult(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "offload result=") {
                let frag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
        }
        return nil
    }

    /// Rows from the newest session.
    ///
    /// A finished session's result line wins, and a result carrying no `rows=` honestly means
    /// ZERO — not an older session's running total, which is what a naive scan would surface and
    /// would make an empty sync look successful.
    public static func sessionRows(taggedTail: [String]) -> Int? {
        for line in taggedTail.reversed() {
            if line.contains("offload result=") { return intField(line, key: "rows=") ?? 0 }
            if let n = intField(line, key: "sessionRows=") { return n }
        }
        return nil
    }

    public static func drainedRowsFromSummary(_ line: String) -> Int? {
        guard let r = line.range(of: "session persisted ") else { return nil }
        let rest = line[r.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(" rows") else { return nil }
        return Int(digits)
    }

    public static func clockCorrelatedDevice(logLines: [String]) -> Int? {
        for line in logLines.reversed() where line.contains("Clock correlated:") {
            return intField(line, key: "device=")
        }
        return nil
    }

    /// Whether the strap's clock has actually latched.
    ///
    /// A clock reading 1970 is not a latched clock, and reporting "yes" for it would send a user
    /// looking for a sync problem when the real fix is to charge the strap.
    public static func clockLatchedLabel(deviceClockUnix: Int?) -> String {
        guard let d = deviceClockUnix else { return "no (waiting for the strap clock)" }
        return d < ConnectionTrace.rtcEpochCeilingUnix ? "no (RTC reads 1970/71)" : "yes"
    }

    static func intField(_ line: String, key: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        return Int(line[r.upperBound...].prefix { $0 != " " })
    }

    static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

/// Module identity, for anything that reports which engine produced a result.
public enum StrapAnalytics {
    /// Bumped when a change alters what the engines OUTPUT, not when code merely moves.
    ///
    /// A stored score carries the version that produced it, which is what lets a later build tell
    /// "this day was never scored" from "this day was scored by an engine that has since changed".
    public static let version = "1.0.0"
}
