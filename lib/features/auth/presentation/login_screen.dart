import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/data/chat_rest_api.dart' show Unauthorized;
import '../application/auth_controller.dart';

/// Username/password login, with a toggle into register mode (which adds a
/// display-name field). Watches [authControllerProvider]: a spinner while the
/// call is in flight, an inline error if it failed. On success the controller
/// publishes the user and the router redirects to chat — this screen does no
/// navigation itself.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  bool _registerMode = false;

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final controller = ref.read(authControllerProvider.notifier);
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) return;
    if (_registerMode) {
      final displayName =
          _displayName.text.trim().isEmpty ? username : _displayName.text.trim();
      controller.register(username, displayName, password);
    } else {
      controller.login(username, password);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final busy = auth.isLoading;

    return Scaffold(
      appBar: AppBar(title: Text(_registerMode ? 'Create account' : 'Sign in')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _username,
                  enabled: !busy,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Username'),
                  textInputAction: TextInputAction.next,
                ),
                if (_registerMode) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _displayName,
                    enabled: !busy,
                    decoration:
                        const InputDecoration(labelText: 'Display name (optional)'),
                    textInputAction: TextInputAction.next,
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => busy ? null : _submit(),
                ),
                if (auth.hasError) ...[
                  const SizedBox(height: 16),
                  Text(
                    _friendlyError(auth.error!),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: busy ? null : _submit,
                  child: busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_registerMode ? 'Create account' : 'Sign in'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() => _registerMode = !_registerMode),
                  child: Text(_registerMode
                      ? 'Have an account? Sign in'
                      : 'New here? Create an account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Keep raw transport/exception detail out of the UI; show a short message.
  /// Classify on the domain [Unauthorized] type (a 401/403 that survived the
  /// interceptor's refresh-and-retry), not a brittle `toString().contains`.
  String _friendlyError(Object error) {
    if (error is Unauthorized) return 'Incorrect username or password.';
    return 'Something went wrong. Please try again.';
  }
}
