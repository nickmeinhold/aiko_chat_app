/// Component B4 — the reconcile engine (design: docs/design/04-b4-reconcile-engine.html).
///
/// The orchestration POLICY that turns the drift cache's atomic primitives into
/// a message that survives `send → disconnect → reconnect → ack` with no
/// duplicate, no loss, and a correct [DeliveryState] at every step. It owns no
/// storage and no invariant enforcement — those live in the cache (Component 3);
/// B4 navigates them. It is the **single writer** to the cache (invariant
/// B-single) and the only component wiring the transport (C1) + REST (C2)
/// together.
library;

import 'dart:async';

import '../../auth/domain/auth_models.dart';
import '../domain/message.dart';
import 'cache/drift_cache.dart';
import 'chat_rest_api.dart';
import 'transport/chat_transport.dart';

/// Observability seam for the cases that must be *seen*, never silently
/// swallowed. Default is a no-op; production wires real telemetry.
abstract class ChatTelemetry {
  const ChatTelemetry();
  void orphanAck(String clientMsgId, String serverUlid) {}
  void reconnectFailed(Object error, StackTrace stack) {}
  void historyGapBeforeFence(String channelId, String? cursor, String fence) {}

  /// An inbound (W3) cache write threw. Surfaced so a failed upsert is OWNED
  /// (observed) rather than leaking as an unhandled async error from the stream
  /// handler.
  void inboundWriteFailed(Object error, StackTrace stack) {}
}

class _NoopTelemetry extends ChatTelemetry {
  const _NoopTelemetry();
}

/// The reconcile engine. Construct it, then [start] to wire the transport
/// streams (established ONCE, outliving every reconnect — invariant B-live).
class ChatRepository {
  final DriftCache _cache;
  final ChatTransport _transport;
  final ChatRestApi _rest;
  final AppUser _me;
  final List<String> _subscribedChannelIds;
  final ChatTelemetry _telemetry;
  final Duration _ackTimeout;
  final String Function() _newTempId;

  ChatRepository({
    required DriftCache cache,
    required ChatTransport transport,
    required ChatRestApi rest,
    required AppUser me,
    required List<String> subscribedChannelIds,
    ChatTelemetry telemetry = const _NoopTelemetry(),
    Duration ackTimeout = const Duration(seconds: 3),
    required String Function() newTempId,
  })  : _cache = cache,
        _transport = transport,
        _rest = rest,
        _me = me,
        _subscribedChannelIds = subscribedChannelIds,
        _telemetry = telemetry,
        _ackTimeout = ackTimeout,
        _newTempId = newTempId;

  final List<StreamSubscription<dynamic>> _subs = [];
  bool _disposed = false;
  bool _started = false;

  /// The optimistic-render identity: the wire send carries no sender (the gateway
  /// derives it from the JWT, I5), so B4 renders the local row as "me".
  MessageSender get _meSender => MessageSender(
      userId: _me.userId, kind: SenderKind.human, label: _me.displayName);

  /// Reactive ordered message list for a channel (delegates to the cache).
  Stream<List<Message>> watchChannel(String channelId) =>
      _cache.watchChannel(channelId);

  // --- B-live: wire the streams ONCE -----------------------------------------

  void start() {
    // B-live: the streams are wired exactly ONCE. A second start() would double
    // every listener (doubled ack reconciliation + reconnect choreography), so
    // a repeat call is a loud programming error, not a silent no-op.
    if (_started) {
      throw StateError('ChatRepository.start() called twice — streams wire ONCE (B-live)');
    }
    _started = true;
    _subs.add(_transport.acks.listen(_onAck)); // W2
    _subs.add(_transport.messages.listen(_onMessage)); // W3
    _subs.add(_transport.errors.listen(_onError)); // W4
    _subs.add(_transport.connectionState.listen(_onConnState)); // reconnect
  }

  Future<void> dispose() async {
    _disposed = true;
    _runEpoch++; // cancel any in-flight choreography
    _failAllAckWaiters();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  // --- W1: optimistic send ---------------------------------------------------

  /// W1 — commit the optimistic row (derives localSeq) BEFORE the wire send, so
  /// an app kill between the two loses nothing: the row is in the outbox and
  /// re-sends on the next connect (invariant B-optimistic).
  Future<void> sendMessage(String channelId, String body,
      {String? replyToId}) async {
    final tempId = _newTempId();
    final optimistic = Message(
      clientTempId: tempId,
      id: null, // serverUlid NULL → in the outbox
      channelId: channelId,
      sender: _meSender,
      body: body,
      replyToId: replyToId,
      createdAt: await _clampToBottom(channelId),
      deliveryState: DeliveryState.sending,
    );
    await _cache.insertOptimistic(optimistic); // COMMITS before the wire send
    _transport.sendMessage(OutgoingMessage(
        clientTempId: tempId, channelId: channelId, body: body, replyToId: replyToId));
  }

  /// W5 — manual retry of a failed row (preserves createdAt + localSeq;
  /// B-noteleport). Re-sends immediately if connected; otherwise the next drain
  /// picks it up from the outbox.
  Future<void> retry(String clientTempId) async {
    await _cache.retry(clientTempId);
    final row = (await _cache.outbox())
        .where((m) => m.clientTempId == clientTempId)
        .firstOrNull;
    if (row != null) _transport.sendMessage(_toOutgoing(row));
  }

  /// `max(now, newestCreatedAt + 1ms)` for the channel, so a skewed client clock
  /// can't park a pending message in the past.
  Future<DateTime> _clampToBottom(String channelId) async {
    final now = DateTime.now().toUtc();
    final rows = await _cache.watchChannel(channelId).first;
    if (rows.isEmpty) return now;
    final newest = rows
        .map((m) => m.createdAt)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final floor = newest.add(const Duration(milliseconds: 1));
    return now.isAfter(floor) ? now : floor;
  }

  OutgoingMessage _toOutgoing(Message m) => OutgoingMessage(
      clientTempId: m.clientTempId,
      channelId: m.channelId,
      body: m.body,
      replyToId: m.replyToId);

  // --- W2 / W3 / W4: stream handlers -----------------------------------------

  Future<void> _onAck(AckResult a) async {
    if (_disposed) return; // a torn-down repo must not write (rebuild overlap)
    final outcome = await _cache.reconcileAck(
        a.clientMsgId, a.msgId, _parseServerTime(a.createdAt));
    _completeAckWaiter(a.clientMsgId); // unblock a drain waiter
    if (outcome == AckOutcome.orphaned) {
      // Unreachable in Phase 1 BY CONSTRUCTION (W1 persists before send; no
      // local delete until W6). The enum makes the impossible OBSERVABLE, not
      // recoverable: there is no targeted backfill (the ack has no channelId)
      // and no "next history sync" backstop under the forward delta.
      _telemetry.orphanAck(a.clientMsgId, a.msgId);
      assert(false, 'orphan ack — unreachable in Phase 1; see AckOutcome.orphaned');
    }
  }

  Future<void> _onMessage(Message m) async {
    if (_disposed) return; // a torn-down repo must not write (rebuild overlap)
    // W3 — fanout echo + others' + history-via-stream. Awaited + guarded so a
    // cache failure (invariant violation, closed DB) is OWNED via telemetry
    // rather than leaking as an unhandled async error from this stream handler.
    try {
      await _cache.upsertInbound(m);
    } catch (e, st) {
      _telemetry.inboundWriteFailed(e, st);
    }
  }

  Future<void> _onError(TransportError e) async {
    if (_disposed) return; // a torn-down repo must not write (rebuild overlap)
    if (e.refClientMsgId != null) {
      // Per-message: fail that row (cache guards serverUlid IS NULL). UI offers
      // W5 retry; no auto-retry.
      await _cache.markFailed(e.refClientMsgId);
      return;
    }
    // Systemic. Terminal (auth) stops draining entirely and routes to
    // unauthenticated via the transport's terminal state; transient leaves rows
    // `sending` for a backed-off redrain. (The ConnectionState.unauthenticated
    // path is handled in _onConnState; here we only surface pending rows.)
    if (_isAuthErrorCode(e.code)) {
      await _transport.disconnect();
      return;
    }
    await _cache.markFailed(null); // surface pending rows; they stay `sending`.
  }

  // --- reconnect choreography: drain-first, timeout-bounded (B-order) ---------

  Future<void>? _reconnecting;
  bool _rerunRequested = false;
  int _runEpoch = 0;
  bool _aborted(int epoch) => epoch != _runEpoch || _disposed;

  void _onConnState(ConnectionState s) {
    if (s != ConnectionState.connected) {
      _runEpoch++; // cancel in-flight choreography
      // A disconnect INVALIDATES any queued rerun: the rerun's only justification
      // is a `connected` event, and this non-connected state supersedes it.
      // Without this, a `connected → connected (queues rerun) → disconnected`
      // sequence would fire the rerun anyway when the dead run completes —
      // running subscribe/drain/history against a transport that is actually
      // disconnected (a false resurrection). A genuine reconnect later emits a
      // fresh `connected` that re-triggers the choreography properly.
      _rerunRequested = false;
      _failAllAckWaiters(); // release waiters; nothing hangs on the timeout
      return;
    }
    if (_reconnecting != null) {
      _rerunRequested = true; // coalesce into exactly ONE re-run
      return;
    }
    final epoch = _runEpoch;
    _reconnecting = _runReconnect(epoch).whenComplete(() {
      final rerun = _rerunRequested;
      _rerunRequested = false;
      _reconnecting = null;
      // Honor a queued rerun unconditionally (round 4): only a `connected` event
      // sets it, so it IS a fresh connection wanting a run; it gets its own
      // epoch on re-entry. The dead run's writes are already fenced per-await.
      if (rerun && !_disposed) _onConnState(ConnectionState.connected);
    });
  }

  Future<void> _runReconnect(int epoch) async {
    try {
      final fences = await _transport.subscribe(_subscribedChannelIds);
      if (_aborted(epoch)) return;
      await _drainOutbox(epoch);
      if (_aborted(epoch)) return;
      for (final channelId in _subscribedChannelIds) {
        if (_aborted(epoch)) return;
        await _fetchDeltaHistory(epoch, channelId, fences[channelId] ?? '');
      }
    } catch (e, st) {
      _telemetry.reconnectFailed(e, st);
      if (_aborted(epoch)) return;
      if (_isAuthError(e)) {
        await _transport.disconnect(); // route to unauthenticated
      }
      // else: transient — pending rows stay `sending`; the next `connected`
      // event redrains. (Explicit backoff scheduling lands with the transient
      // test; a no-op here never hot-loops because nothing re-fires the run.)
    }
  }

  Future<void> _drainOutbox(int epoch) async {
    final pending = await _cache.outbox(); // O: the query, in send order
    final waiting = pending.map((m) => m.clientTempId).toSet();
    _registerAckWaiters(waiting); // register BEFORE dispatch (ack-race fix)
    for (final m in pending) {
      if (_aborted(epoch)) return;
      _transport.sendMessage(_toOutgoing(m)); // gateway idempotent → safe resend
    }
    await _resolveAlreadyAcked(waiting); // an ack that already landed completes now
    await _awaitAcksOrTimeout(waiting);
  }

  Future<void> _fetchDeltaHistory(
      int epoch, String channelId, String fence) async {
    String? cursor = await _cache.historyContiguousThrough(channelId);
    if (_aborted(epoch)) return;
    while (cursor == null ? fence.isNotEmpty : cursor.compareTo(fence) < 0) {
      // `cursor ?? ''` — a NULL cursor must page forward-from-start; the gateway
      // treats `after=null` as the BACKWARD default (newest page), which would
      // skip older history. An empty string is below every ULID → forward path.
      final page = await _rest.getHistory(channelId, after: cursor ?? '', limit: 50);
      if (_aborted(epoch)) return; // TOCTOU: re-check AFTER await, BEFORE write
      if (page.messages.isEmpty) {
        // With a visible-only fence (deleted rows excluded), the fence row is
        // guaranteed > cursor AND visible, so a non-empty page is guaranteed
        // while cursor < fence. An empty page here is an INVARIANT VIOLATION, not
        // a silent termination — blessing it would advance the watermark to a
        // fence the cache never reached, masking real loss. Do NOT advance.
        _telemetry.historyGapBeforeFence(channelId, cursor, fence);
        assert(false,
            'empty history page while cursor ($cursor) < fence ($fence) — gap');
        return;
      }
      for (final m in page.messages) {
        await _cache.upsertInbound(m); // ASC; W3 dedups on serverUlid
      }
      final newCursor = page.messages.last.id;
      // PROGRESS GUARD: the loop's liveness depends on the gateway treating
      // `after` as EXCLUSIVE — a frozen contract owned by a DIFFERENT repo. If a
      // page ever fails to advance (non-exclusive `after`, a ULID tie, or a
      // null-id history row), the loop would re-fetch the same cursor forever,
      // hammering getHistory + re-upserting. Refuse to loop: surface it as the
      // invariant violation it is, don't hang.
      if (newCursor == null ||
          (cursor != null && newCursor.compareTo(cursor) <= 0)) {
        _telemetry.historyGapBeforeFence(channelId, cursor, fence);
        assert(false,
            'history page did not advance (cursor=$cursor newCursor=$newCursor) '
            '— is the gateway `after` cursor exclusive?');
        return;
      }
      cursor = newCursor;
    }
    if (_aborted(epoch)) return;
    // History now covers everything ≤ fence; live owns everything > fence. The
    // pager is the SINGLE writer of this watermark (round-4 invariant).
    await _cache.advanceHistoryContiguous(channelId, fence);
  }

  // --- single-owner ack-waiter completion (round-4 guards) -------------------

  final Map<String, Completer<void>> _ackWaiters = {};

  void _registerAckWaiters(Set<String> ids) {
    for (final id in ids) {
      _ackWaiters[id] = Completer<void>();
    }
  }

  /// Complete any waiter whose row is ALREADY acked (serverUlid != null) in the
  /// cache — e.g. an ack that landed in the dispatch window — so the drain
  /// doesn't burn the full timeout. A self-echo alone does NOT complete it: the
  /// echo writes R_u (keyed by serverUlid) while the optimistic row stays
  /// serverUlid==NULL until the ACK collapse (round-3 distinction).
  Future<void> _resolveAlreadyAcked(Set<String> ids) async {
    if (ids.isEmpty) return;
    final out = (await _cache.outbox()).map((m) => m.clientTempId).toSet();
    for (final id in ids) {
      if (!out.contains(id)) _completeAckWaiter(id); // no longer pending → acked
    }
  }

  Future<void> _awaitAcksOrTimeout(Set<String> ids) async {
    final futures = ids
        .map((id) => _ackWaiters[id]?.future)
        .whereType<Future<void>>()
        .toList();
    if (futures.isEmpty) return;
    try {
      await Future.wait(futures).timeout(_ackTimeout);
    } catch (_) {
      // Timeout: proceed to history — the collapse path guarantees correctness
      // if an ack lands afterward. Drop any still-pending waiters.
    } finally {
      for (final id in ids) {
        _ackWaiters.remove(id);
      }
    }
  }

  void _completeAckWaiter(String id) {
    final c = _ackWaiters.remove(id);
    if (c != null && !c.isCompleted) c.complete();
  }

  void _failAllAckWaiters() {
    for (final c in _ackWaiters.values) {
      if (!c.isCompleted) c.complete();
    }
    _ackWaiters.clear();
  }

  // --- helpers ---------------------------------------------------------------

  DateTime _parseServerTime(String? iso) =>
      (iso != null ? DateTime.tryParse(iso)?.toUtc() : null) ??
      DateTime.now().toUtc();

  /// Classify a reconnect exception as terminal-auth (stop draining, route to
  /// login) vs transient (backed-off redrain). A terminal auth rejection from
  /// the REST seam surfaces as [Unauthorized] — a 401 that survived the auth
  /// interceptor's single-flight refresh-and-retry, or a 403 (translated from
  /// `dio` at the REST boundary so this layer stays HTTP-client-agnostic).
  /// Everything else (network/timeout/5xx) is transient: pending rows stay
  /// `sending` for the next reconnect's redrain. This is the REST-thrown twin of
  /// the transport's `ConnectionState.unauthenticated` path (handled in
  /// `_onConnState`); both route to login.
  bool _isAuthError(Object e) => e is Unauthorized;

  bool _isAuthErrorCode(String code) =>
      code == 'unauthorized' || code == 'token_expired' || code == 'forbidden';
}
