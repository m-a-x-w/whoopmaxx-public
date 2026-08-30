# LOG

Newest first. What changed, and what verified it.

## 2026-09-30: Redesign 037, phase 2 — every screen in "Line", and the Log-tab IA

Six file-owning agents rebuilt the screens on the phase 1 foundation, and one serialized gate followed
them. A read-only review of the combined diff then found about 60 problems, all fixed below. The full
contract, and every deviation from the mockups with its reason, is in the 037 plan doc (kept with the
private plan docs).

- **IA:** the tabs are now Today · Rest · Log · Live · Data. The More tab is gone:
  - Settings is a sheet (`SettingsScreen`) and Strap health a cover, both owned by `AppShell` and opened
    through `AppActions` (Today's settings button and strap chip; Live's strap row).
  - Breathe moved to Live, and Signal Lab, Body Clock and Health monitor to Data › Labs.
  - Journal tags, Insights, Weed, Intake and Habits moved to the new **Log** tab.
- **Today:**
  - The Charge hero sits on a line whose band is the IQR of the same 30-day window the baseline uses.
    Effort and Rest are `ScoreLine`s, dimmed when provisional.
  - Signals, the day rail (with intake dots) and Last workout, with an "All workouts" link.
  - Habits and Intake left for Log.
  - Every honesty state is kept, and the three scores render through one `TodayScores` view, which the
    Honesty gallery now shows too.
  - All derivation moved out of `body` into one `.task(id:)`.
- **Rest:**
  - The hero and the need line, a score line, the stage lanes, Timing, a new **Night detail** screen
    (movement, why you woke, wrist orientation, moved off the scroll with their gating), Tonight
    (bedtime and wake window), and Trend.
  - RestNight construction moved out of `body`.
- **Log:** quick add, the day rail, today's entries (each opening its response), tags, habits with
  streaks, and rows for Insights and Weed. `JournalScreen` split into `InsightsScreen` and
  `JournalTagsSection`.
- **Live:** bpm on a zone line, the stream, readouts, workouts, the strap block, and the Lock Screen
  switch. Breathe is now a horizontal breath line. New `StartWorkoutSheet`.
- **Data:** metric rows on lines (today inside each metric's own prior window, the same window as its
  delta), a domain filter and Labs. Metric detail is a line chart with a band.
- **Shared sheet parts:** header, amount stepper, search field and when-field live once in
  `App/Design/WMSheetChrome.swift`. They used to be built twice by parallel owners.
- **Review fixes:**
  - The tag stepper's hit areas no longer overlap.
  - Dynamic Type restored on the new controls.
  - 44pt targets and header traits.
  - SparkHistory speaks its latest value.
  - Dead code removed: `Sport.icon`, `IntakeVariant.symbol`, `overlineTracking`, `Radius.panel`,
    unused params.
  - About 60 stale comments across App, Core and Tests fixed to describe the new placement.
- **Debug flags:** `--tab log`, `--settings` (and the legacy `--tab more`), `--night-detail`, and
  `--journal` / `--weed` / `--intake`, which now land on Log.

Verified:
- `xcodegen generate` and a simulator build. The only warnings left are old ones in untouched Core
  files.
- The full suite: **1086 tests, 0 failures**, run twice.
- `DemoSeedTests.testSeedsWeedDaysAndSessions` failed once at 00:20 and passed on untouched main and
  on 3 of 3 re-runs here. It's a time-of-day flake in DemoSeed's anchor-day clamp, which this wave
  doesn't touch.
- iPhone 17 simulator screenshots of all 16 states (5 tabs, 6 pushed screens, Settings, Breathe,
  Signal Lab, the wake and honesty galleries) in light AND dark, checked against the approved
  mockups, plus the widget gallery.

Not done here:
- The widgets still use the old layouts on the new tokens (spec follow-up).
- `VitalBands.band` (StrapAnalytics) still folds history itself, one fold per vital per Health monitor
  derivation. Removing it needs a package API change.
- No device or real-strap check.

## 2026-09-29: Redesign 037, phase 1 — the "Line" foundation

The visual identity and IA were redesigned with the user on the design canvas (037).
This first step changes only the shared design system; every screen still has its old layout.

- `Shared/Design/Tokens.swift`: new paper/graphite grounds, a warmer ink scale (inkTertiary still
  ≥ 4.5:1 on ground in both themes), a new `track` surface tint, and new Charge / Effort / Rest hues.
  Gutter 24, section gap 40, and a `row` height of 48. `control` stays a mid tone in dark so the
  toggle thumb stays visible.
- `Shared/Design/Type.swift`: everything in SF Pro Rounded, light tabular numerals, and a 28 bold
  title. `.wmOverline()` keeps its name but becomes a sentence-case 13pt label, which restyles all
  69 section eyebrows at once.
- New components: `LineScale` (Shared), `HeroReadout` + `ScoreLine`, `TabHeader` + `WMIconButton` +
  `StrapChip`, `WMTextTabs`, `WMChip`, `Diverge`, and `WMSecondaryButton`.
- Restyled in place, with the same APIs (additive only):
  - `RuleSection`: no rule.
  - `WMNavRow`: trailing value, destructive title, optional chevron.
  - `WMSettingToggle`: one row.
  - `InkSegmentRow`: rounded segmented control.
  - `WMPrimaryButton`: 54pt capsule.
  - `WMBackLink`.
  - `InkTabBar` pill.
  - `TimelineStrip`: a 6pt day rail. HR intensity now darkens the rail itself instead of shading a band.
  - `StepHypnogram`: rounded lane blocks with connectors; awake drawn in the charge color.
  - `SparkHistory`: track band, 2pt line, ringed dot, no floor rule.
  - `BandChart`: line + track band, y axis fits the data, scrub resolution unchanged.
  - `StrapPanel`: a row block with a battery line.
  - `MetricWall`: hairline-split rows with an optional compact line.
- `App/Shell/AppActions.swift`: an environment seam so any screen can open the Settings sheet or
  the Strap health cover, which `AppShell` will own once the More tab is gone.

Verified: `xcodegen generate`, simulator build, and the full suite (1086 tests, 0 failures). Demo
seed screenshots on iPhone 17 show the new tokens, type, hypnogram and tab bar.

## 2026-09-29: TestFlight lane

Adds a second way to install the app besides the SideStore sideload: internal-only TestFlight, signed
with the personal paid team.

- `scripts/build-testflight.sh`: archives Release with `DEVELOPMENT_TEAM=$TEAM_ID` from the environment
  (`project.yml` keeps it empty), checks the archive, then exports it with `app-store-connect` / `upload`.
  The checks cover signing team, App Group and HealthKit entitlements, both privacy manifests, purpose
  strings, the encryption key and the build number. Export options are `testFlightInternalTestingOnly`
  and `manageAppVersionAndBuildNumber` NO, so project.yml stays the only version source.
- `App/Resources/PrivacyInfo.xcprivacy`: declares UserDefaults (CA92.1, 1C8F.1), file timestamps and
  size (C617.1 container, 3B52.1 the user-picked backup folder), system boot time (35F9.1,
  `Collector`'s uptime clock) and disk space (E174.1 VACUUM and restore gates, 85F4.1 the restore
  refusal names the free space). No tracking, no collected data.
- `Widgets/PrivacyInfo.xcprivacy`: UserDefaults (1C8F.1) only. The extension only touches the App
  Group suite.
- `project.yml`: adds `NSHealthShareUsageDescription`. It is never shown, but App Store Connect rejects
  a bare healthkit entitlement without it (ITMS-90683). Also adds `ITSAppUsesNonExemptEncryption: false`,
  since the app has no network code.
- The internal agent docs: the TestFlight command, the one-install-per-strap rule, and the rule to keep
  the manifests current.

Verified:
- `xcodegen generate` puts each manifest in its own target's Resources phase.
- `build-ipa.sh` still passes its entitlement check.
- The built bundles carry the right manifest byte-for-byte (`cmp`) and `plutil -lint` passes.
- The binaries' undefined symbols match the declared categories. The app has NSUserDefaults,
  NSFileModificationDate, NSFileSize and volumeAvailableCapacity; the widget has NSUserDefaults only.
- The simulator test suite passes.

Then verified for real: 1.9.0 (48) archived under the personal team. The script's archive checks
passed, the export passed App Store Connect's analysis (including its private-API scan), and the upload
succeeded. The first real run surfaced two setup steps:
- Xcode needs the Apple ID signed in (Settings > Accounts). Without it the run fails with "No Accounts".
- Command-line automatic signing registered both App IDs and turned App Groups on, but attached no
  group. The profiles came back with `application-groups: []` and the archive failed on the entitlement
  mismatch. The fix is in the developer portal: register `group.com.whoopmaxx.app` and tick it on both
  App IDs. This is now written up in the script header.
