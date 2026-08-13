/// Mute state — the in-memory, reactive half of [MuteStore].
///
/// Mute answers "stop demanding my attention", never "hide this from me": a
/// muted conversation still receives, caches, and RENDERS every message. The
/// only thing that changes is the unread badge (and, once notifications exist,
/// those). That distinction is why this lives in `chat/` next to the read
/// watermarks rather than in `moderation/` next to blocks — a block is a
/// moderation act with a server behind it, a mute is a local preference about
/// attention.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../data/mute_store.dart';

/// The durable mute store, over the app-wide [SharedPreferences].
final muteStoreProvider = Provider<MuteStore>(
  (ref) => MuteStore(ref.watch(sharedPreferencesProvider)),
);

/// The reactive `target → muted ids` map.
///
/// `.autoDispose` and seeded from the CURRENT user, matching
/// `channelReadMarksProvider` exactly: torn down on logout and rebuilt on the
/// next login, so one user's mutes can never surface in another's session. The
/// user id is read NON-reactively for the same reason it is there — watching
/// `currentUserProvider` here would let a descendant flushing that (login-dirty)
/// provider mid-build self-invalidate this one, which Riverpod reports as
/// "setState during build".
final mutesProvider =
    NotifierProvider.autoDispose<Mutes, Map<MuteTarget, Set<String>>>(
        Mutes.new);

class Mutes extends Notifier<Map<MuteTarget, Set<String>>> {
  /// Every set this notifier publishes is UNMODIFIABLE. `Set<String>` in the
  /// provider signature otherwise invites a consumer to mutate the live state
  /// directly, which would bypass both persistence and Riverpod's notification —
  /// a silent divergence between what the UI shows and what the disk holds
  /// (cage-match #135, Carnot). Freezing at the boundary makes that
  /// unrepresentable rather than merely discouraged. It also keeps the published
  /// instance STABLE while unchanged (the alternative — wrapping at read time in
  /// the derived providers — would mint a new object per recompute and notify
  /// listeners on every rebuild).
  /// Freezes the MAP as well as the sets. Freezing only the sets left the outer
  /// map writable, so `container.read(mutesProvider)[MuteTarget.channel] = {…}`
  /// still bypassed persistence and notification — a half-frozen boundary is a
  /// leak wearing a lock (cage-match #135, Carnot).
  /// Type arguments are EXPLICIT on both constructors. `Set.unmodifiable(...)`
  /// without one infers `UnmodifiableSetView<dynamic>`, which then fails the
  /// `Set<String>` cast the moment `Map.unmodifiable` re-types the entries — at
  /// RUNTIME, inside a provider build, surfacing as "provider is in error state"
  /// rather than a compile error.
  static Map<MuteTarget, Set<String>> _freeze(Map<MuteTarget, Set<String>> m) =>
      Map<MuteTarget, Set<String>>.unmodifiable({
        for (final t in MuteTarget.values)
          t: Set<String>.unmodifiable(m[t] ?? const <String>{})
      });

  @override
  Map<MuteTarget, Set<String>> build() {
    final userId = ref.read(authControllerProvider).value?.userId;
    if (userId == null) {
      // Frozen too. An "empty" state that is quietly writable is where the next
      // edit learns that empty means safe to mutate (cage-match #135 round 3,
      // Carnot + Tesla) — every published state obeys the same contract.
      return _freeze(const {});
    }
    return _freeze(ref.read(muteStoreProvider).readAll(userId));
  }

  bool isMuted(MuteTarget target, String id) => state[target]!.contains(id);

  /// Set [id]'s muted state under [target], in memory first (the UI's fast path)
  /// and durably behind it. Idempotent: setting the state it already holds is a
  /// no-op, so a double-tap costs neither a rebuild nor a disk write.
  ///
  /// [expectUserId] is REQUIRED of any caller writing across an async gap (a menu
  /// that was open, an Undo on a SnackBar that outlived its screen). This method
  /// resolves the principal from the LIVE auth state, so lengthening a handle's
  /// lifetime — which is exactly what capturing the container did — also lets the
  /// write jump into whoever is signed in when it finally lands. Undo tapped after
  /// a different login on the same container would write into the NEW principal's
  /// book (cage-match #135 round 3, Tesla). Binding the id at action time and
  /// FAILING CLOSED on a mismatch means a stale write is dropped rather than
  /// misattributed: a missed unmute is a badge the user can see and redo, a write
  /// into another account's preferences is invisible and wrong.
  void setMuted(
    MuteTarget target,
    String id, {
    required bool muted,
    // REQUIRED, though nullable: `toggle()` was deleted for being a footgun a
    // comment could not disarm, and this was the same shape — a rule stated in
    // prose that the next caller (awaiting a sheet, a menu, a SnackBar) can
    // silently skip. Making it required forces every call site to answer the
    // question; passing null is the explicit "no gap, same frame" answer
    // (cage-match #135 round 7, Tesla — "a comment is not a type").
    required String? expectUserId,
  }) {
    final userId = ref.read(authControllerProvider).value?.userId; // non-reactive
    if (userId == null || id.isEmpty) return;
    if (expectUserId != null && expectUserId != userId) return; // fail closed
    final current = state[target]!;
    if (current.contains(id) == muted) {
      // ALREADY in the requested state in memory — but still queue a snapshot.
      //
      // Returning outright let an undo be overwritten by a write it raced
      // (cage-match #135 round 7, Carnot HIGH): mute (snapshot A=muted queued
      // behind a slow platform write), navigate away so the autoDispose notifier
      // dies, tap Undo — the rebuilt notifier hydrates from a disk that A has not
      // reached yet, so "unmute" reads as already-unmuted, wrote nothing, and A
      // then landed. Disk says muted after the user explicitly undid it, with no
      // corrective write ever queued.
      //
      // Persisting the CURRENT state on a no-op closes it by construction: writes
      // are full snapshots applied in order, so this one lands after A and leaves
      // disk agreeing with the state the user can see. The cost is one redundant
      // write on a redundant tap.
      ref.read(muteStoreProvider).replaceAll(userId, state);
      return;
    }
    final next = {...current};
    if (muted) {
      next.add(id);
    } else {
      next.remove(id);
    }
    // Freeze ONLY the set that changed and keep the other's existing reference.
    // `_freeze`-ing the whole map minted a new `Set.unmodifiable` for both
    // targets on every write, so a user-mute handed channel listeners a
    // different instance and rebuilt them for a fact that had not changed — the
    // code betraying the stability the comment on [_freeze] claims (cage-match
    // #135 round 6, Tesla).
    state = Map<MuteTarget, Set<String>>.unmodifiable({
      for (final t in MuteTarget.values)
        t: t == target ? Set<String>.unmodifiable(next) : state[t]!,
    });
    // Persist the WHOLE new state, never a delta: the notifier is the single
    // historian and disk is its dump, so a failed write is repaired by the next
    // one instead of compounding (see [MuteStore.replaceAll]).
    ref.read(muteStoreProvider).replaceAll(userId, state);
  }

}
// NOTE: a `toggle(target, id)` convenience was deleted rather than kept with a
// guard (cage-match #135 round 4, Tesla). It had no callers, and it invited
// exactly the two bugs this file spent three rounds removing: a relative
// operation races a concurrent change (every live caller writes an ABSOLUTE
// target state), and it had no `expectUserId`, so a future caller across an async
// gap would write into whoever is signed in. Deleting the affordance is cheaper
// than maintaining a safe version nobody uses.

/// The muted CONVERSATION ids (channels and DMs alike).
final mutedChannelIdsProvider = Provider.autoDispose<Set<String>>(
    (ref) => ref.watch(mutesProvider)[MuteTarget.channel]!);

/// The muted ACCOUNT ids. A muted account is silent in EVERY conversation — one
/// noisy participant should not have to be muted channel by channel.
final mutedUserIdsProvider = Provider.autoDispose<Set<String>>(
    (ref) => ref.watch(mutesProvider)[MuteTarget.user]!);

/// WHY a conversation row is quiet — and therefore what a control on that row
/// must act on.
///
/// A row can be silenced by two independent facts: the conversation is muted, or
/// (in a 1:1 DM, which has exactly one other party) its peer's ACCOUNT is muted.
/// Every surface that answers "is this muted?" has to answer it the same way, and
/// every control that offers to undo it has to undo *whatever is actually causing
/// the silence*. Deriving that separately per surface is how the sidebar row came
/// to show a bell while its own menu offered "Mute" — the row saying muted and the
/// control saying not-muted, about the same conversation (cage-match #135 round 3,
/// Tesla). This type is the single door: read [isMuted] to render, call
/// [ConversationMute.apply] to change it.
class ConversationMute {
  const ConversationMute({
    required this.conversationId,
    required this.peerId,
    required this.byConversation,
    required this.byPeer,
  }) : assert(!byPeer || peerId != null,
            'byPeer without a peerId is a cause apply() cannot clear');

  /// Derive from the two mute sets. PURE — the caller does the watching, which
  /// is what keeps this in the application layer (no `WidgetRef`) and, more
  /// importantly, keeps both watches UNCONDITIONAL at the call site.
  ///
  /// The earlier helper did `peerId != null && ref.watch(mutedUserIds)`, whose
  /// short-circuit meant that while a DM roster was unresolved the widget did not
  /// listen to account mutes at all — the same conditional-dependency trap this
  /// feature already fixed in `channelUnreadCountProvider`, reintroduced in the
  /// very helper written to keep every surface on one answer (cage-match #135
  /// round 5, Tesla).
  factory ConversationMute.from({
    required String conversationId,
    required String? peerId,
    required Set<String> mutedConversations,
    required Set<String> mutedUsers,
  }) =>
      ConversationMute(
        conversationId: conversationId,
        peerId: peerId,
        byConversation: mutedConversations.contains(conversationId),
        byPeer: peerId != null && mutedUsers.contains(peerId),
      );

  final String conversationId;

  /// The DM's single peer, or null for a group channel / unresolved roster.
  final String? peerId;

  final bool byConversation;
  final bool byPeer;

  bool get isMuted => byConversation || byPeer;

  /// Apply [muted] to whatever is causing the silence.
  ///
  /// Muting sets the CONVERSATION (the narrow, least surprising act — it does not
  /// silence a person everywhere on the strength of a tap on one row). Unmuting
  /// clears BOTH possible causes, because the user's intent is "make this row
  /// audible again" and leaving one in place presents a control that visibly
  /// fails to do what it says.
  ///
  /// Unmute clears BY ID, unconditionally — it does NOT consult [byConversation]
  /// / [byPeer]. Those flags are a snapshot from when this object was built, and
  /// a menu can hang in the overlay for a human age: mute the peer from a message
  /// sheet while the row's menu is open, and a flag-driven unmute would clear only
  /// the cause it knew about and leave the row silent. `setMuted` is idempotent
  /// for an id that is not muted, so clearing both costs nothing and cannot
  /// under-clear (cage-match #135 round 6, Tesla — the half-frozen-boundary
  /// lesson, in the time domain).
  void apply(Mutes mutes,
      {required bool muted, required String? expectUserId}) {
    if (muted) {
      mutes.setMuted(MuteTarget.channel, conversationId,
          muted: true, expectUserId: expectUserId);
      return;
    }
    mutes.setMuted(MuteTarget.channel, conversationId,
        muted: false, expectUserId: expectUserId);
    final peer = peerId;
    if (peer != null) {
      mutes.setMuted(MuteTarget.user, peer,
          muted: false, expectUserId: expectUserId);
    }
  }
}

/// Watch the mute state of a conversation, peer included. [peerId] is null for a
/// group channel or an unresolved DM roster — an unknown peer is never guessed
/// into a mute.
///
/// Both sets are watched UNCONDITIONALLY before deriving, so this widget's
/// dependency set never becomes a function of whether a roster has resolved.
ConversationMute watchConversationMute(
  WidgetRef ref,
  String conversationId, {
  String? peerId,
}) =>
    ConversationMute.from(
      conversationId: conversationId,
      peerId: peerId,
      mutedConversations: ref.watch(mutedChannelIdsProvider),
      mutedUsers: ref.watch(mutedUserIdsProvider),
    );
