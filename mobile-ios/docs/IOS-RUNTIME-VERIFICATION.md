# iOS: what is verified without a Mac, and what is left

Context: issue #48. There is no Mac of our own and no paid Apple Developer Program yet.
This document says what the CI now establishes about the iOS app by RUNNING it, what it
cannot establish and why, how to accept the result, and what remains for TestFlight.

Nothing here is a claim about an iPhone. Everything in section 1 happens on a simulator
iPhone on a GitHub `macos-14` runner.

## 1. What CI verifies by running the app (workflow `iOS simulator runtime`)

| # | What | How | Where the evidence is |
|---|---|---|---|
| 1 | The production app, freshly installed, starts and reaches the **parish activation screen** | installed on a booted iPhone simulator, launched; the app writes the name of the screen it reached (debug builds only); a screenshot is taken | `ui_marker.json`, `activation-screen.png` |
| 2 | **Native AES-GCM (CryptoKit)** reproduces an answer computed by **OpenSSL**, in both directions | the app asks CryptoKit to seal a known text with a known key and IV, and to open the OpenSSL bytes | `full.json`: `crypto.platform_verified` |
| 3 | **Dart <-> CryptoKit interoperability** on 158 KB: Dart seals -> CryptoKit opens, CryptoKit seals -> Dart opens, with the platform proved to have been used | executed on the simulator | `crypto.interop_dart_and_platform`, with timings |
| 4 | A changed byte of an encrypted payload is refused | executed on the simulator | `crypto.tampered_payload_refused` |
| 5 | An **encrypted saved page is written and read back**: the page is stored encrypted, the public resources authenticated | the real `SnapshotStore` on the simulator's file system | `store.encrypted_roundtrip` |
| 6 | The **loopback HTTP server** serves the page and its three resources, byte-exact, over a real socket; a wrong token gets 404, POST gets 405 | real `dart:io` sockets on 127.0.0.1 | `server.loopback_http` |
| 7 | The server's **security headers**: CSP with `connect-src 'none'` and `form-action 'none'`, `nosniff`, `no-referrer` | executed | `server.security_headers` |
| 8 | The second request for the page is served from memory | executed | `server.second_request_from_memory` |
| 9 | A **closed listener is replaced** and serves again, inside the plan's 1.5 s budget | the listener is closed on purpose | `server.listener_recovery` |
| 10 | A **real WKWebView loads `http://127.0.0.1:<port>/...`**: App Transport Security lets it through, the page, stylesheet, script and logo are all in effect, a frame is drawn | real `WebView` on the simulator; the page reports its own state (`readyState`, images decoded, stylesheet applied, background colour, script ran) | `webview.loads_loopback_http` |
| 11 | The page's **security policy is enforced by WKWebView**: a request made by the saved page is blocked | the page tries a same-origin `fetch`; it must be blocked | `webview.csp_blocks_requests` |
| 12 | The WebView **recovers after the listener is lost** (no restart of the app) | listener closed, replaced, page loaded again | `webview.recovers_after_listener_loss` |
| 13 | **Five cold opens**: a fresh process opens the saved page from disk with nothing warm; time until a frame was drawn | the app is launched five times from a fresh process | `cold_1..5.json`, `walltimes.json` |
| 14 | Project and **built bundle**: bundle id `eu.ministrant.manager`, version = `pubspec.yaml`, minimum iOS, camera permission text, **App Transport Security** (cleartext only for loopback), privacy manifest inside the bundle, `Runner.entitlements` applied in all three configurations, `applinks:app.ministrant.eu` declared, the association file is valid | files and the built `.app` are read | `static.json` |
| 15 | The harness itself | `flutter test` runs the widget-free part of the self-test (real sockets and file system), and 22 Python tests cover the report and the project checks | CI logs |

Everything above ends in ONE verdict (`report.md` in the job summary and the artifact
`ios-simulator-report`). A check that failed, a run that did not finish, or an app that
never reached its first screen fails the job. A run cut short is never a pass.

**Observations, not verdicts.** A result marked `info` is a measurement or an observation
that cannot be judged on a simulator. It never fails the job and is never shown as a pass.
Today that is: the Keychain (an unsigned simulator build may lack the entitlement that
Keychain needs; the result says what happened) and every timing.

## 2. What CI cannot establish, and why

| What | Why it cannot be done in GitHub Actions | What to do instead |
|---|---|---|
| **The 2-second target on an iPhone** | A simulator on a Mac runner is a different CPU, memory and storage, and the five cold opens are counted from the moment the page begins to open, not from the user's tap, with a stand-in page of the size of a real dashboard | Measure on an iPhone with a screen recording: `docs/COLD-START-OFFLINE-ACCEPTANCE.md` sections 1 and 4 apply unchanged (the iOS side: start the recording, tap the icon, read the first frame in which the dashboard is complete) |
| **Real network switching** (online -> offline -> online, Wi-Fi without internet) | The simulator uses the runner's network; there is no supported way to cut it from a workflow without breaking the job itself | The decision logic is the same Dart code as on Android and is covered by the shared unit tests; the iOS-specific part is the `NWPathMonitor` plugin, which needs an iPhone (Airplane mode, then Wi-Fi without internet) |
| **QR scanning and the camera permission prompt** | The simulator has no camera | The permission TEXT is checked statically (a missing one terminates the app when the camera opens). The prompt and a real scan need an iPhone |
| **Universal Links** | They only work in a SIGNED app whose provisioning profile carries Associated Domains, and the association file served by `app.ministrant.eu` has to contain the real Team ID (it is still a placeholder) | After signing: the checks in section 4 |
| **Keychain accessibility** and what survives a reinstall | An unsigned simulator build has no keychain entitlement | A signed build on an iPhone |
| **A signed IPA, TestFlight** | Need the paid Apple Developer Program | Section 3 |
| **Background and memory behaviour** (iOS reclaiming the loopback socket, memory warnings) | The simulator rarely reproduces them | `ensureHealthy` is tested by closing the listener on purpose; the real thing needs an iPhone left in the background |
| **UIScene migration** | Needs a device test | not done |

## 3. What is left for TestFlight

All of it is on Apple's side or needs an account. Nothing is generated or bypassed here.

1. **Apple Developer Program** (paid membership). A free account cannot use TestFlight.
2. **App ID** `eu.ministrant.manager` with the **Associated Domains** capability.
3. A **distribution certificate** (`.p12`) and an **App Store provisioning profile** for that App ID
   -> repository secrets `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
   `APPLE_PROVISIONING_PROFILE_BASE64`, `APPLE_TEAM_ID`.
4. An **App Store Connect API key** (Users and Access -> Integrations)
   -> `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_BASE64`
   (the `.p8` file, base64).
5. The **app record** in App Store Connect, a **privacy policy URL**, the **age rating**
   (minors are involved) and the **export compliance** answer (the app uses HTTPS and its own
   AES-GCM; whether that is exempt is the owner's declaration, then set
   `ITSAppUsesNonExemptEncryption` accordingly).
6. The **iPad decision** (below).
7. The real **Team ID in `backend/public/.well-known/apple-app-site-association`**, deployed to
   `app.ministrant.eu`.

Then run the workflow `iOS build` by hand with `production` and `upload_testflight`.
It prints a table of which secrets are set (names only), fails on what is missing instead of
working around it, checks the project against what App Store Connect refuses, builds the IPA,
**opens the IPA and verifies what is inside it** (bundle id, version, the signed
`application-identifier`, the associated domain, a distribution signature) and only then uploads.
Internal TestFlight testers need no Apple review; external testers need a beta review.

### The iPad decision (found by the checks, not made here)

The project declares iPad support (`TARGETED_DEVICE_FAMILY = "1,2"`) but supports only
Portrait, without `UIRequiresFullScreen`. App Store Connect refuses that upload. Today this is
a WARNING in every run and a FAILURE at the release gate, so it cannot be forgotten.
Two ways out, a decision for the owner:
- **iPhone only**: `TARGETED_DEVICE_FAMILY = 1` in the three Runner configurations. Smallest change.
- **iPad too**: all four orientations on iPad, and the layout tested on an iPad.

## 4. After signing: what to check on the iPhone

- Universal Links: open `https://app.ministrant.eu/activate/<token>` from Notes or Messages; the
  app must open on the activation step. With the app removed, the same link must open the web page
  (the fallback).
- `https://app.ministrant.eu/.well-known/apple-app-site-association` answers `200` with
  `Content-Type: application/json`, no redirect, and the real Team ID.
- Camera: the permission prompt appears the first time the scanner opens; a real QR activates.
- Offline, with the iPhone's Wi-Fi and data off: five cold starts with a screen recording.
- Online -> offline -> online without restarting; Wi-Fi connected without internet.
- Sign out and sign in again: nothing of the previous user.
- The app left in the background for some minutes, then offline.

## 5. How to accept this work

1. Open the pull request, the `iOS simulator runtime` check, **Summary**. It shows the report.
2. Download the artifact `ios-simulator-report`:
   - `report.md`: the verdict and every number,
   - `selftest-full.png`, `activation-screen.png`: screenshots of the simulator,
   - `full.json`, `cold_1..5.json`, `walltimes.json`, `ui_marker.json`, `static.json`: the raw results,
   - `logs/`: the log of every launch, the simulator's own log, `crashes/` if any.
3. Accept if the verdict is PASS **and** you have read the warnings in section 4 of the report (the iPad
   declaration, export compliance, the Team ID placeholder) and agree they are open decisions.
4. A PASS here means: the iOS app starts, its native crypto agrees with OpenSSL and with Dart, the encrypted
   page is saved and read, the loopback server and a real WebView work on iOS, and the project is
   configured as intended. It does NOT mean the app works on an iPhone.
