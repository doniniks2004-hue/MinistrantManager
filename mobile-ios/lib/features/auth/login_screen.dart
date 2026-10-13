import 'package:flutter/material.dart';
import 'user_session_service.dart';

/// Flow step B: the device is already activated, but no human session is
/// present yet. Accounts with users.password_changed=0 are kept inside
/// this screen until they complete the mandatory first-login password
/// change; they never reach the dashboard with a pre-change token.
class LoginScreen extends StatefulWidget {
  const LoginScreen(
      {super.key,
      required this.userSessionService,
      required this.onLoggedIn,
      this.onOpenDeviceSettings});

  final UserSessionService userSessionService;
  final VoidCallback onLoggedIn;
  final VoidCallback? onOpenDeviceSettings;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _submitting = false;
  bool _requiresPasswordChange = false;
  String? _errorMessage;
  bool _obscurePassword = true;
  bool _obscureNewPassword = true;
  bool _obscureConfirmPassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
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

    final result = await widget.userSessionService
        .login(username: username, password: password);
    if (!mounted) return;

    switch (result) {
      case UserLoginSuccess():
        widget.onLoggedIn();
        break;
      case UserLoginPasswordChangeRequired():
        setState(() {
          _submitting = false;
          _requiresPasswordChange = true;
          _errorMessage = null;
        });
        break;
      case UserLoginInvalidCredentials():
        setState(() {
          _submitting = false;
          _errorMessage = 'Nieprawidłowy login lub hasło.';
        });
        break;
      case UserLoginDeviceNotAuthorized():
        _showDeviceError(result.deviceState);
        break;
      case UserLoginNetworkError():
        setState(() {
          _submitting = false;
          _errorMessage =
              'Brak połączenia z serwerem parafii. Spróbuj ponownie.';
        });
    }
  }

  Future<void> _submitPasswordChange() async {
    final newPassword = _newPasswordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (newPassword.isEmpty || confirmPassword.isEmpty) {
      setState(() => _errorMessage = 'Podaj nowe hasło w obu polach.');
      return;
    }
    if (newPassword != confirmPassword) {
      setState(() => _errorMessage = 'Wprowadzone hasła nie są identyczne.');
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    final result = await widget.userSessionService.changeRequiredPassword(
      username: _usernameController.text.trim(),
      currentPassword: _passwordController.text,
      newPassword: newPassword,
    );
    if (!mounted) return;

    switch (result) {
      case UserLoginSuccess():
        _passwordController.clear();
        _newPasswordController.clear();
        _confirmPasswordController.clear();
        widget.onLoggedIn();
        break;
      case UserLoginDeviceNotAuthorized():
        _showDeviceError(result.deviceState);
        break;
      case UserLoginInvalidCredentials():
      case UserLoginPasswordChangeRequired():
        setState(() {
          _submitting = false;
          _requiresPasswordChange = false;
          _passwordController.clear();
          _newPasswordController.clear();
          _confirmPasswordController.clear();
          _errorMessage =
              'Nie udało się dokończyć zmiany hasła. Zaloguj się ponownie.';
        });
        break;
      case UserLoginNetworkError():
        setState(() {
          _submitting = false;
          _errorMessage =
              'Brak połączenia z serwerem parafii. Spróbuj ponownie.';
        });
    }
  }

  void _showDeviceError(String deviceState) {
    setState(() {
      _submitting = false;
      _errorMessage = deviceState == 'central_unavailable'
          ? 'Nie udało się potwierdzić autoryzacji urządzenia. Spróbuj ponownie za chwilę.'
          : 'To urządzenie nie jest autoryzowane do korzystania z tej parafii. Skontaktuj się z administratorem.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_requiresPasswordChange ? 'Ustaw nowe hasło' : 'Logowanie'),
        actions: [
          if (widget.onOpenDeviceSettings != null)
            IconButton(
              tooltip: 'Urządzenie / Parafia',
              onPressed: _submitting ? null : widget.onOpenDeviceSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: _requiresPasswordChange
                ? _buildPasswordChange()
                : _buildLogin(),
          ),
        ),
      ),
    );
  }

  Widget _buildLogin() {
    return Column(
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
          decoration: const InputDecoration(
              labelText: 'Login', border: OutlineInputBorder()),
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
              icon: Icon(
                  _obscurePassword ? Icons.visibility_off : Icons.visibility),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        _buildError(),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('ZALOGUJ'),
        ),
      ],
    );
  }

  Widget _buildPasswordChange() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.password_outlined, size: 48),
        const SizedBox(height: 16),
        const Text(
          'To jest pierwsze logowanie lub administrator zresetował Twoje hasło.\n'
          'Ze względów bezpieczeństwa ustaw teraz nowe hasło.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _newPasswordController,
          enabled: !_submitting,
          obscureText: _obscureNewPassword,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(
            labelText: 'Nowe hasło',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_obscureNewPassword
                  ? Icons.visibility_off
                  : Icons.visibility),
              onPressed: () =>
                  setState(() => _obscureNewPassword = !_obscureNewPassword),
            ),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirmPasswordController,
          enabled: !_submitting,
          obscureText: _obscureConfirmPassword,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(
            labelText: 'Powtórz nowe hasło',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_obscureConfirmPassword
                  ? Icons.visibility_off
                  : Icons.visibility),
              onPressed: () => setState(
                  () => _obscureConfirmPassword = !_obscureConfirmPassword),
            ),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submitPasswordChange(),
        ),
        _buildError(),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _submitting ? null : _submitPasswordChange,
          child: _submitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('ZAPISZ NOWE HASŁO'),
        ),
        TextButton(
          onPressed: _submitting
              ? null
              : () {
                  setState(() {
                    _requiresPasswordChange = false;
                    _newPasswordController.clear();
                    _confirmPasswordController.clear();
                    _errorMessage = null;
                  });
                },
          child: const Text('Wróć do logowania'),
        ),
      ],
    );
  }

  Widget _buildError() {
    if (_errorMessage == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        _errorMessage!,
        style: const TextStyle(color: Colors.red),
        textAlign: TextAlign.center,
      ),
    );
  }
}
