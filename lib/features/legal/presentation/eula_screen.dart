/// The Terms of Use surface. Two modes from one widget:
///   - `gate: true`  — the first-run acceptance gate. No back affordance (the
///     route guard owns navigation), an Accept button that ENABLES ONLY once the
///     reader has scrolled to the bottom, and Android back is swallowed so the
///     gate can't be bypassed.
///   - `gate: false` — a read-only viewer reachable from Settings.
///
/// The text is a bundled asset (`assets/legal/eula.md`), so the gate works on a
/// fresh install with no network — exactly the state an app-store reviewer sees.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/eula_controller.dart';

class EulaScreen extends ConsumerStatefulWidget {
  const EulaScreen({super.key, this.gate = true});

  /// First-run acceptance gate when true; read-only viewer when false.
  final bool gate;

  @override
  ConsumerState<EulaScreen> createState() => _EulaScreenState();
}

class _EulaScreenState extends ConsumerState<EulaScreen> {
  final _scroll = ScrollController();
  bool _atBottom = false;
  bool _accepting = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Within a hair of the end counts as "read to the bottom".
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 16) {
      if (!_atBottom) setState(() => _atBottom = true);
    }
  }

  Future<void> _accept() async {
    setState(() => _accepting = true);
    // On success the route guard redirects past the gate — no manual nav.
    await ref.read(eulaAcceptanceProvider.notifier).accept();
  }

  @override
  Widget build(BuildContext context) {
    final textAsync = ref.watch(eulaTextProvider);
    final scaffold = Scaffold(
      appBar: AppBar(
        title: const Text('Terms of Use'),
        // The gate owns navigation; offer no back button out of it.
        automaticallyImplyLeading: !widget.gate,
      ),
      body: Column(
        children: [
          Expanded(
            child: textAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const Center(
                  child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Could not load the Terms. Please try again.'),
              )),
              data: (text) {
                // Content that fits without scrolling can't reach the bottom by
                // scrolling, so enable acceptance once we know it doesn't overflow.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (_scroll.hasClients &&
                      _scroll.position.maxScrollExtent == 0 &&
                      !_atBottom) {
                    setState(() => _atBottom = true);
                  }
                });
                return _EulaText(text: text, controller: _scroll);
              },
            ),
          ),
          if (widget.gate) _acceptBar(context),
        ],
      ),
    );

    // In gate mode, swallow the Android system back button so the gate can't be
    // dismissed without accepting.
    return widget.gate ? PopScope(canPop: false, child: scaffold) : scaffold;
  }

  Widget _acceptBar(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_atBottom)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Scroll to the bottom to continue',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (_atBottom && !_accepting) ? _accept : null,
                child: _accepting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Accept & Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders the bundled Terms: first line as the title, the rest as body.
class _EulaText extends StatelessWidget {
  const _EulaText({required this.text, required this.controller});

  final String text;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = text.split('\n');
    final title = lines.first.trim();
    final body = lines.skip(1).join('\n').trim();

    return Scrollbar(
      controller: controller,
      child: SingleChildScrollView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            Text(body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.45)),
          ],
        ),
      ),
    );
  }
}
