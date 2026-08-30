import SwiftUI
import UniformTypeIdentifiers

/// First run — three quiet steps on paper, shown once (`wm.onboarded` false, gated in
/// whoopmaxxApp): (1) what it is, (2) pair the strap inline (skippable), (3) offer the backup import —
/// then land on Today. No tour.
///
/// Layout (037, the Pair board): the wordmark on the top line with three step dots trailing, the
/// step's 34pt bold title and one-line instruction well below it, the step's own content, its actions at
/// the foot, and the WHOOP disclaimer under everything.
struct FirstRun: View {
    /// The launch gate's key — owned here, read by whoopmaxxApp to choose first-run vs AppShell.
    static let onboardedKey = "wm.onboarded"

    /// The step title (and the Relaunch wall's): SF Pro Rounded Bold, 34pt at the default size, riding
    /// `.largeTitle` so it follows Dynamic Type like the other text roles.
    static let titleFont: Font = .system(.largeTitle, design: .rounded, weight: .bold)

    @AppStorage(FirstRun.onboardedKey) private var onboarded = false
    @State private var step: Step = .welcome

    private enum Step: Int, CaseIterable, Comparable {
        case welcome, pair, importHistory
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                WMWordmark()
                Spacer(minLength: WM.Space.s)
                stepDots
            }
            .padding(.top, WM.Space.l)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, WM.Space.sectionLoose + WM.Space.m)
                .transition(.opacity)

            Text("Not affiliated with WHOOP, Inc.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, WM.Space.s)
        }
        .padding(.horizontal, WM.Space.gutter)
        .padding(.bottom, WM.Space.l)
        .background(WM.Ground.ground.ignoresSafeArea())
        .wmAnimation(WMMotion.transition, value: step)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:       WelcomeStep { step = .pair }
        case .pair:          PairStep(onContinue: { step = .importHistory })
        case .importHistory: ImportStep(onFinished: finish)
        }
    }

    /// Three ink dots, one per step — quiet progress, no labels.
    private var stepDots: some View {
        HStack(spacing: WM.Space.s) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == step ? WM.Ground.ink : WM.Ground.track)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private func finish() {
        onboarded = true   // whoopmaxxApp flips to AppShell → today
    }
}

/// The app's name as a mark: 17pt heavy rounded ink. The top line of the full-window screens that stand
/// outside the tab shell — First Run and the Relaunch wall.
struct WMWordmark: View {
    var body: some View {
        Text("whoopmaxx")
            .font(.system(size: 17, weight: .heavy, design: .rounded))
            .foregroundStyle(WM.Ground.ink)
    }
}

/// A step's heading: the 34pt title (a VoiceOver header) and, when given, its one-line instruction.
private struct StepHeading: View {
    let title: String
    var line: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text(title)
                .font(FirstRun.titleFont)
                .foregroundStyle(WM.Ground.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let line {
                Text(line)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Step 1: what it is

private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(title: "Welcome",
                        line: "A standalone companion for your WHOOP strap. Everything is read, scored and stored on this iPhone — offline, no account, no cloud.")

            Spacer()

            WMPrimaryButton("Continue", action: onContinue)
        }
    }
}

// MARK: - Step 2: pair inline (skippable)

private struct PairStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(title: "Pair your strap", line: PairFlow.instruction)

            // The same live flow the Settings pair sheet uses, inline. Its Done button (shown once
            // paired) continues; a strap-less user skips below.
            PairFlowLive(onDone: onContinue)
                .padding(.top, WM.Space.section)

            Spacer(minLength: WM.Space.l)

            WMSecondaryButton("Skip for now", action: onContinue)
        }
    }
}

// MARK: - Step 3: backup import offer

private struct ImportStep: View {
    let onFinished: () -> Void

    @EnvironmentObject private var root: AppRoot
    @StateObject private var importer = BackupImportRunner()
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(title: "Bring your history")
                .padding(.bottom, WM.Space.s)

            switch importer.phase {
            case .idle, .failed:
                Text("Already have a backup? Import it (.wmbak) and every night, score and baseline carries over. You can also do this later in Settings.")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .failed(let message) = importer.phase {
                    Text(message)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, WM.Space.m)
                }

                Spacer()

                WMPrimaryButton(importer.phase == .idle ? "Import backup" : "Try again") {
                    showPicker = true
                }
                .padding(.bottom, WM.Space.xs)

                WMSecondaryButton("Start fresh", action: onFinished)

            case .importing:
                Text("Importing your history…")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                Text("This can take a little while for a big library. Keep whoopmaxx open.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .padding(.top, WM.Space.s)
                Spacer()

            case .needsRelaunch:
                // No "Finish" button here any more. Continuing into the shell was the bug: the store
                // handles still point at the inode Gate 6 deleted, so everything the user did next was
                // written into a ghost file and thrown away by the relaunch. `RelaunchWall` takes the
                // whole window over on this edge (see the `.onChange` below); this copy is the brief
                // moment before it does.
                Text("Your history is in.")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                Text(BackupImportRunner.relaunchInstruction)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WM.Space.s)
                Spacer()

            case .imported:
                Text("History imported.")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                Spacer()
                WMPrimaryButton("Continue", action: onFinished)
            }
        }
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: BackupImportRunner.allowedTypes) { result in
            importer.handle(result)
        }
        .onChange(of: importer.phase) { _, phase in
            guard phase == .needsRelaunch else { return }
            // Record the onboarding gate NOW rather than on a tap, so the relaunch lands in the shell
            // instead of replaying first run — the user restored a history, they are not a new user.
            // Then hand the window to `RelaunchWall`: this process must not touch the store again.
            onFinished()
            root.markStoreSwapped()
        }
    }
}

// MARK: - Previews

#Preview("First run — light") {
    FirstRunSpecimen().preferredColorScheme(.light)
}

#Preview("First run — dark") {
    FirstRunSpecimen().preferredColorScheme(.dark)
}

private struct FirstRunSpecimen: View {
    private let root = AppRoot()

    var body: some View {
        FirstRun()
            .environmentObject(root)
            .environmentObject(root.live)
    }
}
