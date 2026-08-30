#!/bin/sh
set -eu

# Package the sideload IPA — with its entitlements actually in it.
#
# Why this is a script and not a bare xcodebuild line: under CODE_SIGNING_ALLOWED=NO, Xcode skips
# ProcessProductPackaging entirely. No .xcent is generated and NO entitlements blob is embedded in
# either binary. AltStore decides what to request at install time from the entitlements it finds
# already on the app — so an artifact built that way asks for nothing and is granted nothing, and the
# App Group silently disappears. That failure is invisible from the inside: UserDefaults(suiteName:)
# still returns a working object, just a PRIVATE per-process one, so the widget's writes and the app's
# reads land in different stores and both succeed. The ad-hoc signing pass below is what puts the
# entitlements into the artifact so the installer can carry them across.
#
# Ad-hoc (`--sign -`) is sufficient: the signature itself is thrown away and replaced at install. Only
# the entitlements need to survive the handoff, and those are the entire point.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DERIVED=${DERIVED_DATA:-$ROOT/dist/dd}
OUT=${OUT_IPA:-$HOME/Downloads/whoopmaxx.ipa}
APP="$DERIVED/Build/Products/Release-iphoneos/whoopmaxx.app"
APPEX="$APP/PlugIns/whoopmaxxWidgets.appex"

echo "==> building Release (unsigned)"
xcodebuild -project "$ROOT/whoopmaxx.xcodeproj" -scheme whoopmaxx -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

[ -d "$APP" ]   || { echo "no app at $APP" >&2; exit 1; }
[ -d "$APPEX" ] || { echo "no widget extension at $APPEX" >&2; exit 1; }

# Take the group id from what the build actually stamped into Info.plist, so the entitlement can never
# drift from the id the running code reads.
GROUP=$(plutil -extract AppGroupIdentifier raw "$APP/Info.plist")
WIDGET_GROUP=$(plutil -extract AppGroupIdentifier raw "$APPEX/Info.plist")
[ "$GROUP" = "$WIDGET_GROUP" ] || {
    echo "app and widget declare different groups: '$GROUP' vs '$WIDGET_GROUP'" >&2; exit 1; }
echo "==> app group: $GROUP"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
sed "s|\$(APP_GROUP_ID)|$GROUP|g" "$ROOT/App/Resources/whoopmaxx.entitlements"    > "$STAGE/app.entitlements"
sed "s|\$(APP_GROUP_ID)|$GROUP|g" "$ROOT/Widgets/whoopmaxxWidgets.entitlements"   > "$STAGE/widgets.entitlements"

# Nested code first, then the outer app: signing the app seals the extension as it stands at that moment.
echo "==> ad-hoc signing entitlements into the artifact"
codesign --force --sign - --entitlements "$STAGE/widgets.entitlements" "$APPEX"
codesign --force --sign - --entitlements "$STAGE/app.entitlements" "$APP"

# Prove the entitlement landed instead of assuming it did — a silent miss here IS the bug this script
# exists to prevent, and it costs nothing to check.
for target in "$APP" "$APPEX"; do
    codesign -d --entitlements - --xml "$target" 2>/dev/null | grep -q "$GROUP" || {
        echo "FAILED: '$GROUP' not present in the signed entitlements of $target" >&2; exit 1; }
done
echo "==> entitlements verified on both binaries"

mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/whoopmaxx.app"
rm -f "$OUT"
(cd "$STAGE" && zip -qry "$OUT" Payload)
echo "==> $OUT"
echo "    unsigned — AltStore signs it at install."
