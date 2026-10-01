#!/bin/bash
# Build the SwiftPM executable and wrap it in a real .app bundle: spyx.app.
#
# A bare `swift build` binary is not an application to macOS: it has no bundle
# identifier, so UNUserNotificationCenter throws on first use, the keychain
# can't remember an "Always Allow", Automation consent has no app name to
# show, and there is no Dock icon to find Settings from. This assembles
# spyx.app the way Xcode would, from the same build products. The Swift
# target is still called LidEffort; only the bundle says spyx. The bundle ID
# is lol.spyx.app (spyx.lol, reversed), which is what macOS keeps permissions, the keychain's
# Always Allow and the login item against.
#
#   script/bundle.sh            # Debug build → build/spyx.app
#   script/bundle.sh --release  # Release build
#   script/bundle.sh --run      # ...and (re)launch it
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug; RUN=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=release ;;
    --run) RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done

VERSION=$(sed -n 's/.*MARKETING_VERSION *= *"\([^"]*\)".*/\1/p' script/version.env 2>/dev/null || true)
VERSION=${VERSION:-0.3.0}
# The build number Sparkle compares, from the version alone — 1.2.3 is
# 10203 — so it rises with every release whichever checkout builds it.
BUILD_NUMBER=$(echo "$VERSION" | awk -F. '{ printf "%d", $1 * 10000 + $2 * 100 + $3 }')

swift build -c "$CONFIG"
PRODUCTS=".build/$CONFIG"
APP="build/spyx.app"
rm -rf "$APP"
# The bundle under its old name, so nothing launches the stale copy.
rm -rf build/LidEffort.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/LidEffort" "$APP/Contents/MacOS/spyx"
# Sparkle, where the binary looks for it.
mkdir -p "$APP/Contents/Frameworks"
cp -R "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/spyx" 2>/dev/null || true
# SwiftPM's Bundle.module looks for this beside the executable or in the
# app's Resources; the latter is where a bundle keeps it.
cp -R "$PRODUCTS/LidEffort_LidEffort.bundle" "$APP/Contents/Resources/"
# The open-source notices the licenses require to ship with the app.
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
[ -d "$PRODUCTS/swift-nio_NIOPosix.bundle" ] && cp -R "$PRODUCTS/swift-nio_NIOPosix.bundle" "$APP/Contents/Resources/"

# The app icon, from the catalogue's PNGs — already named the way iconutil wants.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
cp Sources/LidEffort/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>spyx</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>lol.spyx.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>spyx</string>
  <key>CFBundleDisplayName</key><string>spyx</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>spyx types /effort into the Terminal.app tab a Claude Code session is running in, so a lid gesture updates that session live.</string>
  <key>SUFeedURL</key><string>https://github.com/chrisnguyen1211/spyxdotlol/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>9+PPkW+iIsKvN+uBa6Ab15KmY/D2GYiWCXuAYUC2pGQ=</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Chris. Open-source notices: Settings → General → Acknowledgements.</string>
</dict></plist>
PLIST

# A stable identity keeps the keychain's "Always Allow" for Claude's OAuth
# token alive across rebuilds; ad-hoc gets a new identity every time.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
script/sign.sh "$APP" "${IDENTITY:--}"
echo "bundled: $APP (signed: ${IDENTITY:-ad-hoc})"

if [ "$RUN" = 1 ]; then
  pkill -x spyx 2>/dev/null || true
  pkill -x LidEffort 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi
