# Design 02 — Transport seam: ChatTransport + ChatRestApi + Gateway impls + SecureTokenStore

**Component scope (plan §B1):** the boundary between the app and the gateway.
Riverpod providers depend on the **interfaces**, never on `web_socket_channel`/`dio`,
so tests inject fakes and a contract change touches only the impls + envelopes.dart.

Files: `features/chat/data/transport/{chat_transport.dart, gateway_transport.dart}`,
`features/chat/data/{chat_rest_api.dart, gateway_rest_api.dart}` (or a `core/network/`
home for the REST client), `services/secure_token_store.dart`.

Depends on Component 1 (models + envelopes). No cache/repository/UI here.

## Gateway facts (verified by reading the running code)
- **WSS** `GET /v1/ws?token=<access jwt>` (ws.py:28). Invalid/expired/missing token (or a
  valid token whose user was deleted) → server closes `1008` *before* `accept` (ws.py:32,37-38).
  ⚠️ **CRITICAL (review findings 1+4): the client CANNOT reliably read this 1008.** A close
  before the WS handshake completes surfaces on `dart:io` as a **connect exception with
  `closeCode == null`** (`web_socket_channel`: `closeCode` is null until a *clean* close
  handshake; `ready` throws `WebSocketChannelException`); browsers **mask abnormal closes to
  1006** regardless. So the close code is NOT a usable auth-vs-network discriminator on any
  platform. **Auth state is decided via REST, not the WS close** (see "token lifecycle" below).
- After accept: server reads **JSON text frames** (`receive_json`, ws.py:48). Client sends
  `subscribe`/`send` (Component 1 outbound frames). `subscribe` is **additive** server-side
  (`conn.subscribed |= channel_ids`, ws.py:56) — re-subscribing the full set after reconnect is safe/idempotent.
- A malformed frame → server replies `error` (does NOT close), ws.py:52.
- **REST** base (no `/v1` auth guard on reads yet — task #8): `POST /v1/auth/{register,login,refresh}`,
  `GET /v1/me`, `GET /v1/channels`, `GET /v1/channels/{id}/messages?before=&limit=`.

## `ChatTransport` (realtime; has a lifecycle)
```
abstract interface class ChatTransport {
  Stream<ConnectionState> get connectionState;   // disconnected|connecting|connected|unauthenticated
  Stream<Message>   get messages;   // decoded from MessageFrame
  Stream<AckResult> get acks;       // {clientMsgId, msgId, createdAt}
  Stream<TransportError> get errors;// from ErrorFrame (carries refClientMsgId)
  Future<void> connect();           // pulls token via TokenProvider (below)
  Future<void> disconnect();
  void subscribe(List<String> channelIds);
  String sendMessage(OutgoingMessage m);  // returns clientTempId (echo of m's id)
}
```
- **Phase 1 inbound substreams: messages, acks, errors only.** typing/presence/reactions
  are later phases; UnknownFrame is logged + dropped here (never surfaced).
- `connectionState` is a `unauthenticated` terminal-ish state when refresh fails (drives router → login).

## `ChatRestApi` (no lifecycle)
```
abstract interface class ChatRestApi {
  Future<AuthSession> login(String username, String password);
  Future<AuthSession> register(String username, String displayName, String password);
  Future<String> refresh(String refreshToken);     // returns new access token
  Future<AppUser> me();
  Future<List<Channel>> listChannels();
  Future<HistoryPage> getHistory(String channelId, {String? before, int limit});
}
// HistoryPage { List<Message> messages; String? nextBefore; }
```

## `SecureTokenStore`
`flutter_secure_storage` wrapper: `read() -> AuthTokens?`, `write(AuthTokens)`, `clear()`.
Single source of truth for credentials. Both the REST interceptor and the WSS connect read from it.

## The cross-cutting concern: token lifecycle (the interesting part)

Two consumers need a *fresh access token*: the REST interceptor (per request) and the
WSS connect (per (re)connect). Both must share ONE refresh, not race two.

**`TokenProvider`** (small seam both impls depend on):
```
abstract interface class TokenProvider {
  Future<String?> currentAccessToken();   // cached, may be expired
  Future<String?> refreshAccessToken();   // single-flight; null => refresh failed (logout)
}
```
- **Single-flight refresh — assign the in-flight future SYNCHRONOUSLY (review finding 2).**
  The null-check and the assignment must happen in ONE synchronous step, before any `await`,
  or a second caller slips through during the gap. Mandated shape:
  ```dart
  Future<String?> refreshAccessToken() =>            // NOT async
      _inFlight ??= _doRefresh().whenComplete(() => _inFlight = null);
  Future<String?> _doRefresh() async { /* read store, call bare-dio refresh, write store */ }
  ```
  `??=` + `whenComplete` clear the slot on BOTH success and failure (a failed refresh must not
  pin a dead future forever). `_doRefresh` is the only `async` part.
- **Refresh goes through a token-less client (review finding 6 — avoids a provider cycle).**
  The refresh endpoint is unauthenticated; `_doRefresh` must call it via a **bare `Dio` with
  NO auth interceptor**, never via the interceptor-wrapped `ChatRestApi` (whose interceptor
  depends on `TokenProvider` → cycle). One refresh path only; read the refresh token from
  `SecureTokenStore` inside the provider (callers don't carry it).
- On refresh success → write new `AuthTokens` to `SecureTokenStore`. On failure (refresh
  token invalid/expired) → `clear()` + emit `unauthenticated`.

### `GatewayRestApi` (dio)
- `dio` with base URL + `onRequest` attaches `Authorization: Bearer <currentAccessToken>`.
- `onError` for **401** → `refreshAccessToken()` (single-flight) → retry the original request
  ONCE with the new token; second 401 → propagate (logout). Modeled on TalaThrive
  `common_interceptor.dart`. **Whole-request retry** (not just re-attach) — re-issue the
  full request object. Guard against infinite retry with a per-request `_retried` flag.
- login/register do NOT attach a token; refresh uses the refresh token in the body.

### `GatewayTransport` (web_socket_channel)
- **Long-lived broadcast controllers (review finding 3 — REQUIRED, not optional).** The
  `messages`/`acks`/`errors` `StreamController`s are created ONCE per transport instance and
  survive every reconnect; the per-connection `WebSocketChannel` is the only thing recreated.
  If controllers were per-connection, the repository's `.listen` would bind to a dead
  controller and the first frames after reconnect (incl. an `ack`) would be silently dropped —
  stranding an optimistic row at `sending` forever (no history backfill for acks). Invariant 1
  restated accordingly.
- `connect()`: `token = await tokenProvider.currentAccessToken()`; open
  `ws(s)://host/v1/ws?token=$token` with a **`pingInterval` of ~20-30s** (finding 7: the
  gateway has no server-side ping (ws.py:48) and Caddy/uvicorn will drop an idle socket; the
  client ping keeps it alive AND makes a real drop observable promptly). Attach the demux
  `.listen` (route Ack/Message/Error via `ServerFrame.parse`; UnknownFrame → log+drop).
- **Close handling — REST decides auth, the close code does NOT (findings 1+4).** Any
  connect-failure or close (exception on `ready`, or stream `onDone`, regardless of
  `closeCode`) is an **unclassified "reconnect needed"** event. To classify:
  1. call `tokenProvider.refreshAccessToken()` (single-flight) if the cached access token is
     expired/near-expiry; else attempt reconnect directly.
  2. if refresh returns a new token → it was auth/expiry → reconnect with it.
  3. if refresh returns null (refresh token dead) → `connectionState = unauthenticated`, stop.
  4. if the token was still valid and reconnect keeps failing → treat as **network drop** →
     backoff reconnect (same token). A persistent close with a valid token that *still* 1008s
     (e.g. deleted user) is caught because `GET /v1/me` / refresh will eventually 401 → logout,
     instead of an infinite same-token reconnect loop.
  - The 401 REST path (cleanly observable, finding 5) is the real auth source of truth; the WS
    just triggers a reconnect attempt that *consults* it.
- **Reconnect:** exponential backoff (cap ~30s); on reconnect, **re-emit the last subscribe
  set** (additive server-side per ws.py:56, and a fresh `Connection` starts empty per ws.py:43,
  so re-subscribe is REQUIRED). connectivity_plus can gate retry attempts.
- `sendMessage`: serialise a `SendFrame` (Component 1) to the socket; **always returns
  `m.clientTempId`** (never throws). Deliverability is signalled separately via
  `connectionState`/an `errors` event — the repository keeps the optimistic row `sending` and
  flushes its outbox on reconnect. Transport owns NO outbox/durable message state.

## Invariants (before the mechanism)
1. **Long-lived demux controllers; one `.listen` per connection.** The broadcast controllers
   outlive reconnects (finding 3); each new socket gets exactly one demux `.listen`. No
   per-connection controllers (would drop post-reconnect frames), no double-subscription to a
   raw socket (would dup/drop).
2. **Single-flight refresh, assigned synchronously.** At most one refresh in flight across
   REST + WSS; the in-flight future is set in the same synchronous step as the null-check
   (finding 2), and cleared on success AND failure.
3. **Transport owns no durable MESSAGE state.** Outbox/persistence/dedup is the repository's
   job. (Stream *controllers* and reconnect bookkeeping are connection infrastructure, NOT
   "durable state" in this sense — finding 3 clarification.) `sendMessage` never throws; it
   always returns the clientTempId and signals deliverability out-of-band.
4. **Auth is decided by REST, not the WS close code.** The close code is unreadable/ambiguous
   across platforms (findings 1+4); the 401→refresh path is the source of truth.
5. **Bounded retry.** REST: retry once per request. WSS: reconnect with capped backoff; auth
   resolved via single-flight refresh → at most one refresh per close-burst. No unbounded loops.
6. **Heartbeat.** `pingInterval` set on the socket so an idle connection isn't silently reaped
   by Caddy/uvicorn and so a real drop is detected promptly (finding 7).
7. **Fakeable.** `FakeChatTransport` drives the substreams directly (emitMessage/emitAck);
   tests never touch a real socket.

## Edge cases for the reviewer to attack
- **E1:** access token expired at WSS connect → 1008 → refresh → reconnect. Does the code
  distinguish 1008 from a normal close/network drop? (web_socket_channel exposes
  `sink.closeCode` / `closeCode` after the stream ends — confirm the API surface.)
- **E2:** refresh token ALSO expired → refresh returns null → both REST and WSS must land in
  `unauthenticated`, not retry-loop.
- **E3:** REST 401 burst (3 parallel requests) → exactly ONE refresh, all three retried with
  the new token. Assert single-flight.
- **E4:** message arrives between socket-open and the messages-stream having a listener
  (broadcast streams drop events with no listener) → do we attach listeners BEFORE sending
  subscribe? Order matters.
- **E5:** reconnect mid-send: a `sendMessage` issued while reconnecting → transport reports
  not-connected; repository keeps the optimistic row `sending` and flushes on reconnect.
- **E6:** `wss://` vs `ws://` for local dev (localhost gateway is plain `ws://`); base URL config.
- **E7:** token in query string — leaks into server access logs / proxies. It's the gateway's
  chosen contract (§A1), accept for Phase 1; note as a known tradeoff (header-based WS auth later).

## Test plan (ATDD)
- `FakeChatTransport` emits → controller streams deliver (foundation for repository tests).
- REST: dio with a mock adapter — 401 → refresh called once → retry succeeds; second 401 → throws.
- Single-flight: 3 concurrent 401s → refresh invoked exactly once (counter).
- TokenProvider: concurrent `refreshAccessToken()` share one future.
- 1008 close → refresh + reconnect attempted; null refresh → unauthenticated.

## Resolved by adversarial review (2026-06-21)
1. 🔴→✅ **Close code 1008 is NOT readable** (findings 1+4) — re-architected: WS close = unclassified "reconnect needed"; **REST 401/refresh is the auth source of truth**; close code demoted to a hint. (Pre-accept close → `dart:io` connect exception, `closeCode==null`; browser masks to 1006.)
2. 🔴→✅ **Single-flight race** (finding 2) — must assign in-flight future synchronously (`_inFlight ??= _doRefresh().whenComplete(()=>_inFlight=null)`), clear on success AND failure.
3. 🔴→✅ **Broadcast controllers must be long-lived** (finding 3), not per-connection, or post-reconnect frames (incl. acks → stuck `sending`) drop. Restated in invariant 1.
4. 🟡→✅ **No heartbeat** (finding 7) — `pingInterval ~20-30s` REQUIRED (Caddy/uvicorn idle reap). Invariant 6.
5. 🟡→✅ **Provider cycle** (finding 6) — `TokenProvider._doRefresh` uses a bare interceptor-less `Dio`; single refresh path; reads refresh token from store.
6. ✅ confirmed: refresh NOT rotated; access TTL 15min / refresh 30d (config.py:30-31) → the refresh path IS exercised in a normal Phase-1 session; additive re-subscribe on reconnect (ws.py:56).

## Still-open (minor, decide at build)
- `connectionState` enum: `unauthenticated` IS distinct from `disconnected` (router watches `unauthenticated` → redirect to login). Confirmed direction.
- Android cleartext: plain `ws://` to a localhost dev gateway needs `usesCleartextTraffic` / ATS dev exception, or on-device dev silently fails. Note for the build.
- Backoff numbers: start simple (e.g. 1s,2s,4s… cap 30s); tune later.
