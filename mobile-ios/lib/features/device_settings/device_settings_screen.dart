import 'package:flutter/material.dart';

import '../revocation/revocation_handler.dart';

/// Offline-architecture milestone, P9. Review round decision: "Reset/
/// zmiana parafii traktujemy jak utratę uprawnień do poprzedniej
/// parafii" — the ONLY action here, "Zmień parafię", calls the exact
/// same wipe sequence a server-reported revocation uses
/// ([RevocationHandler.resetParishManually]).
///
/// Deliberately its OWN screen, reached from Profile rather than living
/// inside it — review round: "Nie wrzucałbym tego do profilu
/// użytkownika — to operacja na urządzeniu/parafii, nie na koncie
/// użytkownika." This is DEVICE/installation scope, not an account
/// action, even though the only way to reach it today is a link on the
/// account screen (no broader "Ustawienia" app shell exists yet to hang
/// it off of instead).
class DeviceSettingsScreen extends StatefulWidget {
  const DeviceSettingsScreen({
    super.key,
    required this.revocationHandler,
    required this.parishSlug,
    required this.onParishReset,
  });

  final RevocationHandler revocationHandler;
  final String? parishSlug;

  /// Called once the reset has fully completed (wipe + crypto-erase +
  /// clearActivation) — the caller (main.dart, via the SAME callback
  /// HomeScreen's own `onRevoked` already uses) is responsible for
  /// rebuilding app state and showing the activation screen; this
  /// screen's own job ends at confirming the user's intent and invoking
  /// the handler.
  final VoidCallback onParishReset;

  @override
  State<DeviceSettingsScreen> createState() => _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends State<DeviceSettingsScreen> {
  bool _resetting = false;

  Future<void> _confirmAndReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: !_resetting,
      builder: (ctx) => AlertDialog(
        title: const Text('Zmienić parafię?'),
        content: const Text(
          'Zmiana parafii usunie lokalne dane i zapisane dane offline obecnej parafii. '
          'Tej operacji nie można cofnąć.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ANULUJ')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('ZMIEŃ PARAFIĘ'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _resetting = true);
    try {
      await widget.revocationHandler.resetParishManually();
      // The screen itself is about to be torn down by the caller's
      // onParishReset rebuilding app state down to the activation
      // screen — no further setState on this widget after this point.
      widget.onParishReset();
    } catch (_) {
      if (mounted) {
        setState(() => _resetting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nie udało się zmienić parafii. Spróbuj ponownie.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Urządzenie / Parafia')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.church_outlined),
            title: const Text('Aktualna parafia'),
            subtitle: Text(widget.parishSlug ?? '—'),
          ),
          const Divider(height: 32),
          ListTile(
            leading: Icon(Icons.swap_horiz, color: _resetting ? Colors.grey : Colors.red),
            title: Text('Zmień parafię', style: TextStyle(color: _resetting ? Colors.grey : Colors.red)),
            subtitle: const Text('Usuwa lokalne dane i offline cache tej parafii, wraca do aktywacji QR.'),
            trailing: _resetting ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
            onTap: _resetting ? null : _confirmAndReset,
          ),
        ],
      ),
    );
  }
}
