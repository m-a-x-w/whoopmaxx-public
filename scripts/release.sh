#!/bin/sh
set -eu

# Cut a sideload release: build the IPA, attach it to a GitHub release, and prepend it to the
# SideStore/AltStore manifest.
#
# The manifest lives on the ORPHAN `source` branch, not in the tree: publishing rewrites `main`
# wholesale, so a source.json committed there would need a full re-publish for every release. An
# orphan branch is untouched by that, and raw.githubusercontent serves it over HTTPS with no Pages
# setup:  https://raw.githubusercontent.com/<repo>/source/source.json
#
# Version and build come from project.yml, the single source for both (never hand-edited plists).
#
# ORDER MATTERS: publish the snapshot to the repo's `main` FIRST, then run this — the release tag
# is cut against `main`, so releasing before publishing tags a tree that lacks the code it ships.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${REPO:-m-a-x-w/whoopmaxx-public}
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$ROOT/project.yml")
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' "$ROOT/project.yml")
TAG="v$VERSION-$BUILD"
NOTES=${NOTES:-"whoopmaxx $VERSION ($BUILD)"}
IPA="$ROOT/dist/whoopmaxx-$VERSION-$BUILD.ipa"

# SideStore only offers an update when the build number actually climbs, so a re-used tag is a
# silent no-update rather than a loud failure. Refuse it here instead.
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "$TAG already released — bump CURRENT_PROJECT_VERSION in project.yml first" >&2
    exit 1
fi

# build-ipa.sh is the only sanctioned packaging path: it ad-hoc signs the App Group entitlement
# into the artifact, which a bare unsigned build silently omits.
mkdir -p "$ROOT/dist"
OUT_IPA="$IPA" "$ROOT/scripts/build-ipa.sh"

gh release create "$TAG" "$IPA" -R "$REPO" --target main \
    --title "whoopmaxx $VERSION ($BUILD)" --notes "$NOTES"

DATE=$(gh release view "$TAG" -R "$REPO" --json publishedAt --jq .publishedAt)
URL=$(gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[0].url')

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git clone --depth 1 --branch source "https://github.com/$REPO.git" "$WORK" -q
IPA="$IPA" VERSION="$VERSION" BUILD="$BUILD" DATE="$DATE" URL="$URL" NOTES="$NOTES" \
python3 - "$WORK/source.json" <<'PY'
import hashlib, json, os, sys, pathlib

path = pathlib.Path(sys.argv[1])
src = json.loads(path.read_text())
data = pathlib.Path(os.environ["IPA"]).read_bytes()
app = src["apps"][0]
# Newest first — SideStore installs the first entry the device qualifies for.
app["versions"] = [{
    "version": os.environ["VERSION"],
    "buildVersion": os.environ["BUILD"],
    "date": os.environ["DATE"],
    "localizedDescription": os.environ["NOTES"],
    "downloadURL": os.environ["URL"],
    "size": len(data),
    "sha256": hashlib.sha256(data).hexdigest(),
    "minOSVersion": "26.0",
}] + [v for v in app["versions"] if v["buildVersion"] != os.environ["BUILD"]]
path.write_text(json.dumps(src, indent=2) + "\n")
PY

git -C "$WORK" commit -qam "source: $VERSION ($BUILD)" \
    --author="Max Weinstein <102370987+m-a-x-w@users.noreply.github.com>"
git -C "$WORK" push -q origin source

echo "==> released $TAG"
echo "    source: https://raw.githubusercontent.com/$REPO/source/source.json"
