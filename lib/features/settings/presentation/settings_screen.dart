/// Settings — currently the home of account management. Reachable from the chat
/// AppBar. Built as a simple list so later threads (the in-app gateway picker,
/// #4; a blocked-users list, #7) can slot in as new sections without rework.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../../chat/data/chat_rest_api.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _deleting = false;
  bool _addingPasskey = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Server'),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server'),
            subtitle: Text(_hostOf(ref.watch(configProvider).httpBaseUrl)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/gateway'),
          ),
          const _SectionHeader('Safety'),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Blocked users'),
            subtitle: const Text("People you've blocked won't see your messages."),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/blocked'),
          ),
          const _SectionHeader('Sign-in'),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('Add a passkey'),
            subtitle: const Text(
                'Sign in next time with Face ID, Touch ID, or your device PIN.'),
            enabled: !_addingPasskey,
            trailing: _addingPasskey
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right),
            onTap: _addingPasskey ? null : _addPasskey,
          ),
          const _SectionHeader('Account'),
          ListTile(
            leading: Icon(Icons.delete_forever, color: theme.colorScheme.error),
            title: Text('Delete account',
                style: TextStyle(color: theme.colorScheme.error)),
            subtitle: const Text(
                'Permanently delete your account. This cannot be undone.'),
            enabled: !_deleting,
            trailing: _deleting
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _deleting ? null : _confirmAndDelete,
          ),
          const _SectionHeader('Legal'),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Terms of Use & Community Guidelines'),
            subtitle: const Text('The terms you agreed to, including our '
                'zero-tolerance policy.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/eula'),
          ),
        ],
      ),
    );
  }

  /// Link a new passkey to the signed-in account (#1727). Settings is only
  /// reachable while authenticated, so the controller's live-session precondition
  /// holds. A sheet dismissal returns silently (the controller swallows it); a
  /// real failure surfaces inline via a snackbar without disturbing the session.
  Future<void> _addPasskey() async {
    setState(() => _addingPasskey = true);
    String? message; // null → user cancelled the sheet: no snackbar, no noise
    try {
      final added = await ref
          .read(authControllerProvider.notifier)
          .addPasskeyToCurrentAccount();
      if (added) message = 'Passkey added. You can now sign in with it.';
    } catch (e) {
      message = _addPasskeyError(e);
    }
    if (!mounted) return;
    setState(() => _addingPasskey = false);
    if (message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  String _addPasskeyError(Object e) {
    if (e is PasskeyAlreadyRegistered) {
      return 'That passkey is already on your account.';
    }
    if (e is Unauthorized) {
      return 'Your session has expired. Please sign in again.';
    }
    return 'Could not add a passkey. Please try again.';
  }

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently deletes your account and sign-in. Messages you '
          'sent stay in their conversations but are anonymized — no longer '
          'linked to you. This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _deleting = true);
    try {
      // On success the auth guard redirects to /login — no manual nav here.
      await ref.read(authControllerProvider.notifier).deleteAccount();
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_deleteError(e))));
    }
  }

  String _deleteError(Object e) {
    if (e is SoleAdminDeletionBlocked) return e.message;
    return 'Could not delete your account. Please try again.';
  }

  /// The host for the Server tile subtitle, parsed defensively — a corrupt
  /// persisted value (read directly in [GatewayConfigController.build]) must not
  /// throw on the Settings screen. Falls back to the raw value.
  static String _hostOf(String httpBaseUrl) {
    final host = Uri.tryParse(httpBaseUrl)?.host;
    return (host == null || host.isEmpty) ? httpBaseUrl : host;
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title,
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}
