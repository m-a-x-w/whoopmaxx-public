import Foundation

/// Where an app-sent wrist buzz came from. Only the buzzes whoopmaxx itself initiates are recorded
/// (habit reminder, smart-alarm early wake, inactivity nudge, haptic-clock time check, wake-window
/// test buzz); the strap's own firmware-alarm buzz fires with no app command and is
/// unobservable-as-a-buzz, so it is deliberately absent (the history is honest about covering
/// app-sent buzzes only). Breathe-session pacing pulses are also excluded — they fire every few
/// seconds by design and would flood a record meant to answer "why did the band buzz".
public enum BuzzSource: String, Codable {
    case habit
    case smartAlarm
    case inactivity
    /// Haptic Clock (#460): the current time buzzed on the wrist — strap double-tap or the Strap
    /// Health button.
    case timeCheck
    /// The wake-window "Test buzz" button on Rest — user-initiated, but still an app-sent buzz the
    /// history should account for (a felt buzz with no row reads as a broken record).
    case test
}

/// One app-sent wrist buzz, frozen at the instant it fired. `label` is captured at write time (the
/// habit's then-current name, or "Smart alarm wake") so a later rename or delete can't rewrite what
/// actually buzzed the user.
public struct BuzzEvent: Codable, Identifiable {
    public let ts: Double          // unix seconds
    public let source: BuzzSource
    public let label: String

    public init(ts: Double, source: BuzzSource, label: String) {
        self.ts = ts
        self.source = source
        self.label = label
    }

    public var id: String { "\(ts)-\(source.rawValue)-\(label)" }
    public var date: Date { Date(timeIntervalSince1970: ts) }
}

/// A tiny persisted ring buffer of app-sent wrist buzzes — the quiet "why did the band buzz" record
/// surfaced from Strap Health. Backed by a small JSON file in the same Application Support directory as
/// the store, written with `completeUntilFirstUserAuthentication` protection so the background BLE tick
/// can append a buzz while the phone is locked (the default `complete` protection would fail that write).
/// Capped at the newest `cap` events; a lost history write must never affect the buzz itself.
@MainActor
public final class BuzzLog: ObservableObject {
    /// Chronological (oldest → newest). The history screen displays it reversed.
    @Published public private(set) var events: [BuzzEvent] = []

    private static let cap = 200
    private let fileURL: URL

    public init() {
        fileURL = Self.resolveURL()
        events = Self.load(from: fileURL)
    }

    /// Append one buzz and persist, trimming to the newest `cap`. Called on the main actor from the two
    /// buzz sites (the habit tick in AppRoot and the smart-alarm early wake).
    public func record(source: BuzzSource, label: String, at date: Date = Date()) {
        var next = events
        next.append(BuzzEvent(ts: date.timeIntervalSince1970, source: source, label: label))
        if next.count > Self.cap { next.removeFirst(next.count - Self.cap) }
        events = next
        save()
    }

    /// Wipe the history (the low-key Clear action on the history screen).
    public func clear() {
        events = []
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        // Protection set atomically at write time so a locked-phone background append still succeeds and
        // the file stays encrypted at rest — matching the store's own file protection (StorePaths).
        try? data.write(to: fileURL,
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func load(from url: URL) -> [BuzzEvent] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([BuzzEvent].self, from: data) else { return [] }
        return decoded
    }

    private static func resolveURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("OpenWhoop", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("buzzlog.json")
    }
}
