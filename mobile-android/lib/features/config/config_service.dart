import 'dart:convert';
import 'package:dio/dio.dart';
import '../../core/database/app_database.dart';
import '../../core/network/api_client.dart';

/// Fetches and caches BOTH configs the app depends on, kept strictly
/// separate per spec decision #6:
///   - parish dashboard/module config: {parish_server}/api/v1/mobile/config
///   - global fleet config: app.ministrant.eu/api/client-config
/// Both are cached locally (spec §19) so a temporarily unreachable server
/// never blanks out the dashboard or the update-check logic.
class ConfigService {
  ConfigService({required this.db, required this.api});

  final AppDatabase db;
  final ApiClient api;

  /// Returns the parish dashboard config as a decoded map, preferring a
  /// fresh fetch but always falling back to the cached copy on any
  /// network failure. Returns null only if there is NEITHER a fresh
  /// fetch NOR any cached config yet (e.g. very first run, offline).
  Future<Map<String, dynamic>?> loadDashboardConfig() async {
    try {
      final dio = await api.parish();
      final resp = await dio.get('/mobile/config');
      final data = resp.data as Map<String, dynamic>;
      await db.saveDashboardConfig(data['schema_version'] as int? ?? 1, jsonEncode(data));
      return data;
    } on DioException {
      final cached = await db.getDashboardConfig();
      if (cached == null) return null;
      return jsonDecode(cached.configJson) as Map<String, dynamic>;
    } on StateError {
      // api.parish() throws StateError if not activated yet — caller
      // shouldn't normally reach here in that state, but fail safe.
      final cached = await db.getDashboardConfig();
      if (cached == null) return null;
      return jsonDecode(cached.configJson) as Map<String, dynamic>;
    }
  }

  /// Same fetch-then-fallback-to-cache pattern for the global client
  /// config. This one has NO activation dependency — it's checkable
  /// before the app is even activated (e.g. to show a forced-update
  /// screen right at first launch).
  Future<Map<String, dynamic>?> loadClientConfig() async {
    try {
      final resp = await api.central.get('/client-config');
      final data = resp.data as Map<String, dynamic>;
      await db.saveClientConfig(jsonEncode(data));
      return data;
    } on DioException {
      final cached = await db.getClientConfig();
      if (cached == null) return null;
      return jsonDecode(cached.configJson) as Map<String, dynamic>;
    }
  }
}
