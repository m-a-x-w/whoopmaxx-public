#if os(iOS)
import AppIntents

/// The READ half of App Intents (032). 028 shipped the write half — one tap becomes one intake entry
/// (`LogIntakeIntent`) — and left the opposite question unanswerable: the app publishes a complete
/// Charge / Effort / Rest / heart-rate / battery glance into the App Group four times a day, and the
/// only way to ASK for it was to unlock the phone and open the app.
///
/// **IT READS THE SNAPSHOT AND NOTHING ELSE.** `WidgetSnapshot.load()` is one `UserDefaults` read plus
/// a small JSON decode. The store is a ~350 MB GRDB pool in the APP's container, not in the App Group,
/// and `IntakeOutbox`'s type doc records why it stays there — an extension can be suspended mid
/// transaction holding a lock on a health database. So this answers from the published snapshot or it
/// says it cannot answer; there is no "fall back to the database" branch to get wrong.
///
/// **HOSTING.** The type lives in `Shared/`, which both the app and the widget extension compile — the
/// same arrangement `LogIntakeIntent` has shipped under since 028. That matters because the extension's
/// copy can satisfy `perform()` end to end without waking the app, which is the whole point: an
/// app-target-only intent would cost a background app launch (and therefore a store open) per "what's
/// my Charge". `openAppWhenRun = false` for the same reason — answering a question is not a reason to
/// change what is on screen.
///
/// **LOCKED-DEVICE POLICY, deliberately left at the system default.** The Lock Screen accessory widget
/// already draws a reading of the user's own choosing on a locked phone
/// (`WMWidgetContent.accessoryCircular`, configured through `GlanceWidgetConfigIntent`) — and since 030
/// it picks that reading from THIS file's `GlanceReading` vocabulary, so the widget and this intent can
/// be showing and speaking the very same number on the very same locked device. Demanding
/// authentication here would be a second, contradicting opinion about it. The user's actual control
/// over this is the system's own "Allow Siri When Locked", which is where a decision about audible
/// health data belongs.

// MARK: - Reading

/// The five values a published glance carries. An `AppEnum` for the same reason `IntakeKindChoice` is
/// one — it makes a single parameterized intent possible, which is how this stays ONE action in the
/// Shortcuts library instead of five near-identical structs that can drift apart.
public enum GlanceReading: String, AppEnum, CaseIterable {
    case charge
    case effort
    case rest
    case heartRate
    case battery

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reading"
    /// Symbols reuse the ones already shipped for these values — `bolt.heart` is the widget's Charge
    /// glyph, `moon` the Rest tab's, `waveform.path.ecg` the Live tab's, `battery.100` the widget's
    /// footer strip. Effort has no established glyph anywhere in the app; `flame` is picked here purely
    /// as picker chrome and asserts nothing about the number.
    public static let caseDisplayRepresentations: [GlanceReading: DisplayRepresentation] = [
        .charge:    DisplayRepresentation(title: "Charge", image: .init(systemName: "bolt.heart")),
        .effort:    DisplayRepresentation(title: "Effort", image: .init(systemName: "flame")),
        .rest:      DisplayRepresentation(title: "Rest", image: .init(systemName: "moon")),
        .heartRate: DisplayRepresentation(title: "Heart rate",
                                          image: .init(systemName: "waveform.path.ecg")),
        .battery:   DisplayRepresentation(title: "Strap battery",
                                          image: .init(systemName: "battery.100"))
    ]
}

// MARK: - Answer

/// The spoken sentence, as a pure function of a snapshot, its provenance record and `now`.
///
/// Pure and `now`-taking on purpose — the `SyncStatus` idiom. Every rule below is testable without an
/// intent host, a strap or a clock, which is what keeps the honesty rules from being asserted only in
/// a comment.
///
/// **THE COPY RULES, each of which is a refusal the rest of the app already makes:**
///
/// - **"as of", never "measured at".** `WidgetSnapshot.updated` is when the APP WROTE the snapshot, not
///   when anything was measured — the 15-minute tick restamps it whether or not a single new sample
///   arrived. `WMWidgetContent.headerRow` words it "as of {short time}" for exactly this reason and
///   this reuses that wording verbatim; a battery reading three days stale still publishes under a
///   fresh stamp, and "as of" is the only phrasing that does not lie about that.
/// - **A carried score names its day.** Today dims the column and captions it "carried · Tue"; speech
///   has no dim, so it has to be said. When provenance cannot be established the answer says THAT
///   rather than guessing (see `GlanceSource.unknown`).
/// - **nil is absence, never zero.** "not recorded yet", never "0", never a bare dash.
/// - **Descriptive, within-user, no verdict.** No "good", no "low", no "you should" — the app does not
///   grade the user anywhere else and a voice answer is the easiest place to start by accident.
public enum GlanceAnswer {

    /// The whole answer for one reading. `snapshot: nil` means the App Group holds nothing.
    public static func sentence(reading: GlanceReading, snapshot: WidgetSnapshot?,
                                carry: GlanceCarry?, now: Date) -> String {
        // `isEmpty` is the snapshot's OWN "the app has never published" concept (see its doc) — the same
        // one the widget uses to draw "Open whoopmaxx to set up" instead of a grid of em-dashes under a
        // fresh timestamp. Reused rather than re-derived, so the two surfaces cannot disagree about
        // whether this install has ever produced a reading.
        guard let snapshot, !snapshot.isEmpty else { return notPublished }
        let stamp = asOf(snapshot.updated, now: now)
        switch reading {
        case .charge:
            return score("Charge", snapshot.recovery,
                         GlanceCarry.source(for: snapshot, carry: carry, \.chargeCarriedFrom), stamp)
        case .effort:
            // `.own` unconditionally, and that is a fact rather than a shortcut: Effort NEVER carries
            // (`WidgetDayResolver.fields` — "carrying yesterday's full-day strain as today's Effort
            // would lie"), so the snapshot's `effort` is always the resolved day's own accumulating
            // total or nil. There is deliberately no "so far today" clause: the resolved day is not
            // always the calendar day (the #304 pre-04:00 window), so that phrase would be wrong for
            // four hours a night.
            return score("Effort", snapshot.effort, .own, stamp)
        case .rest:
            // No "last night" either — on a carried Rest it is not last night, and the carried clause
            // below is what names the night it actually is.
            return score("Rest", snapshot.rest,
                         GlanceCarry.source(for: snapshot, carry: carry, \.restCarriedFrom), stamp)
        case .heartRate:
            return plain("Heart rate", snapshot.bpm.map { "\($0) bpm" }, stamp)
        case .battery:
            // Nothing is said about `bonded`. It is in the snapshot, but its meaning is subtle — a 5/MG
            // streaming HR over the UNBONDED standard profile sets it true (`LiveState.bonded`, issue
            // #69) — so turning it into "strap connected" / "strap not connected" would state something
            // the flag does not mean. The widget renders it as an unlabelled dot for the same reason.
            return plain("Strap battery", snapshot.batteryPct.map { "\($0)%" }, stamp)
        }
    }

    /// Mirrors `WMWidgetContent.emptyNote` ("Open whoopmaxx to set up") — a never-published App Group
    /// is an app that has not run, not a broken extension, and the answer should say which.
    static let notPublished = "whoopmaxx hasn't published a reading yet — open the app to set up."

    /// A value with no provenance question attached (heart rate, battery).
    static func plain(_ label: String, _ value: String?, _ stamp: String) -> String {
        guard let value else { return "\(label) not recorded yet, \(stamp)." }
        return "\(label) \(value), \(stamp)."
    }

    /// One of the three scores. `value == nil` short-circuits before provenance is consulted: an absent
    /// score has no source day to argue about, and "Charge not recorded yet" is complete as it stands.
    static func score(_ label: String, _ value: Int?, _ source: GlanceSource, _ stamp: String) -> String {
        guard let value else { return "\(label) not recorded yet, \(stamp)." }
        switch source {
        case .own:
            return "\(label) \(value), \(stamp)."
        case .carried(let day):
            return "\(label) \(value), carried from \(day), \(stamp)."
        case .unknown:
            // The number is real and is still reported — refusing to say it would be its own kind of
            // dishonesty. What is withheld is the claim that it is TODAY's, which is the part that is
            // not known. Reachable only between upgrading to a build that writes `GlanceCarry` and its
            // first publish, i.e. until the app is next opened or syncs.
            return "\(label) \(value), \(stamp). The day it came from isn't recorded — "
                + "open whoopmaxx to refresh."
        }
    }

    /// The publish stamp in words, widening only as far as it has to.
    ///
    /// Today's publish reads exactly as the widget draws it ("as of 9:40" — same
    /// `date: .omitted, time: .shortened` call). A bare clock time stops being an answer once the
    /// snapshot is a day old, though: "as of 9:40" on a phone that last published on Tuesday invites
    /// the listener to hear "this morning". So an older stamp gains its weekday, and one past the
    /// week — where a weekday is ambiguous again — gains its date.
    ///
    /// Day distance via `Calendar.ordinality(of: .day, in: .era)` rather than an elapsed-time divide,
    /// for the reason `TodayModel.daysBetween` documents: in zones whose DST springs forward at
    /// midnight a civil day is 23 h, and a truncating difference comes back one short. A stamp that
    /// somehow sits in the future (a clock moved back) falls to the full-date spelling, which is the
    /// unambiguous one.
    static func asOf(_ updated: Date, now: Date) -> String {
        let time = updated.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        guard let then = cal.ordinality(of: .day, in: .era, for: updated),
              let today = cal.ordinality(of: .day, in: .era, for: now) else {
            return "as of \(updated.formatted(date: .abbreviated, time: .shortened))"
        }
        switch today - then {
        case 0:
            return "as of \(time)"
        case 1...6:
            return "as of \(updated.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        default:
            return "as of \(updated.formatted(date: .abbreviated, time: .shortened))"
        }
    }
}

// MARK: - Intent

/// "What's my Charge?" — answered from the last published glance, with the app closed.
///
/// ONE parameterized intent rather than a `ChargeIntent` / `EffortIntent` / `RestIntent` / … family.
/// The house pattern is already this: `IntakeQuickConfiguring` exists so two configurable surfaces
/// cannot resolve the same choices differently, and `WidgetDayResolver` is "THE one implementation" of
/// the carry rules for the same reason. Five structs each holding their own copy of the honesty rules
/// above is five places for one of them to be forgotten. `parameterSummary` makes the Shortcuts row
/// read "Get Charge", so the collapse costs nothing at the surface.
public struct GlanceReadingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get reading"
    public static let description = IntentDescription(
        "Read the last glance whoopmaxx published — Charge, Effort, Rest, heart rate or strap battery.")
    /// The point of the whole intent. Launching the app to answer a question IS the context switch the
    /// question was asked to avoid — and a background launch would open the store, which is the one
    /// thing this path promises not to do.
    public static let openAppWhenRun = false

    @Parameter(title: "Reading", default: .charge)
    public var reading: GlanceReading

    public init() {}

    public init(reading: GlanceReading) { self.reading = reading }

    public static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$reading)")
    }

    /// Returns a DIALOG and no typed value, deliberately.
    ///
    /// `ReturnsValue<Int>` would be the obvious thing for a Shortcut to chain — and it would force
    /// every absent reading to hand back a sentinel, because there is no Int that means NOT RECORDED.
    /// A shortcut that averaged that column would be averaging in zeros the strap never measured,
    /// which is precisely the assertion this codebase refuses to make. The sentence carries the number
    /// when there is one and says so plainly when there is not.
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        // Without the App Group on THIS target, `UserDefaults(suiteName:)` hands back a private store
        // and `load()` returns nil forever — so the honest-sounding "hasn't published a reading yet"
        // would become a permanent lie about a strap that is recording perfectly well. Say what is
        // actually wrong instead. Checked in Release, since that is the only build it happens in.
        guard WidgetSnapshot.isGroupProvisioned else {
            return .result(dialog: IntentDialog(stringLiteral:
                "whoopmaxx was installed without its App Group, so I can't read your data. "
                + "Reinstall a build packaged by scripts/build-ipa.sh."))
        }
        let line = GlanceAnswer.sentence(reading: reading,
                                         snapshot: WidgetSnapshot.load(),
                                         carry: GlanceCarry.load(),
                                         now: Date())
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}
#endif
