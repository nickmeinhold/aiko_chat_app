// Fixtures for `install_id_test.dart`.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aiko_chat_app/features/chat/data/gateway_rest_api.dart';
import 'package:aiko_chat_app/features/notifications/domain/apns_environment.dart';
import 'package:aiko_chat_app/features/notifications/domain/device_platform.dart';
import 'package:aiko_chat_app/features/notifications/domain/push_token_source.dart';
import 'package:aiko_chat_app/features/notifications/domain/token_kind.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../support/fakes.dart';

/// A method channel that answers one fixed value and COUNTS the asks.
///
/// The count is the instrument, not decoration: a cached and an uncached source
/// return the same string, so only the number of native calls can tell them
/// apart — and the caching is a correctness property here, not a speed one.
///
/// **IT SUSPENDS, AND THAT IS LOAD-BEARING.** An earlier version returned from
/// an `async` body with no real await, so it resolved in the calling microtask —
/// something no platform channel does. That made every test using it blind to
/// interleaving, and it hid a live defect: the source memoised a VALUE behind an
/// "asked" flag set before the await, so a second caller arriving mid-flight got
/// null. Production calls it exactly that way (both registrars, `unawaited`, at
/// one sign-in edge), so the shipped feature would have silently done nothing
/// while a green test asserted the opposite.
///
/// The fix is the FIXTURE, not that one test: a fake that cannot suspend cannot
/// fail for any async reason, so it would have hidden the next one too.
class FixedChannel extends MethodChannel {
  FixedChannel(this.value) : super('test/install');
  final String value;
  int calls = 0;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    calls++;
    await Future<void>.delayed(Duration.zero);
    return value as T;
  }
}

FixedChannel fixedChannel(String value) => FixedChannel(value);

/// The native half absent from this build — a desktop target, or a `.swift`
/// outside the Runner target.
MethodChannel throwingChannel() => _ThrowingChannel();

class _ThrowingChannel extends MethodChannel {
  _ThrowingChannel() : super('test/install');

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    throw MissingPluginException('no install channel in this build');
  }
}

/// A token source pinned to one kind and one token — this file tests the id,
/// not the token lifecycle, which `device_registrar_test.dart` already owns.
class FixedTokenSource implements PushTokenSource {
  FixedTokenSource({required this.kind, required this.token});

  @override
  final TokenKind kind;
  final String token;

  @override
  DevicePlatform get platform => DevicePlatform.apns;

  @override
  Future<ApnsEnvironment?> apnsEnvironment() async => ApnsEnvironment.sandbox;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<String?> currentToken() async => token;

  @override
  Stream<String> tokenRefreshes() => const Stream.empty();
}

/// Captures each request body, so a test can assert on the JSON that actually
/// goes out rather than on the Dart call that produced it. The distinction is
/// the whole point of the omit-vs-null pair: both are `null` in Dart and only
/// one of them is a 422.
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.bodies);
  final List<Map<String, dynamic>> bodies;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final chunks = await requestStream!.toList();
    bodies.add(
      jsonDecode(utf8.decode(chunks.expand((c) => c).toList()))
          as Map<String, dynamic>,
    );
    return jsonBody(
      201,
      jsonEncode({
        'id': 'dev-1',
        'platform': 'apns',
        'apns_environment': 'sandbox',
        'token_kind': 'alert',
      }),
    );
  }

  @override
  void close({bool force = false}) {}
}

(GatewayRestApi, List<Map<String, dynamic>>) capturingIsland() {
  final bodies = <Map<String, dynamic>>[];
  final dio = Dio(BaseOptions(baseUrl: 'http://x'))
    ..httpClientAdapter = _CapturingAdapter(bodies);
  return (GatewayRestApi(bare: dio, authed: dio), bodies);
}
