# Releasing spyx

## Once

Without an Apple Developer Program membership, skip steps 1 and 2: releases
are signed with the Apple Development identity `bundle.sh` finds (free with
any Apple ID in Xcode → Settings → Accounts), not notarized, and a download
needs Open Anyway once. Keep signing with that same identity — it is what
lets macOS keep a user's permissions across updates.

1. **Developer ID certificate.** In your Apple Developer account, create a
   "Developer ID Application" certificate and install it in the login
   keychain. `security find-identity -v -p codesigning` lists its name.
2. **Notary credentials.** `xcrun notarytool store-credentials spyx` (Apple ID,
   team ID and an app-specific password).
3. **Back up the update signing key.** Sparkle updates are signed with an
   EdDSA key kept in the login keychain under the account `spyx.lol`; its
   public half is `SUPublicEDKey` in `script/bundle.sh`. Lose the private key
   and installed copies can never be updated again. Export it to a password
   manager or an encrypted backup:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account spyx.lol -x spyx-sparkle-key.txt
   ```

   Then delete the exported file from disk — or keep it only inside an
   encrypted disk image whose password is in your password manager:

   ```bash
   hdiutil create -encryption AES-256 -fs APFS -volname spyx-sparkle-key -srcfolder <folder holding the key> spyx-sparkle-key-backup.dmg
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

   or, with a Developer ID, notarized:

   ```bash
   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=spyx PUBLISH=1 script/release.sh
   ```

4. That creates the release `v<version>` on
   [chrisnguyen1211/spyxdotlol](https://github.com/chrisnguyen1211/spyxdotlol/releases)
   with `spyx-<version>.dmg` and `appcast.xml`. Installed copies read
   `releases/latest/download/appcast.xml`, so the newest release is the feed:
   never mark an older one "latest", and never delete the newest's appcast.
5. Install the DMG on a clean Mac (or a new user account) and check: it opens
   (after Open Anyway, if not notarized), the notch appears, Settings → General →
   Check Now reports "up to date", and an approval from Claude Code reaches
   the notch.

## What users keep across updates

Settings live in the `lol.spyx.app` defaults domain. Builds before 1.0 used
`dev.lideffort`; the first launch of 1.0 copies those settings across once
(`Preferences.migrateFromPreviousDomain`). Accessibility, Automation and the
keychain's "Always Allow" are granted per bundle id, so testers moving from a
pre-1.0 build are asked for them once more.
