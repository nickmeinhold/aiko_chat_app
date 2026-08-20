import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/chat/domain/channel_member.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:aiko_chat_app/features/chat/presentation/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/ui_fakes.dart';

/// Stage 2 acceptance (task #1): a message's sender name renders the sender's
/// CURRENT handle from the channel roster, not the send-time label baked onto
/// the message — so a rename retitles past messages.
Message _msg(String label) => Message(
  clientTempId: 't1',
  id: 's1',
  channelId: 'c1',
  sender: MessageSender(userId: 'u2', kind: SenderKind.human, label: label),
  body: 'hi',
  createdAt: DateTime(2026, 1, 1),
  deliveryState: DeliveryState.sent,
);

void main() {
  testWidgets(
    'renders the roster CURRENT handle over the stale message label',
    (tester) async {
      final fake = FakeRestApi();
      fake.membersByChannel['c1'] = const [
        ChannelMember(
          userId: 'u2',
          role: 'member',
          canPost: true,
          handle: 'renamed_now',
          displayName: 'Peer',
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [restApiProvider.overrideWithValue(fake)],
          child: MaterialApp(
            home: Scaffold(
              body: MessageTile(
                message: _msg('old_label'),
                isMine: false,
                channelId: 'c1',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(); // let the roster FutureProvider resolve.

      expect(find.text('renamed_now'), findsOneWidget);
      expect(find.text('old_label'), findsNothing);
    },
  );
}
