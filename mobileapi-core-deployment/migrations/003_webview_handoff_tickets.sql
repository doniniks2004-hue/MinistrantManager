-- MobileAPI migration 003 — short-lived, single-use WebView handoff
-- tickets (hybrid dashboard milestone, review round point 18). Lets a
-- user who is already authenticated in the app (mobile_user_token) open
-- a legacy PHP module in a WebView WITHOUT a second login prompt,
-- without ever putting mobile_user_token itself into a URL/JS/WebView.
--
-- The ticket is a cryptographically random, server-generated, server-
-- verified single-use credential — NOT a copy or re-encoding of
-- mobile_user_token, and it authorizes exactly ONE thing (opening
-- `target_path` once) rather than acting as a general bearer credential.
--
-- Safe to run multiple times: `CREATE TABLE IF NOT EXISTS`.

CREATE TABLE IF NOT EXISTS webview_handoff_tickets (
    id INT NOT NULL AUTO_INCREMENT,
    ticket VARCHAR(64) NOT NULL,
    user_id INT NOT NULL,
    installation_id VARCHAR(64) NOT NULL,
    target_path VARCHAR(255) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NOT NULL,
    used_at DATETIME NULL DEFAULT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uniq_ticket (ticket),
    KEY idx_expires_at (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
