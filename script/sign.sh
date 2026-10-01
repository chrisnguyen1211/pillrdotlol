#!/bin/bash
# Sign spyx.app inside-out: Sparkle's helpers first, then Sparkle, then the
# app — the order Sparkle documents, and the one notarization accepts.
# `codesign --deep` signs nested code with the app's options, which gives
# Sparkle's Downloader the wrong entitlements.
#
#   script/sign.sh <app> <identity>            # development
#   script/sign.sh <app> <identity> runtime    # Developer ID: hardened runtime + timestamp
set -euo pipefail
APP="$1"; IDENTITY="$2"; MODE="${3:-}"
OPTS=(--force --sign "$IDENTITY")
if [ "$MODE" = runtime ]; then OPTS+=(--options runtime --timestamp); fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  B="$SPARKLE/Versions/B"
  codesign "${OPTS[@]}" "$B/XPCServices/Installer.xpc"
  codesign "${OPTS[@]}" --preserve-metadata=entitlements "$B/XPCServices/Downloader.xpc"
  codesign "${OPTS[@]}" "$B/Autoupdate"
  codesign "${OPTS[@]}" "$B/Updater.app"
  codesign "${OPTS[@]}" "$SPARKLE"
fi
codesign "${OPTS[@]}" --entitlements "$(dirname "$0")/LidEffort.entitlements" "$APP"
codesign --verify --strict --deep "$APP"
