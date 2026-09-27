# App Links / Universal Links — spec §35, decision #9

Both files are PLACEHOLDERS (spec decision #9: "Na razie użyjcie
placeholderów konfiguracyjnych. Nie wpisujcie wymyślonych danych jako
finalnych."). Neither works until the four real values below replace the
`__PLACEHOLDER__` tokens:

- `public/.well-known/assetlinks.json` — replace `__ANDROID_PACKAGE_NAME__`
  (currently `eu.ministrant.manager`, see mobile app README "applicationId")
  and `__ANDROID_SHA256_FINGERPRINT__` with the SHA-256 fingerprint of the
  REAL release signing keystore (`keytool -list -v -keystore
  release.keystore` after that keystore exists — spec decision #9/#10).
- `public/.well-known/apple-app-site-association` — replace
  `__APPLE_TEAM_ID__` and `__APPLE_BUNDLE_ID__` once an Apple Developer
  account and App ID exist.

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
