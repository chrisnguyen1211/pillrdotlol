#!/bin/bash
# A dressed disk image from a staged folder (pillr.app beside an Applications
# link): the background in .background, the window sized to it, the icons
# where the background's arrow expects them, the volume wearing pillr's icon.
#
#   script/dmg/style.sh <staged folder> <output .dmg>
#
# Finder writes the layout into the image's .DS_Store, so this asks Finder
# over Apple Events — macOS asks once whether Terminal may control Finder.
# The positions match `DMG_ICONS` in the film project's DmgBackground.tsx,
# which draws background.tiff (720 × 405 points, 1× and 2× in one file).
set -euo pipefail
cd "$(dirname "$0")/../.."

STAGE="$1"
OUT="$2"
HERE="script/dmg"
WIDTH=720
HEIGHT=405
ICON=128
TITLEBAR=32

mkdir -p "$STAGE/.background"
cp "$HERE/background.tiff" "$STAGE/.background/background.tiff"
if [ -f "$STAGE/pillr.app/Contents/Resources/AppIcon.icns" ]; then
  cp "$STAGE/pillr.app/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
fi

WORK=$(mktemp -d)
RW="$WORK/rw.dmg"
# Laid out under its final name: Finder's link to the background names the
# volume, and a rename afterwards leaves the window with no picture. So an
# open "pillr" volume — an older image, say — has to be ejected first.
NAME="pillr"
if [ -d "/Volumes/$NAME" ]; then
  echo "style: a volume named $NAME is already open — eject it first" >&2
  exit 1
fi
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$RW"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1}')
MOUNT="/Volumes/$NAME"
trap 'hdiutil detach -quiet "$DEVICE" 2>/dev/null || true; rm -rf "$WORK"' EXIT

[ -f "$MOUNT/.VolumeIcon.icns" ] && SetFile -a C "$MOUNT"
SetFile -a V "$MOUNT/.background"

osascript <<OSA
tell application "Finder"
  tell disk "$NAME"
    open
    set win to container window
    set current view of win to icon view
    set toolbar visible of win to false
    set statusbar visible of win to false
    set pathbar visible of win to false
    set sidebar width of win to 0
    -- Finder's bounds take in the title bar; the picture is the content.
    set bounds of win to {200, 120, 200 + $WIDTH, 120 + $HEIGHT + $TITLEBAR}
    set opts to icon view options of win
    set arrangement of opts to not arranged
    set icon size of opts to $ICON
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "pillr.app" of win to {190, 195}
    set position of item "Applications" of win to {530, 195}
    update without registering applications
    delay 1
    close
    open
    delay 1
    close
  end tell
end tell
OSA

sync
hdiutil detach -quiet "$DEVICE"
trap 'rm -rf "$WORK"' EXIT
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT"
echo "styled: $OUT"
