import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'activation_service.dart';

/// Spec §18–§19: first-run screen, QR scan or manual code entry, then a
/// confirmation step before actually burning the activation code.
/// [initialToken] (spec §35): pre-fills and auto-runs the check step when
/// the app was opened via an Android App Link / iOS Universal Link
/// (https://app.ministrant.eu/activate/{token}) instead of the in-app
/// scanner — same underlying flow either way, just a different token
/// source. Pass a NEW widget instance (e.g. keyed by the token, see
/// DeepLinkService/main.dart) to re-trigger this for a second link
/// received while already on this screen.
class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key, required this.activationService, required this.onActivated, this.initialToken});

  final ActivationService activationService;
  final VoidCallback onActivated;
  final String? initialToken;

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  bool _busy = false;
  String? _error;
  ActivationResult? _pending; // resolved parish, awaiting user confirmation
  String? _pendingToken;
  String? _pendingDisplayCode;

  @override
  void initState() {
    super.initState();
    if (widget.initialToken != null) {
      // Deferred to right after the first frame so context/Navigator are
      // fully ready — matches how _handleScanned is invoked from a real
      // camera callback rather than synchronously during build.
      WidgetsBinding.instance.addPostFrameCallback((_) => _check(token: widget.initialToken));
    }
  }

  Future<void> _handleScanned(String raw) async {
    if (_busy) return;
    final token = widget.activationService.extractTokenFromQr(raw);
    await _check(token: token);
  }

  Future<void> _check({String? token, String? displayCode}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.activationService.checkCode(token: token, displayCode: displayCode);
      setState(() {
        _pending = result;
        _pendingToken = token;
        _pendingDisplayCode = displayCode;
      });
    } on ActivationError catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      await widget.activationService.confirmActivation(token: _pendingToken, displayCode: _pendingDisplayCode);
      widget.onActivated();
    } on ActivationError catch (e) {
      setState(() {
        _error = e.message;
        _pending = null;
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  void _showManualEntry() {
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Wpisz kod aktywacyjny', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(hintText: '73FK-92MX', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _check(displayCode: controller.text.trim());
              },
              child: const Text('Sprawdź kod'),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_pending != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Potwierdź aktywację')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 56),
            const SizedBox(height: 16),
            const Text('Znaleziono parafię', style: TextStyle(fontSize: 16, color: Colors.grey)),
            Text(_pending!.parishName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text(_pending!.serverUrl, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _confirm,
                child: _busy ? const CircularProgressIndicator() : const Text('AKTYWUJ'),
              ),
            ),
          ]),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Ministrant Manager')),
      body: Column(children: [
        Expanded(
          flex: 3,
          child: MobileScanner(
            onDetect: (capture) {
              final code = capture.barcodes.firstOrNull?.rawValue;
              if (code != null) _handleScanned(code);
            },
          ),
        ),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              Image.asset('assets/branding/logo.png', height: 48, errorBuilder: (_, __, ___) => const SizedBox()),
              const SizedBox(height: 12),
              const Text('Aktywuj aplikację swojej parafii.', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              OutlinedButton(onPressed: _showManualEntry, child: const Text('WPISZ KOD')),
            ]),
          ),
        ),
      ]),
    );
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
