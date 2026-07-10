import 'dart:async';
import 'dart:collection';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../../core/auth/token_provider.dart';
import '../../domain/message.dart';
import '../../domain/origin_envelope.dart';
import 'chat_transport.dart';
import 'envelopes.dart';

/// Creates a socket for a url. Injectable so tests drive a fake channel.
typedef ChannelFactory = WebSocketChannel Function(Uri url);

/// Default production factory: IOWebSocketChannel with a ping interval so an
/// idle socket isn't reaped by Caddy/uvicorn (design 02, finding 7). Phase 1
/// targets ios/android/macos (all dart:io); web would need a conditional import.
WebSocketChannel _defaultChannelFactory(Uri url) =>
    IOWebSocketChannel.connect(url, pingInterval: const Duration(seconds: 25));

/// WSS implementation of [ChatTransport].
///
/// Key properties (all from design 02's review):
/// - broadcast controllers are created ONCE and outlive reconnects;
/// - auth is decided via the REST refresh path, NOT the (unreadable) WS close
///   code — any connect failure/drop triggers a refresh-classified reconnect;
/// - refresh is attempted at most once per disconnect-burst;
/// - a transient (network) refresh failure does NOT log out.
class GatewayTransport implements ChatTransport {
  final String _wsBaseUrl; // e.g. ws://localhost:8095 (no trailing slash)
  final TokenProvider _tokens;
  final ChannelFactory _channelFactory;
  final void Function(String message)? _log;

  final _messages = StreamController<Message>.broadcast();
  final _acks = StreamController<AckResult>.broadcast();
  final _errors = StreamController<TransportError>.broadcast();
  final _connState = StreamController<ConnectionState>.broadcast();

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

  GatewayTransport({
    required String wsBaseUrl,
    required TokenProvider tokens,
    ChannelFactory? channelFactory,
    void Function(String message)? log,
  })  : _wsBaseUrl = wsBaseUrl,
        _tokens = tokens,
        _channelFactory = channelFactory ?? _defaultChannelFactory,
        _log = log;

  @override
  Stream<ConnectionState> get connectionState => _connState.stream;
  @override
  Stream<Message> get messages => _messages.stream;
  @override
  Stream<AckResult> get acks => _acks.stream;
  @override
  Stream<TransportError> get errors => _errors.stream;

  @override
  Future<void> connect() async {
    _wantConnected = true;
    await _openSocket();
  }

  @override
  Future<void> disconnect() async {
    _wantConnected = false;
    _reconnectTimer?.cancel();
    await _cleanupChannel();
    _connState.add(ConnectionState.disconnected);
  }

  @override
  Future<Map<String, String>> subscribe(List<String> channelIds) {
    final completer = Completer<Map<String, String>>();
    if (_channel == null) {
      // Disconnected: nothing can ack. Do NOT mutate `_subscribed` — surfacing a
      // failure while silently retaining the channels as desired state would be
      // a state/API mismatch (cage-match: Carnot). The reconcile engine
      // subscribes within a live epoch, so this is an error, not a silent hang.
      completer.completeError(const TransportError(
          code: 'not_connected',
          parsedCode: TransportErrorCode.other,
          detail: 'subscribe before connect'));
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
  Map<String, dynamic>? _originWire(OutgoingMessage message) {
    final o = message.origin;
    if (o == null) return null;
    final wire = o.toWire();
    try {
      validateOrigin(wire, frameClientMsgId: message.clientTempId);
      return wire;
    } on OriginError {
      return null; // fail-safe: strip a malformed self-built origin, still deliver
    }
  }

  // --- internals -----------------------------------------------------------

  Future<void> _openSocket() async {
    if (!_wantConnected || _connecting || _channel != null) return;
    _connecting = true;
    _connState.add(ConnectionState.connecting);

    String? token = await _tokens.currentAccessToken();
    token ??= await _safeRefresh();
    if (token == null) {
      _connecting = false;
      _setUnauthenticated();
      return;
    }

    try {
      final ch = _channelFactory(Uri.parse('$_wsBaseUrl/v1/ws?token=$token'));
      await ch.ready; // throws on connect failure
      _channel = ch;
      _sub = ch.stream.listen(
        _onFrame,
        onError: (_) => _handleDrop(),
        onDone: _handleDrop,
        cancelOnError: true,
      );
      _connecting = false;
      _backoffAttempt = 0;
      _connState.add(ConnectionState.connected);
      _resubscribe();
    } catch (e) {
      _connecting = false;
      _log?.call('ws connect failed: $e');
      await _onConnectFailure();
    }
  }

  /// A connect attempt failed, or a live socket dropped. The WS close code is
  /// not a reliable auth signal, so classify via REST: try a refresh ONCE per
  /// disconnect-burst. RT rejected -> unauthenticated; new token or transient
  /// -> reconnect with backoff.
  Future<void> _onConnectFailure() async {
    if (_backoffAttempt == 0) {
      try {
        final refreshed = await _tokens.refreshAccessToken();
        if (refreshed == null) {
          _setUnauthenticated();
          return;
        }
      } catch (_) {
        // transient (network) refresh failure -> fall through to reconnect
      }
    }
    _scheduleReconnect();
  }

  void _handleDrop() {
    _cleanupChannel();
    if (!_wantConnected) return;
    _connState.add(ConnectionState.disconnected);
    _onConnectFailure();
  }

  void _scheduleReconnect() {
    if (!_wantConnected) return;
    _reconnectTimer?.cancel();
    final seconds = (1 << _backoffAttempt).clamp(1, 30);
    _backoffAttempt = (_backoffAttempt + 1).clamp(0, 5);
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _channel = null;
      _openSocket();
    });
  }

  /// Returns a fresh token on success, null on definitive auth failure; a
  /// transient refresh error is swallowed to null here ONLY at initial connect
  /// (we have no token at all, so we can't proceed regardless).
  Future<String?> _safeRefresh() async {
    try {
      return await _tokens.refreshAccessToken();
    } catch (_) {
      return null;
    }
  }

  void _onFrame(dynamic raw) {
    final text = raw is String ? raw : raw.toString();
    final frame = ServerFrame.parse(text);
    switch (frame) {
      case AckFrame f:
        _acks.add(AckResult(
            clientMsgId: f.clientMsgId, msgId: f.msgId, createdAt: f.createdAt));
      case MessageFrame f:
        _messages.add(Message.fromView(f.msg));
      case SubAckFrame f:
        _resolveSubAck(f.channelFences);
      case ErrorFrame f:
        _errors.add(TransportError(
            code: f.code,
            parsedCode: f.parsedCode,
            detail: f.detail,
            refClientMsgId: f.refClientMsgId));
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

  void _setUnauthenticated() {
    _wantConnected = false;
    _reconnectTimer?.cancel();
    _cleanupChannel();
    _connState.add(ConnectionState.unauthenticated);
  }

  Future<void> _cleanupChannel() async {
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    _failPendingSubacks();
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
    _log?.call('suback matched no pending subscribe (resubscribe ack): $fences');
  }

  /// Reject every in-flight `subscribe` whose `suback` can no longer arrive (the
  /// socket is gone). Without this a reconnect-mid-subscribe would hang forever.
  void _failPendingSubacks() {
    while (_pendingSubacks.isNotEmpty) {
      final p = _pendingSubacks.removeFirst();
      if (!p.completer.isCompleted) {
        p.completer.completeError(const TransportError(
            code: 'disconnected',
            parsedCode: TransportErrorCode.other,
            detail: 'socket dropped before suback'));
      }
    }
  }

  /// Release all resources. Call when the transport is permanently disposed.
  Future<void> dispose() async {
    _wantConnected = false;
    _reconnectTimer?.cancel();
    await _cleanupChannel();
    await _messages.close();
    await _acks.close();
    await _errors.close();
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
