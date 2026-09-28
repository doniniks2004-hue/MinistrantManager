import 'dart:convert';
import 'package:dio/dio.dart';
import '../../core/database/app_database.dart';
import '../../core/network/api_client.dart';
import 'capabilities_dashboard_adapter.dart';

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
  ///
  /// Review round, point 9: the real Legacy adapter's `/mobile/config`
  /// returns `{capabilities: {...}}`, not the `{dashboard, modules}` shape
  /// DashboardRenderer expects — CapabilitiesDashboardAdapter is the one
  /// place that bridges them, applied right here before caching, so
  /// everything downstream (including the cached copy) already speaks
  /// DashboardRenderer's contract.
  ///
  /// ⚠ NOT CURRENTLY CALLED from HomeScreen — the "Mój grafik" milestone
  /// bypasses the generic dashboard-grid system entirely in favor of a
  /// single, direct schedule screen (see HomeScreen/MyScheduleScreen).
  /// Kept valid and tested (config_service_test.dart,
  /// capabilities_dashboard_adapter_test.dart, dashboard_renderer_test.dart)
  /// for whenever a second/third real module needs an actual dashboard
  /// grid to choose between them.
  Future<Map<String, dynamic>?> loadDashboardConfig() async {
    try {
      final dio = await api.parish();
      final resp = await dio.get('/mobile/config');
      final raw = resp.data as Map<String, dynamic>;
      final data = CapabilitiesDashboardAdapter.toDashboardConfig(raw);
      await db.saveDashboardConfig(raw['schema_version'] as int? ?? 1, jsonEncode(data));
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
