import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../../core/auth/token_provider.dart';
import '../../domain/message.dart';
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
  void subscribe(List<String> channelIds) {
    _subscribed.addAll(channelIds);
    _sendRaw(SubscribeFrame(_subscribed.toList()).encode());
  }

  @override
  String sendMessage(OutgoingMessage message) {
    final frame = SendFrame(
      clientMsgId: message.clientTempId,
      channelId: message.channelId,
      body: message.body,
      replyTo: message.replyToId,
    );
    // No-op if not connected; the repository keeps the row 'sending' and flushes
    // its outbox on reconnect. Never throws (interface contract).
    _sendRaw(frame.encode());
    return message.clientTempId;
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
      case ErrorFrame f:
        _errors.add(TransportError(
            code: f.code, detail: f.detail, refClientMsgId: f.refClientMsgId));
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
