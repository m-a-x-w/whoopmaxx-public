import SwiftUI

/// The user's own body metrics — age, sex, weight, height, and an optional max-HR override.
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

                    RuleSection("Body", topGap: WM.Space.section) {
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
                                       display: weightDisplay,
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

                    RuleSection("Max heart rate", topGap: WM.Space.section) {
                        VStack(alignment: .leading, spacing: 0) {
                            stepperRow(label: "Max HR",
                                       value: Double(effectiveHrMax),
                                       display: hrMaxDisplay,
                                       range: 120...220, step: 1,
                                       set: { profile.hrMaxOverride = Int($0.rounded()) })
                            if profile.hrMaxOverride > 0 {
                                WMRule()
                                Button {
                                    profile.hrMaxOverride = 0
                                    root.rescoreAfterProfileChange()
                                } label: {
                                    Text("Use the estimate for my age")
                                        .font(WMType.body)
                                        .foregroundStyle(WM.Ground.inkSecondary)
                                        .padding(.vertical, WM.Space.m)
                                }
                                .accessibilityHint("Clears the override and estimates max heart rate from your age")
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
        // Re-score on the way out rather than on every stepper tick — a full pass per tap would be
        // multi-second work on the main path for a value the user is still adjusting.
        .onDisappear { root.rescoreAfterProfileChange() }
    }

    // MARK: - Rows

    private var sexBinding: Binding<String> {
        Binding(get: { profile.sex }, set: { profile.sex = $0 })
    }

    /// One labelled value with −/+ controls. A stepper rather than a text field on purpose: every field
    /// here is a bounded physical quantity, and a keyboard invites an empty or nonsensical entry that
    /// would silently propagate into the scores.
    @ViewBuilder
    private func stepperRow(label: String, value: Double, display: String,
                            range: ClosedRange<Double>, step: Double,
                            set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Spacer()
            Text(display)
                .font(WMType.numeral(20))
                .foregroundStyle(WM.Ground.ink)
                .monospacedDigit()
            Stepper(label) {
                set(min(range.upperBound, value + step))
            } onDecrement: {
                set(max(range.lowerBound, value - step))
            }
            .labelsHidden()
        }
        .padding(.vertical, WM.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(display)")
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

    private var weightDisplay: String {
        isImperial
            ? "\(Int((profile.weightKg / 0.45359237).rounded())) lb"
            : "\(String(format: "%.1f", profile.weightKg)) kg"
    }

    private var heightDisplay: String {
        guard isImperial else { return "\(Int(profile.heightCm.rounded())) cm" }
        let totalInches = Int((profile.heightCm / 2.54).rounded())
        return "\(totalInches / 12)′ \(totalInches % 12)″"
    }
}
