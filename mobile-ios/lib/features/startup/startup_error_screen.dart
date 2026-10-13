import 'package:flutter/material.dart';

/// Shown instead of a spinner when the app cannot finish starting up.
/// A startup failure used to leave the user on an indefinite spinner with
/// nothing on screen to act on; this gives a plain statement of what
/// failed and a way to try again.
class StartupErrorScreen extends StatelessWidget {
  const StartupErrorScreen({
    super.key,
    required this.message,
    required this.onRetry,
    this.detail,
  });

  final String message;

  /// A short technical hint (an exception type, never a message that could
  /// carry a URL or token) so a support conversation has something to go on.
  final String? detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center),
                if (detail != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    detail!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: onRetry,
                  child: const Text('SPRÓBUJ PONOWNIE'),
                ),
              ],
            ),
          ),
        ),
      );
}
