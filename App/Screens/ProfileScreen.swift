import SwiftUI

/// The user's own body metrics — age, sex, weight, height, and an optional max-HR override. A
/// full-screen cover from Settings › Profile ("You").
///
/// WHY THIS EXISTS. `ProfileStore` has always held these fields and persisted them under `profile.*`,
/// and the score engine has always read them: `hrMax` (override, else Tanaka `208 − 0.7 × age`) sets the
/// heart-rate reserve every Effort/TRIMP number is computed against and every HR zone is drawn from, and
/// weight/height/age/sex drive the Keytel calorie estimate. But NOTHING in the app could write them — a
/// repo-wide grep for a writer found none. Every user was silently scored as a 30-year-old, 75 kg,
/// 178 cm male, and the Live screen printed "of max 187" as if it were theirs.
///
/// The numbers this corrects are not cosmetic: HRmax is the denominator of %HRR, so a real HRmax of 175
/// against the assumed 187 shifts every zone boundary and every Effort score for the life of the install.
///
/// SAFE TO CHANGE LATER. `ScoreEngine` recomputes Effort, zones and calories from the stored raw samples
/// on every pass, so editing this retroactively corrects every day still inside the retention window —
/// which is why this is a settings screen and not a blocking onboarding step.
struct ProfileScreen: View {
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var root: AppRoot
    @Environment(\.dismiss) private var dismiss

    @AppStorage(TempUnit.systemKey) private var unitSystem: String = "metric"
    private var isImperial: Bool { unitSystem == "imperial" }

    var body: some View {
        ZStack {
            WM.Ground.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    WMCoverHeader(title: "You", closeLabel: "Close profile") { dismiss() }

                    RuleSection("Body", topGap: WM.Space.l) {
                        VStack(alignment: .leading, spacing: 0) {
                            stepperRow(label: "Age",
                                       value: Double(profile.age),
                                       display: "\(profile.age)",
                                       range: 13...100, step: 1,
                                       set: { profile.age = Int($0.rounded()) })
                            WMRule()
                            InkSegmentRow(label: "Sex",
                                          options: [("female", "Female"), ("male", "Male"),
                                                    ("nonbinary", "Other")],
                                          selection: sexBinding)
                            WMRule()
                            stepperRow(label: "Weight",
                                       value: profile.weightKg,
                                       display: Self.weightText(kg: profile.weightKg, imperial: isImperial),
                                       range: 35...200, step: isImperial ? 0.45359237 : 0.5,
                                       set: { profile.weightKg = $0 })
                            WMRule()
                            stepperRow(label: "Height",
                                       value: profile.heightCm,
                                       display: heightDisplay,
                                       range: 120...220, step: isImperial ? 2.54 : 1,
                                       set: { profile.heightCm = $0 })
                        }
                    }

                    RuleSection("Max heart rate", topGap: WM.Space.sectionTight) {
                        VStack(alignment: .leading, spacing: 0) {
                            stepperRow(label: "Max HR",
                                       value: Double(effectiveHrMax),
                                       display: hrMaxDisplay,
                                       range: 120...220, step: 1,
                                       set: { profile.hrMaxOverride = Int($0.rounded()) })
                            if profile.hrMaxOverride > 0 {
                                WMRule()
                                // Acts in place (clears the override and re-scores), so no disclosure.
                                WMNavRow(title: "Use the estimate for my age",
                                         hint: "Clears the override and estimates max heart rate from your age",
                                         titleColor: WM.Ground.inkSecondary,
                                         showsDisclosure: false) {
                                    profile.hrMaxOverride = 0
                                    root.rescoreAfterProfileChange()
                                }
                            }
                            WMRule()
                            Text(hrMaxNote)
                                .font(WMType.caption)
                                .foregroundStyle(WM.Ground.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, WM.Space.m)
                        }
                    }

                    Text("Effort, heart-rate zones and active calories are all computed from these. "
                         + "Changing them re-scores the days whose raw signal is still on the phone.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, WM.Space.l)
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
            }
        }
        // Re-score on the way out rather than on every step — a full pass per tap would be multi-second
        // work on the main path for a value the user is still adjusting.
        .onDisappear { root.rescoreAfterProfileChange() }
    }

    // MARK: - Rows

    private var sexBinding: Binding<String> {
        Binding(get: { profile.sex }, set: { profile.sex = $0 })
    }

    /// One labelled value between −/+ circle buttons (the Line language's amount control). Steps rather
    /// than a text field on purpose: every field here is a bounded physical quantity, and a keyboard
    /// invites an empty or nonsensical entry that would silently propagate into the scores.
    ///
    /// VoiceOver reads the row as ONE adjustable element — label, value, and swipe up/down to step — so
    /// the two buttons are not separate stops.
    private func stepperRow(label: String, value: Double, display: String,
                            range: ClosedRange<Double>, step: Double,
                            set: @escaping (Double) -> Void) -> some View {
        let increment = { set(min(range.upperBound, value + step)) }
        let decrement = { set(max(range.lowerBound, value - step)) }
        return HStack(spacing: WM.Space.m) {
            Text(label)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Spacer(minLength: WM.Space.s)
            StepCircle(systemName: "minus", enabled: value > range.lowerBound, action: decrement)
            Text(display)
                .font(WMType.numeral(20))
                .foregroundStyle(WM.Ground.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 64)
            StepCircle(systemName: "plus", enabled: value < range.upperBound, action: increment)
        }
        .padding(.vertical, WM.Space.s)
        .frame(minHeight: WM.Space.row + 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(display)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: increment()
            case .decrement: decrement()
            @unknown default: break
            }
        }
    }

    // MARK: - Display

    private var effectiveHrMax: Int { profile.hrMax }

    private var hrMaxDisplay: String {
        profile.hrMaxOverride > 0 ? "\(profile.hrMax) bpm" : "\(profile.hrMax) bpm · estimated"
    }

    private var hrMaxNote: String {
        profile.hrMaxOverride > 0
            ? "Using your own figure. This is the top of the range every Effort score and heart-rate zone "
              + "is measured against."
            : "Estimated from your age (Tanaka: 208 − 0.7 × age). If you know your real max from a lab or "
              + "field test, set it here — it moves every Effort score and zone boundary."
    }

    private var heightDisplay: String {
        guard isImperial else { return "\(Int(profile.heightCm.rounded())) cm" }
        let totalInches = Int((profile.heightCm / 2.54).rounded())
        return "\(totalInches / 12)′ \(totalInches % 12)″"
    }
}

extension ProfileScreen {
    /// "72.0 kg" / "159 lb" — the weight as this screen and Settings' "You" row both print it, so the
    /// two can never disagree about one number.
    static func weightText(kg: Double, imperial: Bool) -> String {
        imperial
            ? "\(Int((kg / 0.45359237).rounded())) lb"
            : "\(String(format: "%.1f", kg)) kg"
    }
}

/// A −/+ step control: a 36pt circle with a 1.5pt `track` ring and an ink glyph, whose hit region
/// reaches the HIG 44. Inert (tertiary glyph) at the end of its range.
private struct StepCircle: View {
    let systemName: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? WM.Ground.ink : WM.Ground.inkTertiary)
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(WM.Ground.track, lineWidth: 1.5))
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

#Preview("Profile — light") {
    ProfileScreenSpecimen().preferredColorScheme(.light)
}

#Preview("Profile — dark") {
    ProfileScreenSpecimen().preferredColorScheme(.dark)
}

private struct ProfileScreenSpecimen: View {
    private let root = AppRoot()

    var body: some View {
        ProfileScreen()
            .environmentObject(root)
            .environmentObject(root.profile)
    }
}
