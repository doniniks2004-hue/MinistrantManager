# Verification of mobile and installer findings — 2026-10-25

Scope: release/android-ios-close, based on 0a036721. Central admin/backend and archived parish web application are excluded. These changes do not assert that this branch is the deployed server version.

Confirmed and corrected:

- Login and first-password-change now validate successful response bodies, return a safe result for storage failures, and distinguish structured device refusals from generic HTTP 403/503 failures. UI always restores its submission state and rejects duplicate submissions.
- Session replacement removes the previous user/legacy tokens before changing identity, so an interrupted write cannot pair the previous token with the new user ID.
- Session and snapshot integration tests now call production login logic, injecting only HTTP transport instead of copying implementation into test doubles.
- Manual rollback validates all backup sources and relative targets before removing anything, replaces whole restored trees, and serializes with installation. Nested files introduced by an upgrade no longer survive a successful rollback.
- Installation prepares schema and metadata before publishing the new core and routes. Parallel installers are rejected and backup names avoid same-second collisions. Database rollback remains intentionally outside the file rollback contract.
- MobileAPI denies authentication when its limiter table/query/write is unavailable; migration 006 creates a missing login_attempts table without replacing an existing parish schema.

Correction to the earlier audit: the installer already installs an Apache rule denying HTTP access to install/reset/upd/fix/receiver scripts. Optional legacy hardeners do not imply those scripts remain reachable. The success message now explicitly identifies a MobileAPI installation, not a full legacy security audit.

Not established as exploitable bugs: best-effort cookie/snapshot cleanup and the legacy JS token bridge. Snapshot identity and generation checks, navigation allowlisting and the one-use server handoff must be considered together. No speculative change to parish authentication or destructive cache policy is included.

Separate follow-up work, not repaired defects: splitting large widgets, consolidating app trees, physical-device acceptance, signed iOS distribution, camera/PDF/accessibility/performance verification. Signing needs the owner's Apple configuration. No production deployment or merge is performed by this change.
