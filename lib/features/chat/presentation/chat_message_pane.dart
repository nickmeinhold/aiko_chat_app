/// The shared message pane: the connection banner, the message list, and the
/// composer for the active channel. Hosted by BOTH responsive branches (narrow
/// phone layout and wide sidebar layout) as the LAST child of a `Row`, so the
/// pane's Element + State (`_MessageListState._scrollController`,
/// `_ComposerState._controller`) survive a resize across the breakpoint — see
/// [ChatScreen] for the Option-A crossing rationale.
///
/// The load-bearing ValueKeys — `MessageList(key: ValueKey(active.id))` and
/// `Composer(key: ValueKey('composer-${active.id}'))` — force a dispose→recreate
/// per channel so scroll position resets and drafts don't bleed on a switch
/// (cage-match #106). The `NetworkStatusBanner` sits ABOVE the `when(...)` branch
/// so it stays visible in every state — including the offline empty-cache case
/// ("No channels yet"), where it's the only thing explaining WHY the workspace
/// looks empty (Carnot, PR #72).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/network_status_banner.dart';
import '../application/chat_providers.dart';
import 'chat_screen.dart';

class ChatMessagePane extends ConsumerWidget {
  const ChatMessagePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Gate on the REPOSITORY, not on `channelsProvider`. The repo is what makes a
    // conversation usable — it owns the subscription set, the history sync and
    // the send path — and it awaits BOTH lists, so its readiness is the honest
    // answer to "can this pane serve anything".
    //
    // Keying the gate to the channel fetch instead was wrong in both directions
    // once `active` started resolving over channels ∪ DMs (cage-match #136,
    // Tesla HIGH ×2 + Carnot):
    //   * too STRICT — a channel failure hid a DM the user could still see listed
    //     and select, so the one conversation left reachable was the one they
    //     could not read;
    //   * then, after that was loosened to render on `active != null`, too LOOSE —
    //     `GET /v1/dm` returning first made `active` a DM with the channel list
    //     still in flight, so the pane painted Alice's thread with a live
    //     composer, and the arriving channels moved the (still null) default to
    //     the first room: draft destroyed with the keyed Composer, and a send
    //     already in flight had gone to Alice. The old `channelsAsync.when`
    //     spinner had been an ACCIDENTAL phase-lock over that window; loosening it
    //     removed a guard nobody had written down as one.
    // The repo gate restores the interlock deliberately: nothing renders until
    // both lists have settled, so the implicit default cannot move under a user
    // who is already typing.
    final repoAsync = ref.watch(chatRepositoryProvider);
    final selectedId = ref.watch(selectedChannelIdProvider);
    // Active over channels ∪ DMs so a selected DM renders (#2798).
    final active = ChatScreen.resolveActive(
      ref.watch(navigableChannelsProvider),
      selectedId,
    );

    return Column(
      children: [
        const NetworkStatusBanner(),
        Expanded(
          // `hasValue`, NOT `when` — the same predicate the app bar uses, because
          // the two must not wind opposite ways. `AsyncValue.when` takes the
          // LOADING branch on every reload (`skipLoadingOnReload` defaults false),
          // and the repo reloads on the app's most ordinary action: opening a DM
          // seeds it, invalidates `dmsProvider`, and the repo watches that future.
          // So `when` flashed a spinner and DISPOSED the keyed Composer — draft
          // gone, mid-flight send left holding a disposing repo — while the bar,
          // reading `hasValue`, stayed live. That is the split this gate was added
          // to close, reappearing one rising edge later (cage-match #136, Tesla).
          //
          // `hasValue` keeps the previous repo on screen across a reload and only
          // yields the surface when there has never been one: cold start spins,
          // a first-load failure explains itself, and everything after that stays
          // put.
          child: repoAsync.hasValue
              ? (active == null
                    ? const Center(child: Text('No conversations yet.'))
                    : Column(
                        children: [
                          // No channel header in the wide layout (the sidebar already
                          // names + switches channels) nor the narrow layout (its
                          // AppBar does). The redundant per-pane bar is gone; the A/V
                          // call affordance lives on the message long-press action
                          // sheet (message_actions.dart → "Call <name>", #2758).
                          // Key by channel id so a switch gives MessageList a FRESH
                          // State (dispose→recreate) — otherwise the old channel's
                          // ScrollController carries over and lands the new channel at
                          // a stale offset (cage-match #106).
                          Expanded(
                            child: MessageList(
                              key: ValueKey(active.id),
                              channelId: active.id,
                            ),
                          ),
                          // Keyed like MessageList so each channel gets its OWN
                          // composer state — without this a draft typed in one channel
                          // rides into the next (and sends there) (cage-match #106).
                          Composer(
                            key: ValueKey('composer-${active.id}'),
                            channelId: active.id,
                          ),
                        ],
                      ))
              : repoAsync.hasError
              ? Center(
                  child: Text(
                    'Could not load conversations.\n${repoAsync.error}',
                  ),
                )
              : const Center(child: CircularProgressIndicator()),
        ),
      ],
    );
  }
}
