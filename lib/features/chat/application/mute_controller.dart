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
      return {for (final t in MuteTarget.values) t: const <String>{}};
    }
    return _freeze(ref.read(muteStoreProvider).readAll(userId));
  }

  bool isMuted(MuteTarget target, String id) => state[target]!.contains(id);

  /// Set [id]'s muted state under [target], in memory first (the UI's fast path)
  /// and durably behind it. Idempotent: setting the state it already holds is a
  /// no-op, so a double-tap costs neither a rebuild nor a disk write.
  void setMuted(MuteTarget target, String id, {required bool muted}) {
    final userId = ref.read(authControllerProvider).value?.userId; // non-reactive
    if (userId == null || id.isEmpty) return;
    final current = state[target]!;
    if (current.contains(id) == muted) return;
    final next = {...current};
    if (muted) {
      next.add(id);
    } else {
      next.remove(id);
    }
    state = _freeze({
      for (final t in MuteTarget.values) t: t == target ? next : state[t]!,
    });
    // Persist the WHOLE new state, never a delta: the notifier is the single
    // historian and disk is its dump, so a failed write is repaired by the next
    // one instead of compounding (see [MuteStore.replaceAll]).
    ref.read(muteStoreProvider).replaceAll(userId, state);
  }

  void toggle(MuteTarget target, String id) =>
      setMuted(target, id, muted: !isMuted(target, id));
}

/// The muted CONVERSATION ids (channels and DMs alike).
final mutedChannelIdsProvider = Provider.autoDispose<Set<String>>(
    (ref) => ref.watch(mutesProvider)[MuteTarget.channel]!);

/// The muted ACCOUNT ids. A muted account is silent in EVERY conversation — one
/// noisy participant should not have to be muted channel by channel.
final mutedUserIdsProvider = Provider.autoDispose<Set<String>>(
    (ref) => ref.watch(mutesProvider)[MuteTarget.user]!);
