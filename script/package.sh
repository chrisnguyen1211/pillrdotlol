#!/bin/bash
# Build a release pillr.app and put it in a drag-to-Applications disk image.
#
#   script/package.sh
#       → build/pillr-<version>.dmg, signed with whatever identity
#         bundle.sh finds. Fine for your own Macs and testers; anyone else
#         gets Gatekeeper's "can't be verified" and has to use Open Anyway.
#
#   script/package.sh --styled
#       → the same disk image dressed: the film's sky behind the two icons,
#         a pixel arrow from pillr to Applications, a fixed window with no
#         toolbar, and pillr's icon on the volume. Finder lays it out, so the
#         first run asks once to let Terminal control Finder.
#
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=pillr script/package.sh
#       → signed with the hardened runtime, notarized and stapled: opens
#         with a double-click on any Mac. Create the profile once with
#         `xcrun notarytool store-credentials pillr`.
set -euo pipefail
cd "$(dirname "$0")/.."

STYLED=0
for arg in "$@"; do
  case "$arg" in
    --styled) STYLED=1 ;;
    *) echo "usage: script/package.sh [--styled]" >&2; exit 2 ;;
  esac
done

script/bundle.sh --release
APP="build/pillr.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

if [ -n "${DEVELOPER_ID:-}" ]; then
  script/sign.sh "$APP" "$DEVELOPER_ID" runtime
fi

STAGE=$(mktemp -d)/"pillr"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="build/pillr-$VERSION.dmg"
rm -f "$DMG"
if [ "$STYLED" = 1 ]; then
  script/dmg/style.sh "$STAGE" "$DMG"
else
  hdiutil create -quiet -volname "pillr" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
fi
rm -rf "$(dirname "$STAGE")"

if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo "packaged: $DMG"
shasum -a 256 "$DMG"
