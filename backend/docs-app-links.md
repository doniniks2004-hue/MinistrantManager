# App Links / Universal Links — spec §35, decision #9

Android jest już skonfigurowany finalnymi danymi release:

- `public/.well-known/assetlinks.json` zawiera package
  `eu.ministrant.manager` oraz SHA-256 finalnego certyfikatu Android:
  `7B:A4:5D:C9:80:41:DA:E0:BC:96:B2:7B:E1:EB:E2:3F:D5:26:B6:6B:A2:CD:C3:BF:B4:74:C4:68:2E:E7:16:28`.

iOS pozostaje zależny od Apple Developer:

- `public/.well-known/apple-app-site-association` nadal zawiera
  `__APPLE_TEAM_ID__` i `__APPLE_BUNDLE_ID__`; Bundle ID jest znany
  (`eu.ministrant.manager`), ale Team ID musi pochodzić z realnego konta
  Apple Developer.

Both files MUST be served with `Content-Type: application/json` (Laravel
serves static files from `public/` as-is; `apple-app-site-association` has
NO file extension on purpose — Apple requires that exact filename) and
MUST be reachable over HTTPS with no redirect at exactly:

```
https://app.ministrant.eu/.well-known/assetlinks.json
https://app.ministrant.eu/.well-known/apple-app-site-association
```

## Client-side wiring (mobile app)

- **Android App Links**: `android/app/src/main/AndroidManifest.xml` needs
  an `<intent-filter>` on `MainActivity` with
  `android:autoVerify="true"` for `https://app.ministrant.eu/activate` —
  see that file's own comment for the exact block (added, currently
  inert until the manifest's `package_name`/fingerprint match a real
  signed build AND assetlinks.json above is live).
- **iOS Universal Links**: `ios/Runner/Runner.entitlements` needs an
  `com.apple.developer.associated-domains` entry for
  `applinks:app.ministrant.eu` — see that file.

Until all of the above is live, the `/activate/{token}` fallback page
(`ActivationLandingController` in the Backend package) is what every
scanned QR actually opens — that page works today, independent of any of
this.
