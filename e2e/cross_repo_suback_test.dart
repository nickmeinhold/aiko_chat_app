@Timeout(Duration(seconds: 90))
library;

/// Cross-repo suback-handshake integration test (task #34 — Change B capability gate).
///
/// This is the test that makes the two halves of the wire contract actually talk
/// to each other. Every other test in this repo runs the app's transport against
/// a *fake* server (transport_seam_test.dart) or the gateway against *fake* bus
/// input (gateway tests). Here the **real** [GatewayTransport] envelope codec
/// drives a **real** `aiko_chat_gateway` (booted as a uvicorn subprocess) over a
/// real WebSocket, through a real reconnect — promoting Change B (username +
/// timestamp on the wire) from "merged + per-repo verified" to capability-verified.
///
/// It deliberately exercises only the transport layer (NOT [ChatRepository] +
/// drift): the envelope codec is where the two repos agree or drift, and the
/// transport has no native-sqlite dependency, so this rung is cheap and real.
/// The fatter B4-state-machine-over-reconnect test is a separate follow-on.
///
/// ## What it asserts (the cross-repo invariants)
/// 1. **suback fence** round-trips: empty channel → `""`; after a persisted
///    message → that message's server ULID (gateway `latest_ulid` == client fence).
/// 2. **ack** correlates the optimistic `client_msg_id` to the server `msg_id`.
/// 3. **Change B**: the fanned-back `message` frame carries `sender.label`
///    (username/display_name) and a real `created_at` (server timestamp), parsed
///    by the real Dart codec.
/// 4. The handshake **survives a reconnect**: after disconnect+reconnect, a fresh
///    subscribe gets a suback whose fence reflects the persisted state.
///
/// ## Running it
/// This file lives in `e2e/` (NOT `test/`, NOT `integration_test/`): the default
/// `flutter test` only recurses `test/`, so the green CI floor never runs it, and
/// the non-`integration_test` dir name avoids the on-device driver dependency.
/// Run explicitly:
///   flutter test e2e/cross_repo_suback_test.dart
/// It needs a sibling `aiko_chat_gateway` checkout with an installed venv. Override
/// the defaults with env vars:
///   AIKO_GATEWAY_DIR     (default: ../aiko_chat_gateway relative to this repo)
///   AIKO_GATEWAY_PYTHON  (default: `AIKO_GATEWAY_DIR`/.venv/bin/python)
/// If the gateway can't be located/booted the test FAILS (it's a capability gate,
/// not an optional nicety) with a message naming what to set up.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart';
import 'package:aiko_chat_app/features/chat/data/transport/gateway_transport.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

void main() {
  late _Gateway gw;

  setUpAll(() async {
    gw = await _Gateway.boot();
  });

  tearDownAll(() async {
    await gw.shutdown();
  });

  test('real transport ↔ real gateway: connect → suback → send → ack → '
      'message(username+timestamp) → reconnect → suback', () async {
    // --- bootstrap via the gateway's public REST surface ---------------------
    // register seeds the WS-required user row AND returns an access token, so we
    // need no manual JWT minting and no DB poking.
    final reg = await gw.postJson('/v1/auth/register', {
      'username': 'alice',
      'display_name': 'Alice',
      'password': 'pw123456',
    });
    final accessToken = reg['access_token'] as String;
    final userId = (reg['user'] as Map)['user_id'] as String;
    expect(accessToken, isNotEmpty);

    final channels = await gw.getJson('/v1/channels');
    final channelId = (channels['channels'] as List)
        .map((c) => c as Map)
        .firstWhere((c) => c['aiko_channel'] == 'general')['id'] as String;

    // --- the real Dart transport against the real gateway --------------------
    final transport = GatewayTransport(
      wsBaseUrl: 'ws://127.0.0.1:${gw.port}',
      tokens: _StaticTokenProvider(accessToken),
    );
    addTearDown(transport.dispose);

    // Streams are broadcast and outlive reconnects; collect into buffers BEFORE
    // connecting so no event is missed.
    final messages = _Inbox<Message>(transport.messages);
    final acks = _Inbox<AckResult>(transport.acks);
    final conn = _Inbox<ConnectionState>(transport.connectionState);

    await transport.connect();
    await conn.firstWhere((s) => s == ConnectionState.connected,
        reason: 'transport never reached connected');

    // 1. subscribe → suback. Empty channel → empty-string fence.
    final fences = await transport.subscribe([channelId]);
    expect(fences, containsPair(channelId, ''),
        reason: 'empty channel must fence to "" (gateway latest_ulid of empty)');

    // 2. send → ack correlating client_msg_id → server msg_id.
    final clientMsgId = const Uuid().v4();
    final beforeSend = DateTime.now().toUtc();
    transport.sendMessage(OutgoingMessage(
      clientTempId: clientMsgId,
      channelId: channelId,
      body: 'hello from alice',
    ));

    final ack = await acks.firstWhere((a) => a.clientMsgId == clientMsgId,
        reason: 'no ack for our send');
    expect(ack.msgId, isNotEmpty);
    expect(ack.createdAt, isNotNull);

    // 3. Change B: the fanned-back message frame carries username + timestamp.
    // (Fanout includes the sender, so a single connection sees its own message.)
    final msg = await messages.firstWhere((m) => m.id == ack.msgId,
        reason: 'sent message was not fanned back to the subscriber');
    expect(msg.body, 'hello from alice');
    expect(msg.channelId, channelId);
    expect(msg.sender.kind, SenderKind.human);
    expect(msg.sender.userId, userId);
    expect(msg.sender.label, 'Alice',
        reason: 'Change B: username/display_name must ride the wire');
    expect(msg.createdAt.isAfter(DateTime.utc(2020)), isTrue,
        reason: 'Change B: a real server timestamp must ride the wire');
    // Server timestamp should be at/after the moment we sent (sanity, not exact).
    expect(msg.createdAt.isAfter(beforeSend.subtract(const Duration(minutes: 5))),
        isTrue);

    // 4. The handshake survives a reconnect: drop the socket, reconnect, and a
    // fresh subscribe must suback with the fence now advanced to the persisted
    // message (proving both sides agree on the boundary across a reconnect).
    await transport.disconnect();
    await conn.firstWhere((s) => s == ConnectionState.disconnected,
        reason: 'transport never reported disconnected');

    await transport.connect();
    await conn.firstWhere((s) => s == ConnectionState.connected,
        reason: 'transport never reconnected');

    final fences2 = await transport.subscribe([channelId]);
    expect(fences2, containsPair(channelId, ack.msgId),
        reason: 'after reconnect the suback fence must equal the persisted '
            'message id (gateway latest_ulid == client fence)');
  });
}

// --- helpers ----------------------------------------------------------------

/// A [TokenProvider] that always hands back one access token and never refreshes
/// (the test holds a fresh token for its whole short lifetime).
class _StaticTokenProvider implements TokenProvider {
  final String _token;
  _StaticTokenProvider(this._token);

  @override
  Future<String?> currentAccessToken() async => _token;

  @override
  Future<String?> refreshAccessToken() async => _token;
}

/// Buffers a broadcast stream so a `firstWhere` can match events that may have
/// already arrived, with a bounded wait for ones that haven't.
class _Inbox<T> {
  final List<T> _seen = [];
  final List<void Function()> _waiters = [];

  _Inbox(Stream<T> stream) {
    stream.listen((e) {
      _seen.add(e);
      for (final w in List.of(_waiters)) {
        w();
      }
    });
  }

  Future<T> firstWhere(bool Function(T) test,
      {String? reason, Duration timeout = const Duration(seconds: 15)}) async {
    final completer = Completer<T>();
    void check() {
      if (completer.isCompleted) return;
      for (final e in _seen) {
        if (test(e)) {
          completer.complete(e);
          return;
        }
      }
    }

    _waiters.add(check);
    check();
    return completer.future.timeout(timeout, onTimeout: () {
      throw TimeoutException(
          'Inbox.firstWhere timed out${reason == null ? '' : ': $reason'}. '
          'Seen: $_seen');
    });
  }
}

/// A uvicorn-hosted `aiko_chat_gateway` for the duration of the test: no MQTT
/// broker (the bus degrades to a no-op), a throwaway file-backed sqlite DB.
class _Gateway {
  final Process _proc;
  final int port;
  final File _dbFile;
  final HttpClient _http = HttpClient();

  _Gateway._(this._proc, this.port, this._dbFile);

  static Future<_Gateway> boot() async {
    final gatewayDir = _resolveGatewayDir();
    final python = _resolvePython(gatewayDir);

    // Free port: bind to 0, read the assigned port, release it for uvicorn.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final dbFile = File(
        '${Directory.systemTemp.path}/aiko_xrepo_${port}_${DateTime.now().microsecondsSinceEpoch}.db');

    final proc = await Process.start(
      python,
      [
        '-m', 'uvicorn', 'aiko_gateway.main:app',
        '--host', '127.0.0.1', '--port', '$port', '--log-level', 'warning',
      ],
      workingDirectory: gatewayDir,
      environment: {
        // Four slashes = absolute path → file-backed sqlite shared across the
        // app's many SessionLocal connections (`:memory:` is connection-private).
        'DB_URL': 'sqlite+aiosqlite:///${dbFile.path}',
        // Point the bus at a dead host so it fails fast and degrades to a no-op.
        'AIKO_MQTT_HOST': '127.0.0.1',
        'PYTHONUNBUFFERED': '1',
      },
    );

    // Tee the gateway log so a failure prints something actionable.
    final log = <String>[];
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(log.add);
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(log.add);

    final gw = _Gateway._(proc, port, dbFile);
    final ok = await gw._awaitHealth(const Duration(seconds: 30));
    if (!ok) {
      proc.kill(ProcessSignal.sigkill);
      throw StateError(
          'Gateway did not become healthy on :$port within 30s.\n'
          'python=$python\ngatewayDir=$gatewayDir\n'
          '--- gateway log ---\n${log.join('\n')}');
    }
    return gw;
  }

  Future<bool> _awaitHealth(Duration budget) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      try {
        await getJson('/health');
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    return false;
  }

  Future<Map<String, dynamic>> getJson(String path) async {
    final req = await _http.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw HttpException('GET $path -> ${resp.statusCode}: $body');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> postJson(
      String path, Map<String, dynamic> payload) async {
    final req = await _http.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(payload)));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw HttpException('POST $path -> ${resp.statusCode}: $body');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<void> shutdown() async {
    _http.close(force: true);
    _proc.kill(ProcessSignal.sigterm);
    try {
      await _proc.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _proc.kill(ProcessSignal.sigkill);
    }
    if (await _dbFile.exists()) {
      try {
        await _dbFile.delete();
      } catch (_) {/* best-effort temp cleanup */}
    }
  }

  static String _resolveGatewayDir() {
    final override = Platform.environment['AIKO_GATEWAY_DIR'];
    final dir = override != null
        ? Directory(override)
        // Default: sibling of this app repo. `flutter test` runs with cwd at the
        // app repo root.
        : Directory('${Directory.current.path}/../aiko_chat_gateway');
    final resolved = dir.absolute.path;
    if (!Directory('$resolved/src/aiko_gateway').existsSync()) {
      throw StateError(
          'aiko_chat_gateway not found at $resolved. Set AIKO_GATEWAY_DIR to '
          'point at a checkout (expected <dir>/src/aiko_gateway to exist).');
    }
    return resolved;
  }

  static String _resolvePython(String gatewayDir) {
    final override = Platform.environment['AIKO_GATEWAY_PYTHON'];
    final python = override ?? '$gatewayDir/.venv/bin/python';
    if (!File(python).existsSync()) {
      throw StateError(
          'Gateway python not found at $python. Create the venv '
          '(python -m venv .venv && .venv/bin/pip install -e ".[dev]") or set '
          'AIKO_GATEWAY_PYTHON.');
    }
    return python;
  }
}
