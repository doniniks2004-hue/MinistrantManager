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

enum DeviceAuthState { active, revoked, parishDisabled, updateRequired, offlineWithinLease, offlineLeaseExpired }

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
      final resp = await dio.post('/device/status');
      final data = resp.data as Map<String, dynamic>;

      await _persistServerControlledConfig(data);

      return _interpretStatus(data);
    } on DioException {
      // No connectivity / server unreachable — fall back to offline lease,
      // using the LAST value of offline_lease_hours this device actually
      // saw from the server (never a hardcoded client constant).
      final withinLease = offlineLease.isWithinLease(
        meta.lastAuthorizationCheck,
        leaseHours: meta.offlineLeaseHours,
      );
      return DeviceStatusResult(
        withinLease ? DeviceAuthState.offlineWithinLease : DeviceAuthState.offlineLeaseExpired,
      );
    }
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
      default:
        return DeviceStatusResult(DeviceAuthState.active);
    }
  }

  /// Full sync cycle. Safe to call repeatedly (e.g. from a pull-to-refresh
  /// or a periodic foreground timer) — a re-entrant guard prevents
  /// overlapping runs.
  Future<void> runFullSync() async {
    if (_isSyncing) return;
    _isSyncing = true;
    try {
      await pushPendingActions();
      await pullChanges();
      await _acknowledgeSyncToCentral();
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> pullChanges() async {
    final dio = await api.parish();
    var meta = await db.ensureSyncMetadata();

    if (meta.cursor == null) {
      // First-ever contact with this parish: one full snapshot. The
      // response's own "cursor" field (Iteration 1.1 point 1 fix on the
      // server side) is what lets step two below actually start from
      // "right after this snapshot" instead of looping back into
      // bootstrap forever.
      final resp = await dio.get('/mobile/bootstrap');
      await _applyBootstrap(resp.data as Map<String, dynamic>);
      meta = await db.ensureSyncMetadata(); // re-read: cursor is now set
    }

    // Iteration 1.1 point 2: keep paging /mobile/sync until the server
    // reports has_more=false, so ONE runFullSync() call reaches the
    // current end of the change log — a parish with many pending changes
    // no longer needs "five more app launches" to catch up.
    const maxPagesPerRun = 200; // safety cap against a misbehaving server claiming has_more forever
    var page = 0;
    var hasMore = true;
    while (hasMore && page < maxPagesPerRun) {
      final cursor = (await db.ensureSyncMetadata()).cursor;
      final resp = await dio.get('/mobile/sync', queryParameters: {'cursor': cursor});
      hasMore = await _applyIncremental(resp.data as Map<String, dynamic>);
      page++;
    }

    await (db.update(db.syncMetadata)..where((t) => t.id.equals(1))).write(
      SyncMetadataCompanion(lastSyncAt: Value(DateTime.now().toUtc())),
    );
  }

  EventsCompanion _mapEvent(Map<String, dynamic> row) => EventsCompanion.insert(
        id: row['id'].toString(),
        title: row['title'] as String? ?? '',
        startsAt: DateTime.parse(row['starts_at'] as String),
        endsAt: Value(row['ends_at'] != null ? DateTime.parse(row['ends_at'] as String) : null),
        payloadJson: jsonEncode(row),
        version: Value(row['version'] as int? ?? 1),
        updatedAt: DateTime.parse(row['updated_at'] as String? ?? DateTime.now().toUtc().toIso8601String()),
      );

  ScheduleAssignmentsCompanion _mapSchedule(Map<String, dynamic> row) => ScheduleAssignmentsCompanion.insert(
        id: row['id'].toString(),
        eventId: Value(row['event_id']?.toString()),
        personName: row['person_name'] as String? ?? '',
        role: Value(row['role'] as String?),
        payloadJson: jsonEncode(row),
        version: Value(row['version'] as int? ?? 1),
        updatedAt: DateTime.parse(row['updated_at'] as String? ?? DateTime.now().toUtc().toIso8601String()),
      );

  AttendanceCompanion _mapAttendance(Map<String, dynamic> row) => AttendanceCompanion.insert(
        id: row['id'].toString(),
        eventId: row['event_id'].toString(),
        personName: row['person_name'] as String? ?? '',
        status: row['status'] as String? ?? 'unknown',
        recordedAt: DateTime.parse(row['recorded_at'] as String? ?? DateTime.now().toUtc().toIso8601String()),
        payloadJson: jsonEncode(row),
      );

  PointsCompanion _mapPoint(Map<String, dynamic> row) => PointsCompanion.insert(
        id: row['id'].toString(),
        personName: row['person_name'] as String? ?? '',
        amount: row['amount'] as int? ?? 0,
        reason: Value(row['reason'] as String?),
        awardedAt: DateTime.parse(row['awarded_at'] as String? ?? DateTime.now().toUtc().toIso8601String()),
      );

  RankingCompanion _mapRanking(Map<String, dynamic> row) => RankingCompanion.insert(
        id: row['id'].toString(),
        personName: row['person_name'] as String? ?? '',
        totalPoints: row['total_points'] as int? ?? 0,
        position: Value(row['position'] as int?),
        payloadJson: Value(jsonEncode(row)),
        updatedAt: DateTime.parse(row['updated_at'] as String? ?? DateTime.now().toUtc().toIso8601String()),
      );

  AnnouncementsCompanion _mapAnnouncement(Map<String, dynamic> row) => AnnouncementsCompanion.insert(
        id: row['id'].toString(),
        title: row['title'] as String? ?? '',
        body: row['body'] as String? ?? '',
        publishedAt: DateTime.parse(row['published_at'] as String? ?? DateTime.now().toUtc().toIso8601String()),
        isRead: Value(row['is_read'] as bool? ?? false),
      );

  SubstitutionsCompanion _mapSubstitution(Map<String, dynamic> row) => SubstitutionsCompanion.insert(
        id: row['id'].toString(),
        eventId: Value(row['event_id']?.toString()),
        fromPerson: row['from_person'] as String? ?? '',
        toPerson: Value(row['to_person'] as String?),
        status: row['status'] as String? ?? 'requested',
        payloadJson: jsonEncode(row),
        version: Value(row['version'] as int? ?? 1),
        updatedAt: DateTime.parse(row['updated_at'] as String? ?? DateTime.now().toUtc().toIso8601String()),
      );

  List<Map<String, dynamic>> _rows(dynamic raw) =>
      raw is List ? raw.cast<Map<String, dynamic>>() : const <Map<String, dynamic>>[];

  List<String> _ids(dynamic raw) => raw is List ? raw.map((e) => e.toString()).toList() : const <String>[];

  /// Full bootstrap: replaces the local snapshot of every business table
  /// with what the server sent. Each list in the payload is expected to
  /// contain "row-shaped" JSON objects matching the parish backend's
  /// `/mobile/bootstrap` response (see parish-subdomain-api-reference).
  /// Tables are cleared then re-inserted inside ONE transaction, so a
  /// crash mid-bootstrap simply repeats the whole bootstrap next run
  /// (cursor is only written at the very end) rather than leaving a
  /// half-populated database.
  Future<void> _applyBootstrap(Map<String, dynamic> data) async {
    await db.transaction(() async {
      await db.delete(db.events).go();
      for (final row in _rows(data['events'])) {
        await db.into(db.events).insertOnConflictUpdate(_mapEvent(row));
      }

      await db.delete(db.scheduleAssignments).go();
      for (final row in _rows(data['schedule'])) {
        await db.into(db.scheduleAssignments).insertOnConflictUpdate(_mapSchedule(row));
      }

      await db.delete(db.attendance).go();
      for (final row in _rows(data['attendance'])) {
        await db.into(db.attendance).insertOnConflictUpdate(_mapAttendance(row));
      }

      await db.delete(db.points).go();
      for (final row in _rows(data['points'])) {
        await db.into(db.points).insertOnConflictUpdate(_mapPoint(row));
      }

      await db.delete(db.ranking).go();
      for (final row in _rows(data['ranking'])) {
        await db.into(db.ranking).insertOnConflictUpdate(_mapRanking(row));
      }

      await db.delete(db.announcements).go();
      for (final row in _rows(data['announcements'])) {
        await db.into(db.announcements).insertOnConflictUpdate(_mapAnnouncement(row));
      }

      await db.delete(db.substitutions).go();
      for (final row in _rows(data['substitutions'])) {
        await db.into(db.substitutions).insertOnConflictUpdate(_mapSubstitution(row));
      }

      if (data['parish'] != null) {
        final parish = data['parish'] as Map<String, dynamic>;
        await db.into(db.parishInfo).insertOnConflictUpdate(ParishInfoCompanion.insert(
              id: Value(parish['id'] as int),
              name: parish['name'] as String? ?? '',
              slug: parish['slug'] as String? ?? '',
              serverUrl: parish['server_url'] as String? ?? '',
              settingsJson: Value(jsonEncode(parish['settings'] ?? {})),
            ));
      }

      final cursor = data['cursor'] as String?;
      await (db.update(db.syncMetadata)..where((t) => t.id.equals(1)))
          .write(SyncMetadataCompanion(cursor: Value(cursor)));
    });
  }

  /// Incremental sync: upserts only what's in `changes` (same per-table
  /// shape as bootstrap, but partial), THEN applies tombstones from
  /// `deleted`. Returns the server's `has_more` flag so the CALLER
  /// (pullChanges — Iteration 1.1 point 2) can keep paging in a loop
  /// until it's false, instead of applying exactly one page per
  /// `runFullSync()` call regardless of how many pages actually exist.
  Future<bool> _applyIncremental(Map<String, dynamic> data) async {
    await db.transaction(() async {
      final changes = (data['changes'] as Map<String, dynamic>?) ?? {};

      for (final row in _rows(changes['events'])) {
        await db.into(db.events).insertOnConflictUpdate(_mapEvent(row));
      }
      for (final row in _rows(changes['schedule'])) {
        await db.into(db.scheduleAssignments).insertOnConflictUpdate(_mapSchedule(row));
      }
      for (final row in _rows(changes['attendance'])) {
        await db.into(db.attendance).insertOnConflictUpdate(_mapAttendance(row));
      }
      for (final row in _rows(changes['points'])) {
        await db.into(db.points).insertOnConflictUpdate(_mapPoint(row));
      }
      for (final row in _rows(changes['ranking'])) {
        await db.into(db.ranking).insertOnConflictUpdate(_mapRanking(row));
      }
      for (final row in _rows(changes['announcements'])) {
        await db.into(db.announcements).insertOnConflictUpdate(_mapAnnouncement(row));
      }
      for (final row in _rows(changes['substitutions'])) {
        await db.into(db.substitutions).insertOnConflictUpdate(_mapSubstitution(row));
      }

      // Tombstones: rows the server considers deleted since the last cursor.
      final deleted = (data['deleted'] as Map<String, dynamic>?) ?? {};

      final deletedEventIds = _ids(deleted['events']);
      if (deletedEventIds.isNotEmpty) {
        await (db.delete(db.events)..where((t) => t.id.isIn(deletedEventIds))).go();
      }
      final deletedScheduleIds = _ids(deleted['schedule']);
      if (deletedScheduleIds.isNotEmpty) {
        await (db.delete(db.scheduleAssignments)..where((t) => t.id.isIn(deletedScheduleIds))).go();
      }
      final deletedAttendanceIds = _ids(deleted['attendance']);
      if (deletedAttendanceIds.isNotEmpty) {
        await (db.delete(db.attendance)..where((t) => t.id.isIn(deletedAttendanceIds))).go();
      }
      final deletedPointsIds = _ids(deleted['points']);
      if (deletedPointsIds.isNotEmpty) {
        await (db.delete(db.points)..where((t) => t.id.isIn(deletedPointsIds))).go();
      }
      final deletedRankingIds = _ids(deleted['ranking']);
      if (deletedRankingIds.isNotEmpty) {
        await (db.delete(db.ranking)..where((t) => t.id.isIn(deletedRankingIds))).go();
      }
      final deletedAnnouncementIds = _ids(deleted['announcements']);
      if (deletedAnnouncementIds.isNotEmpty) {
        await (db.delete(db.announcements)..where((t) => t.id.isIn(deletedAnnouncementIds))).go();
      }
      final deletedSubstitutionIds = _ids(deleted['substitutions']);
      if (deletedSubstitutionIds.isNotEmpty) {
        await (db.delete(db.substitutions)..where((t) => t.id.isIn(deletedSubstitutionIds))).go();
      }

      final cursor = data['cursor'] as String?;
      await (db.update(db.syncMetadata)..where((t) => t.id.equals(1)))
          .write(SyncMetadataCompanion(cursor: Value(cursor)));
    });

    return data['has_more'] as bool? ?? false;
  }

  /// Tells app.ministrant.eu that this device successfully completed a
  /// business-data sync with its parish. This is what makes the panel's
  /// `last_sync_at` column meaningful (flagged as dead in review) — the
  /// central backend has no other way to know a parish-subdomain sync
  /// happened, since it never sees that traffic.
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
