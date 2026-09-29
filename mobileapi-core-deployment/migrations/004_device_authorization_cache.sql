-- MobileAPI migration 004 — device-control-plane milestone. A SHORT-LIVED
-- LEASE cache of the last answer from app.ministrant.eu's
-- POST /internal/mobile/device/validate — NEVER a copy of the device
-- record itself (review round: "Nie duplikujemy całych rekordów
-- urządzeń"). Exactly two columns of actual content: the state string
-- and when it was checked/expires — see DeviceAuthorizationService.php.
--
-- Safe to run multiple times: CREATE TABLE IF NOT EXISTS.

CREATE TABLE IF NOT EXISTS device_authorization_cache (
    installation_id VARCHAR(64) NOT NULL,
    state VARCHAR(20) NOT NULL, -- active | revoked | parish_disabled | not_found | parish_mismatch
    checked_at DATETIME NOT NULL,
    expires_at DATETIME NOT NULL,
    PRIMARY KEY (installation_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
