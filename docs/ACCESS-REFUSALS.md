# Access refusals: what each answer of the backend means, and what the app does

Read from the code in this repository (PR #49 + the fixes applied after it). Nothing here was
observed on a deployed server. Where the table says "unknown", the app does not guess.

## The three kinds of answer

1. **An unambiguous refusal** the app acts on. It is remembered across restarts (`AccessRefusals`,
   Keystore/Keychain: a short fingerprint of the token, a label, a time; never a token), it is
   reversible, **it erases nothing**, and the saved copy is not opened while it stands.
2. **A session that ended or an answer that cannot be told apart**: the user signs in again, or the
   app reports that it could not confirm. Nothing is remembered, nothing is erased, nothing is
   treated as ACTIVE, and the offline lease is not renewed.
3. **A transient failure** (server unavailable, no connection): the offline lease decides, exactly as
   before. A refusal received earlier is not undone by the connection being gone.

Erasing (the crypto-erase of `RevocationHandler`) happens only on the central server's own explicit
`DEVICE_REVOKED` / `PARISH_DISABLED` answer (or the user's manual reset). That is unchanged.
`UPDATE_REQUIRED` is unchanged.

## Central server, `POST /device/status` (device token)

| Answer | Source in the code | Meaning | App |
|---|---|---|---|
| 200 `ACTIVE` | `DeviceStatusEvaluator` | confirmed | **lifts** a remembered device refusal; renews the lease |
| 200 `DEVICE_REVOKED`, `PARISH_DISABLED` | same | revoked / disabled (cancellation arrives as HTTP 200) | existing wipe, `clearActivation` also clears refusals |
| 200 `UPDATE_REQUIRED` | same | unchanged | unchanged; does **not** lift a refusal |
| 401 | `authenticateDevice()` | the central server does not accept this token | **device refusal, remembered** (`tokenRejected`) |
| 200 with an unknown `status`, or a body that is not an object | client | protocol error | not ACTIVE, not a revocation, lease not renewed, **nothing added, nothing removed** (a remembered refusal stays) |
| 403, other 4xx | this endpoint does not give them (a firewall or proxy does) | an answer that cannot be read | same as the row above |
| 5xx, no answer | — | transient | the lease (or the remembered refusal, if there is one) |

## Parish server (`mobile_user_token`), handoff and sign-in

`DeviceAuthorizationService` asks the central server (`/internal/mobile/device/validate`,
`DeviceValidationEvaluator`) and answers `device_not_authorized` with `device_state`:

| `device_state` | HTTP | Meaning | App (handoff) |
|---|---|---|---|
| `revoked`, `parish_disabled` | 403 | the central server says no | **device refusal, remembered**; no copy offered; not erased here (erasing is the central server's own answer) |
| `not_found` | 403 | the central server has no record of this installation | same |
| `parish_mismatch` | 403 | the installation belongs to another parish | same (a configuration problem, but a copy of this parish is still not opened) |
| `central_unavailable` | 503 | could not check | transient: the lease; nothing remembered |
| anything else, or missing | 403 | unknown | **not** a revocation: nothing remembered; no copy is offered on this reply |

The parish keeps a 10-minute cache of the central answer, so `revoked` can arrive late and a stale
`active` can survive a central outage (capped by `offline_lease_hours`). That is why this answer
**blocks** but does not **erase**: the central `ACTIVE`/`DEVICE_REVOKED` is the one that decides.

| Other handoff answers | Meaning | App |
|---|---|---|
| 403 `forbidden` | the user's role has no access to **this module** | **module refusal, remembered for this user + parish + module**; no copy offered; other modules unaffected |
| 401 (user token) | the user's session | sign in again; the device is untouched |
| 400 `invalid_path` | a module the server does not know | shown; nothing remembered |
| 403 with no machine code (HTML, firewall) | cannot be read | shown; nothing remembered |
| HTML 403 from `mobile_handoff.php` | a used or expired ticket | shown; nothing remembered |
| 5xx, no answer | transient | the lease and the copy |

`session_login.php` and `session_change_password.php` return the same `device_not_authorized` and
`device_state`; the sign-in screen shows its own message. A sign-in has no copy to bypass, so it
does not write a refusal.

## What lifts a refusal

| Refusal | Lifted by | Not lifted by |
|---|---|---|
| device (central 401, or a parish `device_state`) | a verified `ACTIVE` from the central server for the **same token**; or a new activation (another token; `clearActivation` also clears it) | unknown/unreadable answers, 5xx, a user signing out, `UPDATE_REQUIRED`, the lease |
| module | a handoff the server **accepts** for that module (a ticket is issued only after the role check) | central `ACTIVE` (it confirms the device, not the user's role), the user signing out |

## Where it is enforced

- `HomeScreen` reads the remembered device refusal from local storage **before** it shows a page, and
  shows "Serwer odrzucił autoryzację tego urządzenia" instead of the page or a copy.
- `OfflinePageCoordinator` refuses to hand out a copy (`_planOffline`, `hasSavedCopy`,
  `savedCopyFact`) while a device refusal stands, or the module (or the page's entry module) is
  blocked for this user and parish. That is the direct-entry path; hiding a button is not what
  protects it.
- A check that meets such a refusal while a copy is on screen replaces the copy with the refusal.

## Not verified

None of this was compiled or run (no Flutter in the authoring environment). The Dart code and its
tests have been parsed for syntax only. A refusal remembered by the app was never exercised against
a real server or on a device.

## Three results, not two: no refusal / a refusal / cannot tell

Reading the remembered refusal has three outcomes (`RefusalCheck`). Only the first lets a saved copy
open.

| Outcome | When | App |
|---|---|---|
| clear | the record is absent, or is a **complete, valid** record that belongs to another token (only then is it removed) | as before |
| blocked | a record for this token / module stands, **or this process already received the refusal** | no saved copy; refusal screen |
| **unknown** | the keystore cannot be read (error or no answer within 4 s), the text is damaged or of the wrong shape (`{}`, a record without its token, a modules list with any invalid element such as `[{}]`), or the device token itself cannot be read. A damaged record is never taken for "another token" and never deleted by the check | **no saved copy is opened**, nothing is erased, a retry button (`SPRÓBUJ PONOWNIE`); `DeviceAuthState.refusalUnknown`, `HandoffRefusal.unknown` |

"Unknown" is settled by trying again: a readable keystore gives clear/blocked; a verified central
ACTIVE removes a device record, damaged or not. A page request that reaches the server is still
decided by the server (an accepted handoff opens the page online); only the saved copy stays shut.

## A refusal that cannot be written or removed

- **Write fails.** `blockDevice()` / `blockModule()` return `false`, but the refusal is held in memory
  as well, so the next checks, later attempts and the switch to offline in the same process still see
  it (even if the keystore then also cannot be read). If the device token cannot be read, the block is
  kept for the process without binding it to a token. **A restart forgets it** (nothing was written);
  the central check at the next start is what can bring it back.
- **A late answer cannot lift a newer block.** `liftDevice()` carries the token of the activation that asked
  and a `stillCurrent` check; when the token has changed meanwhile it returns `LiftResult.superseded`
  and removes nothing (a record of another complete token is never removed by a lift). The sync engine
  then drops the stale answer (no lease, no config) instead of acting on it.
- **The queue belongs to the storage, not to one `AccessRefusals`.** The queue of operations and the list of
  real calls still running are kept per physical storage (the platform keystore reports one `gateKey`;
  tests with a map are told apart by identity). A NEW instance built after the services were rebuilt
  therefore waits for what the old one gave up on: old delete times out -> new instance writes a refusal
  -> the old delete ends, and the new write is still there (it was only issued after the delete had
  finished). If the delete is still running when the new instance's own time runs out, no write is issued
  (reported `false`, the block stands in that process); the refusal is not lost to the late delete.
  Tested with two instances on one storage and a THIRD fresh instance reading the result.
- **A time-out does not cancel the real call.** `Future.timeout` only stops waiting. Real keystore calls
  for one slot are therefore **serialized**: a new read/write/delete for the slot waits until the
  earlier real call has finished, so an old delete cannot complete after a newer refusal write and
  remove it. Tested with gated (controlled-delay) storage.
- **The register of module refusals is full.** At `maxModuleRecords` (256) a refusal that is not
  already recorded is **not** made room for by dropping the oldest: that would turn a received refusal
  into "no refusal" after the next restart. Before a restart this process blocks all of them (memory).
  After a restart every stored one still stands, the oldest included; the one that did not fit was never
  stored, so it is forgotten exactly like a write that failed, and `blockModule()` returned `false` to
  say so. A block that already has its record is rewritten in place; room made by an accepted handoff
  (a lift) is used by the next block.
- **Lift fails.** `liftDevice()` / `liftModule()` return `LiftResult.failed`; the block stays (it is not
  reported as lifted). After a central ACTIVE whose lift failed the device state is
  `refusalUnknown`, the lease is **not** renewed, and the next ACTIVE tries again. A failed module
  lift is traced and retried by the next accepted handoff for that module.

## A parish refusal against a newer central ACTIVE

The parish keeps the central answer for up to 10 minutes, so an old `revoked` can outlive a later
ACTIVE. Before a parish `device_state` refusal becomes a block, the central server is asked again
(`SyncEngine.reverifyDevice`, 3 s):

| Central answer to that re-check | Result |
|---|---|
| ACTIVE (obtained after the parish reply; it also lifts any stored refusal) | **not blocked**, nothing stored; the page is not opened and no copy is offered on that reply; the screen says the parish answer may be old; retry reaches the parish once its cache is refreshed |
| `DEVICE_REVOKED` / `PARISH_DISABLED` (explicit) | the refusal stands **and the full answer is passed on**: `OfflinePageCoordinator.centralRevocations` emits it, `HomeScreen` hands it to the existing `RevocationHandler` wipe |
| anything else: 401, cannot tell, no answer, error, timeout | the refusal stands and is stored; **nothing is erased** |

A module refusal is never put to the central server (ACTIVE says nothing about the user's role).

## Wipe in progress (a separate marker)

A wipe that is interrupted (the process is killed, the phone restarts) used to leave an app that was
still activated against data that was half erased. It now leaves a **marker**.

| | |
|---|---|
| Written | before anything is deleted, in **two places**: `wipe_in_progress` in Keystore/Keychain, and `wipe_in_progress.json` in the app's own storage (reason, parish, time; no token, no key, no URL, so a plain file is fine). If it cannot be stored in either, the wipe still runs. |
| Checked | first thing at startup, before the activation is read and before any database or saved page is opened (`main.dart`, `_bootstrap`). A marker found in either place is enough. If neither holds one but a place could not be read, that is not "no marker": startup stops. |
| Resumed | the unfinished wipe is run again from the start; every step can run twice and none needs an open database. The parish comes from the marker (the activation may already be gone); an unreadable marker, or one with no parish, removes every saved page. |
| Removed | only when every required step is confirmed: saved pages and their key, the database files (checked to be gone), the database key, the activation. A step that fails keeps the marker and does not skip the next one. Cookies and the row wipe are best effort. |
| If it cannot be finished | startup ends on the retryable error screen (`WipeIncompleteException`): no services are built and no data is shown. |
| Starts a wipe | only the central server's explicit `DEVICE_REVOKED` / `PARISH_DISABLED`, and the user's "Zmień parafię". |
| Never starts one | a plain 401 (`tokenRejected`), an unknown status (`authError`), a parish `device_state`, a module `forbidden`, `UPDATE_REQUIRED`, offline states. These are covered by tests. |

### When no marker could be stored anywhere

`RevocationHandler.lastOutcome` says so (`markerStored: false`, `resumeGuaranteed: false`); no
interrupted wipe is promised to be finished. The wipe still runs, in a different order: **the activation
is cleared first**, so a process that dies part-way leaves an app that is not activated, not one that
still shows revoked data. What it cannot do: a leftover database or saved pages from such an
interrupted wipe are not found again at the next start (nothing records that they exist). That is the
stated limit, not a guarantee.

**One lock for the whole wipe (`WipeLock`).** It is taken when a wipe STARTS (before the marker, before
anything is deleted) and released only when the wipe is confirmed complete; a failed wipe leaves it held.
The same instance is given to `RevocationHandler`, `OfflinePageCoordinator` and (through the handler)
`HomeScreen`. While it is held: the coordinator offers, opens and serves no saved copy and requests no
page (`wipe_in_progress`; the loopback server is shut), and `HomeScreen` shows only the blocking screen
(progress while the wipe runs, retry once it has failed), whichever screen started the wipe: a manual
reset that fails pops the settings screen, and neither its button nor the system Back leads back to the
panel. Retry (`retryIncompleteWipe()`, also what a second "Zmień parafię" does) CONTINUES the pending
wipe. `HomeScreen` goes back to normal only through `onRevoked` after a success.

**Every path of the coordinator obeys it, before the request and before the result is used.** `plan()`,
`probeOnline()` and the refusal handling remember how many wipes had started when they began
(`_wipeEpoch`). A request is not sent while the lock is held; and when a wipe has started since (even one
that is already over) the answer is dropped: no ticket is used (`PageLoadOnline` / `OnlineProbeRecovered`
are not returned), no module block is lifted (the lift also re-checks inside the storage queue,
`LiftResult.superseded`), no refusal is recorded and no central revocation is passed on.

**One wipe operation at a time.** `RevocationHandler` runs a single wipe operation; a manual reset, a
central revocation and a retry that come while it runs get THE SAME operation (same result, same failure)
and wait for it. The marker is written once, each step runs once, the lock is released once, and
`HomeScreen` requests the rebuild once however many callers were waiting.

**An incomplete wipe does not continue the normal flow.** When a wipe ends incomplete (`WipeIncompleteException`),
the services are not rebuilt and no new activation is offered: `HomeScreen` shows a blocking screen
(`SPRÓBUJ PONOWNIE`) and `retryIncompleteWipe()` runs the wipe again; the device-settings screen stays
put with a message. `activationCleared` is `true` only when `clearActivation()` really succeeded (a
failure is retried at the end and otherwise leaves the wipe incomplete). "Activation first" therefore
protects only **after the activation has been removed successfully**; if both marker writes and
`clearActivation()` fail, nothing protects an interrupted process, and the screen says so by staying blocked.

Tested by simulating a process that dies after each step (marker, saved pages, cookies, database
files, database key, activation), with both places working, with only the file, with only the
Keystore, and with neither.

Not verified: nothing here was compiled or run; the tests were written and parsed for syntax only.
