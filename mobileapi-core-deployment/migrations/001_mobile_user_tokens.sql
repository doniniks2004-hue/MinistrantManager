-- MobileAPI migration 001 — per-parish user session tokens for the native
-- app. Deliberately NOT a central-database table: identity stays with the
-- parish (spec decision, Iteration 2 point 1 — "parafia = identity
-- authority"). installation_id is the same value already known from
-- app.ministrant.eu's device activation (Iteration 1), so revoking a
-- device there can target `WHERE installation_id = ?` here directly,
-- without needing to know which user(s) were using it.
--
-- Review round fix: UNIQUE is on installation_id ALONE, not
-- (user_id, installation_id) as an earlier version of this migration had.
-- Real bug that fix closes: with a composite unique key, two DIFFERENT
-- users signing in on the SAME physical device could both hold a live
-- row at once — Adam logs in, then Bartek logs in on the same phone,
-- and Adam's token was still valid because validate()'s lookup (by
-- installation_id alone, correctly matching "one phone, one signed-in
-- account" reality) could resolve to either row. Assumption for this
-- iteration: exactly one signed-in account per installation_id at a
-- time — a new login on a device REPLACES whichever account was
-- previously signed in there, it does not add a second one.
CREATE TABLE IF NOT EXISTS `mobile_user_tokens` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `user_id` INT NOT NULL,
    `installation_id` VARCHAR(64) NOT NULL,
    -- Argon2id hash, same pattern as admin_recovery_codes on app.ministrant.eu
    -- (Iteration 1) — the raw token is shown to the client exactly once
    -- (at mint time) and never persisted in plaintext anywhere.
    `token_hash` VARCHAR(255) NOT NULL,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `last_used_at` DATETIME NULL DEFAULT NULL,
    `revoked_at` DATETIME NULL DEFAULT NULL,
    PRIMARY KEY (`id`),
    -- One row per device, period — minting a new one for this
    -- installation_id (whether the SAME user re-logging in, or a
    -- DIFFERENT user signing in on a device that was previously someone
    -- else's) atomically replaces user_id + token_hash + created_at and
    -- resets last_used_at/revoked_at to NULL (see
    -- MobileUserTokenService::mint()). The old holder's token stops
    -- validating immediately, by construction — not by a separate revoke
    -- step that could be forgotten.
    UNIQUE KEY `uniq_installation_id` (`installation_id`),
    CONSTRAINT `fk_mobile_user_tokens_user`
        FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
