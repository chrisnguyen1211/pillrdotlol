# Releasing pillr

## Once

Without an Apple Developer Program membership, skip steps 1 and 2: releases
are signed with the Apple Development identity `bundle.sh` finds (free with
any Apple ID in Xcode → Settings → Accounts), not notarized, and a download
needs Open Anyway once. Keep signing with that same identity — it is what
lets macOS keep a user's permissions across updates.

1. **Developer ID certificate.** In your Apple Developer account, create a
   "Developer ID Application" certificate and install it in the login
   keychain. `security find-identity -v -p codesigning` lists its name.
2. **Notary credentials.** Stored once in the keychain as the profile `pillr` —
   see [Notarization](#notarization).
3. **Back up the update signing key.** Sparkle updates are signed with an
   EdDSA key kept in the login keychain under the account `pillr`; its
   public half is `SUPublicEDKey` in `script/bundle.sh`. Lose the private key
   and installed copies can never be updated again. Export it to a password
   manager or an encrypted backup:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account pillr -x pillr-sparkle-key.txt
   ```

   Then delete the exported file from disk — or keep it only inside an
   encrypted disk image whose password is in your password manager:

   ```bash
   hdiutil create -encryption AES-256 -fs APFS -volname pillr-sparkle-key -srcfolder <folder holding the key> pillr-sparkle-key-backup.dmg
   ```

## Each release

1. Bump `MARKETING_VERSION` in `script/version.env` and add a matching entry
   at the top of `ReleaseNotes.all` in `Sources/LidEffort/Settings/ReleaseNotes.swift`.
2. `swift test`
3. Build, sign (and notarize, with a Developer ID), write the appcast and
   publish the GitHub release:

   ```bash
   PUBLISH=1 script/release.sh
   ```

   Add `STYLED=1` for the dressed disk image — a background with an arrow
   from pillr to Applications (see `script/dmg/README.md`).

   or, with a Developer ID, notarized:

   ```bash
   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=pillr PUBLISH=1 script/release.sh
   ```

4. That creates the release `v<version>` on
   [chrisnguyen1211/pillrdotlol](https://github.com/chrisnguyen1211/pillrdotlol/releases)
   with `pillr-<version>.dmg` and `appcast.xml`. Installed copies read
   `releases/latest/download/appcast.xml`, so the newest release is the feed:
   never mark an older one "latest", and never delete the newest's appcast.
5. Install the DMG on a clean Mac (or a new user account) and check: it opens
   (after Open Anyway, if not notarized), the notch appears, Settings → General →
   Check Now reports "up to date", and an approval from Claude Code reaches
   the notch.

## Notarization

Notarizing needs an Apple Developer Program membership and the Developer ID
certificate from step 1 above. Without it, everything else in this file works
and releases simply stay un-notarized.

**Once: store the notary credentials.** Create an app-specific password at
[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security →
App-Specific Passwords, then:

```bash
xcrun notarytool store-credentials pillr \
  --apple-id you@example.com \
  --team-id TEAMID
```

`notarytool` prompts for the app-specific password and keeps it in the login
keychain under the profile name `pillr`. The team ID is the ten characters in
parentheses after your name in `security find-identity -v -p codesigning`.
Check the profile with `xcrun notarytool history --keychain-profile pillr`.

**Each release: set two variables.** `script/package.sh` (which
`script/release.sh` runs) reads exactly these:

| Variable | Value | Effect |
|---|---|---|
| `DEVELOPER_ID` | `Developer ID Application: Your Name (TEAMID)` | Signs the app (Sparkle's helpers first) and the DMG with a secure timestamp |
| `NOTARY_PROFILE` | `pillr` | Submits the DMG with `xcrun notarytool submit --keychain-profile "$NOTARY_PROFILE" --wait`, then staples the ticket with `xcrun stapler staple` |

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=pillr PUBLISH=1 script/release.sh
```

Without `DEVELOPER_ID` nothing is notarized, whatever `NOTARY_PROFILE` says;
with `DEVELOPER_ID` but no `NOTARY_PROFILE` the build is Developer ID–signed but
not notarized. A rejected submission stops the script; read Apple's reasons with
`xcrun notarytool log <submission-id> --keychain-profile pillr`. Verify a
finished DMG with `spctl -a -t open --context context:primary-signature -v build/pillr-<version>.dmg`
and `xcrun stapler validate build/pillr-<version>.dmg`.

**What changes for users.**

- New downloads open with a double-click: no "Apple could not verify" message
  and no trip to Privacy & Security → Open Anyway. Remove the Open Anyway
  instructions from `README.md` (Install, FAQ), `site/index.html`, and the
  release notes text in `script/release.sh`.
- Installed copies update through Sparkle as before: the update is still
  checked against the same EdDSA key.
- The first notarized release is signed by a different identity (Developer ID
  instead of Apple Development). macOS ties Accessibility, Automation and the
  keychain's "Always Allow" to the signing identity, so people updating from
  an earlier build may be asked for these once more. Say so in that release's
  notes. Keep signing with the same Developer ID afterwards.

## What users keep across updates

Settings live in the `lol.pillr.app` defaults domain. Builds before 1.0 used
`dev.lideffort`; the first launch of 1.0 copies those settings across once
(`Preferences.migrateFromPreviousDomain`). Accessibility, Automation and the
keychain's "Always Allow" are granted per bundle id, so testers moving from a
pre-1.0 build are asked for them once more.
