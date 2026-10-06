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

  /// Returns the resolved module list for the dashboard — preferring a
  /// fresh fetch but always falling back to the cached copy on any
  /// network failure. Returns null only if there is NEITHER a fresh
  /// fetch NOR any cached list yet (e.g. very first run, offline).
  ///
  /// Hybrid dashboard milestone: if the server's `/mobile/config`
  /// response has a non-empty `modules` array (the NEW, real contract —
  /// see modules_builder.php), that is used directly. If it's missing or
  /// empty (an OLDER backend that only speaks `capabilities`),
  /// CapabilitiesDashboardAdapter derives an equivalent list from
  /// `capabilities` instead — DashboardScreen never needs to know which
  /// source it came from, both produce the exact same descriptor shape.
  Future<List<Map<String, dynamic>>?> loadModules() async {
    try {
      final dio = await api.parish();
      final resp = await dio.get('/mobile/config');
      final raw = resp.data as Map<String, dynamic>;

      final rawModules = raw['modules'];
      final modules = (rawModules is List && rawModules.isNotEmpty)
          ? rawModules.cast<Map<String, dynamic>>()
          : CapabilitiesDashboardAdapter.toModuleList(raw);

      await db.saveDashboardConfig(raw['schema_version'] as int? ?? 1, jsonEncode(modules));
      return modules;
    } on DioException {
      return _cachedModules();
    } on StateError {
      // api.parish() throws StateError if not activated/logged in yet —
      // caller shouldn't normally reach here in that state, but fail safe.
      return _cachedModules();
    }
  }

  Future<List<Map<String, dynamic>>?> _cachedModules() async {
    final cached = await db.getDashboardConfig();
    if (cached == null) return null;
    final decoded = jsonDecode(cached.configJson) as List<dynamic>;
    return decoded.cast<Map<String, dynamic>>();
  }

  /// Same fetch-then-fallback-to-cache pattern for the global client
  /// config. This one has NO activation dependency — it's checkable
  /// before the app is even activated (e.g. to show a forced-update
  /// screen right at first launch).
  Future<Map<String, dynamic>?> loadClientConfig() async {
    try {
      final resp = await api.central.get('/client-config');
      final raw = resp.data;

      // The central endpoint must never be allowed to brick startup because
      // a proxy/error page/legacy response returned a string instead of the
      // expected JSON object. Treat any unexpected shape exactly like an
      // unavailable config and fall back to the cached copy.
      if (raw is! Map) {
        return await _cachedClientConfig();
      }

      final data = Map<String, dynamic>.from(raw);
      await db.saveClientConfig(jsonEncode(data));
      return data;
    } catch (_) {
      return _cachedClientConfig();
    }
  }

  Future<Map<String, dynamic>?> _cachedClientConfig() async {
    final cached = await db.getClientConfig();
    if (cached == null) return null;

    try {
      final decoded = jsonDecode(cached.configJson);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }
}
