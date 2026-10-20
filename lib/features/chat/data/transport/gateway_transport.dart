import 'dart:async';
import 'dart:collection';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../../core/auth/token_provider.dart';
import '../../../../core/logging/aiko_logger.dart';
import '../../domain/message.dart';
import '../../domain/origin_envelope.dart';
import '../../domain/retraction.dart';
import 'chat_transport.dart';
import 'envelopes.dart';

/// Creates a socket for a url. Injectable so tests drive a fake channel.
typedef ChannelFactory = WebSocketChannel Function(Uri url);

/// Default production factory: IOWebSocketChannel with a ping interval so an
/// idle socket isn't reaped by Caddy/uvicorn (design 02, finding 7). Phase 1
/// targets ios/android/macos (all dart:io); web would need a conditional import.
WebSocketChannel _defaultChannelFactory(Uri url) =>
    IOWebSocketChannel.connect(url, pingInterval: const Duration(seconds: 25));

/// How recently a refresh must have SUCCEEDED for a connect failure to skip
/// it. This is the rate limit that "once per disconnect-burst" used to be, minus
/// that rule's defect: a burst's one refresh could run while Doze blocked the
/// network, fail transiently, and never be retried. The access token then
/// expired mid-burst and every reconnect drew a 403 until the app restarted
/// (#392, measured on a Pixel 2026-10-19). Counting only SUCCESSES means a
/// failed refresh is retried on the next failure, and a long outage can't
/// strand a token that expired during it.
const kRefreshFloor = Duration(seconds: 60);

/// WSS implementation of [ChatTransport].
///
/// Key properties (all from design 02's review):
/// - broadcast controllers are created ONCE and outlive reconnects;
/// - auth is decided via the REST refresh path, NOT the (unreadable) WS close
///   code — any connect failure/drop triggers a refresh-classified reconnect;
/// - refresh is attempted on a failure unless one SUCCEEDED within
///   [kRefreshFloor] — a refresh that failed transiently is retried (#392);
/// - a transient (network) refresh failure does NOT log out.
class GatewayTransport implements ChatTransport {
  final String _wsBaseUrl; // e.g. ws://localhost:8095 (no trailing slash)
  final TokenProvider _tokens;
  final ChannelFactory _channelFactory;
  final void Function(String message)? _log;

  /// Structured, release-visible observation (#223): state changes, connect
  /// stages, refresh, and reconnect scheduling — the points a silent transport
  /// death (#392) passes through. Scalars only: never the token, never an
  /// error's string (the redacting sink projects errors to their type name).
  final AikoLogger? _obs;

  /// The capability gate for sovereign `origin` emit (task #1896). Read
  /// synchronously per-send: when it returns false the `origin` envelope is
  /// stripped and the message is sent unsigned — a non-carriage gateway would
  /// otherwise `bad_origin`-reject the whole message. Defaults to **fail-closed
  /// (never emit)** so a caller that forgets to wire the capability degrades to
  /// safe unsigned delivery, not origin-at-every-island (cage-match Tesla). The
  /// production site (`transportProvider`) always injects the real predicate.
  final bool Function() _carriesOrigin;

  /// Fired (fire-and-forget) each time the socket reaches `connected`, so the
  /// carriage capability can be (re)resolved against the live gateway. The gate
  /// reads the freshest value on subsequent sends; the current send uses
  /// whatever was already resolved (allowlist-seeded on first connect).
  final Future<void> Function()? _onConnected;

  final _messages = StreamController<Message>.broadcast();
  final _acks = StreamController<AckResult>.broadcast();
  final _errors = StreamController<TransportError>.broadcast();
  final _retractions = StreamController<Retraction>.broadcast();
  final _connState = StreamController<ConnectionState>.broadcast();

  /// The CURRENT connection state, replayed to every new [connectionState]
  /// subscriber. Connection state is STATE, not an event log — a consumer that
  /// mounts AFTER the `connected` emission (e.g. a repository rebuilt because a
  /// gateway-recovery refetch changed the channel list) must still learn the
  /// socket is live, or its connected-driven choreography never runs.
  /// Starts `idle` (not `disconnected`): no socket has been REQUESTED yet, and
  /// seeding a drop-state before `connect()` would flash a false "server
  /// unreachable" banner on every restored session (cage-match Carnot, PR #75).
  ConnectionState _lastConn = ConnectionState.idle;

  void _setConn(ConnectionState s) {
    if (s != _lastConn) _obs?.info('state', fields: {'to': s.name});
    _lastConn = s;
    _connState.add(s);
  }

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final Set<String> _subscribed = {};

  /// Awaitable `subscribe` calls awaiting their `suback`. A suback resolves the
  /// oldest pending call whose requested channels are all present in the ack —
  /// content correlation, NOT blind FIFO. This matters because the internal
  /// reconnect resubscribe ([_resubscribe]) fires an *untracked* subscribe frame:
  /// its ack (covering only the previously-subscribed set) must NOT consume a
  /// later explicit `subscribe()` that asked for a channel the ack doesn't carry
  /// (cage-match: Carnot's resubscribe-ack race). Such an uncorrelated ack finds
  /// no covered pending call and is dropped. A drop rejects all pending calls.
  final Queue<_PendingSuback> _pendingSubacks = Queue();
  bool _wantConnected = false;
  bool _connecting = false;
  int _backoffAttempt = 0;
  Timer? _reconnectTimer;
  final DateTime Function() _clock;

  /// Which connect attempt owns the transport. Bumped by every new attempt and
  /// by every disconnect/dispose/sign-out; [_openSocket] captures it before
  /// each await and stands down if it has moved on — so a connect pending
  /// across a logout cannot install a socket afterwards (Carnot, cage-match
  /// round 1).
  ///
  /// It is NOT what stops a stale backoff timer orphaning a kicked socket (all
  /// four families, round 1). That was the timer body's `_channel = null`,
  /// which bypassed [_openSocket]'s own live-channel guard; with the bypass
  /// deleted, that guard holds by itself. Mutation-checked: an epoch check in
  /// the failure path as well was a second guard on the same invariant.
  int _epoch = 0;

  /// When a refresh last RETURNED A TOKEN. Null until one has. See
  /// [kRefreshFloor].
  DateTime? _lastRefreshOk;

  GatewayTransport({
    required String wsBaseUrl,
    required TokenProvider tokens,
    ChannelFactory? channelFactory,
    void Function(String message)? log,
    AikoLogger? logger,
    bool Function()? carriesOrigin,
    Future<void> Function()? onConnected,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _wsBaseUrl = wsBaseUrl,
       _tokens = tokens,
       _channelFactory = channelFactory ?? _defaultChannelFactory,
       _log = log,
       _obs = logger,
       _carriesOrigin = carriesOrigin ?? (() => false),
       _onConnected = onConnected;

  @override
  Stream<ConnectionState> get connectionState => Stream.multi((c) {
    // Seed the current state, then forward live changes. Both happen
    // synchronously inside this callback and all state mutations are
    // event-loop-serialized, so no emission slips between seed and
    // subscription.
    c.add(_lastConn);
    final sub = _connState.stream.listen(
      c.add,
      onError: c.addError,
      onDone: c.close,
    );
    c.onCancel = sub.cancel;
  });
  @override
  Stream<Message> get messages => _messages.stream;
  @override
  Stream<AckResult> get acks => _acks.stream;
  @override
  Stream<TransportError> get errors => _errors.stream;
  @override
  Stream<Retraction> get retractions => _retractions.stream;

  @override
  Future<void> connect() async {
    _wantConnected = true;
    await _openSocket();
  }

  /// Connect NOW instead of waiting out the backoff: the caller knows the
  /// network just became usable (a ring was answered, the app resumed, the
  /// device came back online). Backoff exists to spare a dead island, and it
  /// only knows time — so in Doze, where every attempt is refused instantly, it
  /// climbs to its 30s ceiling and then sleeps through the moment a push lifts
  /// the block (11.6s of a 30s answer window on the Pixel, 2026-10-19; #384).
  ///
  /// A no-op unless a connection is wanted and none is live or in flight, so a
  /// kick can never stack a second socket or abort a connect in progress.
  ///
  /// The backoff COUNTER is left alone: a kick buys one attempt now, not a
  /// reset. Resetting it let a phone that resumes or flaps networks while the
  /// island is down retry every second instead of backing off (Noether,
  /// cage-match round 1).
  @override
  void reconnectNow(TransportWakeReason reason) {
    if (!_wantConnected || _connecting || _channel != null) {
      _obs?.info(
        'kick.ignored',
        fields: {
          'reason': reason.name,
          'want': _wantConnected,
          'connecting': _connecting,
          'channel': _channel != null,
        },
      );
      return;
    }
    _obs?.info('kick', fields: {'reason': reason.name});
    _reconnectTimer?.cancel();
    unawaited(_openSocket());
  }

  @override
  Future<void> disconnect() async {
    _wantConnected = false;
    _epoch++; // any attempt still in flight now belongs to no one
    _connecting = false;
    _reconnectTimer?.cancel();
    // Publish FIRST, then close without waiting. Awaiting the close and then
    // publishing let a slow handshake land `disconnected` over a newer
    // connection's `connected` (Carnot), and on the dead network #392 is about
    // a close handshake can hang, so `disconnect()` never returned (Noether,
    // round 3). The fields are detached synchronously inside _cleanupChannel.
    _setConn(ConnectionState.disconnected);
    unawaited(_cleanupChannel());
  }

  @override
  Future<Map<String, String>> subscribe(List<String> channelIds) {
    final completer = Completer<Map<String, String>>();
    if (_channel == null) {
      // Disconnected: nothing can ack. Do NOT mutate `_subscribed` — surfacing a
      // failure while silently retaining the channels as desired state would be
      // a state/API mismatch (cage-match: Carnot). The reconcile engine
      // subscribes within a live epoch, so this is an error, not a silent hang.
      completer.completeError(
        const TransportError(
          code: 'not_connected',
          parsedCode: TransportErrorCode.other,
          detail: 'subscribe before connect',
        ),
      );
      return completer.future;
    }
    _subscribed.addAll(channelIds);
    _pendingSubacks.add(_PendingSuback(channelIds.toSet(), completer));
    // Always (re)send the FULL set — subscribe is additive and idempotent
    // server-side, and the fence is recomputed for every channel each time.
    _sendRaw(SubscribeFrame(_subscribed.toList()).encode());
    return completer.future;
  }

  @override
  String sendMessage(OutgoingMessage message) {
    final frame = SendFrame(
      clientMsgId: message.clientTempId,
      channelId: message.channelId,
      body: message.body,
      replyTo: message.replyToId,
      origin: _originWire(message),
    );
    // No-op if not connected; the repository keeps the row 'sending' and flushes
    // its outbox on reconnect. Never throws (interface contract).
    _sendRaw(frame.encode());
    return message.clientTempId;
  }

  /// Build the wire `origin`, self-asserting through [validateOrigin] before
  /// emit — the OUTBOUND admission gate (origin_envelope.dart): never emit a
  /// malformed envelope. Now that carriage is live a `bad_origin` reject would
  /// drop the whole MESSAGE, so on the (should-be-impossible) construction
  /// failure we strip origin and send UNSIGNED — a legal "unverified" delivery
  /// beats a rejected one. `frameClientMsgId` is the frame's own id, which the
  /// origin's `client_msg_id` must equal (identical by construction).
  ///
  /// The ENTIRE ornament construction is inside the try (cage-match Carnot F1 +
  /// Tesla): `toWire()` calls `encodeMultikey`, which throws [OriginError] on a
  /// bad-length key — that throw is OUTSIDE the caller's control and must not
  /// escape `sendMessage` (never-throws contract) nor defeat the strip. The
  /// catch is broad on purpose: the origin is an OPTIONAL ornament, so ANY
  /// construction failure strips it rather than killing the message. Logged so a
  /// construction bug is observable, not a silent sovereignty downgrade.
  Map<String, dynamic>? _originWire(OutgoingMessage message) {
    final o = message.origin;
    if (o == null) return null;
    // Capability gate (task #1896): a gateway that does not advertise `origin`
    // carriage would `bad_origin`-reject the whole message, so withhold the
    // envelope and send unsigned rather than risk the drop.
    if (!_carriesOrigin()) return null;
    try {
      final wire = o.toWire();
      validateOrigin(wire, frameClientMsgId: message.clientTempId);
      return wire;
    } catch (e) {
      _log?.call('origin self-assert failed, sending unsigned: $e');
      return null;
    }
  }

  // --- internals -----------------------------------------------------------

  /// Run the on-connect capability refresh in isolation from the connect path,
  /// so neither a synchronous throw nor an async rejection can corrupt the live
  /// socket's state machine (cage-match Carnot). Fire-and-forget by design.
  void _fireOnConnected() {
    final hook = _onConnected;
    if (hook == null) return;
    // The `async` wrapper turns a sync throw inside hook() into a future error
    // too, so the single catch covers both failure modes.
    () async {
      try {
        await hook();
      } catch (e) {
        _log?.call('onConnected capability refresh failed: $e');
      }
    }();
  }

  Future<void> _openSocket() async {
    if (!_wantConnected || _connecting || _channel != null) {
      _obs?.info(
        'connect.skipped',
        fields: {
          'want': _wantConnected,
          'connecting': _connecting,
          'channel': _channel != null,
        },
      );
      return;
    }
    final epoch = ++_epoch;
    _connecting = true;
    _setConn(ConnectionState.connecting);

    try {
      // Inside the try: a throwing token read (secure storage, platform
      // channel) used to leave `_connecting` set forever, and every later
      // connect, kick and timer returned at the guard above (Noether, round 2).
      _obs?.info('connect.token.read');
      String? token = await _tokens.currentAccessToken();
      if (token == null) _obs?.info('connect.token.refresh');
      if (epoch == _epoch) token ??= await _safeRefresh();
      if (epoch != _epoch) return _abandoned('token');
      _obs?.info('connect.token.done', fields: {'has': token != null});
      if (token == null) {
        _connecting = false;
        _setUnauthenticated();
        return;
      }

      final ch = _channelFactory(Uri.parse('$_wsBaseUrl/v1/ws?token=$token'));
      await ch.ready; // throws on connect failure
      if (epoch != _epoch) {
        // Disconnected while connecting: this socket belongs to no one.
        unawaited(ch.sink.close());
        return _abandoned('ready');
      }
      _channel = ch;
      _sub = ch.stream.listen(
        _onFrame,
        onError: (_) => _handleDrop(),
        onDone: _handleDrop,
        cancelOnError: true,
      );
      _connecting = false;
      _backoffAttempt = 0;
      _reconnectTimer?.cancel();
      _setConn(ConnectionState.connected);
      _resubscribe();
      // Re-resolve carriage capability against the (possibly changed) gateway.
      // ISOLATED fire-and-forget (cage-match Carnot): the hook must NOT run in
      // the connect `try` — a synchronous throw would be caught below and
      // reclassify an already-live socket as a connect failure (spurious
      // reconnect while `_channel` is non-null), and an async error would be
      // unhandled. `_fireOnConnected` swallows both into the log.
      //
      // Named one-window tradeoff (cage-match Tesla): a send BETWEEN this connect
      // and the refresh landing uses the seed value. Both directions are bounded
      // and acceptable: a stranger seeds false (safe — no emit until proven), and
      // the only host that seeds true is one we've allowlisted as known-carriage,
      // so at worst it keeps emitting for one window until an explicit `false`
      // lands — never a regression for a host that actually carries.
      _fireOnConnected();
    } catch (e) {
      if (epoch != _epoch) return _abandoned('failed');
      _connecting = false;
      _obs?.warning('connect.failed', error: e);
      _log?.call('ws connect failed: $e');
      await _onConnectFailure();
    }
  }

  /// A connect attempt failed, or a live socket dropped. The WS close code is
  /// not a reliable auth signal (an expired token's 403 arrives as an opaque
  /// WebSocketChannelException), so classify via REST: refresh unless one
  /// succeeded within [kRefreshFloor]. RT rejected -> unauthenticated; new
  /// token or transient -> reconnect with backoff.
  Future<void> _onConnectFailure() async {
    final epoch = _epoch;
    final last = _lastRefreshOk;
    if (last == null || _clock().difference(last) >= kRefreshFloor) {
      _obs?.info('failure.refresh.start');
      try {
        final refreshed = await _tokens.refreshAccessToken();
        // A success is stamped even when stale: the token is stored either way.
        if (refreshed != null) _lastRefreshOk = _clock();
        // Then stand down if a newer attempt owns the transport — whatever the
        // outcome. A stale `rejected` would tear down the newer live socket, and
        // after dispose it would publish into closed controllers (Carnot,
        // Noether, Tesla, cage-match round 2: round 1's mutation run covered
        // only the `token` outcome and wrongly called this check redundant).
        if (epoch != _epoch) return _abandoned('refresh');
        _obs?.info(
          'failure.refresh.done',
          fields: {'outcome': refreshed == null ? 'rejected' : 'token'},
        );
        if (refreshed == null) {
          _setUnauthenticated();
          return;
        }
        // A FRESH token is new information, so retry now rather than after the
        // backoff: backoff exists to spare an island that keeps failing, and
        // this attempt differs from the one that failed. Without this, a kick at
        // the 30s cap met the expired token, refreshed, then waited 30s more —
        // past a held answer's deadline (Carnot + Tesla, cage-match round 3).
        // The backoff counter is untouched, so a failure with the fresh token
        // still backs off.
        _obs?.info('reconnect.now', fields: {'why': 'fresh_token'});
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(Duration.zero, _openSocket);
        return;
      } catch (e) {
        if (epoch != _epoch) return _abandoned('refresh');
        // transient (network) refresh failure -> fall through to reconnect
        _obs?.info(
          'failure.refresh.done',
          fields: {'outcome': 'transient'},
          error: e,
        );
      }
    }
    _scheduleReconnect();
  }

  void _handleDrop() {
    _obs?.info('drop', fields: {'want': _wantConnected});
    _cleanupChannel();
    if (!_wantConnected) return;
    _setConn(ConnectionState.disconnected);
    _onConnectFailure();
  }

  void _scheduleReconnect() {
    if (!_wantConnected) return;
    _reconnectTimer?.cancel();
    final seconds = (1 << _backoffAttempt).clamp(1, 30);
    _backoffAttempt = (_backoffAttempt + 1).clamp(0, 5);
    _obs?.info(
      'reconnect.scheduled',
      fields: {'seconds': seconds, 'attempt': _backoffAttempt},
    );
    // No `_channel = null` here: that once nulled a LIVE channel to slip past
    // _openSocket's own guard, orphaning a socket. A timer can no longer
    // outlive its owner — kicks, success and disconnect cancel it, and a stale
    // failure abandons before arming one — so the guard needs no bypass.
    _reconnectTimer = Timer(Duration(seconds: seconds), _openSocket);
  }

  /// Returns a fresh token on success, null on definitive auth failure; a
  /// transient refresh error is swallowed to null here ONLY at initial connect
  /// (we have no token at all, so we can't proceed regardless).
  ///
  /// Reached only when [TokenProvider.currentAccessToken] is null, which with
  /// [DefaultTokenProvider] means NO stored tokens (`AuthTokens.accessToken` is
  /// non-null): its refresh then finds no refresh token and returns null
  /// without throwing. So the transient-swallow and a missed `_lastRefreshOk`
  /// stamp here are unreachable today; raised and rejected in cage-match rounds
  /// 1-2. A TokenProvider that can hold a refresh token without an access token
  /// must revisit this.
  Future<String?> _safeRefresh() async {
    try {
      return await _tokens.refreshAccessToken();
    } catch (_) {
      return null;
    }
  }

  void _onFrame(dynamic raw) {
    final text = raw is String ? raw : raw.toString();
    final frame = GatewayFrame.parse(text);
    switch (frame) {
      case AckFrame f:
        _acks.add(
          AckResult(
            clientMsgId: f.clientMsgId,
            msgId: f.msgId,
            createdAt: f.createdAt,
          ),
        );
      case MessageFrame f:
        _messages.add(Message.fromView(f.msg));
      case SubAckFrame f:
        _resolveSubAck(f.channelFences);
      case ErrorFrame f:
        _errors.add(
          TransportError(
            code: f.code,
            parsedCode: f.parsedCode,
            detail: f.detail,
            refClientMsgId: f.refClientMsgId,
          ),
        );
      case RetractionFrame f:
        _retractions.add(
          Retraction(
            channelId: f.channelId,
            id: f.id,
            targetMsgId: f.targetMsgId,
          ),
        );
      case UnknownFrame f:
        _log?.call('dropped unknown frame: ${f.reason}');
    }
  }

  void _resubscribe() {
    if (_subscribed.isNotEmpty) {
      _sendRaw(SubscribeFrame(_subscribed.toList()).encode());
    }
  }

  void _sendRaw(String data) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(data);
    } catch (e) {
      _log?.call('ws send failed: $e');
    }
  }

  /// A continuation found a newer owner and stood down. Logged so a stood-down
  /// attempt is distinguishable from one that silently never resumed.
  void _abandoned(String at) =>
      _obs?.info('attempt.abandoned', fields: {'at': at});

  void _setUnauthenticated() {
    _wantConnected = false;
    _epoch++;
    _connecting = false;
    _reconnectTimer?.cancel();
    _cleanupChannel();
    _setConn(ConnectionState.unauthenticated);
  }

  /// Detach FIRST, close after. The fields are cleared synchronously so a dying
  /// socket never occupies [_channel] while its close handshake runs — on the
  /// dead network #392 is about, that can outlast the first backoff delays, and
  /// a stale `_channel` makes [_openSocket] and [reconnectNow] skip, with
  /// nothing left to retry (Tesla, cage-match round 2). Closing the detached
  /// locals also means a slow close can never null out a NEWER channel. This is
  /// what the old timer body's `_channel = null` was papering over.
  Future<void> _cleanupChannel() async {
    final sub = _sub;
    final ch = _channel;
    _sub = null;
    _channel = null;
    _failPendingSubacks();
    await sub?.cancel();
    await ch?.sink.close();
  }

  /// Resolve the oldest pending `subscribe()` whose requested channels are ALL
  /// present in this ack. An ack covering none (an uncorrelated reconnect
  /// resubscribe ack) is dropped — it must not consume a later explicit
  /// subscribe that asked for a channel this ack doesn't carry.
  void _resolveSubAck(Map<String, String> fences) {
    for (final p in _pendingSubacks) {
      if (p.requested.every(fences.containsKey)) {
        _pendingSubacks.remove(p);
        if (!p.completer.isCompleted) p.completer.complete(fences);
        return;
      }
    }
    _log?.call(
      'suback matched no pending subscribe (resubscribe ack): $fences',
    );
  }

  /// Reject every in-flight `subscribe` whose `suback` can no longer arrive (the
  /// socket is gone). Without this a reconnect-mid-subscribe would hang forever.
  void _failPendingSubacks() {
    while (_pendingSubacks.isNotEmpty) {
      final p = _pendingSubacks.removeFirst();
      if (!p.completer.isCompleted) {
        p.completer.completeError(
          const TransportError(
            code: 'disconnected',
            parsedCode: TransportErrorCode.other,
            detail: 'socket dropped before suback',
          ),
        );
      }
    }
  }

  /// Release all resources. Call when the transport is permanently disposed.
  Future<void> dispose() async {
    _wantConnected = false;
    _epoch++;
    _connecting = false;
    _reconnectTimer?.cancel();
    unawaited(_cleanupChannel()); // detached synchronously; never await a close
    await _messages.close();
    await _acks.close();
    await _errors.close();
    await _retractions.close();
    await _connState.close();
  }
}

/// One in-flight `subscribe()` awaiting its `suback`: the channels it asked for
/// (the correlation key — an ack must cover all of them to resolve it) and the
/// completer to fulfil with the fence map.
class _PendingSuback {
  final Set<String> requested;
  final Completer<Map<String, String>> completer;
  _PendingSuback(this.requested, this.completer);
}
