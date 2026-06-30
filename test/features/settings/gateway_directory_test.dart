// Gateway/island directory (#36): the live-directory source that swaps the
// hardcoded seed list in the picker.
//
// What these pin:
//  - tolerant parsing — the wire casing isn't pinned (Python/SQLite gateway), so
//    snake_case AND camelCase resolve; a urlless entry is skipped, not crashed;
//  - the unset-URL short-circuit — no endpoint published yet ⇒ [] with NO
//    network (the current launch state: seed-only);
//  - merge/dedup — directory wins over seed on the same normalized URL and comes
//    first; seed-only entries (Local/emulator) survive;
//  - graceful fallback — a fetch error surfaces as AsyncError so the picker shows
//    the seed presets;
//  - the picker renders directory entries when the directory has them.

import 'dart:convert';
import 'dart:typed_data';

import 'package:aiko_chat_app/app/config.dart';
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/features/settings/application/gateway_directory_provider.dart';
import 'package:aiko_chat_app/features/settings/data/gateway_directory_client.dart';
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

  group('GatewayDirectoryClient.fetch', () {
    test('an unset URL short-circuits to [] with NO network', () async {
      // A Dio whose adapter would EXPLODE if touched — proves no request fires.
      final dio = Dio()..httpClientAdapter = _ExplodingAdapter();
      final client = GatewayDirectoryClient(dio: dio, url: '');
      expect(await client.fetch(), isEmpty);
    });

    test('parses a bare JSON array, skipping malformed entries', () async {
      final dio = Dio()
        ..httpClientAdapter = _CannedAdapter(jsonEncode([
          {'name': 'Imagineering', 'base_url': 'https://chat.imagineering.cc'},
          {'name': 'broken — no url'},
          {'name': 'Enspyr', 'base_url': 'https://enspyr.co'},
        ]));
      final client =
          GatewayDirectoryClient(dio: dio, url: 'https://dir.example/list');
      final out = await client.fetch();
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
      final client =
          GatewayDirectoryClient(dio: dio, url: 'https://dir.example/list');
      final out = await client.fetch();
      expect(out.single.httpBaseUrl, 'https://enspyr.co');
    });

    test('an unrecognised shape yields [] (not a crash)', () async {
      final dio = Dio()..httpClientAdapter = _CannedAdapter(jsonEncode(42));
      final client =
          GatewayDirectoryClient(dio: dio, url: 'https://dir.example/list');
      expect(await client.fetch(), isEmpty);
    });

    test('a network error propagates (caller falls back to seed)', () async {
      final dio = Dio()..httpClientAdapter = _ExplodingAdapter();
      final client =
          GatewayDirectoryClient(dio: dio, url: 'https://dir.example/list');
      expect(client.fetch(), throwsA(isA<DioException>()));
    });
  });

  group('mergeDirectory', () {
    test('directory wins + comes first; seed-only entries survive; deduped', () {
      const directory = [
        // Same gateway as the seed Production, but with a trailing slash —
        // normalization must dedupe it against the preset.
        ServerEntry(label: 'Imagineering', httpBaseUrl: 'https://chat.imagineering.cc/'),
        ServerEntry(label: 'Enspyr', httpBaseUrl: 'https://enspyr.co'),
      ];
      final merged = mergeDirectory(directory, kGatewayPresets, normalize: _norm);

      final urls = merged.map((e) => _norm(e.httpBaseUrl)).toList();
      // Directory entries first (and the directory's label wins for the dupe).
      expect(merged.first.label, 'Imagineering');
      expect(urls.sublist(0, 2),
          [_norm('https://chat.imagineering.cc'), _norm('https://enspyr.co')]);
      // Production appears exactly once (deduped against the directory).
      expect(urls.where((u) => u == _norm('https://chat.imagineering.cc')).length, 1);
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
    test('returns the client entries', () async {
      final container = ProviderContainer(overrides: [
        gatewayDirectoryClientProvider
            .overrideWithValue(_FakeClient(const [
          ServerEntry(label: 'Enspyr', httpBaseUrl: 'https://enspyr.co'),
        ])),
      ]);
      addTearDown(container.dispose);
      final out = await container.read(gatewayDirectoryProvider.future);
      expect(out.single.label, 'Enspyr');
    });

    test('surfaces an AsyncError on a client failure', () async {
      // retry disabled: Riverpod 3 otherwise re-runs a failed provider on a
      // backoff timer, so `.future` would never settle to the error here.
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          gatewayDirectoryClientProvider
              .overrideWithValue(_FakeClient.throwing()),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
          container.read(gatewayDirectoryProvider.future), throwsException);
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

    testWidgets('falls back to the seed presets on a directory error',
        (tester) async {
      final container = await pump(
        tester,
        () async => throw Exception('directory down'),
      );
      addTearDown(container.dispose);

      // No directory tile, but every seed preset still renders — never blocked.
      expect(find.text('Production'), findsOneWidget);
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

/// A Dio adapter that throws if hit — proves the unset-URL path fires no request,
/// and drives the network-error path.
class _ExplodingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    throw DioException(requestOptions: options, error: 'boom');
  }

  @override
  void close({bool force = false}) {}
}

/// A directory client with canned output — for provider-level tests.
class _FakeClient implements GatewayDirectoryClient {
  _FakeClient(this._entries) : _throws = false;
  _FakeClient.throwing()
      : _entries = const [],
        _throws = true;
  final List<ServerEntry> _entries;
  final bool _throws;

  @override
  Future<List<ServerEntry>> fetch() async {
    if (_throws) throw Exception('directory down');
    return _entries;
  }
}
