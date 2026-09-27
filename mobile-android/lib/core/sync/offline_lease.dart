/// Implements spec §10: a fully-offline device keeps working on cached
/// data for up to `offline_lease_hours` (server-configurable, default 72)
/// since the last confirmed authorization check. Past that window, the app
/// must refuse to show cached data until it reconnects.
///
/// IMPORTANT: `leaseHours` is NOT a fixed client-side constant — it must
/// be whatever value the server last reported (SyncMetadata.offlineLeaseHours,
/// refreshed on every successful /device/status or /device/heartbeat call).
/// A central config change (72 -> 24) only takes effect on devices that are
/// actually online to receive it; a device offline for the whole window
/// keeps using the last value it saw, which is the correct, safe default.
class OfflineLease {
  const OfflineLease();

  static const int defaultHours = 72;

  bool isWithinLease(DateTime? lastAuthorizationCheck, {int? leaseHours, DateTime? now}) {
    if (lastAuthorizationCheck == null) return false;
    final hours = leaseHours ?? defaultHours;
    final effectiveNow = now ?? DateTime.now().toUtc();
    final expiresAt = lastAuthorizationCheck.toUtc().add(Duration(hours: hours));
    return effectiveNow.isBefore(expiresAt);
  }

  Duration remaining(DateTime? lastAuthorizationCheck, {int? leaseHours, DateTime? now}) {
    if (lastAuthorizationCheck == null) return Duration.zero;
    final hours = leaseHours ?? defaultHours;
    final effectiveNow = now ?? DateTime.now().toUtc();
    final expiresAt = lastAuthorizationCheck.toUtc().add(Duration(hours: hours));
    final diff = expiresAt.difference(effectiveNow);
    return diff.isNegative ? Duration.zero : diff;
  }
}
