import 'package:flutter_test/flutter_test.dart';
import 'package:ministrant_manager/core/sync/offline_lease.dart';

void main() {
  group('OfflineLease', () {
    const lease = OfflineLease();

    test('is within lease when last check was recent', () {
      final now = DateTime.utc(2026, 1, 10, 12, 0, 0);
      final lastCheck = now.subtract(const Duration(hours: 10));

      expect(lease.isWithinLease(lastCheck, leaseHours: 72, now: now), isTrue);
    });

    test('is NOT within lease once the configured hours have elapsed', () {
      final now = DateTime.utc(2026, 1, 10, 12, 0, 0);
      final lastCheck = now.subtract(const Duration(hours: 73));

      expect(lease.isWithinLease(lastCheck, leaseHours: 72, now: now), isFalse);
    });

    test('exactly at the boundary is still within lease (strict > not >=)', () {
      final now = DateTime.utc(2026, 1, 10, 12, 0, 0);
      final lastCheck = now.subtract(const Duration(hours: 72, seconds: -1));

      expect(lease.isWithinLease(lastCheck, leaseHours: 72, now: now), isTrue);
    });

    test('never checked in (null) is NEVER within lease', () {
      expect(lease.isWithinLease(null, leaseHours: 72), isFalse);
    });

    test('no leaseHours passed falls back to defaultHours (72), never a silently-different value', () {
      final now = DateTime.utc(2026, 1, 10, 12, 0, 0);
      final lastCheck = now.subtract(const Duration(hours: 10));

      expect(lease.isWithinLease(lastCheck, now: now), isTrue);
      expect(OfflineLease.defaultHours, 72);
    });

    test('respects a dynamic (non-default) lease hours value — spec Iteration 1.1 point 4', () {
      // This is exactly the property the server-driven offline_lease_hours
      // depends on: the SAME OfflineLease instance behaves differently
      // once the server sends a different value for THIS parish, rather
      // than a hardcoded client-side 72.
      final now = DateTime.utc(2026, 1, 10, 12, 0, 0);
      final lastCheck = now.subtract(const Duration(hours: 30));

      expect(lease.isWithinLease(lastCheck, leaseHours: 24, now: now), isFalse,
          reason: '30h since last check exceeds a 24h lease, even though it would still be within the old hardcoded 72h default');
      expect(lease.isWithinLease(lastCheck, leaseHours: 72, now: now), isTrue,
          reason: 'the SAME 30h gap is fine under a 72h lease — proves leaseHours is genuinely a per-call parameter, not baked into the instance');
    });

    test('remaining() returns zero, not negative, once expired', () {
      final now = DateTime.utc(2026, 1, 10, 12, 0, 0);
      final lastCheck = now.subtract(const Duration(hours: 100));

      expect(lease.remaining(lastCheck, leaseHours: 72, now: now), Duration.zero);
    });
  });
}
