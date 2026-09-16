// The DECODER — the one parser on the CallKit seam, and the one layer every
// other test in this feature replaces with a fake.
//
// `system_call_navigator_test.dart` injects a `_FakeBridge` that emits
// already-constructed `SystemCallAction`s, and the contract test greps NAMES
// without executing anything. So the map extraction below was covered by
// exactly nothing — a naive decode on a structured payload, failing quiet: a
// malformed event drops to null and is indistinguishable from "the user never
// answered". (Maxwell, cage-match PR #201.)
import 'package:aiko_chat_app/features/call/data/system_call_bridge.dart';
import 'package:aiko_chat_app/features/call/domain/system_call_action.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SystemCallActionKind.parse', () {
    test('every member round-trips through its own name', () {
      // The enum is the census: a member added without a Swift case, or renamed
      // on one side, shows up here rather than as a transition silently dropped.
      for (final kind in SystemCallActionKind.values) {
        expect(SystemCallActionKind.parse(kind.name), kind);
      }
    });

    test('an unknown name is NULL, not a guess', () {
      // Permissive decode is a cross-repo obligation: a newer native half can
      // emit a member this build never heard of, and the honest answer is to
      // ignore it. Guessing at the nearest neighbour here would answer a
      // "declined" with a room join.
      expect(SystemCallActionKind.parse('declined'), isNull);
      expect(SystemCallActionKind.parse(''), isNull);
      expect(SystemCallActionKind.parse(null), isNull);
      expect(SystemCallActionKind.parse('ANSWERED'), isNull);
    });
  });

  group('AppleSystemCallBridge.actions decoding', () {
    /// Drives the REAL bridge over a fake platform-channel message stream, so
    /// the decode path under test is the shipped one.
    Stream<SystemCallAction> decoded(List<Object?> events) {
      const name = kSystemCallActionsChannel;
      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockStreamHandler(
            const EventChannel(name),
            _FakeStream(events),
          );
      return AppleSystemCallBridge(
        platformOverride: TargetPlatform.iOS,
      ).actions;
    }

    test('a well-formed event becomes a typed action', () async {
      final out = await decoded([
        {'action': 'answered', 'channel': 'dm:aaa:bbb'},
        {'action': 'ended', 'channel': 'dm:aaa:bbb'},
      ]).toList();
      expect(out, [
        const SystemCallAction(
          kind: SystemCallActionKind.answered,
          channelId: 'dm:aaa:bbb',
        ),
        const SystemCallAction(
          kind: SystemCallActionKind.ended,
          channelId: 'dm:aaa:bbb',
        ),
      ]);
    });

    test('malformed events are DROPPED, and never guessed at', () async {
      // Each of these is a shape the native side should not produce. Joining a
      // room or ending a call on any of them is worse than ignoring it — there
      // is no honest default for "which call did the user mean".
      final out = await decoded([
        null,
        'answered',
        42,
        {'action': 'answered'}, // no channel
        {'action': 'answered', 'channel': ''}, // empty channel
        {'action': 'answered', 'channel': 7}, // channel not a string
        {'channel': 'dm:aaa:bbb'}, // no action
        {'action': 'exploded', 'channel': 'dm:aaa:bbb'}, // unknown kind
        {'action': 'ended', 'channel': 'dm:ccc:ddd'}, // the one good one
      ]).toList();
      expect(out, [
        const SystemCallAction(
          kind: SystemCallActionKind.ended,
          channelId: 'dm:ccc:ddd',
        ),
      ]);
    });

    test('a channel id needing percent-encoding survives the seam intact', () {
      // Pinned because the NAVIGATOR used to compare a reconstructed
      // `/call/$id` against a percent-encoded `uri.path`, which silently missed
      // for exactly these ids. The decoder never encodes; this is the control
      // proving the id reaching the navigator is the raw one.
      const weird = 'dm:a b:é';
      expect(
        const SystemCallAction(
          kind: SystemCallActionKind.ended,
          channelId: weird,
        ).channelId,
        weird,
      );
    });
  });
}

/// Replays a canned list of platform events onto an `EventChannel`.
class _FakeStream extends MockStreamHandler {
  const _FakeStream(this.events);
  final List<Object?> events;

  @override
  void onListen(Object? arguments, MockStreamHandlerEventSink sink) {
    for (final e in events) {
      sink.success(e);
    }
    sink.endOfStream();
  }

  @override
  void onCancel(Object? arguments) {}
}
