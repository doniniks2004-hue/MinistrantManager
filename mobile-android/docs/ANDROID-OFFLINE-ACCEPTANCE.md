# Android: offline acceptance, measured on the device

The requirement: **the complete saved panel is visible within 2 seconds, with nobody touching the
phone**, counted as the user experiences it:

- after a COLD START: from the moment the user starts the app;
- after a LOSS OF NETWORK: from the moment the connection is actually cut.

The time the code takes to open a local file is not the requirement and is not what is measured.

## What the tool does

`.github/scripts/android_offline_acceptance.py` drives the device with `adb` and reads the app's own
trace. It needs a build that writes the trace (a debug build, or `--dart-define=MM_TRACE=true`) **made with
the owner's definition of the real panel**.

### 1. The owner defines the panel (once)

Copy `.github/scripts/panel-spec.example.json` and fill it in from the real page: the logical path, one or
more selectors that exist only on the real panel (`required`), selectors that must NOT be showing (`forbidden`:
the sign-in form, the app's error banner), computed styles that must really be applied (`styles`), and a word
of the title. The example holds `REPLACE_ME` placeholders and is **refused** by the tool. Nobody guesses
what the panel is: not the app, not the script, not the person running it.

```
python .github\scripts\android_offline_acceptance.py --panel-spec panel-spec.json --print-define
#  --dart-define=MM_PANEL_SPEC=<text>      spec id: <12 hex>
flutter build apk --debug --dart-define=MM_PANEL_SPEC=<text>
```

The spec id is the first 12 hex characters of the SHA-256 of that text. The build reports it with every
check, and the tool accepts only reports with the id it computed from the file: a build made with another spec,
or with none, is refused.

### 2. Run (sign in ONLINE once and wait for the panel, which saves the copy)

```
python .github\scripts\android_offline_acceptance.py --panel-spec panel-spec.json --serial emulator-5554 --runs 5 --out acceptance
```

`--runs` must be 1 to 100: 0 would "pass" nothing and is refused.

| Set | Steps (all automatic) | Measured from | To | Required |
|---|---|---|---|---|
| **A. Cold start offline**, 5 runs | force-stop (confirmed); Wi-Fi and data off (confirmed by the system); start the app (confirmed: the command answered and a process exists) | the `am start` command | the accepted report (below) | 5 of 5, each <= 2000 ms |
| **B1. Loss of network**, 5 cycles | start online until the live panel is accepted; Wi-Fi and data off (confirmed) | just BEFORE the commands that cut the network | the accepted report of the saved copy, same process | 5 of 5, each <= 2000 ms |
| **B2. Return**, same 5 cycles | Wi-Fi and data back on | the moment the network is switched on | the accepted report of the LIVE panel, same process, a newer navigation | 5 of 5, within 30 s (no 2 s requirement is stated for it) |

**Both ends come from the device's own clock** (`date` on the device, `logcat -v epoch`), so adb's
latency and a clock difference between the computer and the device cannot enter the numbers. Cold-start
time includes the process start, the engine and the web view.

### What an ACCEPTED report is

The page checks itself two animation frames after it finished loading and the app logs one `PAINTED_FACTS` line.
A run counts only if **all** of this holds for one such line:

| Condition | Why |
|---|---|
| it is from the process `pidof` found right after the start (log pid = reported pid = that pid; one session id in the log) | a report from an earlier run or another process is not evidence |
| `via=raf`: the engine called back after two animation frames | the 1.5 s fallback timer (`via=timer`) only stops the app waiting for ever; it fires on a page that is never drawn. It is **never** accepted |
| `visibility=visible hidden=0`, document `complete`, every image decoded, a stylesheet, a main area with a size | a hidden or half-loaded page is not a panel |
| `spec=` the id computed from the spec file, `verdict=ok`, `path_ok=1`, `panel=1` | the real panel by the owner's definition: required elements SHOWN (not just present), no forbidden element showing (a sign-in page or error page fails here), required styles really applied (computed values, not a stylesheet count) |
| no later navigation of the same process appears in the log | the report is for the page now on screen |
| it is after the start / loss / return being measured, in the right mode (copy offline, live online) | |

If adb fails (non-zero exit, `device offline`, no time from the device), the run is an **error, not a
measurement**; a network or start that cannot be confirmed is not counted. The network is put back as it
was found in a `finally`, whatever happens; the report says whether that worked.

The report (`acceptance.md`, `acceptance.json`) lists every run in milliseconds with the process id and, for
a failure, why the nearest report was refused. Exit code 0 only if every set is 5 of 5; 2 for an error.

The page-side probe and its checks are tested in jsdom (`panel_probe_test.mjs`); the tool's verdicts against
a simulated phone (`test_android_offline_acceptance.py`). Neither replaces running it on the device.

## What it does not do, and how to check it

| Item | How |
|---|---|
| Start with no network and **no saved copy yet** | Clear the app's data, switch the network off, start: a clear message, no endless spinner. (The unit tests cover the screen's logic.) |
| **Sign-out and a change of user**: the earlier copy is not visible to the next person | Sign in as A online, sign out, sign in as B, network off: B must not see A's panel. (Covered by the isolation tests; check once by hand.) |
| **A slow connection, a server that is briefly unavailable** | Throttle the emulator's network (`adb emu network speed gsm`), or stop the backend for a minute: the screen says the server is slow or not answering, never "no internet", and the panel returns by itself. |
| **A refusal the app RECEIVED** (device revoked, parish disabled) | With the phone online, revoke the device in the panel and open the app: it must wipe the parish's copies and the key (`RevocationHandler`) and go to activation. Then network off and start: there is nothing to open. (Covered by `offline_isolation_integration_test.dart` and `revocation_wipe_test.dart`; check once by hand.) |
| **A refusal the app RECEIVED that is not a revocation** (the central server answers 401 to the device token; the parish server refuses the device with `device_not_authorized`; 403 `forbidden` for one module) | See `docs/ACCESS-REFUSALS.md` for what each answer means. By hand, with the phone online: (1) make the central server answer 401 to this device's token (e.g. a token it does not know), open the app: it must stop at "Serwer odrzucił autoryzację tego urządzenia", with **no data erased**. Switch the network off, close the app, start it: it must show the same screen and **not open the saved copy**, though the lease has not expired. Restore a valid state and start online: the first `ACTIVE` lifts it. (2) Take a module's role away from the user and open that module: "Brak uprawnień do tego modułu", no copy offered; other modules still open from their copies, offline too. Give the role back and open the module online: it opens again. (Covered in code by `device_refusal_test.dart`, `access_refusals_test.dart`, `offline_page_coordinator_test.dart`; not run on a device.) |
| **A revocation while the phone is ALREADY offline** | Not detectable: nothing reaches the app. What bounds it is the local lease (`offline_lease_hours` from the last confirmation, 72 h by default): inside it the copy stays available, after it the app refuses until it reaches the server, and at the first answer that reaches it a revocation is acted on. **The app does not detect a remote revocation instantly without a connection, and nothing here claims it does.** (Covered by `offline_lease_revocation_test.dart`.) |
| The same on an iPhone | `docs/IOS-RUNTIME-VERIFICATION.md`; the simulator measures the chain, not the iPhone |

## Notes

- The emulator's `svc wifi disable` is immediate. On a phone the radio may take a moment to report the
  loss; the measurement starts BEFORE the command, so the number is a little longer than the true
  disconnection, never shorter.
- A debug build runs Dart several times slower than release. If a debug build misses 2 s, also run a
  release build made with `--dart-define=MM_TRACE=true` before drawing conclusions.
