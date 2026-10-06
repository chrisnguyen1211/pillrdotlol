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

# What's new, written by hand in release-notes/<version>.md: shown in
# Sparkle's update window (as spyx-<version>.html beside the DMG, which
# generate_appcast embeds) and on the GitHub release.
NOTES_MD="release-notes/$VERSION.md"
if [ -f "$NOTES_MD" ]; then
  python3 - "$NOTES_MD" "$OUT/spyx-$VERSION.html" <<'PY'
import html, re, sys
src, dst = sys.argv[1], sys.argv[2]
out, in_list = [], False
def inline(t):
    t = html.escape(t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"`(.+?)`", r"<code>\1</code>", t)
    return t
for line in open(src, encoding="utf-8").read().splitlines():
    if line.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        out.append("<li>" + inline(line[2:]) + "</li>"); continue
    if in_list: out.append("</ul>"); in_list = False
    if line.startswith("## "): out.append("<h3>" + inline(line[3:]) + "</h3>")
    elif line.startswith("# "): out.append("<h2>" + inline(line[2:]) + "</h2>")
    elif line.strip(): out.append("<p>" + inline(line) + "</p>")
if in_list: out.append("</ul>")
style = "body{font:13px -apple-system,sans-serif;margin:12px}code{font-size:12px}"
open(dst, "w", encoding="utf-8").write("<!doctype html><meta charset=utf-8><style>" + style + "</style>" + "\n".join(out))
PY
else
  echo "note: no $NOTES_MD — the update window will show no notes." >&2
fi

TOOLS=.build/artifacts/sparkle/Sparkle/bin
"$TOOLS/generate_appcast" --account spyx.lol \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  --maximum-versions 1 --maximum-deltas 0 \
  "$OUT/"
echo "release: $OUT/spyx-$VERSION.dmg + $OUT/appcast.xml"

if [ "${PUBLISH:-0}" = 1 ]; then
  if [ -n "${DEVELOPER_ID:-}" ]; then
    OPEN_NOTE="Notarized by Apple: it opens with a double-click."
  else
    OPEN_NOTE="Not notarized yet: the first launch needs **System Settings → Privacy & Security → Open Anyway** (see the README's Install)."
  fi
  {
    [ -f "$NOTES_MD" ] && cat "$NOTES_MD" && echo
    echo "---"
    echo "**Install:** download **spyx-$VERSION.dmg**, open it and drag spyx onto Applications. $OPEN_NOTE"
    echo "Already installed? spyx updates itself — your settings and permissions are kept."
  } | gh release create "v$VERSION" "$OUT/spyx-$VERSION.dmg" "$OUT/appcast.xml" \
    --repo "$REPO" --title "spyx $VERSION" --notes-file -
  echo "published: https://github.com/$REPO/releases/tag/v$VERSION"
fi
