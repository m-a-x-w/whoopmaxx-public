import SwiftUI
import UniformTypeIdentifiers

/// First run — three quiet steps on paper, shown once (`wm.onboarded` false, gated in
/// whoopmaxxApp): (1) wordmark + what-it-is, (2) pair the strap inline (skippable),
/// (3) offer the backup import — then land on today. No tour.
struct FirstRun: View {
    /// The launch gate's key — owned here, read by whoopmaxxApp to choose first-run vs AppShell.
    static let onboardedKey = "wm.onboarded"

    @AppStorage(FirstRun.onboardedKey) private var onboarded = false
    @State private var step: Step = .welcome

    private enum Step: Int, CaseIterable, Comparable {
        case welcome, pair, importHistory
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)

            stepDots
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, WM.Space.l)
        }
        .padding(.horizontal, WM.Space.gutter)
        .padding(.vertical, WM.Space.sectionLoose)
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
                    .fill(s == step ? WM.Ground.ink : WM.Ground.rule)
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

// MARK: - Step 1: wordmark + what it is

private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text("whoopmaxx")
                .font(WMType.display(44))
                .foregroundStyle(WM.Ground.ink)
                .padding(.bottom, WM.Space.l)

            Text("A standalone companion for your WHOOP strap. Everything is read, scored and stored on this iPhone — offline, no account, no cloud.")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, WM.Space.m)

            Text("Not affiliated with WHOOP, Inc.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)

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
            Text("Pair your strap")
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
                .padding(.bottom, WM.Space.l)

            // The same live flow the More → Pair sheet uses, inline. Its Done button (shown once
            // paired) continues; a strap-less user skips below.
            PairFlowLive(onDone: onContinue)

            Spacer()

            Button(action: onContinue) {
                Text("Skip for now")
                    .font(WMType.label)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
            Text("Bring your history")
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
                .padding(.bottom, WM.Space.l)

            switch importer.phase {
            case .idle, .failed:
                Text("Already have a backup? Import it (.wmbak) and every night, score and baseline carries over. You can also do this later under More.")
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
                .padding(.bottom, WM.Space.s)

                Button(action: onFinished) {
                    Text("Start fresh")
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
