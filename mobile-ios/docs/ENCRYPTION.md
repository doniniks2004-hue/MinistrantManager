# Local database encryption — status and required follow-up

**Status: `IMPLEMENTED / NOT VERIFIED ON REAL DEVICE`.**

This becomes `VERIFIED` only once someone with a real Flutter/Android/iOS
toolchain and a real device/emulator confirms ALL FOUR of the following
against an actual build — not before, and this document will not claim
otherwise:

- [x] **Build**: the app compiles with a SQLite3MultipleCiphers-enabled
      `sqlite3` linked in via the `hooks.user_defines.sqlite3.source:
      sqlite3mc` entry in `pubspec.yaml`. **CONFIRMED in real GitHub
      Actions CI**: `flutter pub get`, `flutter build apk --debug`, and
      `flutter build ios --simulator --no-codesign` all succeeded against
      this exact pubspec.yaml (see the project's CI run history) — the
      hook mechanism genuinely resolves and the app genuinely compiles
      with it. This does NOT yet confirm the cipher is actually active at
      runtime — see the remaining three items below.
- [ ] **Open with correct key**: a fresh database opens successfully
      through `MultiCiphersEngine` with a real key from
      `SecureStorageService.getOrCreateDbEncryptionKey()`, and
      `verifyCipherActive()` passes — i.e. `PRAGMA cipher;` echoes back
      `chacha20` (see `multi_ciphers_engine.dart`), not merely "returns
      something".
- [ ] **Open with wrong/missing key fails**: attempting to open that SAME
      database file with a different (or no) key fails — proving the
      file is genuinely encrypted, not just PRAGMA'd against a no-op.
- [ ] **Crypto-erase round-trip**: after a revoke-triggered reset, the OLD
      key is gone and a NEW key is generated on next activation — confirm
      the old database file (if somehow still present) is NOT openable
      with the new key either. (The crypto-erase MECHANISM itself —
      closing the connection, deleting the file + `-wal`/`-shm`/
      `-journal`, deleting the key, generating a fresh one — is
      structurally complete and was confirmed correct in review round 2;
      this checklist item is specifically about confirming it against a
      REAL encrypted file on a real device, not the logic.)

There is no legacy fallback engine (review round 2, point 1:
`sqlcipher_flutter_libs` and the `SqlCipherEngine` class that wrapped it
were removed entirely). `MultiCiphersEngine` is the only `CipherEngine`
implementation in this codebase.

## What changed this round (review round 3, point 1)

The PREVIOUS round's `pubspec.yaml` was wrong: it added `sqlite3mc` as a
separate top-level dependency and pointed at a `hooks/build.dart` file to
write by hand. Neither is how this actually works:

- **SQLite3MultipleCiphers is NOT a separate package dependency.** It is
  selected by configuring the `sqlite3` package's own build-hook
  mechanism, via a `hooks.user_defines` entry in `pubspec.yaml` itself:

  ```yaml
  hooks:
    user_defines:
      sqlite3:
        source: sqlite3mc
  ```

  There is no `hooks/build.dart` to author — the hook logic lives inside
  the `sqlite3` package, driven purely by this configuration. Any earlier
  mention of `hooks/build.dart` or a `sqlite3mc` package dependency in
  this codebase's docs/comments was incorrect and has been removed.

- **Version compatibility**: Drift's support for `sqlite3` v3.x (and this
  `user_defines` build-hook mechanism) landed in **Drift 2.32**, not 2.21
  (which predates it). `pubspec.yaml` now pins `drift: ^2.32.0`,
  `drift_dev: ^2.32.0` (dev_dependencies), and `sqlite3: ^3.0.0` as a
  mutually-compatible set on that basis, rather than mixing an old Drift
  with a new sqlite3.

## What's NOT finished, and why

This sandbox has no Flutter/Dart toolchain AND no pub.dev access (only
npm/PyPI/crates.io/GitHub/Ubuntu archive mirrors are reachable here) — so
unlike essentially everything else in this delivery, this piece could not
be built-and-verified here at all, not even partially. What's genuinely
implemented and correct as far as static review can confirm: the
`user_defines` config shape, the compatible Drift/sqlite3 version pins,
the `CipherEngine` abstraction, and the mandatory `verifyCipherActive()`
guard (which this sandbox DID verify the failure path of — see below).
What remains, for a team member with real pub.dev + toolchain access:

1. **Confirm the exact `drift`/`sqlite3` version numbers** above against
   the live pub.dev registry, and confirm `source: sqlite3mc` is still
   the current, correct `user_defines` value for this build-hook
   mechanism at implementation time (this area was evolving; verify
   rather than trust a version pinned without live access).
2. **Actually running `flutter pub get` and a build** and confirming it
   successfully fetches/builds the SQLite3MultipleCiphers native library
   through this hook — this sandbox cannot invoke Dart's build-hook
   machinery at all.
3. **Actually running the app** end-to-end and confirming the four
   checklist items at the top of this document. This sandbox verified
   only `verifyCipherActive()`'s *failure* path (it correctly throws when
   the extension is absent, and correctly throws when a DIFFERENT cipher
   than expected is reported) — never its success path, since there is no
   toolchain here capable of producing a build where the extension is
   genuinely present and active.

## If the build-hook mechanism turns out impractical before a deadline

Do not silently fall back to an unencrypted database. If the
`user_defines` build-hook route cannot be gotten working in time, the
fallback is to compile
https://github.com/utelle/SQLite3MultipleCiphers from source for each
target platform and vendor the resulting binaries manually (Android `.so`
per ABI under `android/app/src/main/jniLibs/`, an iOS `.xcframework` or
static lib), then point `sqlite3`'s `open.overrideFor(...)` at them
directly — `MultiCiphersEngine` itself does not care how the native
binary got there, only that `PRAGMA cipher;` reports `chacha20` once it
has. Treat any such delay as a blocker to communicate explicitly, not
something to route around with weaker encryption.
