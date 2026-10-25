# iOS — what stands between this repository and TestFlight

Status of 12 Oct 2026. Nothing here is a secret and no secret belongs in the
repository (never commit a `.p12`, a `.mobileprovision` or a password).

## What the repository now has

| | State |
|---|---|
| Entitlements (`Runner.entitlements`) | **Applied** by the Runner target (`CODE_SIGN_ENTITLEMENTS`, all three configurations). Until this change the file existed but the project did not use it, so Universal Links were configured and never applied. A contract test keeps it that way. |
| `PrivacyInfo.xcprivacy` | Part of the app bundle. No tracking; declares the one required-reason API the app's own code uses (file timestamps inside its container, `C617.1`). Re-check the list when native code is added. |
| ATS | Loopback HTTP only (`NSAllowsLocalNetworking` and an exception for `127.0.0.1`); no general cleartext. |
| Camera | `NSCameraUsageDescription` is set (QR activation). |
| Network signal | `NWPathMonitor` in `AppDelegate.swift`, decisions in shared Dart. |
| Scenes | `SceneDelegate.swift` is compiled but **not wired** (`Info.plist` has no `UIApplicationSceneManifest`): the app runs on the classic lifecycle. See "Needs a Mac". |

## What only the owner can provide

1. **Apple Developer Program membership** (paid) and the **Team ID**.
2. **App ID** `eu.ministrant.manager` with the **Associated Domains** capability
   enabled. This is now REQUIRED for any signed build: the entitlement is applied,
   and a provisioning profile without the capability makes signing fail.
3. **Distribution certificate** (Apple Distribution) exported as `.p12`, and an
   **App Store provisioning profile** for that App ID that includes Associated
   Domains. Store them as the four existing repository secrets:
   `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
   `APPLE_PROVISIONING_PROFILE_BASE64`, `APPLE_TEAM_ID`. The workflow refuses a
   partial set.
4. **App Store Connect**: an app record for that bundle id, TestFlight internal
   testers, the privacy questionnaire (what the app collects is the owner's
   decision; the manifest declares none) and a privacy policy URL.
5. **Export compliance.** `Info.plist` has no `ITSAppUsesNonExemptEncryption`, so
   App Store Connect will ask on every upload. The app uses HTTPS and encrypts
   the local database (SQLite3 Multiple Ciphers) and the saved pages itself
   (see `ENCRYPTION.md`).
   Whether that is exempt is the owner's declaration to make; once decided, the
   key can be set so the question stops being asked.
6. **Association file.** Replace `__APPLE_TEAM_ID__.__APPLE_BUNDLE_ID__` in
   `backend/public/.well-known/apple-app-site-association` with
   `<TeamID>.eu.ministrant.manager` and deploy it so that
   `https://app.ministrant.eu/.well-known/apple-app-site-association` answers 200,
   **without a redirect**, as `application/json`. The `.htaccess` next to it forces
   the type under Apache; under nginx set it in the server block. Check with
   `curl -sI https://app.ministrant.eu/.well-known/apple-app-site-association`.

## Needs a Mac (not verified, because it cannot be done here)

- A build on a simulator and on a real iPhone; WKWebView loading
  `http://127.0.0.1:<port>` (the ATS exception is in place; the behaviour is not tested).
- The saved-copy server after the app was in the background (the shared Dart now
  repairs a dead listener; whether iOS actually reclaims it on a given device is
  to be observed).
- Keychain after uninstall and reinstall (the shared Dart now clears credentials
  of a deleted install; the update path must be checked: an update must not sign
  anyone out).
- A Universal Link opening the app (only after items 2 and 6).
- **UIScene migration.** Apple will require it in a later SDK. It is a change of
  `Info.plist` (`UIApplicationSceneManifest` naming `SceneDelegate`) together with
  the way plugins are registered in `AppDelegate`, and a mistake shows as a black
  screen at launch, which cannot be tested without a device. Follow Flutter's
  published migration guide for the Flutter version in use and verify on a device
  before merging; the native network signal is registered through
  `registrar(forPlugin:)` and does not depend on a window.

## Order

1. Owner: items 1 to 3. 2. Owner: item 4 and 5. 3. Owner: item 6.
4. Fill the four secrets; the iOS workflow then produces a signed IPA.
5. Upload to App Store Connect; install through TestFlight on an iPhone.
6. Run the "Needs a Mac" list on that phone.
