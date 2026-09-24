// The VoIP token is a door into being CALLED, and it was not behind the calling
// gate (claude-tasks#4420, found while wiring the answer path).
//
// `callingEnabled` closes the three doors INTO calling — the `/call/:id` route,
// the ring banner, the DM long-press action — and the flag's own doc says it
// closes every door. It was not closing this one: a store build still minted a
// PushKit token, still registered a `voip` row with the island, and would ring
// full-screen on a locked handset for a call it has no route to answer. Rung but
// unanswerable, in exactly the configuration that ships.
//
// BOTH ARMS ARE ASSERTED HERE ON PURPOSE. A gate test that only proves the
// closed state passes just as well when the provider returns null always — a
// check whose disabled value equals its success value cannot report its own
// absence.
import 'package:aiko_chat_app/app/feature_flags.dart';
import 'package:aiko_chat_app/features/notifications/application/push_providers.dart';
import 'package:aiko_chat_app/features/notifications/domain/token_kind.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  ProviderContainer containerWith({required bool calling}) {
    final c = ProviderContainer(
      overrides: [callingEnabledProvider.overrideWithValue(calling)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('calling ON → iOS takes a VoIP token', () {
    // The positive arm. Without it the closed arm below is satisfied by a
    // provider that answers null unconditionally, which is the same silence the
    // whole push feature is written against.
    final source = containerWith(calling: true).read(voipTokenSourceProvider);
    expect(source, isNotNull);
    expect(
      source!.kind,
      TokenKind.voip,
      reason:
          'the island stores alert and voip as two rows; the wrong kind '
          'here is a device that is registered and never rings',
    );
  });

  test(
    'calling OFF → no VoIP token, so nothing can ring an unanswerable build',
    () {
      expect(
        containerWith(calling: false).read(voipTokenSourceProvider),
        isNull,
      );
    },
  );

  test('no VoIP source → no VoIP registrar, so no row is ever registered', () {
    // The gate has to reach the REGISTRAR, not just the source: the registrar is
    // what talks to the island, and a registrar built on a null source would be
    // the gap reopened one layer down.
    // No other overrides: the registrar reads the REST client and the island
    // config, and a null answer here is also evidence it short-circuits on the
    // null source BEFORE touching either of them.
    expect(
      containerWith(calling: false).read(voipDeviceRegistrarProvider),
      isNull,
    );
  });
}
