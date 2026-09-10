import 'dart:convert';

import 'package:aiko_chat_app/features/notifications/data/pending_unregister_store.dart';
import 'package:aiko_chat_app/features/notifications/domain/token_kind.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The unregister debt ledger, keyed by KIND (design 16 v2 §5).
///
/// Every test here is a way the ledger can lie quietly. It has no failure that
/// announces itself: a lost debt is an island row nothing will ever clear, and
/// under CallKit a lost VOIP debt is a stranger's handset ringing full-screen
/// for the previous owner.
const _key = 'aiko_pending_device_unregisters';
const _island = 'https://chat.example.cc';
const _other = 'https://other.example.cc';

Future<PendingUnregisterStore> _store(Map<String, Object> seed) async {
  SharedPreferences.setMockInitialValues(seed);
  final store = PendingUnregisterStore(await SharedPreferences.getInstance());
  return store;
}

void main() {
  group('migration — the sharp edge', () {
    test('A LEGACY KINDLESS LIST READS AS THE ALERT LIST', () async {
      // The whole change turns on this. `read` promises that a corrupt value
      // reads as "nothing owed", so a format change that made live ledgers
      // unreadable would SILENTLY DISCHARGE EVERY OUTSTANDING DEBT — the one
      // failure this class exists to prevent, caused by the migration meant to
      // strengthen it.
      final store = await _store({
        _key: jsonEncode({
          _island: ['legacy-a', 'legacy-b'],
        }),
      });
      expect(store.read(_island, TokenKind.alert), ['legacy-a', 'legacy-b']);
    });

    test('a legacy entry is NOT read as a voip debt', () async {
      // Alert by construction, not by convenience: no build has ever minted a
      // VoIP token, so a kindless entry can only ever have held alert tokens.
      // Reading it as voip would invent an obligation nobody owes.
      final store = await _store({
        _key: jsonEncode({
          _island: ['legacy-a'],
        }),
      });
      expect(store.read(_island, TokenKind.voip), isEmpty);
    });

    test('ONE unreadable island drops ONE island, not the ledger', () async {
      // The old decoder wrapped the whole map in a single catch, so a single
      // bad entry emptied everything. Per-entry tolerance is the difference
      // between losing one debt and losing all of them.
      final store = await _store({
        _key: jsonEncode({
          _island: 42, // neither a List nor a Map
          _other: {
            'voip': ['good'],
          },
        }),
      });
      expect(store.read(_island, TokenKind.alert), isEmpty);
      expect(store.read(_other, TokenKind.voip), [
        'good',
      ], reason: 'a sibling island survives its neighbour being corrupt');
    });

    test(
      'a wholly corrupt blob still reads as nothing owed, not a throw',
      () async {
        final store = await _store({_key: 'not json at all'});
        expect(store.read(_island, TokenKind.alert), isEmpty);
      },
    );

    test('a round trip through the new format preserves both kinds', () async {
      final store = await _store({});
      await store.remember(_island, TokenKind.alert, 'a1');
      await store.remember(_island, TokenKind.voip, 'v1');
      final reopened = PendingUnregisterStore(
        await SharedPreferences.getInstance(),
      );
      expect(reopened.read(_island, TokenKind.alert), ['a1']);
      expect(reopened.read(_island, TokenKind.voip), ['v1']);
    });
  });

  group('the kinds do not contaminate each other', () {
    test('THE BUG THIS EXISTS FOR: a drain cannot see the other kind', () async {
      // Concretely, the interleaving that would otherwise happen at sign-in:
      //   VOIP  remembers its token write-ahead, POST in flight
      //   ALERT drains, reads the ledger, finds the VOIP token, and DELETEs
      //         the row the concurrent POST just created
      // Net: the app believes voip is paired, the island has no voip row, and
      // the handset never rings. DeviceRegistrar's own proof ("a drain must
      // never be a session-start's last write") is sound and scoped to ONE
      // registrar — a second token moved the work outside the scope it covers.
      final store = await _store({});
      await store.remember(_island, TokenKind.voip, 'voip-tok');
      expect(
        store.read(_island, TokenKind.alert),
        isEmpty,
        reason: 'an alert drain must not be handed a voip obligation',
      );
    });

    test('forgetting one kind leaves the other owed', () async {
      final store = await _store({});
      await store.remember(_island, TokenKind.alert, 'a1');
      await store.remember(_island, TokenKind.voip, 'v1');
      await store.forget(_island, TokenKind.alert, 'a1');
      expect(store.read(_island, TokenKind.alert), isEmpty);
      expect(store.read(_island, TokenKind.voip), ['v1']);
    });

    test('the island entry survives until BOTH kinds are clear', () async {
      final store = await _store({});
      await store.remember(_island, TokenKind.alert, 'a1');
      await store.remember(_island, TokenKind.voip, 'v1');
      await store.forget(_island, TokenKind.alert, 'a1');
      final reopened = PendingUnregisterStore(
        await SharedPreferences.getInstance(),
      );
      expect(reopened.read(_island, TokenKind.voip), [
        'v1',
      ], reason: 'clearing one kind must not drop the island wholesale');
    });
  });

  group('the cap is per KIND, not per island', () {
    test('ALERT CHURN CANNOT EVICT THE VOIP DEBT', () async {
      // Eviction is oldest-first, so with one shared list a burst of alert
      // rotations would silently drop the voip obligation. The two are not
      // equally valuable: a dropped alert debt is a stray banner, a dropped
      // voip debt is a stranger's phone ringing full-screen.
      final store = await _store({});
      await store.remember(_island, TokenKind.voip, 'voip-precious');
      for (var i = 0; i < 40; i++) {
        await store.remember(_island, TokenKind.alert, 'alert-$i');
      }
      expect(store.read(_island, TokenKind.voip), ['voip-precious']);
      expect(
        store.read(_island, TokenKind.alert).length,
        16,
        reason: 'the alert list is still capped at 16 on its own',
      );
    });
  });
}
