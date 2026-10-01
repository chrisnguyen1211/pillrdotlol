#!/bin/bash
# Build, sign and publish: a DMG and the appcast that points every installed
# spyx at it, as one GitHub release of the public repository.
#
#   script/release.sh
#       → signed with the Apple Development identity bundle.sh finds, not
#         notarized. Downloads need Open Anyway once (see README → Install);
#         the identity stays the same from release to release, so macOS keeps
#         the permissions and keychain access it granted across updates.
#
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=spyx script/release.sh
#       → with an Apple Developer Program membership: hardened runtime,
#         notarized and stapled, opens with a double-click anywhere.
#
#   PUBLISH=1 script/release.sh
#       → and creates the GitHub release v<version> with both files.
#
# Installed copies read https://github.com/<repo>/releases/latest/download/appcast.xml
# (SUFeedURL in bundle.sh): the newest release's appcast, which names that
# release's DMG. Each release carries its own, so only the newest is listed —
# Sparkle only ever needs the newest.
#
# The update is signed with the EdDSA key generate_keys stored in the login
# keychain under the account "spyx.lol"; its public half is in Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=chrisnguyen1211/spyxdotlol

if [ -z "${DEVELOPER_ID:-}" ]; then
  echo "note: no DEVELOPER_ID — signing for development, not notarizing." >&2
fi

script/package.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/spyx.app/Contents/Info.plist)
OUT="release/$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "build/spyx-$VERSION.dmg" "$OUT/"

TOOLS=.build/artifacts/sparkle/Sparkle/bin
"$TOOLS/generate_appcast" --account spyx.lol \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  --maximum-versions 1 --maximum-deltas 0 \
  "$OUT/"
echo "release: $OUT/spyx-$VERSION.dmg + $OUT/appcast.xml"

if [ "${PUBLISH:-0}" = 1 ]; then
  gh release create "v$VERSION" "$OUT/spyx-$VERSION.dmg" "$OUT/appcast.xml" \
    --repo "$REPO" --title "spyx $VERSION" --notes-file - <<NOTES
Download **spyx-$VERSION.dmg**, open it and drag spyx onto Applications.
Not notarized yet: the first launch needs **System Settings → Privacy & Security → Open Anyway** (see the README's Install).
NOTES
  echo "published: https://github.com/$REPO/releases/tag/v$VERSION"
fi
