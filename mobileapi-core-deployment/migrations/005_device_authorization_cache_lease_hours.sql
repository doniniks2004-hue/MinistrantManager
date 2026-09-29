-- MobileAPI migration 005 — follow-up fix (review round): a stale
-- 'active' cache answer must NOT be trustable forever during a central
-- outage. Stores the parish's own offline_lease_hours (already returned
-- by /internal/mobile/device/validate, the SAME policy that already
-- governs how long the Flutter app itself may run offline — never a
-- third, independently-invented duration) alongside the cached answer,
-- so DeviceAuthorizationService can compute a hard cap:
--   now() - checked_at > offline_lease_hours  =>  treat as
--   central_unavailable, no matter how the 10-minute lease looks.
--
-- Safe to run multiple times / on a table that may already have rows:
-- ADD COLUMN IF NOT EXISTS with a sane default (72h, matching
-- Parish::effectiveOfflineLeaseHours()'s own fallback default).

ALTER TABLE device_authorization_cache
    ADD COLUMN IF NOT EXISTS offline_lease_hours INT NOT NULL DEFAULT 72 AFTER state;
