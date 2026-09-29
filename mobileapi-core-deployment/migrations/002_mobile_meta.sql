-- MobileAPI migration 002 — one row per parish describing what this
-- installation of the MobileAPI adapter supports, so `/mobile/config`
-- reads a precomputed answer instead of probing 80+ tables on every
-- request (Iteration 2 point 9). Populated/updated by the adapter's own
-- installer/updater script (out of scope for this migration file itself),
-- never guessed at request time.
CREATE TABLE IF NOT EXISTS `mobile_meta` (
    -- Single-row table by convention (id always 1) — simplest way to get
    -- "exactly one settings row" without a separate uniqueness trick.
    `id` TINYINT NOT NULL DEFAULT 1,
    `schema_version` INT NOT NULL,
    `adapter_version` VARCHAR(40) NOT NULL,
    `capabilities_json` TEXT NOT NULL,
    `installed_at` DATETIME NOT NULL,
    `updated_at` DATETIME NOT NULL,
    PRIMARY KEY (`id`),
    CONSTRAINT `chk_mobile_meta_single_row` CHECK (`id` = 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
