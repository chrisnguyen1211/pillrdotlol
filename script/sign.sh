#!/bin/bash
# Sign pillr.app inside-out: Sparkle's helpers first, then Sparkle, then the
# app — the order Sparkle documents, and the one notarization accepts.
# `codesign --deep` signs nested code with the app's options, which gives
# Sparkle's Downloader the wrong entitlements.
#
#   script/sign.sh <app> <identity>            # Apple Development or ad-hoc
#   script/sign.sh <app> <identity> runtime    # Developer ID: + secure timestamp
#
# Always with the hardened runtime, whatever the identity. pillr holds
# Accessibility, Automation of Terminal and the keychain's Always Allow for
# other apps' logins; without the runtime, dyld loads any library named in
# DYLD_INSERT_LIBRARIES into it, and that library would hold them too.
set -euo pipefail
APP="$1"; IDENTITY="$2"; MODE="${3:-}"
OPTS=(--force --sign "$IDENTITY" --options runtime)
if [ "$MODE" = runtime ]; then OPTS+=(--timestamp); fi

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
# Refuse to hand on an app without the runtime — the release must not
# quietly regress to one.
FLAGS=$(codesign -dv "$APP" 2>&1)
case "$FLAGS" in *"flags="*"runtime"*) ;; *) echo "sign: $APP lacks the hardened runtime" >&2; exit 1 ;; esac
