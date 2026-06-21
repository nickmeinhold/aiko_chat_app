import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/transport/envelopes.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SenderKind lenient decode', () {
    test('known values map exactly', () {
      expect(SenderKind.fromWire('human'), SenderKind.human);
      expect(SenderKind.fromWire('llm'), SenderKind.llm);
      expect(SenderKind.fromWire('robot'), SenderKind.robot);
      expect(SenderKind.fromWire('actor'), SenderKind.actor);
    });
    test('unknown/null -> actor (forward-compat, never throws)', () {
      expect(SenderKind.fromWire('hologram'), SenderKind.actor);
      expect(SenderKind.fromWire(null), SenderKind.actor);
    });
    test('isExternalActor', () {
      expect(SenderKind.human.isExternalActor, false);
      expect(SenderKind.llm.isExternalActor, true);
      expect(SenderKind.robot.isExternalActor, true);
      expect(SenderKind.actor.isExternalActor, true);
    });
  });

  group('ChannelKind / MessageKind lenient decode', () {
    test('unknown -> standard / text', () {
      expect(ChannelKind.fromWire('void'), ChannelKind.standard);
      expect(ChannelKind.fromWire(null), ChannelKind.standard);
      expect(MessageKind.fromWire('hologram'), MessageKind.text);
      expect(MessageKind.fromWire(null), MessageKind.text);
    });
  });

  group('MessageSender.fromJson', () {
    test('full sender', () {
      final s = MessageSender.fromJson(
          {'user_id': 'u1', 'kind': 'human', 'label': 'Alice'});
      expect(s.userId, 'u1');
      expect(s.kind, SenderKind.human);
      expect(s.label, 'Alice');
      expect(s.displayLabel, 'Alice');
    });
    test('null label does NOT throw (review finding #4)', () {
      final s = MessageSender.fromJson(
          {'user_id': null, 'kind': 'actor', 'label': null});
      expect(s.label, isNull);
      expect(s.userId, isNull);
      expect(s.displayLabel, 'actor'); // falls back to kind
    });
  });

  group('Message.fromView', () {
    final view = {
      'msg_id': '01J_ULID',
      'channel_id': 'c1',
      'sender': {'user_id': 'u1', 'kind': 'human', 'label': 'Alice'},
      'body': 'hello',
      'created_at': '2026-06-21T12:00:00+00:00',
      'reply_to': null,
    };

    test('server id doubles as durable cache PK', () {
      final m = Message.fromView(view);
      expect(m.id, '01J_ULID');
      expect(m.clientTempId, '01J_ULID');
      expect(m.body, 'hello');
      expect(m.deliveryState, DeliveryState.sent);
      expect(m.kind, MessageKind.text);
      expect(m.createdAt.isUtc, true);
    });

    test('label null + unknown kind survive (no throw)', () {
      final m = Message.fromView({
        ...view,
        'sender': {'user_id': null, 'kind': 'hologram', 'label': null},
      });
      expect(m.sender.kind, SenderKind.actor);
      expect(m.sender.label, isNull);
    });

    test('missing created_at -> epoch, no throw (symmetry)', () {
      final m = Message.fromView({...view, 'created_at': null});
      expect(m.createdAt.millisecondsSinceEpoch, 0);
    });
  });

  group('two-id reconcile via copyWith', () {
    test('optimistic row (id null) -> acked (id set, state sent)', () {
      final optimistic = Message(
        clientTempId: 'tmp-1',
        id: null,
        channelId: 'c1',
        sender: const MessageSender(userId: 'me', kind: SenderKind.human),
        body: 'hi',
        createdAt: DateTime.utc(2026),
        deliveryState: DeliveryState.sending,
      );
      final acked = optimistic.copyWith(
        id: '01J_SERVER',
        deliveryState: DeliveryState.sent,
        createdAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
      );
      expect(acked.clientTempId, 'tmp-1'); // PK preserved
      expect(acked.id, '01J_SERVER');
      expect(acked.deliveryState, DeliveryState.sent);
      expect(optimistic.id, isNull); // original unchanged (immutable)
    });

    test('id==null message is a valid, comparable value (symmetry)', () {
      final a = Message(
        clientTempId: 'tmp-1',
        channelId: 'c1',
        sender: const MessageSender(kind: SenderKind.human),
        body: 'x',
        createdAt: DateTime.utc(2026),
        deliveryState: DeliveryState.sending,
      );
      final b = Message(
        clientTempId: 'tmp-1',
        channelId: 'c1',
        sender: const MessageSender(kind: SenderKind.human),
        body: 'x',
        createdAt: DateTime.utc(2026),
        deliveryState: DeliveryState.sending,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('ServerFrame.parse (never throws)', () {
    test('ack', () {
      final f = ServerFrame.parse(
          '{"type":"ack","client_msg_id":"tmp-1","msg_id":"01J","created_at":"2026-06-21T00:00:00Z"}');
      expect(f, isA<AckFrame>());
      f as AckFrame;
      expect(f.clientMsgId, 'tmp-1');
      expect(f.msgId, '01J');
    });

    test('message', () {
      final f = ServerFrame.parse(
          '{"type":"message","msg":{"msg_id":"01J","channel_id":"c1","sender":{"kind":"human","label":"A"},"body":"hi","created_at":"2026-06-21T00:00:00Z","reply_to":null}}');
      expect(f, isA<MessageFrame>());
      f as MessageFrame;
      expect(f.msgId, '01J');
      final m = Message.fromView(f.msg);
      expect(m.body, 'hi');
    });

    test('error', () {
      final f = ServerFrame.parse(
          '{"type":"error","code":"bad","detail":"nope","ref_client_msg_id":"tmp-9"}');
      expect(f, isA<ErrorFrame>());
      f as ErrorFrame;
      expect(f.code, 'bad');
      expect(f.refClientMsgId, 'tmp-9');
    });

    test('non-JSON -> UnknownFrame', () {
      expect(ServerFrame.parse('not json {'), isA<UnknownFrame>());
    });
    test('non-object JSON -> UnknownFrame', () {
      expect(ServerFrame.parse('[1,2,3]'), isA<UnknownFrame>());
    });
    test('unknown type -> UnknownFrame (forward-compat)', () {
      final f = ServerFrame.parse('{"type":"typing","user":"a"}');
      expect(f, isA<UnknownFrame>());
    });
    test('ack missing ids -> UnknownFrame', () {
      expect(ServerFrame.parse('{"type":"ack","client_msg_id":"x"}'),
          isA<UnknownFrame>());
    });
  });

  group('outbound frames', () {
    test('SendFrame omits reply_to when null, has no sender (I5)', () {
      final j = const SendFrame(
              clientMsgId: 'tmp-1', channelId: 'c1', body: 'hi')
          .toJson();
      expect(j['type'], 'send');
      expect(j['client_msg_id'], 'tmp-1');
      expect(j.containsKey('reply_to'), false);
      expect(j.containsKey('sender'), false);
    });
    test('SendFrame includes reply_to when set', () {
      final j = const SendFrame(
              clientMsgId: 'tmp-1', channelId: 'c1', body: 'hi', replyTo: 'r1')
          .toJson();
      expect(j['reply_to'], 'r1');
    });
    test('SubscribeFrame', () {
      final j = const SubscribeFrame(['c1', 'c2']).toJson();
      expect(j['type'], 'subscribe');
      expect(j['channel_ids'], ['c1', 'c2']);
    });
  });

  group('auth models', () {
    test('AuthSession.fromJson (login response)', () {
      final s = AuthSession.fromJson({
        'access_token': 'a',
        'refresh_token': 'r',
        'user': {
          'user_id': 'u1',
          'username': 'alice',
          'display_name': 'Alice',
          'aiko_username': 'alice',
        },
      });
      expect(s.tokens.accessToken, 'a');
      expect(s.tokens.refreshToken, 'r');
      expect(s.user.username, 'alice');
    });
    test('refresh preserves refresh token (not rotated)', () {
      const t = AuthTokens(accessToken: 'old', refreshToken: 'r');
      final t2 = t.withRefreshedAccess('new');
      expect(t2.accessToken, 'new');
      expect(t2.refreshToken, 'r');
    });
    test('Channel.fromJson tolerates missing aiko_channel', () {
      final c = Channel.fromJson({'id': 'c1', 'name': 'general', 'kind': 'standard'});
      expect(c.aikoChannel, isNull);
      expect(c.kind, ChannelKind.standard);
    });
  });
}
