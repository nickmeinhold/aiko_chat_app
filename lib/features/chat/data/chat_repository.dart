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

import '../../../services/sovereign_key_store.dart';
import '../../auth/domain/auth_models.dart';
import '../domain/message.dart';
import '../domain/message_signing.dart';
import '../domain/origin_envelope.dart';
import '../domain/ulid.dart';
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

  /// An empty-page-before-fence gap that has PERSISTED at the same watermark
  /// across [streak] consecutive history-sync attempts (#16). A single
  /// occurrence is a benign visibility shrink (`historyGapBeforeFence`); a
  /// streak that survives the threshold means the fence is genuinely unreachable
  /// — a real history gap or a regressed per-viewer fence-visibility invariant
  /// (aiko-chat-island#22). LOUD by contract: restores the failure visibility
  /// #15's benign downgrade removed for true gaps.
  ///
  /// [streak] counts SYNC ATTEMPTS (reconnect runs of the choreography), not
  /// wall-clock reconnects — coalesced `connected` events resolve to one run.
  /// Fires once per attempt WHILE the gap persists (the signal reflects ongoing
  /// state), so any destructive remediation a consumer wires (e.g. a forced full
  /// resync) MUST debounce. Production should escalate (surface "history may be
  /// incomplete" / force a resync), not just log — see [LoggingChatTelemetry].
  void historySyncFault(
      String channelId, String? cursor, String fence, int streak) {}

  /// An inbound (W3) cache write threw. Surfaced so a failed upsert is OWNED
  /// (observed) rather than leaking as an unhandled async error from the stream
  /// handler.
  void inboundWriteFailed(Object error, StackTrace stack) {}

  /// Inbound backpressure engaged/released (#9 — the named-tradeoff threshold
  /// deferred from #33). [engaged] is true when the inbound FIFO crossed the
  /// high-water mark and the three inbound subscriptions were PAUSED; false when
  /// it drained to the low-water mark and resumed. [depth] is the in-flight unit
  /// count at the transition. A sustained engaged state is the canary that
  /// inbound throughput has outrun the cache writer — exactly the condition #33
  /// judged acceptable-for-now and deferred. Production should treat a frequent
  /// or sticky engagement as a signal to investigate (a flood, a wedged writer),
  /// not just log it — see [LoggingChatTelemetry].
  void inboundBackpressure({required bool engaged, required int depth}) {}
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
  final Duration _disposeDrainTimeout;

  /// Inbound backpressure water marks (#9). At [_inboundHighWater] in-flight
  /// units the three inbound subscriptions PAUSE; they resume once drained to
  /// [_inboundLowWater]. The gap is hysteresis — it stops pause/resume thrash
  /// when the depth hovers at the threshold.
  final int _inboundHighWater;
  final int _inboundLowWater;

  final String Function() _newTempId;

  /// The device sovereign signing key (sovereign-message-signing). When present,
  /// every optimistic send is signed at birth and the signature persisted on the
  /// row (LOCAL verifiable history — NOT emitted on the wire). Nullable so tests
  /// that don't exercise signing needn't provide one; the PRODUCTION provider
  /// MUST wire it (see chatRepositoryProvider + its provider-default test), the
  /// same DI-wiring discipline the telemetry sink needed (PR #45).
  final SovereignKey? _signingKey;

  ChatRepository({
    required DriftCache cache,
    required ChatTransport transport,
    required ChatRestApi rest,
    required AppUser me,
    required List<String> subscribedChannelIds,
    ChatTelemetry telemetry = const _NoopTelemetry(),
    Duration ackTimeout = const Duration(seconds: 3),
    Duration disposeDrainTimeout = const Duration(seconds: 5),
    int inboundHighWater = 256,
    int inboundLowWater = 64,
    SovereignKey? signingKey,
    required String Function() newTempId,
  })  : _signingKey = signingKey,
        assert(inboundHighWater > inboundLowWater && inboundLowWater >= 0,
            'low-water must be below high-water (hysteresis), both non-negative'),
        _cache = cache,
        _transport = transport,
        _rest = rest,
        _me = me,
        _subscribedChannelIds = subscribedChannelIds,
        _telemetry = telemetry,
        _ackTimeout = ackTimeout,
        _disposeDrainTimeout = disposeDrainTimeout,
        _inboundHighWater = inboundHighWater,
        _inboundLowWater = inboundLowWater,
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

  /// TEST-ONLY read access to the injected telemetry sink. Exists so a
  /// provider-wiring test can assert the production graph injects a REAL sink
  /// (never the silent [_NoopTelemetry] default) — the #16 regression that
  /// shipped precisely because no test could observe the repo's actual
  /// collaborator (the provider-default test pins the provider, not the
  /// consumption edge). Not for production use.
  ChatTelemetry get debugTelemetry => _telemetry;

  /// Test-only: the injected sovereign signing key (or null if unwired). Guards
  /// the same DI-no-op class as [debugTelemetry] — a nullable injectable that
  /// silently doesn't sign if the production provider forgets to wire it.
  SovereignKey? get debugSigningKey => _signingKey;

  // --- B-live: wire the streams ONCE -----------------------------------------

  void start() {
    // B-live: the streams are wired exactly ONCE. A second start() would double
    // every listener (doubled ack reconciliation + reconnect choreography), so
    // a repeat call is a loud programming error, not a silent no-op.
    if (_started) {
      throw StateError('ChatRepository.start() called twice — streams wire ONCE (B-live)');
    }
    _started = true;
    // INBOUND SERIALIZATION (PR#7 finding 2). The three inbound mutation streams
    // (ack/message/error) are NOT serialized against each other by Dart: while
    // one handler is suspended at an `await`, another can begin and interleave
    // its cache write. The cache is atomic PER operation, but ORDERING ACROSS
    // operations was left to scheduler chance (an ack and the message it acks
    // could reconcile out of order). Funnel all three through ONE repository-
    // owned FIFO queue so single-writer ordering is STRUCTURAL, not incidental.
    // connectionState stays direct: it is the reconnect COORDINATOR (epoch-
    // guarded; its own writes go through the cache via drain/history), not a
    // simple inbound mutation, and it must be able to bump the epoch to cancel
    // in-flight work without waiting behind the queue.
    // The three inbound subscriptions are held separately (_inboundSubs) so the
    // backpressure valve can pause/resume exactly them — and NEVER connectionState
    // (the reconnect coordinator must keep flowing to bump the epoch even while
    // inbound is paused). They are also in _subs so dispose() cancels everything.
    final ackSub =
        _transport.acks.listen((a) => _enqueueInbound(() => _onAck(a))); // W2
    final msgSub = _transport.messages
        .listen((m) => _enqueueInbound(() => _onMessage(m))); // W3
    final errSub = _transport.errors
        .listen((e) => _enqueueInbound(() => _onError(e))); // W4
    _inboundSubs.addAll([ackSub, msgSub, errSub]);
    _subs.addAll([ackSub, msgSub, errSub]);
    _subs.add(_transport.connectionState.listen(_onConnState)); // reconnect
  }

  // --- inbound mutation serialization queue (PR#7 finding 2) -----------------

  /// The tail of the inbound FIFO. Each enqueued unit chains onto the previous
  /// one's completion, so units run with no interleaving — the single-writer
  /// discipline made structural. "Arrival order" here means LISTENER-CALLBACK
  /// order: the order the three transport streams (acks/messages/errors) deliver
  /// events to this repository, NOT a server causal order across those
  /// independent streams. Within that, the queue guarantees each unit runs to
  /// completion before the next starts.
  Future<void> _inboundTail = Future<void>.value();

  /// The three inbound subscriptions (ack/message/error) — the only ones the
  /// backpressure valve pauses. connectionState is deliberately excluded.
  final List<StreamSubscription<dynamic>> _inboundSubs = [];

  /// In-flight inbound units: incremented at enqueue (when a transport event is
  /// delivered), decremented when that unit settles. The queue's depth.
  int _inboundDepth = 0;

  /// Whether the inbound subscriptions are currently paused for backpressure.
  bool _inboundPaused = false;

  void _enqueueInbound(Future<void> Function() unit) {
    _inboundDepth++;
    _maybePauseInbound();
    _inboundTail = _inboundTail.then((_) {
      if (_disposed) return null; // drop queued work for a torn-down session
      return unit();
    }).catchError((Object e, StackTrace st) {
      // The FIFO chain must outlive any single unit's failure, so nothing thrown
      // here may propagate down the `then` chain (that would poison every later
      // unit). Each escapee is instead OBSERVED, not swallowed (cage-match
      // Carnot F3):
      //   - AssertionError — a debug tripwire (e.g. the orphan-ack assert).
      //     Re-surfaced as an uncaught zone error so it crashes LOUDLY in debug
      //     (stripped in release), proving the impossible case fired.
      //   - Any other escape is unexpected (handlers already own their runtime
      //     errors via internal try/catch). Route it to telemetry so it is
      //     visible. TRADEOFF: it is no longer observable via `await
      //     _inboundTail` in dispose() (the chain stays green by design) — the
      //     telemetry seam is the single observability point for an escaped
      //     inbound error, in dispose() and everywhere else alike.
      if (e is AssertionError) {
        Zone.current.handleUncaughtError(e, st);
      } else {
        _telemetry.inboundWriteFailed(e, st);
      }
    }).whenComplete(() {
      // Decrement AFTER the unit settles (success or observed failure), then let
      // a drained queue release backpressure. `whenComplete` runs for both paths
      // because `catchError` already returns normally, so the count can never
      // leak. The next enqueued unit chains onto THIS future, so the resume
      // decision is made on the freshest depth before more work starts.
      _inboundDepth--;
      _maybeResumeInbound();
    });
  }

  /// Engage backpressure: at/above the high-water mark, pause the three inbound
  /// subscriptions so the slowdown propagates toward the transport instead of
  /// piling unbounded `.then` units (and their captured events) onto the FIFO.
  /// Idempotent via [_inboundPaused]; a no-op once disposed (teardown cancels the
  /// subs, and pausing a cancelled subscription is meaningless).
  void _maybePauseInbound() {
    if (_inboundPaused || _disposed) return;
    if (_inboundDepth < _inboundHighWater) return;
    _inboundPaused = true;
    for (final s in _inboundSubs) {
      s.pause();
    }
    _telemetry.inboundBackpressure(engaged: true, depth: _inboundDepth);
  }

  /// Release backpressure: once the queue has drained to the low-water mark,
  /// resume the inbound subscriptions (their buffered events deliver and re-enter
  /// the FIFO, idempotently). Skipped during teardown — dispose() cancels the
  /// subs, and resuming a cancelled subscription would throw.
  void _maybeResumeInbound() {
    if (!_inboundPaused || _disposed) return;
    if (_inboundDepth > _inboundLowWater) return;
    _inboundPaused = false;
    for (final s in _inboundSubs) {
      s.resume();
    }
    _telemetry.inboundBackpressure(engaged: false, depth: _inboundDepth);
  }

  Future<void> dispose() async {
    _disposed = true;
    _runEpoch++; // cancel any in-flight choreography
    _failAllAckWaiters();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    // The inbound subs were cancelled via _subs above; drop our pause/resume
    // refs so the valve never touches a dead subscription during the drain.
    _inboundSubs.clear();
    // Drain the inbound FIFO so a unit that was mid-flight when dispose() began
    // finishes (its writes are guarded benign by _disposed) before we return —
    // no inbound mutation outlives dispose(). Queued-but-unstarted units are
    // dropped by the _disposed check in _enqueueInbound.
    //
    // BOUNDED (cage-match Carnot F1): the in-flight unit awaits cache/transport
    // work that *should* complete promptly, but dispose() must ALWAYS terminate
    // — a wedged unit must not hang teardown to the heat death of the universe.
    // The timeout is a fail-safe, not the expected path; if it ever fires it
    // means an inbound mutation is stuck, which is itself worth observing.
    // Upper bound (_disposeDrainTimeout, default 5s, injectable for tests): a
    // generous-but-finite fail-safe so teardown can never hang on a wedged unit.
    try {
      await _inboundTail.timeout(_disposeDrainTimeout);
    } on TimeoutException catch (e, st) {
      _telemetry.inboundWriteFailed(e, st);
    }
  }

  // --- W1: optimistic send ---------------------------------------------------

  /// W1 — commit the optimistic row (derives localSeq) BEFORE the wire send, so
  /// an app kill between the two loses nothing: the row is in the outbox and
  /// re-sends on the next connect (invariant B-optimistic).
  Future<void> sendMessage(String channelId, String body,
      {String? replyToId}) async {
    // Disposed-guard (PR#7 cage-match finding 3). DECISION: silent no-op, NOT a
    // loud StateError. Unlike start() (a true double-wire programming error), a
    // post-dispose send is a benign LIFECYCLE RACE: the repo is an autoDispose
    // Riverpod value, so a UI action firing as the provider tears down must not
    // crash the app — it just has nowhere to land (the cache is closing). The
    // entry guard proves entry-time state; a dispose that begins DURING the
    // awaits below is caught + owned in the catch (teardown-race write).
    if (_disposed) return;
    try {
      final tempId = _newTempId();
      final createdAt = await _clampToBottom(channelId);
      final optimistic = Message(
        clientTempId: tempId,
        id: null, // serverUlid NULL → in the outbox
        channelId: channelId,
        sender: _meSender,
        body: body,
        replyToId: replyToId,
        createdAt: createdAt,
        deliveryState: DeliveryState.sending,
      );
      // Sign at birth (sovereign-message-signing). signedAtMs is the compose
      // time, fixed here and persisted in its own column so ack reconciliation
      // overwriting createdAt with server time never breaks verification. The
      // signature is LOCAL history only — deliberately NOT added to
      // OutgoingMessage/SendFrame (wire emission is gated on gateway carriage).
      MessageSignature? signature;
      if (_signingKey != null) {
        signature = await sign(
          _signingKey,
          SignedPayload(
            rawPublicKey: _signingKey.rawPublicKey,
            channelId: channelId,
            clientMsgId: tempId,
            signedAtMs: createdAt.toUtc().millisecondsSinceEpoch,
            body: body,
            replyTo: replyToId,
          ),
        );
      }
      // COMMITS before the wire send — signature written in the same txn.
      await _cache.insertOptimistic(optimistic, signature: signature);
      _transport.sendMessage(OutgoingMessage(
          clientTempId: tempId, channelId: channelId, body: body, replyToId: replyToId));
    } catch (e, st) {
      // The entry guard proves entry-time state only; dispose can begin DURING
      // the awaits above and close the cache. A teardown-race write is benign
      // (session ending) — own it; a genuine error still propagates.
      if (!_disposed) rethrow;
      _telemetry.inboundWriteFailed(e, st);
    }
  }

  /// W5 — manual retry of a failed row (preserves createdAt + localSeq;
  /// B-noteleport). Re-sends immediately if connected; otherwise the next drain
  /// picks it up from the outbox.
  Future<void> retry(String clientTempId) async {
    if (_disposed) return; // silent no-op (see sendMessage): benign teardown race
    try {
      await _cache.retry(clientTempId);
      final row = (await _cache.outbox())
          .where((m) => m.clientTempId == clientTempId)
          .firstOrNull;
      if (row != null) _transport.sendMessage(_toOutgoing(row));
    } catch (e, st) {
      // Teardown race (cache closing) is benign; a genuine error propagates.
      if (!_disposed) rethrow;
      _telemetry.inboundWriteFailed(e, st);
    }
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
    final AckOutcome outcome;
    try {
      outcome = await _cache.reconcileAck(
          a.clientMsgId, a.msgId, _parseServerTime(a.createdAt));
    } catch (e, st) {
      // A write already past the guard can land as the cache closes during
      // teardown — benign (the session is ending), so OWN it, don't leak it.
      _telemetry.inboundWriteFailed(e, st);
      return;
    }
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
      await _persistInbound(m);
    } catch (e, st) {
      _telemetry.inboundWriteFailed(e, st);
    }
  }

  /// Verify an inbound message's sovereign origin (if any) ONCE at ingest, then
  /// persist. The single verify point for BOTH inbound paths (live fanout +
  /// history sync) so the cache never runs crypto and the verdict is computed
  /// exactly once. A malformed origin was already dropped at parse (fromView);
  /// an unverifiable-but-well-formed origin persists with originCryptoValid=false
  /// (carried-but-invalid), which is DATA — no UI ships from it (wire-half T5).
  Future<void> _persistInbound(Message m) async {
    final o = m.origin;
    final verified = o == null
        ? m
        : m.copyWith(
            originCryptoValid: await verifyOrigin(o,
                channelId: m.channelId, body: m.body, replyTo: m.replyToId),
          );
    await _cache.upsertInbound(verified);
  }

  Future<void> _onError(TransportError e) async {
    if (_disposed) return; // a torn-down repo must not write (rebuild overlap)
    if (e.refClientMsgId != null) {
      // Per-message: fail that row (cache guards serverUlid IS NULL). UI offers
      // W5 retry; no auto-retry. Guarded: a write landing as the cache closes
      // during teardown is benign (session ending) — own it, don't leak it.
      try {
        await _cache.markFailed(e.refClientMsgId);
      } catch (err, st) {
        _telemetry.inboundWriteFailed(err, st);
      }
      return;
    }
    // Systemic. Terminal (auth) stops draining entirely and routes to
    // unauthenticated via the transport's terminal state; transient leaves rows
    // `sending` for a backed-off redrain. (The ConnectionState.unauthenticated
    // path is handled in _onConnState; here we only surface pending rows.)
    if (e.parsedCode.isAuthTerminal) {
      await _transport.disconnect();
      return;
    }
    try {
      await _cache.markFailed(null); // surface pending rows; they stay `sending`.
    } catch (err, st) {
      _telemetry.inboundWriteFailed(err, st); // benign if cache closing (teardown)
    }
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

  /// #16 — per-channel streak of empty-page-before-fence gaps at an UNCHANGED
  /// watermark. Survives reconnects (the repo outlives them), so a gap that
  /// keeps recurring at the SAME stall cursor across reconnects is detectable.
  /// Reset when the channel fully syncs (gap healed) or the stall cursor moves
  /// (visibility still settling — benign). Reaching [_historyGapFaultThreshold]
  /// escalates a benign gap to a loud sync fault.
  final Map<String, ({String? cursor, int count})> _historyGapStreaks = {};
  static const int _historyGapFaultThreshold = 3;

  Future<void> _fetchDeltaHistory(
      int epoch, String channelId, String fence) async {
    // The loop + progress guards below compare ids lexicographically; that is
    // only monotonic for canonical (UPPERCASE) ULIDs. Assert at the boundary so
    // a non-canonical fence/cursor fails LOUDLY instead of silently breaking
    // ordering (PR#7 finding 4). Empty fence ('' = below every ULID) is fine.
    if (fence.isNotEmpty) assertCanonicalUlid(fence, context: 'fence');
    String? cursor = await _cache.historyContiguousThrough(channelId);
    if (cursor != null) assertCanonicalUlid(cursor, context: 'resume cursor');
    if (_aborted(epoch)) return;
    while (cursor == null ? fence.isNotEmpty : cursor.compareTo(fence) < 0) {
      // `cursor ?? ''` — a NULL cursor must page forward-from-start; the gateway
      // treats `after=null` as the BACKWARD default (newest page), which would
      // skip older history. An empty string is below every ULID → forward path.
      final page = await _rest.getHistory(channelId, after: cursor ?? '', limit: 50);
      if (_aborted(epoch)) return; // TOCTOU: re-check AFTER await, BEFORE write
      if (page.messages.isEmpty) {
        // An empty page while cursor < fence USED to be an invariant violation
        // (assert). It no longer is: visibility can legitimately SHRINK between
        // the fence read (at subscribe) and this paging — a moderation block (#7)
        // or a soft-delete can hide the very row the fence pointed at, so the
        // fence becomes unreachable by currently-visible rows. This is expected,
        // not corruption. Handle it as a benign re-sync: surface it via telemetry
        // (still observable — it IS unusual), then RETURN WITHOUT advancing the
        // watermark. The next reconnect recomputes a FRESH per-viewer fence and
        // the loop converges.
        //
        // CONVERGENCE CONTRACT (cage-match Carnot HIGH, cross-repo): the self-heal
        // holds ONLY because the gateway's `latest_ulid` fence is per-viewer and
        // applies the SAME visibility filter as `get_history` (soft-delete + block)
        // — aiko-chat-island#22. So once a block/delete lands, the next subscribe's
        // fence excludes the now-hidden row and is reachable. If the gateway ever
        // regressed that (a fence over rows hidden from the viewer), this would
        // refetch the same watermark every reconnect forever — a permanent
        // reconnect-cycle retry rather than a hot loop. Repeated gaps across
        // reconnects should therefore be treated as a sync FAULT, not noise
        // (claude-tasks #16). Not advancing the watermark means we never claim
        // coverage we don't have — a genuine gap re-attempts rather than being
        // masked (it is now telemetried, not asserted).
        // #16 — distinguish a benign one-off visibility shrink from a GENUINELY
        // unreachable fence (real history loss, or a regressed per-viewer fence
        // invariant). Count consecutive gaps at the SAME stall cursor: a fresh
        // cursor (visibility still settling) resets the streak via the equality
        // check; a clean sync resets it at loop completion. A streak that
        // survives the threshold across reconnects is no longer "expected".
        final prev = _historyGapStreaks[channelId];
        final streak =
            (prev != null && prev.cursor == cursor) ? prev.count + 1 : 1;
        _historyGapStreaks[channelId] = (cursor: cursor, count: streak);
        if (streak >= _historyGapFaultThreshold) {
          // ESCALATE: the gap is stuck at one watermark across N reconnects, so
          // it is not a transient shrink. Surface it LOUD (restores the failure
          // visibility #15's benign downgrade removed for true gaps).
          _telemetry.historySyncFault(channelId, cursor, fence, streak);
        } else {
          _telemetry.historyGapBeforeFence(channelId, cursor, fence);
        }
        return;
      }
      for (final m in page.messages) {
        await _persistInbound(m); // ASC; W3 dedups on serverUlid, verifies origin
      }
      final newCursor = page.messages.last.id;
      if (newCursor != null) {
        assertCanonicalUlid(newCursor, context: 'history page cursor');
      }
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
    // Synced clean through the fence → any prior empty-page-before-fence streak
    // for this channel has healed; clear it so a future gap counts from 1 (#16).
    _historyGapStreaks.remove(channelId);
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
}
