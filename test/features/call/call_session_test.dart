import 'dart:async';

import 'package:aiko_chat_app/features/call/data/call_session.dart';
import 'package:aiko_chat_app/features/call/data/livekit_call_service.dart';
import 'package:aiko_chat_app/features/call/domain/call_connection_state.dart';
import 'package:aiko_chat_app/features/call/domain/video_token.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [ChatRestApi] that only answers [requestVideoToken] — CallSession touches
/// nothing else. `noSuchMethod` covers the (unused) rest of the surface.
class _FakeApi implements ChatRestApi {
  _FakeApi({this.token, this.error});
  final VideoToken? token;
  Object? error; // mutable so a test can flip it mid-session (e.g. token expiry).
  int calls = 0;

  @override
  Future<VideoToken> requestVideoToken(String channelId) async {
    calls++;
    if (error != null) throw error!;
    return token!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [LiveKitCallService] with a scripted connect and a manual connection-lost
/// trigger — no real Room/WebRTC. Each [connect] returns the next scripted
/// result (last one repeats).
class _FakeService extends LiveKitCallService {
  _FakeService(this.scripted);
  final List<ConnectionResult> scripted;
  int connectCalls = 0;
  int enableMediaCalls = 0;
  final _lost = StreamController<String?>.broadcast();

  @override
  Stream<String?> get connectionLost => _lost.stream;

  @override
  Future<ConnectionResult> connect(VideoToken token) async {
    final i = connectCalls < scripted.length ? connectCalls : scripted.length - 1;
    connectCalls++;
    return scripted[i];
  }

  @override
  Future<void> enableMedia() async => enableMediaCalls++;

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    if (!_lost.isClosed) await _lost.close();
  }

  void fireLost() => _lost.add('test-drop');
}

const _token = VideoToken(token: 't', url: 'wss://x', room: 'c1');

void main() {
  group('CallSession.connect', () {
    test('happy path → connected + media enabled', () async {
      final service = _FakeService([ConnectionResult.connected]);
      final session = CallSession(
        api: _FakeApi(token: _token),
        channelId: 'c1',
        service: service,
      );
      final result = await session.connect();
      expect(result, ConnectionResult.connected);
      expect(session.state.value, CallConnectionState.connected);
      expect(service.enableMediaCalls, 1);
      await session.leave();
    });

    test('503 → videoUnavailable, never attempts a LiveKit connect', () async {
      final service = _FakeService([ConnectionResult.connected]);
      final session = CallSession(
        api: _FakeApi(error: const VideoNotEnabled()),
        channelId: 'c1',
        service: service,
      );
      final result = await session.connect();
      expect(result, ConnectionResult.videoUnavailable);
      expect(session.state.value, CallConnectionState.videoUnavailable);
      expect(service.connectCalls, 0); // no point connecting a video-less room
      await session.leave();
    });

    test('Unauthorized → failed (auth abort)', () async {
      final service = _FakeService([ConnectionResult.connected]);
      final session = CallSession(
        api: _FakeApi(error: const Unauthorized(401)),
        channelId: 'c1',
        service: service,
      );
      final result = await session.connect();
      expect(result, ConnectionResult.tokenAuthError);
      expect(session.state.value, CallConnectionState.failed);
      await session.leave();
    });
  });

  group('CallSession reconnect', () {
    test('a mid-call drop reconnects and returns to connected', () async {
      // First connect ok; the reconnect attempt also ok.
      final service = _FakeService(
          [ConnectionResult.connected, ConnectionResult.connected]);
      final session = CallSession(
        api: _FakeApi(token: _token),
        channelId: 'c1',
        service: service,
        reconnectDelays: const [Duration.zero],
      );
      await session.connect();
      expect(session.state.value, CallConnectionState.connected);

      service.fireLost();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(session.state.value, CallConnectionState.connected);
      expect(service.connectCalls, 2); // initial + one reconnect
      await session.leave();
    });

    test('an auth error DURING reconnect aborts the loop (no endless retry)',
        () async {
      // Genuinely exercise reconnect: connect OK, then the token turns bad and
      // the room drops. The backoff loop must fetch a token, get Unauthorized,
      // and STOP — not burn all three delays. (cage-match Carnot+Tesla: the old
      // test built a second session that failed on INITIAL connect and never
      // fired connectionLost, so it never touched _handleConnectionLost.)
      final api = _FakeApi(token: _token);
      final service = _FakeService(
          [ConnectionResult.connected, ConnectionResult.connected]);
      final session = CallSession(
        api: api,
        channelId: 'c1',
        service: service,
        reconnectDelays: const [Duration.zero, Duration.zero, Duration.zero],
      );
      await session.connect();
      expect(session.state.value, CallConnectionState.connected);
      expect(api.calls, 1);

      // Token now rejected; drop the live call.
      api.error = const Unauthorized(401);
      service.fireLost();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(session.state.value, CallConnectionState.failed);
      // Exactly ONE reconnect token-fetch, then abort — not three.
      expect(api.calls, 2);
      // Token fetch failed before any LiveKit connect on the reconnect.
      expect(service.connectCalls, 1);
      await session.leave();
    });

    test('a ban during reconnect surfaces suspended copy, not "session expired"',
        () async {
      final api = _FakeApi(token: _token);
      final service = _FakeService([ConnectionResult.connected]);
      final session = CallSession(
        api: api,
        channelId: 'c1',
        service: service,
        reconnectDelays: const [Duration.zero],
      );
      await session.connect();
      api.error = const AccountSuspended();
      service.fireLost();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.state.value, CallConnectionState.failed);
      expect(session.message.value, 'This account is suspended');
      await session.leave();
    });

    test('leaving during the backoff does not mutate state after dispose',
        () async {
      final service = _FakeService(
          [ConnectionResult.connected, ConnectionResult.connected]);
      final session = CallSession(
        api: _FakeApi(token: _token),
        channelId: 'c1',
        service: service,
        reconnectDelays: const [Duration(milliseconds: 50)],
      );
      await session.connect();
      service.fireLost();
      // Leave WHILE the 50ms backoff is pending.
      await session.leave();
      // Wait past the backoff — the reconnect must have bailed on _disposed.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // No throw = the disposed-guard prevented touching disposed notifiers.
      expect(service.connectCalls, 1); // only the initial connect ran
    });
  });
}
