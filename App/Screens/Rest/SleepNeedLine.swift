import SwiftUI
import StrapAnalytics

/// Need-vs-actual plus the trailing sleep-debt line, in the plain copy voice: what happened, exact
/// numbers, no coaching. A thin need bar shows the night (rest ink) with the day's credited nap
/// minutes APPENDED as a visually distinct rest-`dim` segment (007 F3 — credit is additive, never
/// folded into the night number), against an ink tick at the personal need. The debt readout is the
/// `SleepDebt.ledger` net balance over the trailing window (surplus nights offset deficit ones;
/// wear-gap nights are skipped, never zero-filled).
struct SleepNeedLine: View {
    /// Nightly need in minutes (8h default per spec).
    var needMin: Double = 480
    /// Last night's minutes asleep; nil = unknown.
    let asleepMin: Double?
    /// The displayed day's CREDITED nap minutes (`NapCredit`, capped); 0 = none.
    var napMin: Double = 0
    /// Net ledger balance in minutes over the trailing window (`SleepDebtLedger.balanceMin`):
    /// negative = net debt, positive = net surplus.
    let balanceMin: Double
    /// How many nights actually contributed to the ledger (wear-gap nights skipped).
    var debtNights: Int = 14
    /// Total credited nap minutes folded into the debt window, and how many naps made them up. The Rest
    /// screen renders only the displayed day's nap rows, so prior nights' naps reduce the balance with no
    /// visible row — the debt line names their total + count so the credit is never invisible. 0 = none.
    var windowNapMin: Double = 0
    var windowNapCount: Int = 0
    /// How many nights IN THE DEBT WINDOW were kept but FLAGGED (`RestNight.lowConfidenceNightCount`,
    /// counting any night whose main-sleep group carries `CachedSleepSession.lowConfidence`). 0 = none,
    /// which is every ordinary window.
    ///
    /// The flag now has TWO causes, which is why this is a bare count and the note below names both.
    /// The stager still sets it on a run longer than `SleepDetection.maxMainSleepSpanS`, and ScoreEngine now
    /// also sets it on a night whose staged span overlaps unexplained worn silence — minutes the strap
    /// was on the wrist for and banked nothing from, which the night's totals are nonetheless drawn
    /// across. Both mean the same thing to this line: the balance was summed over a night whose record
    /// is not a clean measurement. This count cannot tell them apart (one Int, one selector), so the
    /// note must be true of either and asserts neither — see `lowConfidenceWindowNote`.
    ///
    /// Over the WINDOW, not over the displayed night: the ledger reaches 14 nights back, so a flagged
    /// night with no row on screen still moved this balance — the same reason `windowNapMin` /
    /// `windowNapCount` exist. A hero that caveats while the ledger silently banks the surplus would be
    /// worse than neither, because the ledger would be trusted BECAUSE the hero looked careful
    /// (016 decision 3); the two land together.
    ///
    /// REQUIRED, deliberately no default — that "land together" is the whole point, and a default is
    /// exactly how a call site drops one half of a pair. 013's receipt, 014's aged-out states and 015's
    /// calibrating note each shipped DEAD behind a defaulted argument the production caller forgot,
    /// with green tests throughout. The compiler is the only thing that reliably catches it.
    let lowConfidenceNights: Int
    /// Whether the screen is on its newest night. "the LAST n nights" is only true there — browsed back
    /// (014), the ledger is truncated at the selected night, so the wording has to move with it.
    var isNewest: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            if asleepMin != nil {
                needBar
                    .padding(.bottom, WM.Space.xs)
            }
            Text(needLine)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Text(debtLine)
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Night bar (rest) + appended nap-credit segment (rest dim) against the need tick (ink).
    /// Scale = max(need, night+naps) so an over-slept night never overflows the track.
    private var needBar: some View {
        let asleep = asleepMin ?? 0
        let scale = max(needMin, asleep + napMin, 1)
        var segments: [(fraction: Double, color: Color)] = [(asleep / scale, WM.Domain.rest.color)]
        if napMin > 0 { segments.append((napMin / scale, WM.Domain.rest.dim)) }
        return WMTrackBar(segments: segments, track: nil,
                          reference: (needMin / scale, WM.Ground.ink, 1.5, 12))
            .frame(height: 6)
            // The row reserves 12pt so the taller need tick straddles the 6pt bar without colliding.
            .frame(height: 12)
            .accessibilityHidden(true)   // the text lines carry the same facts
    }

    private var needLine: String {
        guard let asleepMin else { return "Need \(RestFormat.hmm(needMin))." }
        // Naps credit TOWARD need (capped upstream), so the shortfall is vs night + credited naps.
        let short = needMin - (asleepMin + napMin)
        let napNote = napMin >= 1 ? " with \(RestFormat.hmm(napMin)) of naps credited" : ""
        if short >= 1 {
            return "\(RestFormat.hmm(short)) short of your \(RestFormat.hmm(needMin)) need\(napNote)."
        }
        return "Met your \(RestFormat.hmm(needMin)) need\(napNote)."
    }

    /// The ledger's net balance, with `SleepDebt.onTargetBandMin` as the headline deadband so a few
    /// stray minutes never flip the reading. When naps credited the window, the note names their total +
    /// count so prior nights' naps (no rows on a today-only view) aren't invisible in the balance.
    /// Internal, not private, so the browse-aware wording is pinned by a test — the arithmetic followed
    /// the browse before the words did, which is the quietest kind of wrong.
    var debtLine: String {
        // Two notes, both APPENDED, never substituted for one another: the nap note explains credit that
        // pushed the balance up, the flagged note explains a night that may not have belonged in it at
        // all. A window can have both, and dropping either to make room for the other would delete the
        // explanation it was meant to sharpen.
        let n = napWindowNote + lowConfidenceWindowNote
        // "…the last 1 nights" read as a bug on every user's first week. `debtNights` counts nights that
        // HAD data, not calendar days, so the singular is a real case rather than a rounding artefact.
        let nights = debtNights == 1 ? "night" : "\(debtNights) nights"
        // "the LAST n nights" is only true at the newest night. Browsed back, the ledger is truncated at
        // the selected night (014 decision 3) — the arithmetic already follows the browse, and the words
        // have to follow it too, or a March balance reads as this week's.
        let window = isNewest ? "the last \(nights)" : "the \(nights) up to it"
        if balanceMin <= -SleepDebt.onTargetBandMin {
            return "\(RestFormat.hmm(-balanceMin)) of sleep debt over \(window)\(n)."
        }
        if balanceMin >= SleepDebt.onTargetBandMin {
            return "\(RestFormat.hmm(balanceMin)) of sleep surplus over \(window)\(n)."
        }
        return "No sleep debt over \(window)\(n)."
    }

    /// " (incl. +1:10 from 2 naps)" — the nap credit folded into the debt window, or "" when no nap
    /// credited it. Minutes come from the authoritative `nap_min` credit; the count from the same
    /// habitual classifier, so the note can't disagree with the balance it explains.
    private var napWindowNote: String {
        guard windowNapMin >= 1, windowNapCount > 0 else { return "" }
        let napWord = windowNapCount == 1 ? "nap" : "naps"
        return " (incl. +\(RestFormat.hmm(windowNapMin)) from \(windowNapCount) \(napWord))"
    }

    /// ", including 1 night with unmeasured minutes or a stretch longer than a night can be" — the
    /// flagged nights the balance was summed over, or "" when the window holds none.
    ///
    /// A clause rather than a second parenthesis, so it reads as one sentence beside the nap note. It
    /// says only that the nights are IN the balance — nothing here excludes, down-weights or re-credits
    /// them (016 decision 1).
    ///
    /// It names BOTH causes of the flag as alternatives because `lowConfidenceNights` is a count and
    /// cannot say which one fired on which night, and a note that named only one would be flatly wrong
    /// on a window flagged by the other. It used to read ", including 1 night longer than a night can
    /// be" — true while the over-long run was the only way to earn the flag, and a false statement about
    /// an 8-hour night flagged for a hole in the middle of it. The over-long half keeps the hero
    /// caption's exact wording (`RestNight.lowConfidenceCaption`) so the two surfaces still name that
    /// cause in the same words, and the new half says what was observed and stops: minutes inside the
    /// night were never measured. Neither half grades the night or the sleeper — the same register the
    /// Data wall's `sleep_unmeasured_min` entry keeps for the same fact.
    ///
    /// The "or" is a real uncertainty at THIS call site, not hedging: on a window holding two flagged
    /// nights the causes may genuinely differ. Splitting it into two counted clauses needs the cause
    /// threaded through `RestNight.lowConfidenceNightCount` and `RestScreen`, and a defaulted second
    /// count here is precisely the dead-behind-a-default failure the `lowConfidenceNights` doc above
    /// exists to prevent — so it stays one honest sentence until the count itself can tell them apart.
    private var lowConfidenceWindowNote: String {
        guard lowConfidenceNights > 0 else { return "" }
        let nightWord = lowConfidenceNights == 1 ? "night" : "nights"
        return ", including \(lowConfidenceNights) \(nightWord) "
            + "with unmeasured minutes or a stretch longer than a night can be"
    }
}

#Preview("SleepNeedLine — light") {
    SleepNeedSpecimen().preferredColorScheme(.light)
}

#Preview("SleepNeedLine — dark") {
    SleepNeedSpecimen().preferredColorScheme(.dark)
}

private struct SleepNeedSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.section) {
            SleepNeedLine(asleepMin: 432, balanceMin: -144, lowConfidenceNights: 0)
            SleepNeedLine(asleepMin: 412, napMin: 45, balanceMin: -62,
                          windowNapMin: 70, windowNapCount: 2, lowConfidenceNights: 0)
            SleepNeedLine(asleepMin: 505, balanceMin: 96, lowConfidenceNights: 0)
            SleepNeedLine(asleepMin: nil, balanceMin: -62, debtNights: 3, lowConfidenceNights: 0)
            // A window holding one flagged night — the surplus branch, where the caveat matters most
            // (a flagged night banks hours the ledger then reads as credit). The note names both causes
            // of the flag, so this one specimen shows the wording for either: the over-long run and the
            // night with unmeasured minutes inside it. The second is the corpus night this exists for —
            // 10:10 asleep, met need, a Rest score in the nineties, and part of it never measured.
            SleepNeedLine(asleepMin: 580, balanceMin: 342, lowConfidenceNights: 1)
            SleepNeedLine(asleepMin: 610, balanceMin: 288, lowConfidenceNights: 1)
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WM.Ground.ground)
    }
}
