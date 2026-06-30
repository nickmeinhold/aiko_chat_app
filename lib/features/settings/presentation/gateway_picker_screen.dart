/// The gateway picker (#4) — choose which server the app talks to.
///
/// Lists the built-in presets ([kGatewayPresets]) plus a custom-URL field, marks
/// the active gateway, and routes a selection through
/// [AuthController.switchGateway] — which signs the user out first, because JWTs
/// are gateway-specific. The list is rendered from `List<ServerEntry>` so P2 can
/// swap the preset source for the live discovery directory with no UI rework.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/config.dart';
import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../domain/server_entry.dart';

class GatewayPickerScreen extends ConsumerStatefulWidget {
  const GatewayPickerScreen({super.key});

  @override
  ConsumerState<GatewayPickerScreen> createState() =>
      _GatewayPickerScreenState();
}

class _GatewayPickerScreenState extends ConsumerState<GatewayPickerScreen> {
  final _customController = TextEditingController();
  bool _switching = false;

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = ref.watch(configProvider).httpBaseUrl;

    return Scaffold(
      appBar: AppBar(title: const Text('Server')),
      body: AbsorbPointer(
        absorbing: _switching,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Choose which server Aiko Chat connects to. Switching signs you '
                'out, because your sign-in only works on the server that issued '
                'it.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const _SectionHeader('Servers'),
            for (final entry in kGatewayPresets)
              _ServerTile(
                label: entry.label,
                url: entry.httpBaseUrl,
                selected: _isCurrent(entry.httpBaseUrl, current),
                onTap: () => _select(entry.httpBaseUrl, entry.label),
              ),
            const _SectionHeader('Custom'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _customController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'https://chat.example.com',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _selectCustom(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _selectCustom,
                  child: const Text('Connect'),
                ),
              ),
            ),
            if (_switching)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  /// True when [candidate] resolves to the same gateway as the active [current]
  /// (after normalization, so a stored trailing slash doesn't hide the match).
  bool _isCurrent(String candidate, String current) =>
      GatewayConfig.normalized(candidate).httpBaseUrl == current;

  void _selectCustom() {
    final raw = _customController.text.trim();
    final error = _validate(raw);
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    _select(raw, raw);
  }

  /// Validate a custom URL: must parse to an absolute http(s) URL with a host.
  /// Returns an error message, or null if valid.
  String? _validate(String raw) {
    if (raw.isEmpty) return 'Enter a server URL.';
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.isAbsolute) return 'Not a valid URL.';
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return 'URL must start with http:// or https://';
    }
    if (uri.host.isEmpty) return 'URL is missing a host.';
    return null;
  }

  Future<void> _select(String url, String label) async {
    final current = ref.read(configProvider).httpBaseUrl;
    if (_isCurrent(url, current)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already connected to this server.')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch server?'),
        content: Text(
          'You\'ll be signed out and need to sign in again on $label. '
          'Your account on the current server is not affected.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Switch')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _switching = true);
    // switchGateway publishes `loading` (router → /splash) then logs the user out
    // on the new gateway. A persistence failure throws BEFORE any teardown
    // (session intact) — surface it and stay put.
    try {
      await ref.read(authControllerProvider.notifier).switchGateway(url);
    } catch (e) {
      if (!mounted) return;
      setState(() => _switching = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_switchError(e))),
      );
      return;
    }
    // Land deterministically on the new gateway's /login. We're now logged out,
    // so /login is always correct. This is NOT redundant: since #35 made
    // /settings/gateway reachable while logged out, the redirect treats it as a
    // valid logged-out resting state — so without an explicit nav the picker
    // stays on screen after the switch (the loading→/splash hop only moves us if
    // a frame happens to pump mid-switch — a race we don't depend on). maybeOf
    // keeps the bare-widget unit test (no GoRouter ancestor) a safe no-op.
    if (mounted) GoRouter.maybeOf(context)?.go('/login');
    if (mounted) setState(() => _switching = false);
  }

  String _switchError(Object e) {
    if (e is GatewaySwitchFailed) return e.message;
    return 'Could not switch servers. Please try again.';
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.label,
    required this.url,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String url;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? theme.colorScheme.primary : null,
      ),
      title: Text(label),
      subtitle: Text(url),
      trailing: selected
          ? Text('Connected',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.primary))
          : null,
      onTap: selected ? null : onTap,
    );
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
