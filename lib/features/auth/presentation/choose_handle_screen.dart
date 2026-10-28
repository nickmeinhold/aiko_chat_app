import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/diagnostics/report_problem_button.dart';
import '../../chat/data/chat_rest_api.dart'
    show HandleChangeOnCooldown, HandleTaken;
import '../application/auth_controller.dart';
import 'auth_error_text.dart';
import 'login_screen.dart' show loginActionProvider;

/// Pick your handle, BEFORE the passkey exists (#436, Nick 2026-10-28).
///
/// The island has created every passkey account with an auto-assigned `aiko-…`
/// handle since #1728, so the claim-handle step never fired and nobody was
/// asked. This screen is where they are asked, at two moments:
///
/// - **Signed out, from "Create a passkey".** The handle comes first so the
///   passkey in the user's password manager is named after it; then
///   [AuthController.registerWithPasskey] runs the ceremony and applies it.
/// - **Signed in, while the account still owes one.** The island refused the
///   first choice, the app was killed mid-way, or the island reports the
///   handle as still auto-assigned. [AuthController.chooseHandle] applies it.
///
/// The router holds an owing account here; there is no way into chat past it.
/// A successful save starts the island's 30-day handle cooldown, so the button
/// spells out the exact handle it will commit.
class ChooseHandleScreen extends ConsumerStatefulWidget {
  const ChooseHandleScreen({super.key});

  @override
  ConsumerState<ChooseHandleScreen> createState() => _ChooseHandleScreenState();
}

/// The island's own bound on a handle (`PATCH /v1/me`: 1 to 64 characters).
/// Deliberately no stricter: a rule only the app enforced would be its own
/// drift from the island.
///
/// Counted the island's way, in CODE POINTS ([handleLength]). Dart's
/// `String.length` counts UTF-16 units and a TextField's `maxLength` counts
/// grapheme clusters, so either would refuse emoji handles the island takes,
/// or pass ones it 422s. Same class as RFC-0001's codec bug (UTF-16 units
/// against Python's code points).
const kMaxHandleLength = 64;

/// A handle's length as the island (Python, pydantic `max_length`) counts it.
int handleLength(String handle) => handle.runes.length;

class _ChooseHandleScreenState extends ConsumerState<ChooseHandleScreen> {
  final _handle = TextEditingController();
  final _displayName = TextEditingController();
  bool _prefilled = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _handle.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _handle.dispose();
    _displayName.dispose();
    super.dispose();
  }

  String get _trimmed => _handle.text.trim();

  Future<void> _submit({required bool signedIn}) async {
    final handle = _trimmed;
    if (handle.isEmpty || handleLength(handle) > kMaxHandleLength) {
      setState(() => _error = 'A handle is 1 to $kMaxHandleLength characters.');
      return;
    }
    final name = _displayName.text.trim();
    final displayName = name.isEmpty ? handle : name;
    setState(() => _error = null);

    if (!signedIn) {
      ref.read(loginActionProvider.notifier).set(AuthAction.createAccount);
      await ref
          .read(authControllerProvider.notifier)
          .registerWithPasskey(handle: handle, displayName: displayName);
      return;
    }

    setState(() => _saving = true);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .chooseHandle(handle, displayName);
    } on HandleTaken {
      if (mounted) setState(() => _error = '@$handle is already taken.');
    } on HandleChangeOnCooldown {
      if (mounted) {
        setState(() => _error = "This account can't change its handle yet.");
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              "Couldn't save your handle. Check your connection "
              'and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Leave the gate by signing out, to the login screen. Explicitly: signed
  /// out, this route is also sign-up's first step, so the router alone would
  /// leave the person on a sign-up form they never asked for.
  Future<void> _signOut() async {
    await ref.read(authControllerProvider.notifier).logout();
    if (mounted) context.go('/login');
  }

  /// Why the island refused the handle chosen at sign-up, if it did.
  String? _refusal(Object? failure) => switch (failure) {
    null => null,
    HandleTaken() => 'Someone took that handle just now. Pick another.',
    _ =>
      "Your account is ready, but we couldn't save your handle yet. Try "
          'again.',
  };

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final owed = ref.watch(owedHandleProvider);
    final signedIn = auth.value != null;
    final busy = auth.isLoading || _saving;

    // Pre-fill from what was chosen before, exactly once, so a refused or
    // interrupted sign-up picks up where it left off.
    if (!_prefilled && owed != null) {
      _handle.text = owed.handle;
      if (owed.displayName != owed.handle) {
        _displayName.text = owed.displayName;
      }
      _prefilled = true;
    }

    final shown = _trimmed.isEmpty ? '' : ' as @$_trimmed';
    final error = _error ?? (signedIn ? _refusal(owed?.failure) : null);

    return Scaffold(
      key: const Key('choose-handle-screen'),
      appBar: AppBar(
        title: const Text('Pick your handle'),
        // Signed out it is a step you can back out of. Signed in it is the
        // gate, so there is no back, only signing out.
        automaticallyImplyLeading: !signedIn,
        actions: [
          if (signedIn)
            TextButton(
              onPressed: busy ? null : _signOut,
              child: const Text('Sign out'),
            ),
        ],
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
                Text(
                  signedIn
                      ? 'One more step: choose the handle others will see.'
                      : 'Choose the handle others will see. Your passkey will '
                            'be saved under it.',
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('choose-handle-field'),
                  controller: _handle,
                  enabled: !busy,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Handle',
                    prefixText: '@',
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 4),
                TextField(
                  key: const Key('choose-display-name-field'),
                  controller: _displayName,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Display name (optional)',
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => busy ? null : _submit(signedIn: signedIn),
                ),
                const SizedBox(height: 12),
                Text(
                  'You can change your handle once every 30 days.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    error,
                    key: const Key('choose-handle-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ] else if (!signedIn && auth.hasError) ...[
                  const SizedBox(height: 16),
                  Text(
                    authErrorText(
                      auth.error,
                      host: islandHostLabel(
                        ref.watch(configProvider).httpBaseUrl,
                      ),
                      action: AuthAction.createAccount,
                    ),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  ReportProblemButton(error: auth.error),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const Key('choose-handle-submit'),
                  onPressed: busy || _trimmed.isEmpty
                      ? null
                      : () => _submit(signedIn: signedIn),
                  icon: busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(signedIn ? Icons.check : Icons.fingerprint),
                  label: Text(
                    signedIn ? 'Continue$shown' : 'Create passkey$shown',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
