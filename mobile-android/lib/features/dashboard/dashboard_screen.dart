import 'package:flutter/material.dart';
import '../../core/database/app_database.dart';
import '../../core/secure/secure_storage_service.dart';
import '../announcements/announcements_screen.dart';
import '../attendance/attendance_screen.dart';
import '../points/points_screen.dart';
import '../profile/profile_screen.dart';
import '../ranking/ranking_screen.dart';
import '../schedule/my_schedule_screen.dart';
import '../substitutions/substitutions_screen.dart';
import '../webview/legacy_module_screen.dart';
import '../webview/webview_handoff_service.dart';
import 'module_descriptor.dart';

/// Hybrid dashboard milestone — the app's main screen post-login.
/// Renders a grid of tiles from the server-driven module list, routing
/// each tap to either a native screen or a [LegacyModuleScreen] (WebView)
/// — review round point 1: the dashboard makes NO assumption that any
/// given module is native; that's entirely a server decision, re-read on
/// every sync.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.modules,
    required this.userRoleId,
    required this.db,
    required this.secureStorage,
    required this.handoffService,
    required this.appVersion,
    required this.isOnline,
    required this.syncFailed,
    required this.lastSyncAt,
    required this.onSync,
    required this.onLogout,
  });

  final List<ModuleDescriptor> modules;
  final int? userRoleId;
  final AppDatabase db;
  final SecureStorageService secureStorage;
  final WebviewHandoffService handoffService;
  final String appVersion;
  final bool isOnline;
  final bool syncFailed;
  final DateTime? lastSyncAt;
  final Future<void> Function() onSync;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    // Review round point 22: "nie ufamy tylko UI" — this filter decides
    // what to DRAW, nothing more. The actual enforcement (role checks on
    // bootstrap.php / webview_handoff.php's allowlist) happens server-side
    // regardless of what this filter lets through to the grid.
    final visible = modules.where((m) => m.visibleFor(userRoleId)).toList();
    // UX pass: everyday modules stay on the main grid; the ~40 admin
    // "Konfiguracja" items (mirroring the real sidebar.php's own section
    // title) move behind one "Administracja" entry point instead of
    // flooding the dashboard — review round point 3/5: "dashboard ma
    // wyglądać jak właściwa aplikacja, a nie techniczny launcher".
    final everyday = visible.where((m) => m.section != 'config').toList();
    final adminItems = visible.where((m) => m.section == 'config').toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Ministrant Manager')),
      body: Column(
        children: [
          if (!isOnline)
            _Banner(
              color: Colors.amber.shade100,
              text: '⚠ OFFLINE — dane z ${lastSyncAt != null ? _formatDateTime(lastSyncAt!) : "poprzedniej synchronizacji"}',
            )
          else if (syncFailed)
            _Banner(
              color: Colors.red.shade100,
              text: 'Nie udało się zaktualizować danych. Pokazujemy ostatnią znaną wersję.',
            ),
          Expanded(
            child: RefreshIndicator(
              // UX pass: "Pull-to-refresh: snapshot refresh. Nie blokuj
              // ekranu spinnerem... Refresh działa w tle. Po commit do
              // SQLite Drift odświeża ekran." — onSync() is the SAME
              // background sync HomeScreen already runs on init/resume;
              // this just gives the user a way to trigger it on demand.
              onRefresh: onSync,
              child: everyday.isEmpty && adminItems.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 120),
                        Center(child: Text('Brak dostępnych modułów.')),
                      ],
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 1.1,
                      ),
                      itemCount: everyday.length + (adminItems.isEmpty ? 0 : 1),
                      itemBuilder: (context, i) {
                        if (i == everyday.length) {
                          // The one synthetic "Administracja" tile — only
                          // shown at all if this user's role has ANY
                          // visible config-section item.
                          return _AdminEntryTile(onTap: () => _openAdminSection(context, adminItems));
                        }
                        final module = everyday[i];
                        return _ModuleTile(module: module, onTap: () => _openModule(context, module));
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openModule(BuildContext context, ModuleDescriptor module) async {
    switch (module.type) {
      case ModuleType.native:
        final screen = _buildNativeScreen(module.screen);
        if (screen == null) {
          _showUnsupported(context);
          return;
        }
        if (context.mounted) {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
        }
        break;
      case ModuleType.webview:
        if (module.path == null) {
          _showUnsupported(context);
          return;
        }
        final serverUrl = await secureStorage.serverUrl;
        if (serverUrl == null) return;
        final host = Uri.parse(serverUrl).host;
        if (context.mounted) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => LegacyModuleScreen(
              title: module.title,
              path: module.path!,
              handoffService: handoffService,
              allowedHost: host,
              isOnline: isOnline,
            ),
          ));
        }
        break;
      case ModuleType.unknown:
        _showUnsupported(context);
    }
  }

  /// Review round point 23: an unrecognized `screen` string never
  /// crashes — returning null routes to the safe-fallback dialog instead.
  Widget? _buildNativeScreen(String? screen) {
    switch (screen) {
      case 'my_schedule':
        return MyScheduleScreen(db: db);
      case 'announcements':
        return AnnouncementsScreen(db: db);
      case 'points_history':
        return PointsScreen(db: db);
      case 'ranking':
        return RankingScreen(db: db);
      case 'substitutions':
        return SubstitutionsScreen(db: db);
      case 'attendance':
        return AttendanceScreen(db: db);
      case 'profile':
        return ProfileScreen(
          db: db,
          secureStorage: secureStorage,
          appVersion: appVersion,
          onSync: onSync,
          onLogout: onLogout,
        );
      default:
        // Safety net for any `screen` name an older app build doesn't
        // recognize yet (review round point 23) — every P1 module is
        // now implemented; this branch exists for FUTURE server
        // capabilities this exact build predates.
        return null;
    }
  }

  void _showUnsupported(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Niedostępne'),
        content: const Text('Ten moduł wymaga nowszej wersji aplikacji.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}, ${two(local.hour)}:${two(local.minute)}';
  }

  void _openAdminSection(BuildContext context, List<ModuleDescriptor> adminItems) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _AdminSectionScreen(
        items: adminItems,
        onOpenModule: (module) => _openModule(context, module),
      ),
    ));
  }
}

/// UX pass: the real legacy `sidebar.php` groups these under one
/// "Konfiguracja" section title — this screen is that same grouping,
/// just as its own scrollable list instead of 40 tiles crammed into the
/// main dashboard grid.
class _AdminSectionScreen extends StatelessWidget {
  const _AdminSectionScreen({required this.items, required this.onOpenModule});

  final List<ModuleDescriptor> items;
  final void Function(ModuleDescriptor) onOpenModule;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Administracja')),
      body: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final module = items[i];
          return ListTile(
            leading: Icon(_ModuleTile.iconFor(module.icon)),
            title: Text(module.title),
            trailing: module.type == ModuleType.webview ? const Icon(Icons.public, size: 16) : null,
            onTap: () => onOpenModule(module),
          );
        },
      ),
    );
  }
}

class _AdminEntryTile extends StatelessWidget {
  const _AdminEntryTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.admin_panel_settings_outlined, size: 36),
              SizedBox(height: 12),
              Text('Administracja', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.all(12),
      child: Text(text, textAlign: TextAlign.center),
    );
  }
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({required this.module, required this.onTap});
  final ModuleDescriptor module;
  final VoidCallback onTap;

  static const _icons = {
    'calendar': Icons.calendar_today,
    'check': Icons.check_circle_outline,
    'star': Icons.star_outline,
    'trophy': Icons.emoji_events_outlined,
    'swap': Icons.swap_horiz,
    'megaphone': Icons.campaign_outlined,
    'user': Icons.person_outline,
    'note': Icons.note_outlined,
    'search': Icons.search,
    'sun': Icons.wb_sunny_outlined,
    'church': Icons.church_outlined,
    'bus': Icons.directions_bus_outlined,
    'users': Icons.groups_outlined,
    'calendar-off': Icons.event_busy_outlined,
    'user-plus': Icons.person_add_outlined,
    'candle': Icons.local_fire_department_outlined,
    'edit': Icons.edit_outlined,
    'users-cog': Icons.manage_accounts_outlined,
    'chart': Icons.bar_chart_outlined,
    'settings': Icons.settings_outlined,
  };

  static IconData iconFor(String icon) => _icons[icon] ?? Icons.apps;

  @override
  Widget build(BuildContext context) {
    final icon = iconFor(module.icon);
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 36),
              const SizedBox(height: 12),
              Text(module.title, textAlign: TextAlign.center),
              if (module.type == ModuleType.webview) ...[
                const SizedBox(height: 4),
                Icon(Icons.public, size: 14, color: Colors.grey.shade500),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
