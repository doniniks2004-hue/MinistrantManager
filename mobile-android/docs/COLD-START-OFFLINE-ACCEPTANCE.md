# Cold start offline: how to establish that it works

The requirement: **the complete saved page is visible at most 2 seconds after the
user starts the app, with no network, after a cold start.** Everything below
serves that sentence. The in-app measurements are diagnostics that say WHERE time
goes; they do not replace measuring the requirement itself.

## 1. The requirement itself, measured from outside the app

An in-app clock cannot see the launch of the process or the engine, and a
JavaScript callback is not proof that the user sees a finished panel. So the
requirement is measured with a screen recording and the launcher's own number.

```
# the saved copy must exist: open the app ONLINE once, wait for the dashboard, then
adb shell svc wifi disable ; adb shell svc data disable
adb shell am force-stop eu.ministrant.manager          # NOT "pm clear": that deletes the copy

# one run: record, wait 1 s, launch, keep recording
adb shell "screenrecord --time-limit 8 /sdcard/cold.mp4 & sleep 1; am start -W -n eu.ministrant.manager/.MainActivity; wait"
adb pull /sdcard/cold.mp4
```

- `am start -W` prints `TotalTime` / `WaitTime`: the launcher's own time to the
  first frame of the activity (it does not know about the WebView content).
- In the recording, t0 is the moment the launch was issued (about 1.0 s into the
  video, +/- 0.1 s: record the real offset from the first frame that changes) and
  the end is the FIRST frame in which the dashboard is complete: the sidebar, the
  logo and the content cards are drawn, not a white page and not just the banner.
  Extract frames (`ffmpeg -i cold.mp4 -vf fps=30 f%04d.png`) and read the frame number;
  time = frame / 30.
- A run passes if `end - t0 <= 2.0 s`. **5 of 5 runs must pass.** Write down every
  number, including the failures.

## 2. Where the time went (in the app: diagnostics, not the verdict)

The same run, from the trace (a debug build, or any build made with
`--dart-define=MM_TRACE=true`, which is the build that will be shipped and the only
one whose Dart speed is real):

```
adb logcat -c   # before the run
adb logcat -d -v time | grep -E "nav#|offline-|net:|crypto-selftest|loop-lag|capture:" > run1.log
```

Also on the device, no adb needed: Profile -> Urządzenie/Parafia shows the start
marks (`main`, `services_built`, `app_ready`, `screen_init`, `plan_start`, `plan_done`,
`load_request`, `page_ready_offline`, `panel_painted_copy`), in milliseconds since
the Dart `main()`. Time from the process start to `main()` is NOT in them.

What each line is evidence of:

| Line | What it shows | What it does NOT show |
|---|---|---|
| `start: the system reports no network; skipping the online attempt` | the server was not tried first | that the copy opened |
| `offline-serve: <file> ... verified/decrypted ... (cipher so far: platform=N dart=M)` | which implementation read each file, how long | that the page was drawn |
| `finished <copy>` / `READY mode=copy` | the engine says loading finished | that the user sees the panel |
| `PAINTED ... readyState= images=a/b stylesheets= main=WxHpx` | two animation frames after finish, and what was on the page: a page with `images=0/1`, `stylesheets=0` or `main=0x0px` is NOT a complete panel whatever else is logged | a guarantee: it is the page's own report |
| `loop-lag: ... busy for N ms` | the interface isolate was held for N ms, ending at +T ms | WHAT held it |

The explanation that the 240 ms reads were caused by the interface isolate being busy
is a HYPOTHESIS. `loop-lag` tests it: if it reports long stretches around the reads, the
hypothesis stands; if it reports none, it is wrong and the time went elsewhere.

## 3. Is the platform AES-GCM compatible with Dart? (required before acceptance)

Three independent checks; all must pass on Android, and on iOS before iOS is accepted.

1. **Known answer, on the device, automatically.** At every start the app asks the
   platform's AES-GCM to reproduce an answer computed by OpenSSL, in both directions.
   The log must contain
   `crypto-selftest: verified: the platform AES-GCM reproduces the OpenSSL known answer in both directions; used for pages`.
   `MISMATCH` or `failed` means the Kotlin or Swift code is wrong: the app then uses Dart
   (nothing is lost but the speed), and this is a bug to fix before acceptance.
2. **Real saved pages across implementations.** On one device, without clearing data:
   build A = normal build; open the page online (it is captured: the platform seals it;
   the trace shows `platform=` rising). Install build B = the same code made with
   `--dart-define=MM_CRYPTO_DART_ONLY=true` over it (`adb install -r`), go offline, start
   the app: the page must open (Dart opens what the platform sealed). Then the other way:
   capture with B (Dart seals), install A over it, go offline, open. Both must open
   with no "uszkodzona" message.
3. **Unit tests** (CI): the Dart implementation against the OpenSSL bytes (both
   directions, a changed byte refused, another key refused).

## 4. The five cold starts

From a state with a valid saved copy and no network:

1. 5 times: `force-stop`, run section 1 (the recording).
2. Do NOT clear the app's data between runs and do not reinstall (except step 3.2).
3. Keep the logs of all five runs, passing or not.

Pass: every run's `end - t0 <= 2.0 s` AND the page in the last frame is complete
(`PAINTED` reports `readyState=complete`, all images, a stylesheet, a non-empty `main`).

## 5. What would make this not enough

- If `am start -W` shows `TotalTime` well over a second on its own, the app cannot meet
  2 s from the user's launch by anything done in Dart; then the requirement has to be
  restated (from which moment) with that number in front of everyone.
- A debug build is several times slower in Dart than the release build. Judge the
  requirement on a release build made with `MM_TRACE=true`.
