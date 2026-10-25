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
-- MySQL and MariaDB compatible, safe to repeat on an existing column.
SET @mm_add_lease_column = IF(
    EXISTS(SELECT 1 FROM information_schema.COLUMNS
           WHERE TABLE_SCHEMA = DATABASE()
             AND TABLE_NAME = 'device_authorization_cache'
             AND COLUMN_NAME = 'offline_lease_hours'),
    'SELECT 1',
    'ALTER TABLE device_authorization_cache ADD COLUMN offline_lease_hours INT NOT NULL DEFAULT 72 AFTER state'
);
PREPARE mm_lease_migration FROM @mm_add_lease_column;
EXECUTE mm_lease_migration;
DEALLOCATE PREPARE mm_lease_migration;
