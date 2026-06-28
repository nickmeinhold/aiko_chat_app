/// The long-press moderation menu on a message (UGC — Apple 1.2 / Google UGC, #7).
///
/// Surfaced only on ANOTHER human's message (gated by the caller: `!isMine &&
/// sender.userId != null`) — you cannot block/report yourself or an external
/// actor (LLM/robot have no account to action). Offers Report (reason picker) and
/// Block (confirm), both calling [BlockedUsersController]. Errors surface as a
/// SnackBar; block additionally hides the user's messages instantly via the
/// client-side filter in `messagesProvider`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/domain/message.dart';
import '../application/moderation_controller.dart';
import '../domain/moderation_models.dart';

/// Show the moderation actions for [message]. Caller guarantees the message is
/// another human's (has a non-null `sender.userId`).
Future<void> showMessageActions(
  BuildContext context,
  WidgetRef ref,
  Message message,
) async {
  final userId = message.sender.userId;
  if (userId == null) return; // defensive: caller should have gated this
  final name = message.sender.displayLabel;

  final action = await showModalBottomSheet<_Action>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Report message'),
            onTap: () => Navigator.pop(ctx, _Action.report),
          ),
          ListTile(
            leading: Icon(Icons.block, color: Theme.of(ctx).colorScheme.error),
            title: Text(
              'Block $name',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
            onTap: () => Navigator.pop(ctx, _Action.block),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;

  switch (action) {
    case _Action.report:
      await _report(context, ref, message.id ?? message.clientTempId);
    case _Action.block:
      await _block(context, ref, userId, name);
  }
}

enum _Action { report, block }

Future<void> _report(
  BuildContext context,
  WidgetRef ref,
  String messageId,
) async {
  final reason = await showModalBottomSheet<ReportReason>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Why are you reporting this?'),
            ),
          ),
          for (final r in ReportReason.values)
            ListTile(title: Text(r.label), onTap: () => Navigator.pop(ctx, r)),
        ],
      ),
    ),
  );
  if (reason == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(blockedUsersProvider.notifier).report(messageId, reason);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Thanks — your report has been sent for review.'),
      ),
    );
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Could not send the report. Please try again.'),
      ),
    );
  }
}

Future<void> _block(
  BuildContext context,
  WidgetRef ref,
  String userId,
  String name,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Block $name?'),
      content: Text(
        "You won't see $name's messages and they won't see yours. You can "
        'unblock them later in Settings.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Block'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref
        .read(blockedUsersProvider.notifier)
        .block(userId, displayName: name);
    messenger.showSnackBar(SnackBar(content: Text('$name blocked.')));
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Could not block this user. Please try again.'),
      ),
    );
  }
}
