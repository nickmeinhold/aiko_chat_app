import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/data/chat_rest_api.dart' show HandleTaken;
import '../application/auth_controller.dart';

/// Shown once, right after a NEW social identity is verified: the user picks
/// their public `@handle` and confirms a display name (pre-filled from the
/// provider when it supplied one). On success the controller publishes the user
/// and the router redirects to chat. Closing the screen abandons the pending
/// identity and returns to `/login`.
class ClaimHandleScreen extends ConsumerStatefulWidget {
  const ClaimHandleScreen({super.key});

  @override
  ConsumerState<ClaimHandleScreen> createState() => _ClaimHandleScreenState();
}

class _ClaimHandleScreenState extends ConsumerState<ClaimHandleScreen> {
  final _handle = TextEditingController();
  final _displayName = TextEditingController();
  bool _prefilled = false;

  @override
  void dispose() {
    _handle.dispose();
    _displayName.dispose();
    super.dispose();
  }

  void _submit() {
    final handle = _handle.text.trim();
    if (handle.isEmpty) return;
    final displayName =
        _displayName.text.trim().isEmpty ? handle : _displayName.text.trim();
    ref.read(authControllerProvider.notifier).claimHandle(handle, displayName);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final busy = auth.isLoading;
    final pending = ref.watch(pendingHandleProvider);

    // Pre-fill the display name from the provider's suggested name, exactly once
    // (Apple/Google give it on first consent; the user can edit it).
    if (!_prefilled && (pending?.suggestedName ?? '').isNotEmpty) {
      _displayName.text = pending!.suggestedName!;
      _prefilled = true;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick your handle'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed:
              busy ? null : () => ref.read(pendingHandleProvider.notifier).clear(),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Welcome! Choose a handle others will see.'),
                const SizedBox(height: 16),
                TextField(
                  controller: _handle,
                  enabled: !busy,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Handle',
                    prefixText: '@',
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _displayName,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: 'Display name'),
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
                      : const Text('Continue'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Surface a taken handle inline; keep raw transport detail out of the UI.
  String _friendlyError(Object error) {
    if (error is HandleTaken) {
      return "That handle is taken — try another. If it's already yours, sign in "
          'with your existing account, then add a passkey from Settings.';
    }
    return 'Something went wrong. Please try again.';
  }
}
