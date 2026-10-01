#!/bin/bash
# Build a release spyx.app and put it in a drag-to-Applications disk image.
#
#   script/package.sh
#       → build/spyx-<version>.dmg, signed with whatever identity
#         bundle.sh finds. Fine for your own Macs and testers; anyone else
#         gets Gatekeeper's "can't be verified" and has to use Open Anyway.
#
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=spyx script/package.sh
#       → signed with the hardened runtime, notarized and stapled: opens
#         with a double-click on any Mac. Create the profile once with
#         `xcrun notarytool store-credentials spyx`.
set -euo pipefail
cd "$(dirname "$0")/.."

script/bundle.sh --release
APP="build/spyx.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

if [ -n "${DEVELOPER_ID:-}" ]; then
  script/sign.sh "$APP" "$DEVELOPER_ID" runtime
fi

STAGE=$(mktemp -d)/"spyx"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="build/spyx-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "spyx" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
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
