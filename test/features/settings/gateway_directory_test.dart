// Gateway/island directory (#36): the live-directory source that swaps the
// hardcoded seed list in the picker, now WITHOUT a single point of failure.
//
// What these pin:
//  - tolerant parsing — the wire casing isn't pinned (Python/SQLite gateway), so
//    snake_case AND camelCase resolve; a urlless/junk entry is skipped, not
//    crashed (the directory is attacker-influenceable);
//  - NO discovery SPOF — the provider discovers from the CURRENTLY-SELECTED
//    gateway (`<base>/v1/gateways`), not a fixed origin, and re-composes that URL
//    from whatever gateway is active;
//  - merge/dedup — directory wins over the known seed set on the same normalized
//    URL and comes first; seed-only entries (Local/emulator) survive;
//  - graceful fallback — a fetch error surfaces as AsyncError so the picker shows
//    the known set;
//  - the picker renders directory entries when the directory has them.
//
// The GROWING persisted seed set (discovered islands remembered across launches)
// is pinned separately in gateway_seed_store_test.dart.

import 'dart:convert';
import 'dart:typed_data';

import 'package:aiko_chat_app/app/config.dart';
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/settings/application/gateway_directory_provider.dart';
import 'package:aiko_chat_app/features/settings/data/gateway_directory_client.dart';
import 'package:aiko_chat_app/features/settings/data/gateway_seed_store.dart';
import 'package:aiko_chat_app/features/settings/domain/server_entry.dart';
import 'package:aiko_chat_app/features/settings/presentation/gateway_picker_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _norm(String url) => GatewayConfig.normalized(url).httpBaseUrl;

void main() {
  group('ServerEntry.tryFromJson (tolerant)', () {
    test('snake_case contract maps to label + url + metadata', () {
      final e = ServerEntry.tryFromJson({
        'id': 'imagineering',
        'display_name': 'Imagineering',
        'base_url': 'https://chat.imagineering.cc',
        'description': 'flagship island',
        'region': 'au',
      })!;
      expect(e.label, 'Imagineering');
      expect(e.httpBaseUrl, 'https://chat.imagineering.cc');
      expect(e.id, 'imagineering');
      expect(e.description, 'flagship island');
      expect(e.region, 'au');
    });

    test('camelCase spellings also resolve', () {
      final e = ServerEntry.tryFromJson({
        'name': 'Enspyr',
        'baseUrl': 'https://enspyr.co',
      })!;
      expect(e.label, 'Enspyr');
      expect(e.httpBaseUrl, 'https://enspyr.co');
    });

    test('a missing name falls back to the host', () {
      final e = ServerEntry.tryFromJson({'base_url': 'https://enspyr.co'})!;
      expect(e.label, 'enspyr.co');
    });

    test('an entry with no usable URL is skipped (null)', () {
      expect(ServerEntry.tryFromJson({'name': 'no url here'}), isNull);
      expect(ServerEntry.tryFromJson({'base_url': '   '}), isNull);
    });

    test('a non-http(s) or malformed URL is skipped (same bar as custom field)',
        () {
      // The directory is attacker-influenceable; a directory tile bypasses the
      // picker's custom-URL validation, so junk must be rejected at parse time.
      expect(ServerEntry.tryFromJson({'base_url': 'garbage'}), isNull);
      expect(ServerEntry.tryFromJson({'base_url': 'ftp://example.com'}), isNull);
      expect(ServerEntry.tryFromJson({'base_url': 'https://'}), isNull);
      expect(
          ServerEntry.tryFromJson({'base_url': 'javascript:alert(1)'}), isNull);
    });
  });

  group('GatewayDirectoryClient.fetchFrom', () {
    test('parses a bare JSON array, skipping malformed entries', () async {
      final dio = Dio()
        ..httpClientAdapter = _CannedAdapter(jsonEncode([
          {'name': 'Imagineering', 'base_url': 'https://chat.imagineering.cc'},
          {'name': 'broken — no url'},
          {'name': 'Enspyr', 'base_url': 'https://enspyr.co'},
        ]));
      final client = GatewayDirectoryClient(dio: dio);
      final out = await client.fetchFrom('https://dir.example/v1/gateways');
      expect(out.map((e) => e.httpBaseUrl),
          ['https://chat.imagineering.cc', 'https://enspyr.co']);
    });

    test('parses an envelope object under a conventional key', () async {
      final dio = Dio()
        ..httpClientAdapter = _CannedAdapter(jsonEncode({
          'gateways': [
            {'name': 'Enspyr', 'base_url': 'https://enspyr.co'}
          ]
        }));
      final client = GatewayDirectoryClient(dio: dio);
      final out = await client.fetchFrom('https://dir.example/v1/gateways');
      expect(out.single.httpBaseUrl, 'https://enspyr.co');
    });

    // Forward-compat (Design 10): when an island renames `/v1/gateways`'s payload
    // to the canonical `islands` key, the app already reads it — a pure widening.
    test('parses an envelope under the canonical `islands` key', () async {
      final dio = Dio()
        ..httpClientAdapter = _CannedAdapter(jsonEncode({
          'islands': [
            {'name': 'Enspyr', 'base_url': 'https://enspyr.co'}
          ]
        }));
      final client = GatewayDirectoryClient(dio: dio);
      final out = await client.fetchFrom('https://dir.example/v1/gateways');
      expect(out.single.httpBaseUrl, 'https://enspyr.co');
    });

    // Guard-contract, not just outcome: `islands` is tried BEFORE `gateways`, so
    // during a compat window that double-serves both, the canonical key wins.
    test('`islands` wins over `gateways` when both keys are present', () async {
      final dio = Dio()
        ..httpClientAdapter = _CannedAdapter(jsonEncode({
          'islands': [
            {'name': 'New', 'base_url': 'https://new.example'}
          ],
          'gateways': [
            {'name': 'Legacy', 'base_url': 'https://legacy.example'}
          ],
        }));
      final client = GatewayDirectoryClient(dio: dio);
      final out = await client.fetchFrom('https://dir.example/v1/gateways');
      expect(out.single.httpBaseUrl, 'https://new.example');
    });

    // Empty-shadow guard (Tesla): an empty `islands` must NOT blank the directory
    // when a populated `gateways` is present — priority yields to usability, so we
    // fall through to the legacy rail rather than silently show zero islands.
    test('an empty `islands` does not shadow a populated `gateways`', () async {
      final dio = Dio()
        ..httpClientAdapter = _CannedAdapter(jsonEncode({
          'islands': <dynamic>[],
          'gateways': [
            {'name': 'Legacy', 'base_url': 'https://legacy.example'}
          ],
        }));
      final client = GatewayDirectoryClient(dio: dio);
      final out = await client.fetchFrom('https://dir.example/v1/gateways');
      expect(out.single.httpBaseUrl, 'https://legacy.example');
    });

    // Invalid-shadow guard (Tesla, second harmonic): a non-empty `islands` whose
    // every entry is malformed is ALSO unusable — it must not shadow a valid
    // `gateways` either. Dissolves the whole shadow class, not just the empty case.
    test('an all-malformed `islands` does not shadow a valid `gateways`',
        () async {
      final dio = Dio()
        ..httpClientAdapter = _CannedAdapter(jsonEncode({
          'islands': [
            {'name': 'Bad', 'base_url': 'javascript:alert(1)'}, // fails validator
            {'name': 'AlsoBad'}, // no url at all
          ],
          'gateways': [
            {'name': 'Legacy', 'base_url': 'https://legacy.example'}
          ],
        }));
      final client = GatewayDirectoryClient(dio: dio);
      final out = await client.fetchFrom('https://dir.example/v1/gateways');
      expect(out.single.httpBaseUrl, 'https://legacy.example');
    });

    // Both empty is a genuinely empty directory, not a crash and not a fallthrough
    // to something else — the "recognised but empty" result.
    test('both keys empty yields [] (genuinely empty directory)', () async {
      final dio = Dio()
        ..httpClientAdapter = _CannedAdapter(jsonEncode({
          'islands': <dynamic>[],
          'gateways': <dynamic>[],
        }));
      final client = GatewayDirectoryClient(dio: dio);
      expect(await client.fetchFrom('https://dir.example/v1/gateways'), isEmpty);
    });

    test('an unrecognised shape yields [] (not a crash)', () async {
      final dio = Dio()..httpClientAdapter = _CannedAdapter(jsonEncode(42));
      final client = GatewayDirectoryClient(dio: dio);
      expect(await client.fetchFrom('https://dir.example/v1/gateways'), isEmpty);
    });

    test('a network error propagates (caller falls back to seed)', () async {
      final dio = Dio()..httpClientAdapter = _ExplodingAdapter();
      final client = GatewayDirectoryClient(dio: dio);
      expect(client.fetchFrom('https://dir.example/v1/gateways'),
          throwsA(isA<DioException>()));
    });
  });

  group('mergeDirectory', () {
    test('directory wins + comes first; seed-only entries survive; deduped', () {
      const directory = [
        // Same gateway as the seed Production, but with a trailing slash —
        // normalization must dedupe it against the preset.
        ServerEntry(
            label: 'Imagineering',
            httpBaseUrl: 'https://chat.imagineering.cc/'),
        ServerEntry(label: 'Enspyr', httpBaseUrl: 'https://enspyr.co'),
      ];
      final merged = mergeDirectory(directory, kGatewayPresets, normalize: _norm);

      final urls = merged.map((e) => _norm(e.httpBaseUrl)).toList();
      // Directory entries first (and the directory's label wins for the dupe).
      expect(merged.first.label, 'Imagineering');
      expect(urls.sublist(0, 2),
          [_norm('https://chat.imagineering.cc'), _norm('https://enspyr.co')]);
      // Production appears exactly once (deduped against the directory).
      expect(
          urls.where((u) => u == _norm('https://chat.imagineering.cc')).length,
          1);
      // Dev-only seed entries the directory never mentions survive.
      expect(urls, contains(_norm('http://localhost:8095')));
      expect(urls, contains(_norm('http://10.0.2.2:8095')));
    });

    test('an empty directory returns the seed unchanged (the fallback)', () {
      expect(mergeDirectory(const [], kGatewayPresets, normalize: _norm),
          kGatewayPresets);
    });
  });

  group('gatewayDirectoryProvider', () {
    Future<ProviderContainer> makeContainer(
      _FakeClient client, {
      String gatewayBaseUrl = 'https://chat.imagineering.cc',
    }) async {
      SharedPreferences.setMockInitialValues(
          {gatewayBaseUrlPrefKey: gatewayBaseUrl});
      final prefs = await SharedPreferences.getInstance();
      return ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          gatewayDirectoryClientProvider.overrideWithValue(client),
        ],
      );
    }

    test('discovers from the CURRENT gateway (composes <base>/v1/gateways)',
        () async {
      final client = _FakeClient(const [
        ServerEntry(label: 'Enspyr', httpBaseUrl: 'https://enspyr.co'),
      ]);
      final container =
          await makeContainer(client, gatewayBaseUrl: 'https://chat.enspyr.co/');
      addTearDown(container.dispose);

      final out = await container.read(gatewayDirectoryProvider.future);
      expect(out.single.label, 'Enspyr');
      // The SPOF-removal invariant: the URL is derived from the SELECTED gateway
      // (normalized, trailing slash stripped), NOT a fixed origin.
      expect(client.lastUrl, 'https://chat.enspyr.co/v1/gateways');
    });

    test('re-composes the URL against a different active gateway', () async {
      final client = _FakeClient(const []);
      final container = await makeContainer(client,
          gatewayBaseUrl: 'https://chat.imagineering.cc');
      addTearDown(container.dispose);

      await container.read(gatewayDirectoryProvider.future);
      expect(client.lastUrl, 'https://chat.imagineering.cc/v1/gateways');
    });

    test('surfaces an AsyncError on a client failure', () async {
      final container = await makeContainer(_FakeClient.throwing());
      addTearDown(container.dispose);
      await expectLater(
          container.read(gatewayDirectoryProvider.future), throwsException);
    });

    test('a persisted island seeds the known set on COLD load (no discovery) — '
        'survives a down bootstrap gateway', () async {
      // Previous session persisted an island; THIS session the gateway is down,
      // so discovery never fires. The persisted island must STILL be reachable
      // from disk — otherwise persistence is useless in the exact SPOF case.
      SharedPreferences.setMockInitialValues({
        gatewayBaseUrlPrefKey: 'https://chat.imagineering.cc',
        kKnownGatewaysPrefKey: jsonEncode([
          {'base_url': 'https://chat.seen-before.example', 'display_name': 'Seen Before'},
        ]),
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ]);
      addTearDown(container.dispose);

      // Read the known set directly — NO gatewayDirectoryProvider touched.
      expect(
          container
              .read(knownGatewaysProvider)
              .map((e) => _norm(e.httpBaseUrl)),
          contains(_norm('https://chat.seen-before.example')));
    });

    test('a freshly-discovered island is remembered into the known set + '
        'persisted (the DHT grow loop)', () async {
      // A brand-new island the app has never seen and that isn't a bundled seed.
      final client = _FakeClient(const [
        ServerEntry(
            label: 'New Island', httpBaseUrl: 'https://chat.newisland.example'),
      ]);
      final container = await makeContainer(client);
      addTearDown(container.dispose);
      // Materialize the known set BEFORE discovery so the notifier is alive to
      // receive the remember() (a NotifierProvider is lazy).
      expect(
          container
              .read(knownGatewaysProvider)
              .map((e) => _norm(e.httpBaseUrl)),
          isNot(contains(_norm('https://chat.newisland.example'))));

      await container.read(gatewayDirectoryProvider.future);
      await pumpEventQueue(); // let the fire-and-forget remember() settle

      // GROW: the known set (what the picker seeds from) now includes it.
      expect(
          container
              .read(knownGatewaysProvider)
              .map((e) => _norm(e.httpBaseUrl)),
          contains(_norm('https://chat.newisland.example')));
      // PERSIST: a fresh store over the same prefs sees it → survives a restart.
      expect(
          container.read(gatewaySeedStoreProvider).load().map(
                (e) => _norm(e.httpBaseUrl),
              ),
          contains(_norm('https://chat.newisland.example')));
    });
  });

  group('GatewayPickerScreen directory rendering', () {
    Future<ProviderContainer> pump(
      WidgetTester tester,
      Future<List<ServerEntry>> Function() directoryFetch,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        // retry disabled so an error-override doesn't leak a backoff timer.
        retry: (_, _) => null,
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          gatewayDirectoryProvider.overrideWith((ref) => directoryFetch()),
        ],
      );
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: GatewayPickerScreen()),
      ));
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('renders live directory entries merged over the seed',
        (tester) async {
      final container = await pump(
        tester,
        () async => const [
          ServerEntry(label: 'Enspyr Island', httpBaseUrl: 'https://enspyr.co'),
        ],
      );
      addTearDown(container.dispose);

      expect(find.text('Enspyr Island'), findsOneWidget); // from the directory
      expect(find.text('Production'), findsOneWidget); // seed survives
      expect(find.text('Local'), findsOneWidget); // dev seed survives
    });

    testWidgets('falls back to the known seed set on a directory error',
        (tester) async {
      final container = await pump(
        tester,
        () async => throw Exception('directory down'),
      );
      addTearDown(container.dispose);

      // No directory tile, but every bundled seed still renders — never blocked.
      expect(find.text('Production'), findsOneWidget);
      expect(find.text('Enspyr'), findsOneWidget); // second real seed
      expect(find.text('Local'), findsOneWidget);
      expect(find.text('Android emulator'), findsOneWidget);
    });
  });
}

/// A Dio adapter returning a canned JSON body — lets us exercise the parse path
/// without a real network.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this._body);
  final String _body;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString(_body, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// A Dio adapter that throws if hit — drives the network-error path.
class _ExplodingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    throw DioException(requestOptions: options, error: 'boom');
  }

  @override
  void close({bool force = false}) {}
}

/// A directory client with canned output — for provider-level tests. Records the
/// URL it was asked to fetch so the URL-composition invariant can be asserted.
class _FakeClient implements GatewayDirectoryClient {
  _FakeClient(this._entries) : _throws = false;
  _FakeClient.throwing()
      : _entries = const [],
        _throws = true;
  final List<ServerEntry> _entries;
  final bool _throws;
  String? lastUrl;

  @override
  Future<List<ServerEntry>> fetchFrom(String directoryUrl) async {
    lastUrl = directoryUrl;
    if (_throws) throw Exception('directory down');
    return _entries;
  }
}
