-- Required by both legacy web login and MobileAPI. Existing parish tables
-- are preserved; the authenticator also supports schemas without was_successful.
CREATE TABLE IF NOT EXISTS login_attempts (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    ip_address VARCHAR(45) NOT NULL,
    username VARCHAR(50) NOT NULL,
    attempt_time DATETIME NOT NULL,
    was_successful TINYINT(1) NOT NULL DEFAULT 0,
    KEY idx_login_ip_time (ip_address, attempt_time),
    KEY idx_login_user_time (username, attempt_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
