import 'package:aiko_chat_app/features/chat/domain/channel_member.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';

MessageSender _sender({String? userId, String? label}) =>
    MessageSender(userId: userId, kind: SenderKind.human, label: label);

void main() {
  group(
    'senderDisplayName — render current handle, not the send-time label',
    () {
      test(
        'my own message uses my CURRENT handle, overriding a stale label',
        () {
          final name = senderDisplayName(
            _sender(userId: 'me', label: 'old_handle'),
            isMine: true,
            myHandle: 'new_handle',
            roster: const {'me': 'roster_stale'},
          );
          expect(name, 'new_handle');
        },
      );

      test(
        'another member resolves to the roster CURRENT handle, not the label',
        () {
          final name = senderDisplayName(
            _sender(userId: 'u2', label: 'u2_old'),
            isMine: false,
            myHandle: 'me',
            roster: const {'u2': 'u2_new'},
          );
          expect(name, 'u2_new');
        },
      );

      test('sender not in the roster falls back to the stored label', () {
        final name = senderDisplayName(
          _sender(userId: 'ghost', label: 'left_the_channel'),
          isMine: false,
          roster: const {'u2': 'u2_new'},
        );
        expect(name, 'left_the_channel');
      });

      test('roster not yet loaded (null) falls back to the stored label', () {
        final name = senderDisplayName(
          _sender(userId: 'u2', label: 'u2_old'),
          isMine: false,
          roster: null,
        );
        expect(name, 'u2_old');
      });

      test('mine but handle not yet known falls through to roster/label', () {
        expect(
          senderDisplayName(
            _sender(userId: 'me', label: 'lbl'),
            isMine: true,
            myHandle: null,
            roster: const {'me': 'roster_me'},
          ),
          'roster_me',
        );
        expect(
          senderDisplayName(
            _sender(userId: 'me', label: 'lbl'),
            isMine: true,
            myHandle: '',
          ),
          'lbl',
        );
      });

      test('an empty roster handle is ignored (fall back to label)', () {
        final name = senderDisplayName(
          _sender(userId: 'u2', label: 'u2_lbl'),
          isMine: false,
          roster: const {'u2': ''},
        );
        expect(name, 'u2_lbl');
      });

      test('a keyless sender (LLM/robot, no userId) uses its label', () {
        final name = senderDisplayName(
          _sender(userId: null, label: 'aiko'),
          isMine: false,
          roster: const {'u2': 'u2_new'},
        );
        expect(name, 'aiko');
      });
    },
  );

  group('ChannelMember.fromJson', () {
    test('parses the full roster item', () {
      final m = ChannelMember.fromJson(const {
        'user_id': 'u1',
        'role': 'member',
        'can_post': true,
        'handle': 'alice',
        'display_name': 'Alice',
      });
      expect(m.userId, 'u1');
      expect(m.role, 'member');
      expect(m.canPost, isTrue);
      expect(m.handle, 'alice');
      expect(m.displayName, 'Alice');
    });

    test('tolerates missing optionals (defaults, never throws on absent)', () {
      final m = ChannelMember.fromJson(const {'user_id': 'u1'});
      expect(m.userId, 'u1');
      expect(m.role, '');
      expect(m.canPost, isFalse);
      expect(m.handle, '');
      expect(m.displayName, '');
    });
  });
}
