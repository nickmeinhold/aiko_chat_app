/// The moderator triage queue (#33/#35 — the operator seat). Reachable from
/// Settings ONLY for a moderator ([isModeratorProvider]); lists unresolved
/// reports and lets an operator take a message down, dismiss the report, or ban
/// the sender. The server `ModeratorUser` gate is the REAL boundary — this UI is
/// presentation-only, and defends in depth by gating its own body on the flag so
/// a mid-session revocation (surfaced as [Forbidden] → `/me` refresh) collapses
/// the screen instead of showing dead controls.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_controller.dart';
import '../../chat/data/chat_rest_api.dart' show Forbidden;
import '../application/moderation_controller.dart';
import '../domain/moderation_models.dart';

class ReportQueueScreen extends ConsumerWidget {
  const ReportQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Defense in depth: if the moderator flag flips false mid-session (a
    // Forbidden action refreshed /me), gate the whole screen off rather than
    // render controls every action would 403 on.
    final isModerator = ref.watch(isModeratorProvider);
    if (!isModerator) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reports')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'You no longer have moderator access on this island.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final reportsAsync = ref.watch(pendingReportsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(pendingReportsProvider.future),
        child: reportsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            // ListView so the RefreshIndicator still pulls on an error.
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load the report queue.\n$e',
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          data: (reports) {
            if (reports.isEmpty) {
              return ListView(
                children: const [
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No pending reports. The queue is clear.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              );
            }
            return ListView.separated(
              itemCount: reports.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _ReportTile(reports[i]),
            );
          },
        ),
      ),
    );
  }
}

class _ReportTile extends ConsumerStatefulWidget {
  const _ReportTile(this.report);
  final PendingReport report;

  @override
  ConsumerState<_ReportTile> createState() => _ReportTileState();
}

class _ReportTileState extends ConsumerState<_ReportTile> {
  bool _busy = false;

  PendingReport get _r => widget.report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      isThreeLine: true,
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.errorContainer,
        child: Icon(Icons.flag_outlined, color: theme.colorScheme.onErrorContainer),
      ),
      title: Text(
        _r.messageBody.isEmpty ? '(empty message)' : _r.messageBody,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          [
            'Reason: ${_r.reasonLabel}',
            'Reporter: ${_r.reporterDisplayName ?? 'unknown'}',
            if (_r.isAlreadyDeleted) 'Already removed',
          ].join(' · '),
          style: theme.textTheme.bodySmall,
        ),
      ),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : PopupMenuButton<_ReportAction>(
              onSelected: _onAction,
              itemBuilder: (_) => [
                if (!_r.isAlreadyDeleted)
                  const PopupMenuItem(
                    value: _ReportAction.takeDown,
                    child: Text('Take message down'),
                  ),
                const PopupMenuItem(
                  value: _ReportAction.dismiss,
                  child: Text('Dismiss report'),
                ),
                const PopupMenuItem(
                  value: _ReportAction.ban,
                  child: Text('Ban sender'),
                ),
              ],
            ),
    );
  }

  Future<void> _onAction(_ReportAction action) async {
    switch (action) {
      case _ReportAction.takeDown:
        await _run(
          confirm: (
            'Take message down?',
            'This removes the message for everyone. This can be moderated but not undone from here.',
            'Take down',
          ),
          act: () =>
              ref.read(pendingReportsProvider.notifier).resolve(_r.reportId),
          ok: 'Message taken down.',
        );
      case _ReportAction.dismiss:
        await _run(
          confirm: null,
          act: () =>
              ref.read(pendingReportsProvider.notifier).dismiss(_r.reportId),
          ok: 'Report dismissed.',
        );
      case _ReportAction.ban:
        await _run(
          confirm: (
            'Ban sender?',
            'Suspends this account from the island. Reversible, but they lose '
                'access immediately. The report stays in the queue until you act '
                'on it.',
            'Ban',
          ),
          act: () => ref
              .read(pendingReportsProvider.notifier)
              .ban(_r.messageSenderUserId),
          ok: 'Sender banned.',
        );
    }
  }

  /// Run an operator action with an optional confirm dialog, a busy spinner, and
  /// dispose-safe messaging. The tile's State is disposed mid-await when a
  /// resolve/dismiss removes it from the list, so the messenger is captured
  /// BEFORE the await and every post-await `context`/`setState` is `mounted`-
  /// guarded (mirrors _BlockedTile — cage-match Kelvin + Carnot).
  Future<void> _run({
    required (String, String, String)? confirm,
    required Future<void> Function() act,
    required String ok,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    if (confirm != null) {
      final (title, body, cta) = confirm;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(cta),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      if (!mounted) return;
    }
    setState(() => _busy = true);
    try {
      await act();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(ok)));
      // No setState(_busy=false) after resolve/dismiss — the tile is gone. A ban
      // leaves the tile, so restore below on that path via the mounted check.
      if (mounted) setState(() => _busy = false);
    } on Forbidden {
      // The moderator flag was revoked server-side; the controller already
      // refreshed /me (→ isModeratorProvider flips → the screen gates off).
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('You no longer have moderator access.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('Action failed. Please try again.')),
      );
    }
  }
}

enum _ReportAction { takeDown, dismiss, ban }
