// iOS takes a PushKit (VoIP) token — the door into being CALLED.
//
// This was a gate test while calling shipped behind a build flag (the
// token was the one door the flag did not close). The flag is gone
// since 0.0.6, so what remains is the positive arm: an iOS build registers a
// `voip` row, or a closed app can never ring.
import 'package:aiko_chat_app/features/notifications/application/push_providers.dart';
import 'package:aiko_chat_app/features/notifications/domain/token_kind.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS takes a VoIP token', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final source = c.read(voipTokenSourceProvider);
    expect(source, isNotNull);
    expect(
      source!.kind,
      TokenKind.voip,
      reason:
          'the island stores alert and voip as two rows; the wrong kind '
          'here is a device that is registered and never rings',
    );
  });
}
