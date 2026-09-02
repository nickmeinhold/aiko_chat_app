/// The gateway picker (#4) — choose which server the app talks to.
///
/// Lists the available gateways plus a custom-URL field, marks the active
/// gateway, and routes a selection through [AuthController.switchGateway] — which
/// signs the user out first, because JWTs are gateway-specific. The list source
/// is the live directory fetched from the CURRENT gateway ([gatewayDirectoryProvider],
/// #36) merged over the known-islands seed set ([knownGatewaysProvider] = bundled
/// presets ∪ the persisted ever-seen set): the known set renders instantly and is
/// the fallback while the directory loads / on error, so the screen is never
/// blocked on the network — and discovery has no single point of failure.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/config.dart';
import '../../../app/providers.dart';
import '../../../core/widgets/reading_column.dart';
import '../application/gateway_directory_provider.dart';
import '../data/gateway_directory_client.dart';
import 'gateway_switch_action.dart';

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
    // Seed-first: render the known set (presets ∪ ever-seen) immediately, upgrade
    // to the merged live directory once it loads. Loading/error all fall back to
    // the known set — a slow or absent directory never blocks the screen.
    final known = ref.watch(knownGatewaysProvider);
    final servers = ref
        .watch(gatewayDirectoryProvider)
        .maybeWhen(
          data: (directory) => mergeDirectory(
            directory,
            known,
            normalize: (url) => GatewayConfig.normalized(url).httpBaseUrl,
          ),
          orElse: () => known,
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Island')),
      body: ReadingColumn(
        child: AbsorbPointer(
          absorbing: _switching,
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Choose which island Aiko Chat connects to. Switching signs you '
                  'out, because your sign-in only works on the island that issued '
                  'it.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const _SectionHeader('Islands'),
              for (final entry in servers)
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
                    labelText: 'Island URL',
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    _select(raw, raw);
  }

  /// Validate a custom URL: must parse to an absolute http(s) URL with a host.
  /// Returns an error message, or null if valid.
  String? _validate(String raw) {
    if (raw.isEmpty) return 'Enter an island URL.';
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.isAbsolute) return 'Not a valid URL.';
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return 'URL must start with http:// or https://';
    }
    if (uri.host.isEmpty) return 'URL is missing a host.';
    return null;
  }

  /// Route through the shared [confirmAndSwitchGateway] so this picker and the
  /// wide-layout sidebar switcher present the identical no-op guard, confirm
  /// dialog, error copy, and post-switch `/login` landing — they can't drift.
  /// The picker owns only its local AbsorbPointer spinner, driven via
  /// [onSwitching].
  Future<void> _select(String url, String label) => confirmAndSwitchGateway(
    context,
    ref,
    url: url,
    label: label,
    onSwitching: (switching) {
      if (mounted) setState(() => _switching = switching);
    },
  );
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
          ? Text(
              'Connected',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            )
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
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
