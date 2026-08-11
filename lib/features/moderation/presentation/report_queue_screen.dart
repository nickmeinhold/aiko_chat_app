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

import '../../../core/widgets/reading_column.dart';
import '../../auth/application/auth_controller.dart';
import '../../chat/data/chat_rest_api.dart' show AccountSuspended, Forbidden;
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
        body: ReadingColumn(
          child: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'You no longer have moderator access on this island.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    final reportsAsync = ref.watch(pendingReportsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: ReadingColumn(
        child: RefreshIndicator(
        onRefresh: () => ref.refresh(pendingReportsProvider.future),
        child: reportsAsync.when(
          // Scrollable so the RefreshIndicator's pull works on every branch, not
          // just error/empty (completes the loading/error/empty/data triad —
          // cage-match Tesla round 5).
          loading: () => ListView(
            children: const [
              Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
          ),
          error: (e, _) => ListView(
            // ListView so the RefreshIndicator still pulls on an error.
            children: const [
              Padding(
                padding: EdgeInsets.all(24),
                // Fixed operator-facing copy — never interpolate the raw
                // exception (a DioException / Forbidden(context: /v1/...) leaks
                // endpoint + backend body into the UI; keep diagnostics in
                // telemetry only — cage-match Tesla + Carnot round 3). Pull to
                // retry.
                child: Text(
                  "Could not load the report queue. Pull to retry.",
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
        // Bounded line budget so the fixed-height ListTile (isThreeLine) doesn't
        // overflow at large accessibility text scales (cage-match Carnot round 4).
        _r.messageBody.isEmpty ? '(empty message)' : _r.messageBody,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                'Reason: ${_r.reasonLabel}',
                'Reporter: ${_r.reporterDisplayName ?? 'unknown'}',
                if (_r.isAlreadyDeleted) 'Already removed',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // Traceability for the moderator (cage-match Carnot): which message /
            // channel this preview refers to, so an ambiguous body isn't acted on
            // blind.
            Text(
              'msg ${_r.messageId} · ch ${_r.channelId}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
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
                // Fail closed client-side: never offer a ban for a report whose
                // sender id decoded empty (a malformed row would POST
                // /v1/users//ban) — cage-match Tesla + Carnot.
                if (_r.messageSenderUserId.isNotEmpty)
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
          // Dismiss resolves the report server-side (recoverable only by a fresh
          // re-report), so it gets a light confirm too — the PR's "confirm on
          // server-mutating actions" claim must hold for all three, not just the
          // other-user-affecting ones (cage-match Tesla + Carnot round 5).
          confirm: (
            'Dismiss report?',
            'Marks this report as not actionable and removes it from the queue. '
                'Recoverable only if someone reports the message again.',
            'Dismiss',
          ),
          act: () =>
              ref.read(pendingReportsProvider.notifier).dismiss(_r.reportId),
          ok: 'Report dismissed.',
        );
      case _ReportAction.ban:
        await _run(
          confirm: (
            'Ban sender?',
            // Name WHO is being banned so an ambiguous body preview can't lead to
            // banning the wrong principal (cage-match Tesla round 4). The island's
            // report DTO carries only the sender id, not a handle — surface the id.
            'Suspends the sender (${_r.messageSenderUserId}) from the island. '
                'Reversible, but they lose access immediately. The report stays in '
                'the queue until you act on it.',
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
    // The snackbars below fire through the messenger captured BEFORE the await, so
    // they show even when a resolve/dismiss removed this tile mid-await and
    // unmounted its State (that is the whole point of capturing it early —
    // cage-match Tesla + Carnot round 2: the old `if (!mounted) return` shorted
    // the success snackbar on the destructive path). Only `setState` needs the
    // mount guard.
    try {
      await act();
      messenger.showSnackBar(SnackBar(content: Text(ok)));
      if (mounted) setState(() => _busy = false); // tile survives (ban) → reset
    } on Forbidden {
      // The moderator flag was revoked server-side; the controller already
      // refreshed /me (→ isModeratorProvider flips → the screen gates off). Trust
      // the RECONCILED flag for the copy: an unmount here means the flag flipped
      // (demotion); if still mounted, read it — a transient refresh failure that
      // left the flag true reads as a plain denial, not a false "you were demoted."
      final demoted = !mounted || !ref.read(isModeratorProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(demoted
              ? 'You no longer have moderator access.'
              : 'Action denied. Please try again.'),
        ),
      );
      if (mounted) setState(() => _busy = false);
    } on AccountSuspended {
      // The operator's OWN account was banned mid-action. The controller already
      // settled suspension (→ the router is navigating to /suspended); don't paint
      // a competing "action failed" snackbar — let the router speak (Tesla r3).
      if (mounted) setState(() => _busy = false);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Action failed. Please try again.')),
      );
      if (mounted) setState(() => _busy = false);
    }
  }
}

enum _ReportAction { takeDown, dismiss, ban }
