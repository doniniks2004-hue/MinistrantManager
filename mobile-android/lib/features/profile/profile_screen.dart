import 'package:flutter/material.dart';
import '../../core/database/app_database.dart';
import '../../core/secure/secure_storage_service.dart';
import '../device_settings/device_settings_screen.dart';
import '../revocation/revocation_handler.dart';

/// "Moje konto" (hybrid dashboard milestone, review round point 24).
/// Minimum: name, parish, connection status, last sync, app version,
/// sync button, logout. Deliberately never shows mobile_user_token or
/// device_token — "Nie pokazuj użytkownikowi tokenów."
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.db,
    required this.secureStorage,
    required this.appVersion,
    required this.onSync,
    required this.onLogout,
    required this.revocationHandler,
    required this.onParishReset,
  });

  final AppDatabase db;
  final SecureStorageService secureStorage;
  final String appVersion;
  final Future<void> Function() onSync;
  final VoidCallback onLogout;

  /// Offline-architecture milestone, P9 — device/parish-level, not an
  /// account action (see DeviceSettingsScreen's own docblock for why
  /// it's a separate screen reached FROM here rather than living here).
  final RevocationHandler revocationHandler;
  final VoidCallback onParishReset;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _syncing = false;

  Future<void> _handleSync() async {
    setState(() => _syncing = true);
    try {
      await widget.onSync();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wyloguj się?'),
        content: const Text('Będziesz musiał/a zalogować się ponownie.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ANULUJ')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('WYLOGUJ')),
        ],
      ),
    );
    if (confirmed == true) widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Moje konto')),
      body: FutureBuilder<_ProfileData>(
        future: _loadProfileData(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Center(
                child: CircleAvatar(radius: 36, child: Icon(Icons.person, size: 36)),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  data.fullName ?? 'Użytkownik',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 24),
              _InfoTile(icon: Icons.church_outlined, label: 'Parafia', value: data.parishSlug ?? '—'),
              _InfoTile(
                icon: Icons.sync,
                label: 'Ostatnia synchronizacja',
                value: data.lastSyncAt != null ? _formatDateTime(data.lastSyncAt!) : 'Nigdy',
              ),
              _InfoTile(icon: Icons.info_outline, label: 'Wersja aplikacji', value: widget.appVersion),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _syncing ? null : _handleSync,
                icon: _syncing
                    ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
                label: const Text('SYNCHRONIZUJ'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _confirmLogout,
                icon: const Icon(Icons.logout),
                label: const Text('WYLOGUJ'),
              ),
              // Review round P9: a visually separate section — this is
              // device/parish scope, not an account action, even though
              // Profile is where a user happens to reach it from (no
              // broader "Ustawienia" app shell exists yet to hang it off
              // of instead).
              const Divider(height: 48),
              ListTile(
                leading: const Icon(Icons.phone_android),
                title: const Text('Urządzenie / Parafia'),
                subtitle: const Text('Zmień parafię, zarządzaj aktywacją tego urządzenia'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DeviceSettingsScreen(
                      revocationHandler: widget.revocationHandler,
                      parishSlug: data.parishSlug,
                      onParishReset: widget.onParishReset,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<_ProfileData> _loadProfileData() async {
    final fullName = await widget.secureStorage.currentUserFullName;
    final parishSlug = await widget.secureStorage.parishSlug;
    final meta = await widget.db.ensureSyncMetadata();
    return _ProfileData(fullName: fullName, parishSlug: parishSlug, lastSyncAt: meta.lastSyncAt);
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year}, ${two(local.hour)}:${two(local.minute)}';
  }
}

class _ProfileData {
  const _ProfileData({this.fullName, this.parishSlug, this.lastSyncAt});
  final String? fullName;
  final String? parishSlug;
  final DateTime? lastSyncAt;
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value),
    );
  }
}
