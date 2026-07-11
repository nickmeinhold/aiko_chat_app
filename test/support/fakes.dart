import 'dart:async';
import 'dart:typed_data';

import 'package:aiko_chat_app/core/network/network_status.dart';
import 'package:aiko_chat_app/features/auth/data/cached_user_store.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/legal/data/eula_store.dart';
import 'package:aiko_chat_app/services/secure_token_store.dart';
import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// In-memory token store: subclasses the real store and overrides its three
/// methods, so tests never touch the platform FlutterSecureStorage.
class InMemoryTokenStore extends SecureTokenStore {
  AuthTokens? _tokens;
  InMemoryTokenStore([AuthTokens? initial]) : _tokens = initial;

  @override
  Future<AuthTokens?> read() async => _tokens;
  @override
  Future<void> write(AuthTokens tokens) async => _tokens = tokens;
  @override
  Future<void> clear() async => _tokens = null;

  AuthTokens? get current => _tokens;
}

/// In-memory cached-user store: subclasses the real store and overrides its
/// three methods (passing null prefs to the base, which the overrides never
/// touch), so tests never depend on a real SharedPreferences. Seed with an
/// initial user to exercise offline restore; `written`/`cleared` expose the
/// lifecycle for symmetry assertions.
class InMemoryCachedUserStore extends CachedUserStore {
  AppUser? _user;
  AppUser? written;
  bool cleared = false;

  /// When true, `write` returns `false` (SharedPreferences persistence-failure
  /// semantics — no throw) so a test can exercise the caller's fallback.
  bool failWrites = false;
  InMemoryCachedUserStore([AppUser? initial])
      : _user = initial,
        super(null);

  @override
  AppUser? read() => _user;
  @override
  Future<bool> write(AppUser user) async {
    if (failWrites) return false; // persisted nothing; no throw
    _user = user;
    written = user;
    return true;
  }

  @override
  Future<bool> clear() async {
    _user = null;
    cleared = true;
    return true;
  }

  AppUser? get current => _user;
}

/// In-memory EULA store: fakes the SharedPreferences-backed acceptance flag at
/// the seam, so tests never touch the platform channel. Defaults to NOT
/// accepted; `accepted: true` lets a test bypass the first-run gate.
class FakeEulaStore extends EulaStore {
  bool accepted;
  bool throwOnAccept;
  int setCalls = 0;
  FakeEulaStore({this.accepted = false, this.throwOnAccept = false});

  @override
  Future<bool> hasAccepted() async => accepted;

  @override
  Future<void> setAccepted() async {
    setCalls++;
    if (throwOnAccept) throw Exception('persist failed');
    accepted = true;
  }
}

/// In-memory connectivity: no platform channel. Defaults to online; a test can
/// seed offline or push changes via [emit].
class FakeConnectivityService implements ConnectivityService {
  bool online;
  final _controller = StreamController<bool>.broadcast();
  FakeConnectivityService({this.online = true});

  @override
  Future<bool> isOnline() async => online;
  @override
  Stream<bool> get onlineChanges => _controller.stream;

  void emit(bool v) {
    online = v;
    _controller.add(v);
  }
}

/// In-memory reachability probe: no network. Defaults to reachable.
class FakeReachabilityProbe implements ReachabilityProbe {
  bool reachable;
  FakeReachabilityProbe({this.reachable = true});
  @override
  Future<bool> canReach(String httpBaseUrl) async => reachable;
}

/// Programmable dio adapter: routes each request through [handler].
class FakeHttpAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions options) handler;
  FakeHttpAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(int status, String body) => ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

/// A controllable fake WebSocketChannel for transport tests.
class FakeWebSocketChannel implements WebSocketChannel {
  final StreamController<dynamic> incoming = StreamController<dynamic>();
  final FakeWebSocketSink _sink = FakeWebSocketSink();
  final Completer<void> _ready = Completer<void>();

  /// If set, `ready` completes with this error (simulates connect failure).
  FakeWebSocketChannel({Object? readyError}) {
    if (readyError != null) {
      _ready.completeError(readyError);
    } else {
      _ready.complete();
    }
  }

  List<dynamic> get sent => _sink.sent;

  /// Push an inbound frame to listeners.
  void emit(dynamic frame) => incoming.add(frame);

  /// Simulate the socket closing (onDone).
  void closeFromServer() => incoming.close();

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  Future<void> get ready => _ready.future;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeWebSocketSink implements WebSocketSink {
  final List<dynamic> sent = [];
  bool closed = false;

  @override
  void add(dynamic data) => sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> get done async {}
}
