#!/bin/sh
set -eu

# Archive a signed Release build and upload it to App Store Connect for TestFlight INTERNAL testing.
#
# Signing and upload both go through the Apple ID signed into Xcode (Settings > Accounts). The team id
# comes from the environment, never from project.yml: the repo is public and DEVELOPMENT_TEAM stays
# empty there on purpose. With several accounts signed in, TEAM_ID is also what picks the right one.
#
#   TEAM_ID=XXXXXXXXXX ./scripts/build-testflight.sh
#
# One-time portal setup that command-line signing will NOT do: it registers both App IDs and turns the App
# Groups capability on, but attaches no group, so the archive fails with "Provisioning profile ... doesn't
# match the entitlements file's value for the com.apple.security.application-groups entitlement". Register
# the group under Identifiers and tick it on BOTH com.whoopmaxx.app and com.whoopmaxx.app.widgets. The
# upload also needs an App Store Connect app record for com.whoopmaxx.app to exist first.
#
# Export choices, each on purpose:
# - testFlightInternalTestingOnly: the build can never reach external testers or the App Store. Both of
#   those go through App Review, which an app built on a third-party strap's protocol is not made to pass.
# - manageAppVersionAndBuildNumber NO: project.yml is the single source for version and build. Letting
#   Xcode bump the number at upload would ship a build that disagrees with the tree. Every upload needs a
#   CURRENT_PROJECT_VERSION App Store Connect has not seen yet, and it refuses a repeat loudly.
#
# One install per strap: a TestFlight build and a SideStore build are separate apps on the phone, and both
# are Release builds carrying WM_HISTORY_AUTHORITY (BuildPolicy.swift). Two of them connected to the same
# strap race to ack its history, and the loser never sees those nights. Keep exactly one installed.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEAM=${TEAM_ID:?set TEAM_ID to your personal team id (developer.apple.com > Account > Membership details)}
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$ROOT/project.yml")
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' "$ROOT/project.yml")
DERIVED=${DERIVED_DATA:-$ROOT/dist/dd}
# One fixed path, replaced every run: the symbols go up with the build (uploadSymbols), so App Store
# Connect symbolicates TestFlight crashes itself and older archives would only pile up in dist/.
ARCHIVE="$ROOT/dist/whoopmaxx-testflight.xcarchive"
APP="$ARCHIVE/Products/Applications/whoopmaxx.app"
APPEX="$APP/PlugIns/whoopmaxxWidgets.appex"

echo "==> archiving whoopmaxx $VERSION ($BUILD) for team $TEAM"
rm -rf "$ARCHIVE"
xcodebuild -project "$ROOT/whoopmaxx.xcodeproj" -scheme whoopmaxx -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" archive

[ -d "$APP" ]   || { echo "no app at $APP" >&2; exit 1; }
[ -d "$APPEX" ] || { echo "no widget extension at $APPEX" >&2; exit 1; }

# Check the archive before it leaves the machine: App Store Connect reports each of these only after a
# full upload and processing, one rejection email at a time.
fail() { echo "FAILED: $*" >&2; exit 1; }

GROUP=$(plutil -extract AppGroupIdentifier raw "$APP/Info.plist")
for target in "$APP" "$APPEX"; do
    codesign -dv "$target" 2>&1 | grep -q "^TeamIdentifier=$TEAM\$" || fail "$target is not signed by team $TEAM"
    codesign -d --entitlements - --xml "$target" 2>/dev/null | grep -q "$GROUP" \
        || fail "'$GROUP' not in the signed entitlements of $target"
    [ -f "$target/PrivacyInfo.xcprivacy" ] || fail "no PrivacyInfo.xcprivacy in $target (ITMS-91053)"
    [ "$(plutil -extract CFBundleVersion raw "$target/Info.plist")" = "$BUILD" ] \
        || fail "$target CFBundleVersion is not $BUILD"
done
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.developer.healthkit" \
    || fail "HealthKit entitlement missing from the app signature"
for key in NSHealthShareUsageDescription NSHealthUpdateUsageDescription NSBluetoothAlwaysUsageDescription; do
    plutil -extract "$key" raw "$APP/Info.plist" >/dev/null 2>&1 || fail "$key missing from Info.plist (ITMS-90683)"
done
[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw "$APP/Info.plist")" = "false" ] \
    || fail "ITSAppUsesNonExemptEncryption is not false"
echo "==> archive verified: team, App Group, HealthKit, privacy manifests, purpose strings, build $BUILD"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cat > "$STAGE/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>testFlightInternalTestingOnly</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

echo "==> uploading to App Store Connect"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$STAGE/ExportOptions.plist" \
    -exportPath "$STAGE/export" -allowProvisioningUpdates

echo "==> uploaded whoopmaxx $VERSION ($BUILD)"
echo "    It appears in TestFlight once App Store Connect finishes processing (usually minutes)."
echo "    Archive left at $ARCHIVE until the next run."
