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
import '../../call/domain/call_invite.dart' show kCallInviteBody;
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
  if (_refuseBlocked(messenger, ref, userId, _Verb.message, name)) return;
  // Collected rather than shown inline: every arm fires after an await, so the
  // ONE liveness check at the tail covers them all instead of six scattered ones.
  final String failure;
  try {
    final dm = await ref.read(restApiProvider).openDm(userId);
    // Everything past this point touches the WIDGET-SCOPED ref, which throws once
    // the widget is disposed — so the liveness check gates the ref work, not just
    // the navigation (cage-match #133: Carnot HIGH, Tesla, Maxwell). The DM itself
    // is already created server-side; the next `GET /v1/dm` surfaces it.
    if (!context.mounted) return;
    _seedIfNew(ref, dm);
    ref.read(selectedChannelIdProvider.notifier).select(dm.id);
    return;
  } on DmTargetNotFound {
    failure = "Couldn't message $name — no such person here.";
  } on NetworkUnavailable {
    failure = "You're offline — can't start a message.";
  } catch (_) {
    // Terminal auth (Unauthorized/AccountSuspended) lands here as a generic
    // message, matching the sibling handlers: the repository/transport layer
    // owns terminal-auth routing (a 401 on the next sync disconnects → logout /
    // suspended screen), and a per-action rethrow here would be an unhandled
    // async error. Named tradeoff: one generic hop, real routing next sync.
    failure = 'Could not open that conversation. Please try again.';
  }
  // Liveness on the ERROR path too. Every arm above fires after an await and the
  // messenger was captured before it, so telling a torn-down surface about a
  // failed action is noise at best and an assertion on a disposed messenger at
  // worst (cage-match #133, Carnot + Tesla — the success path got this gate
  // first, which left the error path as the last place the old habit survived).
  if (!context.mounted) return;
  messenger.showSnackBar(SnackBar(content: Text(failure)));
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
  if (_refuseBlocked(messenger, ref, userId, _Verb.call, name)) return;
  // Single-flight from HERE, not from inside pushCall. The launch latch used to
  // sit downstream of the ring, so a double-tap ran openDm twice (harmless,
  // idempotent) and `_ring` twice — writing TWO invitations into permanent
  // signed history for one intent, on a body this design calls a one-way door
  // (cage-match #139, Maxwell). Guarding the navigation was guarding the wrong
  // step; the whole action is what must be single-flight. (Task #18 asked for
  // this latch as tidiness; the ring promoted it to correctness.)
  if (_callActionInFlight) return;
  _callActionInFlight = true;
  final String failure;
  try {
    // openDm stays idempotent (same room on a re-open) — belt-and-braces under
    // the action latch above, which is now what actually stops a second tap.
    final dm = await ref.read(restApiProvider).openDm(userId);
    // Liveness BEFORE the ref work, not just before the navigation — the seed
    // uses the widget-scoped ref and throws on a disposed widget. This ordering
    // was inverted in the pre-move `_call` (cage-match #133).
    if (!context.mounted) return;
    _seedIfNew(ref, dm);
    final rang = await _ring(ref, dm.id);
    // RE-checked after the ring: `_ring` awaits, so the mounted check above no
    // longer holds here. A mounted check does not survive a subsequent await —
    // adding the ring introduced a NEW async gap, not just another statement
    // (the #133 bug class, caught by `use_build_context_synchronously`).
    if (!context.mounted) return;
    if (!rang) {
      // Honest, not fatal: the room is still opening behind this.
      messenger.showSnackBar(SnackBar(
          content: Text("Couldn't ring $name — they may not see the call.")));
    }
    await pushCall(context, dm.id);
    return;
  } on DmTargetNotFound {
    failure = "Couldn't reach $name for a call.";
  } on NetworkUnavailable {
    failure = "You're offline — can't start a call.";
  } catch (_) {
    failure = 'Could not start the call. Please try again.';
  } finally {
    // Released on EVERY exit — the three early returns above included, and after
    // `pushCall` resolves (which is when the call route pops, so the latch
    // covers the whole call exactly as the old navigation latch did). A latch
    // without a finally is a latch that leaks on the first unmounted-context
    // return and locks Call out for the rest of the session.
    _callActionInFlight = false;
  }
  // Liveness on the ERROR path too. Every arm above fires after an await and the
  // messenger was captured before it, so telling a torn-down surface about a
  // failed action is noise at best and an assertion on a disposed messenger at
  // worst (cage-match #133, Carnot + Tesla — the success path got this gate
  // first, which left the error path as the last place the old habit survived).
  if (!context.mounted) return;
  messenger.showSnackBar(SnackBar(content: Text(failure)));
}

/// "A call action is being placed" — one app-wide fact, module-global like
/// [pushCall]'s navigation latch, because a second tap on ANY surface (message
/// sheet, DM header, roster) is the same intent as a second tap on this one.
///
/// Test-only reset lives in [resetCallActionGuard]; a widget test that never
/// pops the call route would otherwise leak the latch into the next test.
bool _callActionInFlight = false;

/// Clear the call-action latch between widget tests. Not a production seam.
@visibleForTesting
void resetCallActionGuard() => _callActionInFlight = false;

/// Ring the peer: send the signed call invitation into the DM (#2808).
///
/// Deliberately **non-blocking on failure** — the call itself is the capability,
/// so a failed invite must not stop you entering the room. But it is NOT silent:
/// a swallowed failure leaves the caller believing the peer was rung while the
/// peer heard nothing, and the two mental models diverge with no way back
/// (cage-match #139, Kelvin, twice). Returns false so the caller can say so.
///
/// Ordering: sent BEFORE `pushCall`, so the peer's device starts ringing while
/// we are connecting rather than after. `sendMessage` commits the optimistic row
/// before the wire send (invariant B-optimistic), so this returns fast and does
/// not gate navigation on a round-trip.
///
/// The body is [kCallInviteBody] and nothing else — room, caller and start time
/// are already inside the signed envelope (channelId, signing key, signedAtMs).
Future<bool> _ring(WidgetRef ref, String channelId) async {
  try {
    final repo = await ref.read(chatRepositoryProvider.future);
    await repo.sendMessage(channelId, kCallInviteBody);
    return true;
  } catch (_) {
    return false; // reported to the user by the caller; the call proceeds.
  }
}

/// The contact surfaces this file offers, as a closed set rather than a free
/// `String` — the copy below is the only thing that varies between them, and a
/// mistyped verb would ship silently to a user (cage-match #133, Carnot).
enum _Verb {
  message('message'),
  call('call');

  const _Verb(this.label);
  final String label;
}

/// True when [userId] is blocked — and shows the explanatory SnackBar.
///
/// Defence-in-depth on the UGC block boundary (cage-match #132 Tesla, HIGH). A
/// blocked user's messages are already filtered out of the list, so these
/// actions are normally unreachable; each is a NEW contact surface, so it
/// refuses locally rather than leaning on that upstream filter.
///
/// Scope of the claim, stated honestly (cage-match #133, Carnot): this is
/// BEST-EFFORT, not fail-closed. [blockedUserIdsProvider] collapses loading and
/// error to an empty set (`orElse`), so while the block list is unresolved this
/// refuses nothing and the attempt reaches the island. That is the right
/// direction for a reversible capability — refusing to open a conversation
/// because a list has not loaded strands the user over a transient fetch — but
/// it means the ISLAND is the boundary, not this check (backend-first; #2633
/// Decision 5 has the DM *send* block-gated, with the video-token path tracked).
/// Read this as "do not even ask when we know better", not as enforcement.
bool _refuseBlocked(
  ScaffoldMessengerState messenger,
  WidgetRef ref,
  String userId,
  _Verb verb,
  String name,
) {
  if (!ref.read(blockedUserIdsProvider).contains(userId)) return false;
  messenger.showSnackBar(
    SnackBar(
      content: Text("You've blocked $name — unblock in Settings to ${verb.label}."),
    ),
  );
  return true;
}

/// Surface a NEWLY-opened DM in the sidebar + subscription set so it is
/// navigable the moment we land in it.
///
/// Seeds ONLY when the DM isn't already listed: `openDm` is idempotent, so
/// re-opening a conversation you already have must not trigger a full repo
/// rebuild (dispose→reconnect→resubscribe-all) — which on the call path is the
/// hot path (cage-match #132 Tesla, call-path churn). [seedOpenedDm] writes into
/// last-known FIRST and then invalidates, so the just-opened DM survives even if
/// the refetch fails soft — otherwise a failed refetch returns the stale list
/// WITHOUT this DM and drops it from the subscription set while we are standing
/// in it.
///
/// This check reads `null → []` while [dmsProvider] is mid-refresh, so it can say
/// "not listed" about a DM that IS listed. That is why the no-op suppression
/// lives in [seedOpenedDm] rather than here — a guard on this side would have to
/// be repeated correctly by every caller (cage-match #133).
void _seedIfNew(WidgetRef ref, Channel dm) {
  final knownDms = ref.read(dmsProvider).value ?? const <Channel>[];
  if (!knownDms.any((d) => d.id == dm.id)) {
    seedOpenedDm(ref, dm);
  }
}
