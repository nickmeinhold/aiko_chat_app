// The handset id, end to end — what reaches the wire, what never does, and the
// one property that makes the field useful at all.
//
// WHY THIS FIELD EXISTS. A dual-registered iPhone is two island rows (alert from
// UIKit, voip from PushKit). A call invite fans out to both, so one call rings
// CallKit *and* draws a banner. The island ships that duplicate deliberately —
// "a duplicate notification is a blemish; a missed call is the bug" — because
// suppressing the alert row requires knowing the two rows share a screen, and it
// refuses to guess. This value is that knowledge.
//
// WHICH MAKES THE INTERESTING TESTS THE NEGATIVE ONES. The feature's upside is
// cosmetic; its downside is a handset that never rings, reachable two ways:
// a 422 that fails the whole registration, or a WRONG grouping that makes the
// island silence a second physical phone. So most of this file pins what must
// NOT happen.

import 'package:aiko_chat_app/features/notifications/application/device_registrar.dart';
import 'package:aiko_chat_app/features/notifications/data/keychain_install_id_source.dart';
import 'package:aiko_chat_app/features/notifications/data/pending_unregister_store.dart';
import 'package:aiko_chat_app/features/notifications/domain/device_platform.dart';
import 'package:aiko_chat_app/features/notifications/domain/install_id_source.dart';
import 'package:aiko_chat_app/features/notifications/domain/token_kind.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/ui_fakes.dart';
import 'install_id_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what reaches the wire', () {
    test('sends install_id when there is one', () async {
      final (api, bodies) = capturingIsland();
      await api.registerDevice(
        platform: DevicePlatform.apns,
        token: 'tok',
        installId: 'ABC-123',
      );
      expect(bodies.single['install_id'], 'ABC-123');
    });

    // THE KEY THAT IS ABSENT IS NOT THE KEY THAT IS NULL, and here the
    // difference is a handset that does not wake. The island's field is
    // `Field(min_length=1)`, so an explicit null is an out-of-set value at a
    // validating boundary: 422, and the 422 fails the ENTIRE registration, not
    // just this field. Absent means "the client did not say" — what every build
    // before this one said, and what a platform with no answer must keep saying.
    test('OMITS the key entirely when there is no id', () async {
      final (api, bodies) = capturingIsland();
      await api.registerDevice(platform: DevicePlatform.apns, token: 'tok');
      expect(bodies.single.containsKey('install_id'), isFalse);
      // Stated separately, because `containsKey` false and a null value read
      // identically through `body['install_id']` and only one of them is safe.
      expect(bodies.single['install_id'], isNull);
    });
  });

  group('the grouping invariant', () {
    late FakeRestApi api;
    late PendingUnregisterStore pending;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      api = FakeRestApi();
      pending = PendingUnregisterStore(await SharedPreferences.getInstance());
    });

    DeviceRegistrar registrar(TokenKind kind, InstallIdSource? ids) =>
        DeviceRegistrar(
          source: FixedTokenSource(kind: kind, token: 'tok-${kind.wire}'),
          api: api,
          pending: pending,
          islandBaseUrl: 'https://island.example',
          installIds: ids,
        );

    // THE WHOLE POINT OF THE FIELD, and the reason the source is shared rather
    // than per-registrar. Two rows that disagree about which handset they are on
    // are worse than two rows that say nothing: the island would group one phone
    // as two and suppress nothing, or — once it prefers voip within a group —
    // group two phones as one and silence a real handset's only reach.
    test('both token kinds register under the SAME id', () async {
      final shared = KeychainInstallIdSource(methods: fixedChannel('ID-1'));
      await registrar(TokenKind.alert, shared).start();
      await registrar(TokenKind.voip, shared).start();
      expect(api.registeredInstallIds, ['ID-1', 'ID-1']);
    });

    // THE SHAPE PRODUCTION ACTUALLY USES, and the one the sequential test above
    // cannot reach. `pushPairingProvider` fires both registrar chains
    // `unawaited` at a sign-in edge — they are in flight together, not one after
    // the other. Caught by Carnot in cage-match and independently while writing
    // this file's own review; the code passed the sequential test while
    // returning null to whichever caller arrived second, so the alert row and
    // the voip row would never have grouped and the feature would have shipped
    // doing nothing.
    test('CONCURRENT callers both receive the id', () async {
      final source = KeychainInstallIdSource(methods: fixedChannel('ID-1'));
      final results = await Future.wait([
        source.installId(),
        source.installId(),
      ]);
      expect(results, ['ID-1', 'ID-1']);
    });

    // The memo is a CORRECTNESS property, not a performance one: a source that
    // could answer differently on a second call reintroduces the split above
    // inside one instance. Pinned by counting native calls, because an identical
    // answer twice cannot distinguish "cached" from "asked twice and got lucky".
    test('asks the platform once and reuses the answer', () async {
      final channel = fixedChannel('ID-1');
      final source = KeychainInstallIdSource(methods: channel);
      await registrar(TokenKind.alert, source).start();
      await registrar(TokenKind.voip, source).start();
      expect(channel.calls, 1);
    });

    // NEVER A GATE. Everything on this path degrades reach and nothing else, and
    // a cosmetic field must not be the exception: a missing native half is a
    // desktop target or a `.swift` outside the Runner target, and the device
    // still has to register.
    test('a source that cannot answer still registers the device', () async {
      final source = KeychainInstallIdSource(methods: throwingChannel());
      await registrar(TokenKind.alert, source).start();
      expect(api.registeredInstallIds, [null]);
      expect(api.liveRows, {'tok-alert'});
    });

    // The state every build before this one was in, and it must stay reachable
    // rather than becoming a null-check somebody "tidies up".
    test('no source at all is a registration with no id', () async {
      await registrar(TokenKind.alert, null).start();
      expect(api.registeredInstallIds, [null]);
      expect(api.liveRows, {'tok-alert'});
    });
  });

  // THE ASYMMETRY IS THE ARGUMENT. A dropped id costs a banner nobody wanted; a
  // forwarded bad id costs a 422 and therefore a handset that never wakes. So an
  // unexpected native answer is refused here rather than sent and rejected
  // there, even though the native side mints a UUID that satisfies the contract
  // by construction — "by construction" is exactly the assumption that stops
  // being true when somebody changes the minting.
  group('a value the island would refuse never leaves', () {
    Future<String?> resolve(String native) =>
        KeychainInstallIdSource(methods: fixedChannel(native)).installId();

    test('passes a UUID, which is what the native side mints', () async {
      expect(await resolve('7C9E6679-7425-40DE-944B-E07FC1F90AE7'), isNotNull);
    });

    test('drops a value over the column width', () async {
      expect(await resolve('a' * 65), isNull);
      // The boundary itself passes — an off-by-one here would silently disable
      // the feature for ids nothing is wrong with.
      expect(await resolve('a' * 64), isNotNull);
    });

    test('drops an empty answer', () async {
      expect(await resolve(''), isNull);
    });

    // The island's charset is `^[A-Za-z0-9_.:-]+$`. Whitespace is the one a
    // careless native change actually produces (a trailing newline off a file
    // read), and it is a 422 rather than a trim island-side.
    test('drops a value outside the island charset', () async {
      expect(await resolve('has space'), isNull);
      expect(await resolve('trailing\n'), isNull);
      expect(await resolve('slash/es'), isNull);
    });
  });
}
