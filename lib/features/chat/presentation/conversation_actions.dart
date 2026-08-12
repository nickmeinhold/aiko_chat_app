/// The two CONVERSATION actions you can take on another human: message them, or
/// call them. Both find-or-create the same DM channel (`POST /v1/dm`); they
/// differ only in where they land you — the message surface, or its LiveKit room.
///
/// Chat-owned on purpose (#2798 Inc 4). These used to live inside
/// `moderation/message_actions.dart`, which is documented as the *moderation*
/// sheet (UGC — Apple 1.2 / Google UGC, #7); starting a conversation is the
/// opposite of moderating one, and the mis-homing is what left `openDm` with a
/// single caller on the CALL path — so for the whole of Inc 1 the only way to
/// bring a DM into existence was to video-call someone. Moderation keeps
/// Report/Block; the sheet composes both halves.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../call/presentation/call_screen.dart' show pushCall;
import '../../moderation/application/moderation_controller.dart';
import '../application/chat_providers.dart';
import '../data/chat_rest_api.dart' show DmTargetNotFound, NetworkUnavailable;
import '../domain/channel.dart';

/// Open (find-or-create) the DM with [userId] and make it the active
/// conversation. Selection is the SAME mutator a channel tile uses, so the
/// message pane, the sidebar highlight and the self-heal all treat the DM
/// exactly like a channel (#2798 Inc 1).
///
/// Failures surface as a SnackBar and never change the selection — landing the
/// user in a conversation that does not exist is worse than staying put.
Future<void> startDm(
  BuildContext context,
  WidgetRef ref,
  String userId,
  String name,
) async {
  final messenger = ScaffoldMessenger.of(context);
  if (_refuseBlocked(messenger, ref, userId, name, verb: 'message')) return;
  try {
    final dm = await _openAndSeed(ref, userId);
    ref.read(selectedChannelIdProvider.notifier).select(dm.id);
  } on DmTargetNotFound {
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't message $name — no such person here.")),
    );
  } on NetworkUnavailable {
    messenger.showSnackBar(
      const SnackBar(content: Text("You're offline — can't start a message.")),
    );
  } catch (_) {
    // Terminal auth (Unauthorized/AccountSuspended) lands here as a generic
    // message, matching the sibling handlers: the repository/transport layer
    // owns terminal-auth routing (a 401 on the next sync disconnects → logout /
    // suspended screen), and a per-action rethrow here would be an unhandled
    // async error. Named tradeoff: one generic hop, real routing next sync.
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not open that conversation. Please try again.')),
    );
  }
}

/// Open (find-or-create) the DM with [userId] and push its call screen. The room
/// IS the DM channel id; `openDm` idempotency means a re-tap — or the peer
/// tapping too — resolves to the SAME room (DM handoff #2633; call gating #2726).
Future<void> startCall(
  BuildContext context,
  WidgetRef ref,
  String userId,
  String name,
) async {
  final messenger = ScaffoldMessenger.of(context);
  if (_refuseBlocked(messenger, ref, userId, name, verb: 'call')) return;
  try {
    // openDm is idempotent: if a second Call slips through during this await it
    // resolves to the SAME room, and pushCall's latch then dedups the
    // navigation. The first tap always navigates — a double-fire costs at most
    // one redundant idempotent open, never a second call nor a swallowed tap
    // (cage-match #132 Tesla, latch-scope).
    final dm = await _openAndSeed(ref, userId);
    if (!context.mounted) return;
    await pushCall(context, dm.id);
  } on DmTargetNotFound {
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't reach $name for a call.")),
    );
  } on NetworkUnavailable {
    messenger.showSnackBar(
      const SnackBar(content: Text("You're offline — can't start a call.")),
    );
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not start the call. Please try again.')),
    );
  }
}

/// True when [userId] is blocked — and shows the explanatory SnackBar.
///
/// Defence-in-depth on the UGC block boundary (cage-match #132 Tesla, HIGH). A
/// blocked user's messages are already filtered out of the list, so these
/// actions are normally unreachable; but each is a NEW contact surface and must
/// FAIL CLOSED rather than lean on that upstream filter. The island is the real
/// boundary (backend-first — #2633 Decision 5 has the DM *send* block-gated,
/// with the video-token path tracked); this refuses the client attempt so a
/// blocked pair never even requests a channel.
bool _refuseBlocked(
  ScaffoldMessengerState messenger,
  WidgetRef ref,
  String userId,
  String name, {
  required String verb,
}) {
  if (!ref.read(blockedUserIdsProvider).contains(userId)) return false;
  messenger.showSnackBar(
    SnackBar(content: Text("You've blocked $name — unblock in Settings to $verb.")),
  );
  return true;
}

/// `POST /v1/dm`, then surface a NEWLY-opened DM in the sidebar + subscription
/// set so it is navigable the moment we land in it.
///
/// Seeds ONLY when the DM isn't already listed: `openDm` is idempotent, so
/// re-opening a conversation you already have must not trigger a full repo
/// rebuild (dispose→reconnect→resubscribe-all) — which on the call path is the
/// hot path (cage-match #132 Tesla, call-path churn). [seedOpenedDm] writes into
/// last-known FIRST and then invalidates, so the just-opened DM survives even if
/// the refetch fails soft — otherwise a failed refetch returns the stale list
/// WITHOUT this DM and drops it from the subscription set while we are standing
/// in it.
Future<Channel> _openAndSeed(WidgetRef ref, String userId) async {
  final dm = await ref.read(restApiProvider).openDm(userId);
  final knownDms = ref.read(dmsProvider).value ?? const <Channel>[];
  if (!knownDms.any((d) => d.id == dm.id)) {
    seedOpenedDm(ref, dm);
  }
  return dm;
}
