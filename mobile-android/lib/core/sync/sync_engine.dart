import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import '../database/app_database.dart';
import '../network/api_client.dart';
import '../secure/secure_storage_service.dart';
import 'offline_lease.dart';

enum DeviceAuthState {
  active,
  revoked,
  parishDisabled,
  updateRequired,
  // Review round: covers BOTH an explicit HTTP 401/403 from a server that
  // DID respond (invalid/unknown token, or another explicit security
  // rejection) AND an unrecognized/missing `status` string in an
  // otherwise-successful response. Neither is "offline" (the server
  // answered) and neither is safely treated as ACTIVE (fail-open) —
  // access is blocked, cached data is not shown, without necessarily
  // being as destructive as a confirmed revoked/parishDisabled signal.
  authError,
  offlineWithinLease,
  offlineLeaseExpired,
}

class DeviceStatusResult {
  DeviceStatusResult(this.state, {this.minimumSupportedAppVersion});
  final DeviceAuthState state;
  final String? minimumSupportedAppVersion;
}

/// Orchestrates the whole offline-first lifecycle described in spec
/// §25–§34: status/lease check -> push pending_actions -> pull
/// bootstrap-or-incremental-sync -> update local DB -> heartbeat.
///
/// UI NEVER blocks on this. The pattern (spec §26) is:
///   1. render immediately from SQLite (see AppDatabase streams)
///   2. kick off SyncEngine.runFullSync() in the background
///   3. UI updates reactively as rows change (drift Streams)
/// Review round (milestone "Mój grafik", point 4): thrown by
/// `fetchAndApplySnapshot()` when the PARISH api rejects the current
/// mobile_user_token with a 401 — a USER session problem. The caller
/// (HomeScreen) must clear ONLY the user session
/// (UserSessionService.handleParishSessionExpired()) and route to the
/// login screen — NEVER treat this as DEVICE_REVOKED, never clear
/// installation_id/device_token, never re-trigger QR activation.
class ParishSessionExpiredException implements Exception {
  @override
  String toString() => 'ParishSessionExpiredException: the parish API rejected the current mobile_user_token (401).';
}

/// Review round fix (real bug — a missing X-Installation-Id header
/// produced exactly this: a 400 that HomeScreen's old generic
/// `catch (_)` silently swallowed, showing an EMPTY "Mój grafik" as if
/// the user genuinely had no assignments): thrown for 400/403/422 from
/// the parish API — a CONTRACT problem (malformed request, a header the
/// backend now requires but the client stopped sending, a validation
/// failure), never a transport/connectivity problem. Deliberately a
/// DIFFERENT exception type from both ParishSessionExpiredException
/// (401 — re-login) and a plain DioException left to propagate for
/// transport failures/timeouts/5xx (offline-lease path, cached snapshot
/// stays valid, no visible error). The caller MUST surface this visibly
/// (a "couldn't update" banner) and MUST NOT show an empty/stale
/// snapshot as if it were current.
class ParishContractErrorException implements Exception {
  ParishContractErrorException({required this.statusCode, this.message});
  final int statusCode;
  final String? message;

  @override
  String toString() =>
      'ParishContractErrorException: HTTP $statusCode from parish API${message != null ? " ($message)" : ""}';
}

class SyncEngine {
  SyncEngine({
    required this.db,
    required this.api,
    required this.secureStorage,
    this.offlineLease = const OfflineLease(),
  });

  final AppDatabase db;
  final ApiClient api;
  final SecureStorageService secureStorage;
  final OfflineLease offlineLease;
  final _uuid = const Uuid();

  bool _isSyncing = false;

  /// Returns null if the app isn't activated yet — caller should route to
  /// the activation screen.
  Future<DeviceStatusResult?> checkDeviceStatus({required String appVersion, required String osVersion}) async {
    final token = await secureStorage.deviceToken;
    if (token == null) return null;

    final meta = await db.ensureSyncMetadata();

    try {
      final dio = api.centralWithAuth(token);
      // Review round: app_version/os_version are now actually SENT — the
      // backend was evaluating UPDATE_REQUIRED against whatever version
      // was last recorded at activation/heartbeat time, which could be
      // stale for a device that just updated but hasn't heartbeat'd yet.
      final resp = await dio.post('/device/status', data: {
        'app_version': appVersion,
        'os_version': osVersion,
      });
      final data = resp.data as Map<String, dynamic>;

      await _persistServerControlledConfig(data);

      return _interpretStatus(data);
    } on DioException catch (e) {
      return _interpretDioFailure(e, meta);
    }
  }

  /// Review round fix: the previous code treated EVERY DioException as
  /// "no internet" and fell back to the offline lease — but a DioException
  /// also wraps ordinary HTTP error responses (401, 403, 5xx). A server
  /// that explicitly answered "401 unknown token" is reachable and has an
  /// opinion; silently reading that as "offline, use cached lease" would
  /// let a device with an invalidated token keep using local data for up
  /// to the whole lease window.
  DeviceStatusResult _interpretDioFailure(DioException e, SyncMetadataData meta) {
    final statusCode = e.response?.statusCode;

    if (statusCode != null) {
      // The server responded — this is never a connectivity problem.
      if (statusCode == 401) {
        // Invalid/unknown device token — fail closed, do not serve cached data.
        return DeviceStatusResult(DeviceAuthState.authError);
      }
      if (statusCode == 403) {
        // Explicit security rejection — same treatment as 401.
        return DeviceStatusResult(DeviceAuthState.authError);
      }
      if (statusCode >= 500) {
        // Server-side failure, not a device-auth decision by the server —
        // treated as a temporary outage, same as a genuine transport
        // failure below (an explicit, deliberate choice per review, not
        // an oversight: a device shouldn't be locked out by a backend
        // deploy blip).
        return _offlineLeaseResult(meta);
      }
      // Any other unexpected HTTP status from a server that DID respond:
      // fail closed rather than silently trusting cached data.
      return DeviceStatusResult(DeviceAuthState.authError);
    }

    // No response at all — genuine transport failure (timeout, DNS,
    // connection refused, no network reachability). This is the ONLY
    // case the offline lease is meant to cover.
    return _offlineLeaseResult(meta);
  }

  DeviceStatusResult _offlineLeaseResult(SyncMetadataData meta) {
    final withinLease = offlineLease.isWithinLease(
      meta.lastAuthorizationCheck,
      leaseHours: meta.offlineLeaseHours,
    );
    return DeviceStatusResult(
      withinLease ? DeviceAuthState.offlineWithinLease : DeviceAuthState.offlineLeaseExpired,
    );
  }

  /// Persists everything the central server is authoritative for and that
  /// the client must keep honoring even while offline: the authorization
  /// timestamp itself and the current `offline_lease_hours` policy.
  Future<void> _persistServerControlledConfig(Map<String, dynamic> data) async {
    final leaseHours = data['offline_lease_hours'] as int?;
    await (db.update(db.syncMetadata)..where((t) => t.id.equals(1))).write(
      SyncMetadataCompanion(
        lastAuthorizationCheck: Value(DateTime.now().toUtc()),
        offlineLeaseHours: leaseHours != null ? Value(leaseHours) : const Value.absent(),
      ),
    );
  }

  @visibleForTesting
  DeviceStatusResult interpretStatusForTesting(Map<String, dynamic> data) => _interpretStatus(data);

  DeviceStatusResult _interpretStatus(Map<String, dynamic> data) {
    switch (data['status'] as String?) {
      case 'DEVICE_REVOKED':
        return DeviceStatusResult(DeviceAuthState.revoked);
      case 'PARISH_DISABLED':
        return DeviceStatusResult(DeviceAuthState.parishDisabled);
      case 'UPDATE_REQUIRED':
        return DeviceStatusResult(
          DeviceAuthState.updateRequired,
          minimumSupportedAppVersion: data['minimum_supported_app_version'] as String?,
        );
      case 'ACTIVE':
        return DeviceStatusResult(DeviceAuthState.active);
      default:
        // Review round fix: was `DeviceAuthState.active` — fail-OPEN. An
        // unrecognized status string (a future server status this build
        // predates, or a malformed/empty response) must NEVER be treated
        // as active. Fail closed instead.
        return DeviceStatusResult(DeviceAuthState.authError);
    }
  }

  /// Full sync cycle. Safe to call repeatedly (e.g. from a pull-to-refresh
  /// or a periodic foreground timer) — a re-entrant guard prevents
  /// overlapping runs.
  ///
  /// Review round (snapshot-first model): the Legacy/Witosa adapter uses
  /// NO cursor, NO `/mobile/sync`, NO tombstones — see
  /// `fetchAndApplySnapshot()`. The OLD incremental-cursor path below
  /// (`pullChanges()`/`_drainSyncPages()`/`_applyIncremental()`) is kept
  /// in this file as a reference/FUTURE design (Iteration 1's original
  /// contract, for a backend that DOES maintain a real change-log) but is
  /// deliberately NOT called from here anymore — do not wire it back in
  /// without a deliberate decision to, matching the backend's own
  /// "⚠ NOT USED BY THE LEGACY SNAPSHOT ADAPTER / FUTURE" markers.
  ///
  /// Review round fix, point 3: does NOT call `pushPendingActions()` on
  /// this read-only milestone. The Witosa adapter has no
  /// `/mobile/actions` endpoint yet — if a pending action were ever
  /// queued (it never is on this milestone, nothing in the UI enqueues
  /// one yet, but "the queue happens to be empty today" is not a
  /// guarantee), pushing it would throw on a 404, and that exception
  /// would abort this whole method BEFORE `fetchAndApplySnapshot()` ever
  /// ran — meaning one stray pending action could block even a plain,
  /// read-only schedule refresh. Restore the `pushPendingActions()` call
  /// here once real write/actions support exists for this adapter.
  ///
  /// Review round fix, point 5: `sync-ack` is back — dropping it when we
  /// moved to snapshot-first would have silently blinded
  /// app.ministrant.eu's admin panel to whether a device is actually
  /// syncing. Sent ONLY after `fetchAndApplySnapshot()` returns
  /// successfully (i.e. the GET succeeded AND the SQLite transaction
  /// committed) — if either fails, the exception propagates out of THIS
  /// method before reaching the ack call, so a failed/rolled-back
  /// snapshot never gets falsely reported as a successful sync.
  Future<void> runFullSync() async {
    if (_isSyncing) return;
    _isSyncing = true;
    try {
      await fetchAndApplySnapshot();
      await _acknowledgeSyncToCentral();
    } finally {
      _isSyncing = false;
    }
  }

  /// Snapshot-first sync (review round correction — replaces the
  /// cursor/incremental model for the Legacy/Witosa adapter): one GET
  /// `/mobile/bootstrap`, then ONE atomic SQLite transaction that
  /// REPLACES the local events+schedule snapshot outright — never an
  /// upsert-only merge. This is what correctly reflects rows deleted
  /// server-side even though the real legacy tables have no updated_at
  /// or tombstone column at all (see the backend's
  /// EventsRepositoryInterface docblock).
  ///
  /// Point 7 (atomicity): `db.transaction()` is Drift's real
  /// BEGIN/COMMIT/ROLLBACK — if ANYTHING inside throws (a malformed row
  /// from the server, a disk write error), Drift rolls the whole thing
  /// back automatically and this function's exception propagates to the
  /// caller. The previous snapshot is left completely untouched either
  /// way: never a partial mix of old and new rows. The caller (typically
  /// a background sync trigger) is expected to swallow/log that
  /// exception and let the UI keep showing the last good snapshot,
  /// exactly per spec §26's "UI never blocks on this" pattern — this
  /// method itself does not swallow anything, so a test or a stricter
  /// caller can still observe failures.
  Future<void> fetchAndApplySnapshot() async {
    final dio = await api.parish();
    try {
      final resp = await dio.get('/mobile/bootstrap');
      await _applySnapshot(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;

      // Review round (milestone "Mój grafik", point 4): a 401 from the
      // PARISH api (this Dio, `api.parish()`) means the mobile_user_token
      // is invalid/expired/revoked — a USER session problem. This must
      // NEVER be confused with a 401 from app.ministrant.eu
      // (checkDeviceStatus's own DioException handling, a DEVICE problem
      // — see DeviceAuthState.authError) — they are different tokens,
      // different servers, different remediation (re-login vs.
      // re-activation).
      if (statusCode == 401) {
        throw ParishSessionExpiredException();
      }

      // Review round fix: 400/403/422 are CONTRACT problems (a header
      // the backend requires but wasn't sent, a validation failure) —
      // the exact bug this closes: a missing X-Installation-Id header
      // produced a 400 that used to be swallowed by HomeScreen's generic
      // catch, silently rendering an empty "Mój grafik" as if the user
      // genuinely had no assignments. NEVER conflate this with a
      // transport failure below.
      if (statusCode == 400 || statusCode == 403 || statusCode == 422) {
        String? message;
        final body = e.response?.data;
        if (body is Map) {
          message = body['message'] as String? ?? body['error'] as String?;
        }
        throw ParishContractErrorException(statusCode: statusCode!, message: message);
      }

      // Anything else (no response at all — timeout/DNS/connection
      // error — or a 5xx) is a genuine transport/server-outage failure:
      // rethrown as a plain DioException, which the caller (HomeScreen)
      // is expected to treat as "offline, keep showing the last good
      // snapshot" — exactly spec §26's "UI never blocks on this".
      rethrow;
    }
  }

  /// Test seam (review round, point 7): lets a test drive the atomic
  /// snapshot-replace logic directly with a synthetic payload, without
  /// needing a real/fake HTTP layer for `/mobile/bootstrap` itself.
  @visibleForTesting
  Future<void> applySnapshotForTesting(Map<String, dynamic> data) => _applySnapshot(data);

  Future<void> _applySnapshot(Map<String, dynamic> data) async {
    final generatedAt = DateTime.tryParse(data['generated_at'] as String? ?? '') ?? DateTime.now().toUtc();

    await db.transaction(() async {
      await db.delete(db.events).go();
      for (final row in _rows(data['events'])) {
        await db.into(db.events).insertOnConflictUpdate(_mapLegacyEvent(row));
      }

      await db.delete(db.scheduleAssignments).go();
      for (final row in _rows(data['schedule'])) {
        await db.into(db.scheduleAssignments).insertOnConflictUpdate(_mapLegacySchedule(row));
      }

      // Hybrid dashboard milestone, P1: parish-wide, replaced wholesale
      // on every snapshot — same reasoning as events/schedule (the real
      // legacy `announcements` table has no updated_at/tombstone column
      // either, so a full replace is the only way to reflect a deletion).
      await db.delete(db.announcements).go();
      for (final row in _rows(data['announcements'])) {
        await db.into(db.announcements).insertOnConflictUpdate(_mapLegacyAnnouncement(row));
      }

      // Points: history is per-user already (bootstrap.php scopes the
      // query to the caller), replaced wholesale — same reasoning as
      // everything else in this snapshot.
      await db.delete(db.points).go();
      final pointsData = data['points'];
      if (pointsData is Map) {
        for (final row in _rows(pointsData['history'])) {
          await db.into(db.points).insertOnConflictUpdate(_mapLegacyPoint(row));
        }
      }

      // Ranking: a fresh server-computed projection every sync — see
      // LegacyMysqlRankingRepository's own docblock ("nie twórz lokalnego
      // źródła prawdy rankingu"). Replaced wholesale like everything else.
      await db.delete(db.rankingEntries).go();
      final rankingData = data['ranking'];
      if (rankingData is Map) {
        for (final row in _rows(rankingData['entries'])) {
          await db.into(db.rankingEntries).insertOnConflictUpdate(_mapLegacyRankingEntry(row));
        }
      }

      // Substitutions: READ ONLY (review round — write stays on the
      // substitution-finder.php WebView until the known
      // accept_substitution.php bug is fixed). "mine" and "available" are
      // mutually exclusive server-side, so no id collision between them.
      await db.delete(db.substitutionRequests).go();
      final substitutionsData = data['substitutions'];
      if (substitutionsData is Map) {
        for (final row in _rows(substitutionsData['mine'])) {
          await db.into(db.substitutionRequests).insertOnConflictUpdate(_mapLegacySubstitution(row, isMine: true));
        }
        for (final row in _rows(substitutionsData['available'])) {
          await db.into(db.substitutionRequests).insertOnConflictUpdate(_mapLegacySubstitution(row, isMine: false));
        }
      }

      // Review round fix (real bug, found via a direct-call test that
      // bypasses HomeScreen's usual checkDeviceStatus()-first ordering):
      // this used to be a bare `update()..where(id.equals(1))`, which is
      // a SILENT NO-OP if no sync_metadata row exists yet. In the real
      // app this is normally masked — checkDeviceStatus() always runs
      // first and calls ensureSyncMetadata(), which creates the row —
      // but that ordering is an assumption this method itself shouldn't
      // depend on to correctly persist `generated_at`. insertOnConflictUpdate
      // is unconditionally correct: creates the row with lastSyncAt set
      // if none existed, or updates ONLY lastSyncAt (leaving cursor/
      // lastAuthorizationCheck/offlineLeaseHours untouched) if one did.
      await db.into(db.syncMetadata).insertOnConflictUpdate(
            SyncMetadataCompanion.insert(id: const Value(1), lastSyncAt: Value(generatedAt)),
          );
    });
  }

  EventsCompanion _mapLegacyEvent(Map<String, dynamic> row) => EventsCompanion.insert(
        id: row['id'] as String, // canonical "{source}:{raw_id}" — see the backend contract
        rawId: row['raw_id'] as int,
        source: row['source'] as String,
        eventDate: DateTime.parse(row['event_date'] as String),
        description: Value(row['description'] as String?),
        moduleId: Value(row['module_id'] as int?),
        isCancelled: Value(row['is_cancelled'] as bool? ?? false),
      );

  ScheduleAssignmentsCompanion _mapLegacySchedule(Map<String, dynamic> row) => ScheduleAssignmentsCompanion.insert(
        id: row['id'] as String,
        rawId: row['raw_id'] as int,
        eventId: row['event_id'] as String,
        eventSource: row['event_source'] as String,
        userId: Value(row['user_id'] as int?),
        guestName: Value(row['guest_name'] as String?),
        isPresent: Value(row['is_present'] as bool? ?? false),
        status: row['status'] as String,
      );

  AnnouncementsCompanion _mapLegacyAnnouncement(Map<String, dynamic> row) => AnnouncementsCompanion.insert(
        id: row['id'] as String,
        rawId: row['raw_id'] as int,
        title: row['title'] as String,
        content: row['content'] as String,
        authorName: Value(row['author_name'] as String?),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  PointsCompanion _mapLegacyPoint(Map<String, dynamic> row) => PointsCompanion.insert(
        id: row['id'] as String,
        rawId: row['raw_id'] as int,
        pointsValue: row['points_value'] as int,
        reason: Value(row['reason'] as String?),
        eventType: Value(row['event_type'] as String?),
        assignerName: Value(row['assigner_name'] as String?),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  RankingEntriesCompanion _mapLegacyRankingEntry(Map<String, dynamic> row) => RankingEntriesCompanion.insert(
        id: 'ranking:${row['user_id']}',
        userId: row['user_id'] as int,
        fullName: row['full_name'] as String,
        totalPoints: row['total_points'] as int,
        position: row['position'] as int,
        isCurrentUser: Value(row['is_current_user'] as bool? ?? false),
      );

  SubstitutionRequestsCompanion _mapLegacySubstitution(Map<String, dynamic> row, {required bool isMine}) =>
      SubstitutionRequestsCompanion.insert(
        id: row['id'] as String,
        rawId: row['raw_id'] as int,
        status: row['status'] as String,
        requestingUserName: row['requesting_user_name'] as String,
        acceptedByName: Value(row['accepted_by_name'] as String?),
        eventId: row['event_id'] as String,
        eventSource: row['event_source'] as String,
        eventDate: Value(row['event_date'] != null ? DateTime.parse(row['event_date'] as String) : null),
        eventDescription: Value(row['event_description'] as String?),
        isMine: isMine,
        createdAt: DateTime.parse(row['created_at'] as String),
      );



  List<Map<String, dynamic>> _rows(dynamic raw) =>
      raw is List ? raw.cast<Map<String, dynamic>>() : const <Map<String, dynamic>>[];

  /// Tells app.ministrant.eu that this device successfully completed a
  /// business-data sync with its parish — this is what makes the panel's
  /// `last_sync_at` column meaningful (the central backend has no other
  /// way to know a parish-subdomain sync happened, since it never sees
  /// that traffic). Review round point 5: restored after a brief absence
  /// during the snapshot-first migration — called by `runFullSync()`
  /// ONLY after `fetchAndApplySnapshot()` returns successfully.
  Future<void> _acknowledgeSyncToCentral() async {
    final token = await secureStorage.deviceToken;
    if (token == null) return;
    try {
      final dio = api.centralWithAuth(token);
      await dio.post('/device/sync-ack');
    } on DioException {
      // Best-effort — a missed ack just delays what the panel shows, it
      // never blocks the actual sync that already succeeded above.
    }
  }

  /// Pushes every queued PendingAction to the parish server, one at a time,
  /// removing each on success. A 409 conflict is surfaced to the caller
  /// via [onConflict] rather than silently resolved — per spec §1, the
  /// app must never auto-overwrite someone else's later change.
  Future<void> pushPendingActions({void Function(PendingAction action, Map<String, dynamic> conflict)? onConflict}) async {
    final pending = await db.select(db.pendingActions).get();
    if (pending.isEmpty) return;

    final dio = await api.parish();

    final resp = await dio.post('/mobile/actions', data: {
      'actions': pending
          .map((a) => {
                'client_action_id': a.clientActionId,
                'type': a.type,
                'payload': jsonDecode(a.payloadJson), // was: raw String — backend expects a JSON object
                if (a.baseVersion != null) 'base_version': a.baseVersion,
                'created_at': a.createdAt.toIso8601String(),
              })
          .toList(),
    });

    final results = (resp.data['results'] as List).cast<Map<String, dynamic>>();

    for (final result in results) {
      final action = pending.firstWhere((a) => a.clientActionId == result['client_action_id']);

      switch (result['status']) {
        case 'applied':
        case 'already_applied':
          await (db.delete(db.pendingActions)..where((t) => t.id.equals(action.id))).go();
          break;
        case 'conflict':
          // Leave the action queued for now — the caller (UI layer) decides
          // whether to drop it, or fetch the current record and let the
          // user redo their edit against the new base_version.
          onConflict?.call(action, result);
          break;
        default:
          await (db.update(db.pendingActions)..where((t) => t.id.equals(action.id))).write(
            PendingActionsCompanion(
              attemptCount: Value(action.attemptCount + 1),
              lastError: Value(result['reason']?.toString() ?? 'unknown_error'),
            ),
          );
      }
    }
  }

  /// Enqueue a user action performed right now (online or offline — the
  /// caller doesn't need to know or care). Call `runFullSync()` afterwards
  /// if you want to try pushing immediately.
  Future<void> enqueueAction({required String type, required Map<String, dynamic> payload, int? baseVersion}) async {
    await db.into(db.pendingActions).insert(
          PendingActionsCompanion.insert(
            clientActionId: _uuid.v4(),
            type: type,
            payloadJson: jsonEncode(payload), // real JSON — was payload.toString() (invalid JSON, backend rejected it)
            baseVersion: Value(baseVersion),
            createdAt: DateTime.now().toUtc(),
          ),
        );
  }

  Future<void> heartbeat({required String appVersion, required String osVersion}) async {
    final token = await secureStorage.deviceToken;
    if (token == null) return;
    try {
      final dio = api.centralWithAuth(token);
      final resp = await dio.post('/device/heartbeat', data: {'app_version': appVersion, 'os_version': osVersion});
      await _persistServerControlledConfig(resp.data as Map<String, dynamic>);
    } on DioException {
      // Best-effort — heartbeat failing silently is fine, see spec §34.
    }
  }
}
