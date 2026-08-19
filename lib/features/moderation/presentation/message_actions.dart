/// The long-press action sheet on a message.
///
/// Surfaced only on ANOTHER human's message (gated by the caller: `!isMine &&
/// sender.userId != null`) — you cannot block/report yourself or an external
/// actor (LLM/robot have no account to action).
///
/// Deliberately layered by OWNER, not by menu position: the CONVERSATION actions
/// (Message, Call) are chat-owned and live in
/// `chat/presentation/conversation_actions.dart`; the MODERATION actions (UGC —
/// Apple 1.2 / Google UGC, #7) are this file's — Report (reason picker) and Block
/// (confirm), both calling [BlockedUsersController]. Errors surface as a SnackBar;
/// block additionally hides the user's messages instantly via the client-side
/// filter in `messagesProvider`.
///
/// Mute is a THIRD owner appearing in the same sheet: chat-owned attention state
/// ([Mutes]), not moderation — nothing is sent anywhere and nothing is hidden. It
/// is presented here because the sheet is where a user decides what to do about a
/// person, and offering the mild reversible option above Report/Block is what
/// keeps "too noisy" from having to escalate into a moderation act (#2913 tracks
/// splitting the non-moderation actions out of this file).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/application/chat_providers.dart'
    show currentUserProvider, dmConversationIdsProvider;
import '../../chat/application/mute_controller.dart';
import '../../chat/domain/message.dart';
import '../../chat/presentation/conversation_actions.dart'
    show startCall, startDm;
import '../application/moderation_controller.dart';
import '../domain/moderation_models.dart';

/// Show the actions for [message]. Caller guarantees the message is another
/// human's (has a non-null `sender.userId`).
Future<void> showMessageActions(
  BuildContext context,
  WidgetRef ref,
  Message message,
) async {
  final userId = message.sender.userId;
  if (userId == null) return; // defensive: caller should have gated this
  final name = message.sender.displayLabel;

  // "Message" is the entry point INTO a DM, so it is meaningless once you are
  // standing in one — `openDm` is idempotent and would resolve to the very
  // channel you are reading. Hide it there rather than offer a no-op.
  //
  // DM-ness by SOURCE, through the one door (#136): an id absent from the set
  // reads as "not a DM", so an unknown channel fails OPEN — an extra idempotent
  // open costs nothing, a missing one strands the user, which is the bug this
  // whole slice exists to fix.
  final inDm = ref.read(dmConversationIdsProvider).contains(message.channelId);

  // Read once, before the sheet opens: the sheet's own labels must describe the
  // state the user is acting FROM, and a rebuild mid-sheet would flip the verb
  // under their finger.
  final muted = ref.read(mutedUserIdsProvider).contains(userId);
  // BOUND HERE, on the NEAR side of the sheet — beside `muted`, at the instant
  // the user acts.
  //
  // Read after the await instead (as this did for seven rounds) and the
  // fail-closed check becomes `liveAuth == liveAuth`: a principal sampled on the
  // far side of the gap is BY DEFINITION equal to live auth, so the comparison
  // carries zero information and always conducts. The guard rounds 3-7 built for
  // the other two doors was, at this one — the only writer of an account mute —
  // a rod painted copper (cage-match #135 round 10, Tesla). What was actually
  // stopping a cross-principal write here was the `context.mounted` check below:
  // a neighbour of the write, not a property of it.
  final container = ProviderScope.containerOf(context, listen: false);
  final actingUserId = container.read(currentUserProvider)?.userId;

  final action = await showModalBottomSheet<_Action>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Open (find-or-create) the DM with this sender and go there. Until
          // this existed, `openDm`'s only caller was Call — so a DM could only
          // be born as a side effect of a video call and Inc 1's sidebar section
          // was unreachable for anyone who had never called (#2798).
          if (!inDm)
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text('Message $name'),
              onTap: () => Navigator.pop(ctx, _Action.message),
            ),
          // Start a 1:1 A/V call with this sender: the same DM channel, joined
          // as its LiveKit room. `openDm` is idempotent, so both parties tapping
          // Call resolve to the SAME room (DM handoff #2633; gating #2726).
          ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: Text('Call $name'),
            onTap: () => Navigator.pop(ctx, _Action.call),
          ),
          // Mute sits ABOVE the moderation pair deliberately: it is the mild,
          // reversible, private option, and offering it first means "too noisy"
          // doesn't have to escalate to a moderation act. Muting is silent and
          // one-sided — nothing is sent anywhere — so unlike Block it needs no
          // confirmation step.
          ListTile(
            // Bell, not speaker — a speaker-with-slash means call audio in an
            // app that ships 1:1 A/V (cage-match #135, Maxwell).
            leading: Icon(
              muted
                  ? Icons.notifications_none
                  : Icons.notifications_off_outlined,
            ),
            title: Text(muted ? 'Unmute $name' : 'Mute $name'),
            // Say EVERYWHERE. This is the only door that writes a
            // `MuteTarget.user`, and it is the global act — a long-press in
            // #general quiets that person in every room. The conversation
            // controls were made to confess when they touch an account mute; the
            // account door itself was still speaking in the local present
            // (cage-match #135 round 7, Tesla).
            //
            // Present tense only for what actually happens today: there are no
            // notifications yet, so promising them would be prophecy in the
            // indicative (round 6, Tesla).
            subtitle: Text(
              muted
                  ? "You'll see unread badges from them again, everywhere"
                  : "No unread badge from them in any conversation — you'll still "
                        'see their messages',
            ),
            onTap: () => Navigator.pop(ctx, _Action.mute),
          ),
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
    case _Action.message:
      await startDm(context, ref, userId, name);
    case _Action.call:
      await startCall(context, ref, userId, name);
    case _Action.mute:
      // No principal to bind → do not act. `expectUserId: null` means "no async
      // gap, same frame" at the synchronous call sites, so a null arriving HERE
      // (an auth flicker at bind time) would not fail closed — it would skip the
      // comparison entirely and let the write land under whoever is live when the
      // session returns. `B == B` was killed in round 10; `null ⇒ any` is the
      // same hole in a rarer costume (cage-match #135 round 14, Tesla).
      if (actingUserId == null) return;
      // `container` and `actingUserId` were captured BEFORE the sheet (see the
      // top of this function). The container, not the ref and not the notifier:
      // the SnackBar belongs to the ScaffoldMessenger ABOVE the chat surface, so
      // it outlives this message tile — mute, navigate to Settings or sign out,
      // then tap Undo. A captured `WidgetRef` is dead by then, and so is a
      // captured notifier, because `mutesProvider` is `.autoDispose` and a handle
      // to it is not a keep-alive (cage-match #135 rounds 1-2).
      container
          .read(mutesProvider.notifier)
          .setUserMuted(userId, muted: !muted, expectUserId: actingUserId);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(muted ? 'Unmuted $name' : 'Muted $name'),
          action: SnackBarAction(
            label: 'Undo',
            // Absolute target state (the value BEFORE this action), never a
            // toggle — a double-tap restores rather than oscillates.
            onPressed: () => container
                .read(mutesProvider.notifier)
                .setUserMuted(userId, muted: muted, expectUserId: actingUserId),
          ),
        ),
      );
    case _Action.report:
      await _report(context, ref, message.id ?? message.clientTempId);
    case _Action.block:
      await _block(context, ref, userId, name);
  }
}

enum _Action { message, call, mute, report, block }

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
