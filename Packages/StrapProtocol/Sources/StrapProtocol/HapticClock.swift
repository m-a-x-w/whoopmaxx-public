import Foundation

/// Tells the time in buzzes, so the wrist can be read without a screen.
///
/// The scheme is a 12-hour dial: one long pulse per hour, then — after a longer silence — one
/// short pulse per completed five minutes. 7:20 is seven long, pause, four short.
///
/// Timing is start-to-start SPACING, not envelope: the buzz itself is a fixed hardware waveform,
/// so `gapMs` is the silence that follows a pulse. The gaps are deliberately wide. Narrow ones
/// let consecutive taps blend together on the wrist, which makes the count impossible to read
/// back — the failure is not a missed buzz but a miscounted one.
public enum HapticClock {

    /// One instruction: buzz for `durationMs`, then stay silent for `gapMs`.
    public struct Pulse: Equatable, Sendable {
        public let durationMs: Int
        public let gapMs: Int
        public init(durationMs: Int, gapMs: Int) {
            self.durationMs = durationMs
            self.gapMs = gapMs
        }
        /// True for an hour pulse. The two lengths must stay far enough apart to be told apart
        /// through clothing.
        public var isLong: Bool { durationMs >= HapticClock.longMs }
    }

    /// An hour pulse.
    public static let longMs = 550
    /// A five-minute pulse.
    public static let shortMs = 200
    /// Silence between two pulses inside one block.
    public static let intraGapMs = 450
    /// Silence between the hour block and the minute block — the cue that the count restarts.
    public static let blockGapMs = 1500

    /// Minutes each short pulse stands for.
    public static let minutesPerBlock = 5

    /// Encode a wall-clock time into its buzz schedule.
    ///
    /// Minutes round to the nearest five. A time within two minutes of the hour rounds up and
    /// carries: 7:58 is eight long pulses and no short ones, never seven-long-plus-twelve-short.
    public static func pulses(hour: Int, minute: Int) -> [Pulse] {
        var displayHour = hour % 12
        var blocks = Int((Double(minute) / Double(minutesPerBlock)).rounded())

        if blocks == 60 / minutesPerBlock {      // rounded up to the full hour
            blocks = 0
            displayHour += 1
        }
        // A 12-hour dial reads 12, not 0 — both midnight and noon are twelve pulses.
        if displayHour % 12 == 0 { displayHour = 12 } else { displayHour %= 12 }

        var out = [Pulse](repeating: Pulse(durationMs: longMs, gapMs: intraGapMs),
                          count: displayHour)
        guard blocks > 0 else { return out }

        // The last hour pulse carries the block gap, so the two runs are separable.
        out[out.count - 1] = Pulse(durationMs: longMs, gapMs: blockGapMs)
        out += [Pulse](repeating: Pulse(durationMs: shortMs, gapMs: intraGapMs), count: blocks)
        return out
    }
}
