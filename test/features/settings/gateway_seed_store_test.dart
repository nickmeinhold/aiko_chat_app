// The "islands I've met" seed store (#36) — the DHT-style GROWING half of
// resilient discovery.
//
// What these pin:
//  - GROW: a discovered island is persisted and comes back on the next load, so
//    it becomes a future bootstrap contact (reachable set = presets ∪ ever-seen);
//  - UNION + dedup: remember() accumulates across calls and dedups on the
//    normalized base URL (a trailing-slash variant is the SAME island);
//  - SECURITY (the load-bearing one): load() re-validates every stored entry
//    through ServerEntry.tryFromJson, so a TAMPERED prefs blob (a file:// URL, a
//    hostless URL, a non-http scheme, junk) is dropped on read — never surfaced
//    as a tile that would bypass the picker's URL validation into switchGateway;
//  - robustness: a malformed/mis-typed blob yields [] rather than crashing.

import 'dart:convert';

import 'package:aiko_chat_app/app/config.dart';
import 'package:aiko_chat_app/features/settings/data/gateway_seed_store.dart';
import 'package:aiko_chat_app/features/settings/domain/server_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _norm(String url) => GatewayConfig.normalized(url).httpBaseUrl;

Future<GatewaySeedStore> storeWith(Map<String, Object> initial) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  return GatewaySeedStore(prefs: prefs, normalize: _norm);
}

void main() {
  test('an empty store loads to []', () async {
    final store = await storeWith({});
    expect(store.load(), isEmpty);
  });

  test('a discovered island is persisted and reloaded (the GROW property)',
      () async {
    final store = await storeWith({});
    await store.remember(const [
      ServerEntry(
          label: 'Enspyr', httpBaseUrl: 'https://chat.enspyr.co', id: 'enspyr'),
    ]);

    final loaded = store.load();
    expect(loaded.single.httpBaseUrl, 'https://chat.enspyr.co');
    expect(loaded.single.label, 'Enspyr');
    expect(loaded.single.id, 'enspyr', reason: 'metadata round-trips');
  });

  test('remember unions across calls and dedups on the normalized URL',
      () async {
    final store = await storeWith({});
    await store.remember(const [
      ServerEntry(label: 'Enspyr', httpBaseUrl: 'https://chat.enspyr.co'),
    ]);
    // Second call: one NEW island + a re-advertisement of Enspyr with a trailing
    // slash (same island) and a different label. The existing entry must win and
    // the set must not double up.
    final merged = await store.remember(const [
      ServerEntry(label: 'Enspyr RENAMED', httpBaseUrl: 'https://chat.enspyr.co/'),
      ServerEntry(label: 'Imagineering', httpBaseUrl: 'https://chat.imagineering.cc'),
    ]);

    final urls = merged.map((e) => _norm(e.httpBaseUrl)).toList();
    expect(urls, [
      _norm('https://chat.enspyr.co'),
      _norm('https://chat.imagineering.cc'),
    ]);
    expect(merged.first.label, 'Enspyr',
        reason: 'first-seen entry wins over a re-advertisement');
    // And it survives a reload.
    expect(store.load().map((e) => _norm(e.httpBaseUrl)), urls);
  });

  group('SECURITY: load() re-validates a tampered blob', () {
    test('a hostile stored entry is dropped, valid siblings survive', () async {
      // Simulate a prefs blob an attacker (or a corrupted write) planted: a mix
      // of a good island and several that must NEVER become a tappable tile —
      // each would otherwise bypass the picker's custom-URL validation straight
      // into switchGateway.
      final tampered = jsonEncode([
        {'base_url': 'https://chat.enspyr.co', 'display_name': 'Enspyr'}, // good
        {'base_url': 'file:///etc/passwd', 'display_name': 'pwn'}, // non-http
        {'base_url': 'javascript:alert(1)', 'display_name': 'xss'}, // scheme
        {'base_url': 'https://', 'display_name': 'no host'}, // hostless
        {'base_url': 'garbage', 'display_name': 'junk'}, // unparseable
        {'display_name': 'no url at all'}, // no url
      ]);
      final store = await storeWith({kKnownGatewaysPrefKey: tampered});

      final loaded = store.load();
      expect(loaded.map((e) => e.httpBaseUrl), ['https://chat.enspyr.co'],
          reason: 'only the http(s)+host entry survives re-validation');
    });

    test('a non-JSON / mis-typed blob yields [] (no crash)', () async {
      expect((await storeWith({kKnownGatewaysPrefKey: 'not json {['}))
          .load(), isEmpty);
      // A JSON value that isn't a list of objects is also just "nothing".
      expect((await storeWith({kKnownGatewaysPrefKey: jsonEncode(42)}))
          .load(), isEmpty);
      expect((await storeWith({kKnownGatewaysPrefKey: jsonEncode({'x': 1})}))
          .load(), isEmpty);
    });
  });
}
