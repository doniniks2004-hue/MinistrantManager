# Standalone tests (no Laravel required)

Actually executed with plain `php` in an environment without Packagist
access. Run them all:

```bash
for f in test_*.php; do php "$f"; done
```

- `test_token_service.php` — TokenService (activation/device token
  generation, display-code format, hashing)
- `test_recovery_code_formatter.php` — RecoveryCodeFormatter (format,
  normalization, and Argon2id hashing/verification — Iteration 1.1
  point 10)
- `test_device_status_evaluator.php` — DeviceStatusEvaluator: both
  verbatim Iteration 1.1 point 3 review cases (Android 1.0.0/min 1.2.0 →
  UPDATE_REQUIRED; iOS 1.0.0/min 0.9.0 → ACTIVE), plus priority-order and
  no-minimum-configured cases
- `test_activation_concurrency.php` (+ `concurrency_worker.php`) — REAL
  two-OS-process race against the `max_uses` race-condition fix
- `test_recovery_code_concurrency.php` (+ `recovery_code_concurrency_worker.php`)
  — REAL two-OS-process race against the recovery-code atomic-consume fix
  (Iteration 1.1 point 7)

Everything else in this package (controllers, models needing Eloquent,
routes, views) requires the actual Laravel framework and was NOT executed
in the sandbox that produced this package (Packagist unreachable there) —
checked with `php -l` only. `.github/workflows/backend-test.yml` scaffolds
a real Laravel app in CI and runs both this suite AND a real
`php artisan test` (see `tests/Feature/ActivationApiTest.php`).
