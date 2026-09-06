// Details about THIS conversation — and the home mute never had.
//
// The app bar's title used to be the conversation SWITCHER, which is why mute
// had nowhere to go on a phone and ended up behind an unannounced long-press.
// Every comparable app (Slack, Discord, WhatsApp, Telegram, Signal, iMessage)
// reaches its conversation list through a drawer, which leaves the title free
// to mean "this conversation", and that is where mute lives in all of them.
//
// The measured version of that story: a blind playtester given only screenshots
// and the goal "silence the conversation called general" spent five presses,
// tried the chevron, the title, the gear and a long press, and gave up —
// "no mute, silence, or notification control appears anywhere in it". The
// control existed and was reachable in two presses by someone who already knew
// where it was. That gap is what this screen closes.
//
// Long-press on a sidebar row stays as the ACCELERATOR. It was never wrong as a
// secondary path; it was wrong as the only door.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/chat_providers.dart';
import '../application/mute_controller.dart';
import '../domain/channel_member.dart';
import 'chat_screen.dart';

/// Details for the ACTIVE conversation.
///
/// It takes no id: the active conversation is already a settled fact in
/// `chat_providers`, and passing one through the route would create a second
/// source for it — the exact two-routes-to-one-fact shape that produced the
/// switcher's crash (cage-match #136).
class ConversationDetailsScreen extends ConsumerWidget {
  const ConversationDetailsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(selectedChannelIdProvider);
    final navigable = ref.watch(navigableChannelsProvider);
    final active = ChatScreen.resolveActive(navigable, selectedId);

    if (active == null) {
      // Not an error state: the conversation can settle a frame later, or the
      // island can retire it while this page is open. Say so rather than
      // rendering controls that would act on nothing.
      return Scaffold(
        appBar: AppBar(title: const Text('Conversation')),
        body: const Center(child: Text('No conversation selected.')),
      );
    }

    final isDm = ref.watch(dmConversationIdsProvider).contains(active.id);
    final roster = ref.watch(channelRosterProvider(active.id)).value;
    final myId = ref.watch(currentUserProvider)?.userId;
    final peerId = isDm ? dmPeerId(roster, myId) : null;
    final title = isDm ? dmPeerTitle(roster, myId) : active.name;

    final mute = watchConversationMute(
      ref,
      active.id,
      peerId: peerId,
      hasPeer: isDm,
    );

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(isDm ? Icons.person_outline : Icons.tag),
            title: Text(title),
            subtitle: Text(isDm ? 'Direct message' : 'Channel'),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: Icon(
              mute.isMuted
                  ? Icons.notifications_off_outlined
                  : Icons.notifications_none,
            ),
            title: const Text('Mute this conversation'),
            // The same sentence the row long-press offers, from the same pure
            // getter. Two controls for one act must not describe it differently.
            subtitle: Text(mute.actionDetail),
            value: mute.isMuted,
            onChanged: (want) => mute.apply(
              ref.read(mutesProvider.notifier),
              muted: want,
              // Bound at the moment of the act, so a write landing after a
              // logout or user switch is dropped rather than filed under
              // another account (cage-match #135 round 3).
              expectUserId: ref.read(currentUserProvider)?.userId,
            ),
          ),
        ],
      ),
    );
  }
}
