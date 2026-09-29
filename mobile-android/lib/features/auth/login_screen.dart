import 'package:flutter/material.dart';
import 'user_session_service.dart';

/// Flow step B (milestone "Mój grafik", review round point 2): device is
/// already activated, but no `mobile_user_token` exists yet (first launch
/// after activation, or after logout/session-expiry). Deliberately does
/// NOT re-trigger QR activation — only asks for username/password against
/// this parish's own `/session/login`.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.userSessionService, required this.onLoggedIn});

  final UserSessionService userSessionService;
  final VoidCallback onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _errorMessage;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Podaj login i hasło.');
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    final result = await widget.userSessionService.login(username: username, password: password);

    if (!mounted) return;

    switch (result) {
      case UserLoginSuccess():
        widget.onLoggedIn();
        break;
      case UserLoginInvalidCredentials():
        setState(() {
          _submitting = false;
          _errorMessage = 'Nieprawidłowy login lub hasło.';
        });
        break;
      case UserLoginDeviceNotAuthorized():
        // Device-control-plane milestone (review round point 8):
        // deliberately NEVER "zły login/hasło" (password was correct)
        // and NEVER the generic network-error message below —
        // 'central_unavailable' is a retriable hiccup, the other four
        // states mean a human needs to sort this out.
        //
        // Dart already promotes `result` to UserLoginDeviceNotAuthorized
        // inside this case (empty-pattern object match) — no cast needed;
        // `analyze` flags the explicit cast as `unnecessary_cast`.
        final deviceState = result.deviceState;
        setState(() {
          _submitting = false;
          _errorMessage = deviceState == 'central_unavailable'
              ? 'Nie udało się potwierdzić autoryzacji urządzenia. Spróbuj ponownie za chwilę.'
              : 'To urządzenie nie jest autoryzowane do korzystania z tej parafii. Skontaktuj się z administratorem.';
        });
        break;
      case UserLoginNetworkError():
        setState(() {
          _submitting = false;
          _errorMessage = 'Brak połączenia z serwerem parafii. Spróbuj ponownie.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Logowanie')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.person_outline, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'To urządzenie jest już aktywowane.\nZaloguj się swoim kontem Ministrant Manager.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _usernameController,
                  enabled: !_submitting,
                  autofillHints: const [AutofillHints.username],
                  decoration: const InputDecoration(labelText: 'Login', border: OutlineInputBorder()),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  enabled: !_submitting,
                  obscureText: _obscurePassword,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Hasło',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(_errorMessage!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('ZALOGUJ'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
