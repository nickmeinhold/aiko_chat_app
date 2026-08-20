import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../auth/domain/auth_models.dart';
import '../../auth/domain/identity_models.dart';
import '../../call/domain/video_token.dart';
import '../../moderation/domain/moderation_models.dart';
import '../../notifications/domain/device_platform.dart';
import '../../../core/auth/token_provider.dart';
import '../../../services/secure_token_store.dart';
import '../domain/channel.dart';
import '../domain/channel_member.dart';
import '../domain/gateway_capabilities.dart';
import '../domain/message.dart';
import '../domain/retraction.dart';
import 'chat_rest_api.dart';

/// Attaches the bearer token and transparently refreshes on 401.
///
/// Retries a 401'd request exactly ONCE after a single-flight refresh; a second
/// 401 (or a null refresh) propagates. Refresh itself goes through the
/// [TokenProvider] (which uses a token-less client), never this interceptor —
/// no cycle (design 02, finding 6).
class AuthInterceptor extends Interceptor {
  final TokenProvider _tokens;
  final Dio _authedDio;

  AuthInterceptor(this._tokens, this._authedDio);

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _tokens.currentAccessToken();
    if (token != null) options.headers['Authorization'] = 'Bearer $token';
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final is401 = err.response?.statusCode == 401;
    final alreadyRetried = err.requestOptions.extra['retried'] == true;
    if (!is401 || alreadyRetried) {
      handler.next(err);
      return;
    }
    String? newToken;
    try {
      newToken = await _tokens.refreshAccessToken();
    } catch (_) {
      // TRANSIENT refresh failure (network/timeout/5xx) — the session is NOT
      // known-dead. Mark the forwarded 401 so `_authedCall` does NOT translate
      // it to terminal `Unauthorized` (which would log the user out on a network
      // blip — the exact failure design 02's refresh taxonomy exists to prevent).
      err.requestOptions.extra['auth_transient'] = true;
      handler.next(err); // surface original error as transient
      return;
    }
    if (newToken == null) {
      handler.next(err); // refresh token rejected -> session is unauthenticated
      return;
    }
    final req = err.requestOptions..extra['retried'] = true;
    try {
      // Re-issue the whole request; onRequest re-attaches the (now fresh) token.
      final response = await _authedDio.fetch(req);
      handler.resolve(response);
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}

class GatewayRestApi implements ChatRestApi {
  /// Token-less client for unauthenticated endpoints (passkey/claim/refresh).
  final Dio _bare;

  /// Interceptor-wrapped client for authed endpoints (me/channels/history).
  final Dio _authed;

  GatewayRestApi({required Dio bare, required Dio authed})
    : _bare = bare,
      _authed = authed;

  @override
  Future<String> refresh(String refreshToken) async {
    final r = await _bare.post(
      '/v1/auth/refresh',
      data: {'refresh_token': refreshToken},
    );
    return _map(r.data)['access_token'] as String;
  }

  @override
  Future<GatewayCapabilities?> getCapabilities() async {
    // Best-effort + token-less on the bare client. A 404 (endpoint not deployed
    // yet), a network error, or a non-object body all yield `null` = "unknown",
    // which the carriage resolver reads as "fall back to the allowlist". Never
    // throws — capability discovery must not break connect.
    try {
      final r = await _bare.get('/capabilities');
      final data = r.data is String ? jsonDecode(r.data as String) : r.data;
      // parse() is itself three-state: a Map missing/malforming carriage.origin
      // returns null (unknown), same as a non-Map body or a 404 below. Every
      // "can't determine" path collapses to null uniformly, so the resolver
      // keeps the seed rather than flipping an allowlisted host off on a stub
      // 200 (cage-match Tesla + Carnot — the malformed-200 inconsistency).
      if (data is Map) {
        return GatewayCapabilities.parse(Map<String, dynamic>.from(data));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PasskeyChallenge> startPasskeyRegistration() =>
      _passkeyStart('/v1/auth/passkey/register/start');

  @override
  Future<IdentityOutcome> finishPasskeyRegistration(
    String state,
    String credentialJson,
  ) =>
      _passkeyFinish('/v1/auth/passkey/register/finish', state, credentialJson);

  @override
  Future<PasskeyChallenge> startPasskeyAuthentication() =>
      _passkeyStart('/v1/auth/passkey/authenticate/start');

  @override
  Future<IdentityOutcome> finishPasskeyAuthentication(
    String state,
    String credentialJson,
  ) => _passkeyFinish(
    '/v1/auth/passkey/authenticate/finish',
    state,
    credentialJson,
  );

  @override
  Future<AppUser> addPasskey(String state, String credentialJson) async {
    // Decode the authenticator's JSON up front (outside the authed call) so a
    // client-plumbing corruption reads as a FormatException, not an auth error —
    // same contract as `_passkeyFinish`.
    final Object? credential;
    try {
      credential = jsonDecode(credentialJson);
    } on FormatException catch (e) {
      throw FormatException(
        'passkey: add received malformed credential JSON from the '
        'authenticator: ${e.message}',
      );
    }
    // Runs on the AUTHED client: the bearer IS the identity the credential links
    // to — that is the whole distinction from register/finish (which mints a new
    // account). `_authedCall` maps 401 → Unauthorized (terminal) and a plain
    // 403 → Forbidden (authZ, non-terminal); a suspended-403 → AccountSuspended.
    return _authedCall(() async {
      try {
        final r = await _authed.post(
          '/v1/auth/passkey/add/finish',
          data: {'state': state, 'credential': credential},
        );
        // The add endpoint returns a BARE user view (no tokens — the caller is
        // already authenticated), so it deliberately bypasses `_resolveOutcome`
        // (which requires a token/provisioning_token and would throw here).
        return AppUser.fromJson(_map(r.data));
      } on DioException catch (e) {
        if (e.response?.statusCode == 409) {
          throw const PasskeyAlreadyRegistered();
        }
        rethrow; // _authedCall maps 401→Unauthorized / plain 403→Forbidden; else propagate
      }
    });
  }

  /// Begin a passkey ceremony: the gateway returns `{state, options}` where
  /// `options` is the WebAuthn options object. We re-encode `options` to the
  /// opaque JSON string the device authenticator consumes, and carry `state`
  /// untouched to the `finish` call (server-side challenge binding).
  Future<PasskeyChallenge> _passkeyStart(String path) => _mapNetwork(() async {
    final r = await _bare.post(path);
    final m = _map(r.data);
    final options = m['options'];
    final state = m['state'];
    if (options is! Map || state is! String) {
      throw const FormatException(
        'passkey: start response missing state/options',
      );
    }
    return (state: state, optionsJson: jsonEncode(options));
  });

  /// Complete a passkey ceremony: POST the device's response [credentialJson]
  /// (WebAuthn JSON the authenticator produced) plus the binding [state], and
  /// route the gateway's identity response through the single-door resolver so
  /// register and authenticate can never diverge on how the outcome is read.
  Future<IdentityOutcome> _passkeyFinish(
    String path,
    String state,
    String credentialJson,
  ) async {
    final Object? credential;
    try {
      credential = jsonDecode(credentialJson);
    } on FormatException catch (e) {
      // The authenticator's own toJsonString is the producer, so a decode
      // failure here is client-plumbing corruption, not a server rejection.
      // Tag it (like the start path) so it doesn't read as a generic auth fail.
      throw FormatException(
        'passkey: finish received malformed credential JSON from the '
        'authenticator: ${e.message}',
      );
    }
    return _mapNetwork(() async {
      try {
        final r = await _bare.post(
          path,
          data: {'state': state, 'credential': credential},
        );
        return _resolveOutcome(_map(r.data));
      } on DioException catch (e) {
        _throwIfAuthTerminal(e); // 401/403 → Unauthorized; else rethrow.
      }
    });
  }

  /// Map a terminal auth status (401/403) on a token-less [_bare] auth call to
  /// the domain [Unauthorized]. The passkey finish + claim paths go through
  /// [_bare] (they carry a credential/provisioning token, not a bearer), so they
  /// don't get [_authedCall]'s mapping — without this a rejected assertion or an
  /// expired provisioning token propagates as a raw [DioException] whose string
  /// can carry the request body (provisioning_token/handle/display_name),
  /// leaking it into the on-screen error banner AND leaving the UI's action-aware
  /// Unauthorized copy with no producer (cage-match #74 R2, Carnot + Tesla).
  /// Non-terminal statuses rethrow unchanged (a connection-class error then maps
  /// to [NetworkUnavailable] in the enclosing [_mapNetwork]).
  static Never _throwIfAuthTerminal(DioException e) {
    final code = e.response?.statusCode;
    if (_isSuspended(e)) throw const AccountSuspended();
    if (code == 401 || code == 403) throw Unauthorized(code);
    throw e;
  }

  /// True iff this is the island's account-ban response — `403 {"detail":
  /// "account suspended"}` (handoff 2026-07-27). Keyed on the body, not the bare
  /// 403, so an unrelated forbidden (e.g. a moderator-only endpoint) is NOT
  /// mislabelled as a ban. Matches the island's exact phrase (case-insensitive,
  /// tolerant of surrounding text/punctuation) rather than a bare `suspend`
  /// substring — so a future 403 whose prose merely *mentions* suspend/suspension
  /// ("cannot suspend this operation") is not baptised a ban (cage-match Tesla).
  /// Robust to a Map body (dio-decoded JSON) or a raw JSON string. Any parse
  /// hiccup falls through to the generic mapping — on the bare login door that is
  /// 401/403 → Unauthorized; on the authed door a plain 403 → Forbidden (A3). A
  /// suspended user hitting the login door then sees the re-auth copy, never a crash.
  static bool _isSuspended(DioException e) {
    if (e.response?.statusCode != 403) return false;
    final data = e.response?.data;
    final Object? body = data is String && data.isNotEmpty
        ? _tryJson(data)
        : data;
    final detail = body is Map ? body['detail'] : null;
    return detail is String &&
        detail.toLowerCase().contains('account suspended');
  }

  static Object? _tryJson(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  /// Resolve the gateway's identity response (from a passkey finish) into an
  /// [IdentityOutcome]. Route on the PRIMARY signal — a provisioning_token
  /// (or explicit status:pending) — not the mere ABSENCE of an access_token, so a
  /// malformed authenticated response fails loudly instead of casting a null
  /// provisioning_token (cage-match consensus: Maxwell/Kelvin/Carnot).
  IdentityOutcome _resolveOutcome(Map<String, dynamic> m) {
    final ptok = m['provisioning_token'];
    if (m['status'] == 'pending' || ptok != null) {
      if (ptok is! String) {
        throw const FormatException(
          'auth: pending response missing provisioning_token',
        );
      }
      return PendingHandle(
        provisioningToken: ptok,
        suggestedName: m['suggested_name'] as String?,
        email: m['email'] as String?,
      );
    }
    if (m['access_token'] == null) {
      throw const FormatException(
        'auth: response has neither access_token nor provisioning_token',
      );
    }
    return Authenticated(AuthSession.fromJson(m));
  }

  @override
  Future<AuthSession> claimHandle({
    required String provisioningToken,
    required String handle,
    required String displayName,
  }) => _mapNetwork(() async {
    try {
      final r = await _bare.post(
        '/v1/auth/social/claim',
        data: {
          'provisioning_token': provisioningToken,
          'handle': handle,
          'display_name': displayName,
        },
      );
      return AuthSession.fromJson(_map(r.data));
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) throw const HandleTaken();
      _throwIfAuthTerminal(e); // 401/403 (expired provisioning) → Unauthorized.
    }
  });

  @override
  // me() is the offline-first restore probe (its only caller is
  // AuthController._restoreSession). Terminal auth → Unauthorized (via
  // _authedCall); a connection/DNS/timeout-class failure → NetworkUnavailable so
  // the controller can safely distinguish "server unreachable" (optimistic
  // restore OK) from "server answered with something unexpected" (fail closed).
  Future<AppUser> me() => _mapNetwork(
    () => _authedCall(() async {
      final r = await _authed.get('/v1/me');
      return AppUser.fromJson(_map(r.data));
    }),
  );

  @override
  Future<AppUser> updateProfile({
    String? handle,
    String? displayName,
  }) => _mapNetwork(
    () => _authedCall(() async {
      try {
        final r = await _authed.patch(
          '/v1/me',
          data: <String, dynamic>{
            'handle': ?handle,
            'display_name': ?displayName,
          },
        );
        return AppUser.fromJson(_map(r.data));
      } on DioException catch (e) {
        // Map ONLY this endpoint's own codes here; everything else rethrows
        // so `_authedCall` applies the AUTHED-door taxonomy (cage-match #114,
        // Carnot+Tesla+Wu). This is a bearer endpoint, NOT a `_bare` login
        // door: `_throwIfAuthTerminal` would wrongly baptise a transient
        // refresh-401 AND a plain authZ-403 as terminal `Unauthorized` →
        // spurious logout. `_authedCall` instead honours the `auth_transient`
        // marker, maps a suspended-403 → AccountSuspended, a terminal 401 →
        // Unauthorized, and a plain 403 → Forbidden (session stays valid).
        final code = e.response?.statusCode;
        if (code == 409) throw const HandleTaken();
        if (code == 429) {
          final body = e.response?.data;
          final secs = (body is Map && body['retry_after'] is num)
              ? (body['retry_after'] as num).toInt()
              : 0;
          throw HandleChangeOnCooldown(secs);
        }
        rethrow;
      }
    }),
  );

  /// Translate a connection-class [DioException] (no response from the server —
  /// DNS/connect/timeout) into the domain [NetworkUnavailable]. A DioException
  /// that carries a response (the server answered, even an error) is NOT
  /// remapped — it propagates so the caller fails closed rather than treating a
  /// server-side error as a benign network blip.
  ///
  /// Wraps every offline-reachable AUTH ingress: me() (restore), the passkey
  /// ceremony start/finish, and claimHandle — so an offline first sign-in or
  /// handle claim surfaces as the same domain [NetworkUnavailable] the UI maps to
  /// a friendly "you're offline" message, instead of a raw transport exception.
  /// The classification stays narrow (connection-class, no response) so the
  /// offline-first trust boundary does not widen (see me_network_mapping_test).
  static Future<T> _mapNetwork<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      const connectionClass = {
        DioExceptionType.connectionError,
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      };
      if (e.response == null && connectionClass.contains(e.type)) {
        throw NetworkUnavailable(e);
      }
      rethrow;
    }
  }

  @override
  Future<void> deleteAccount() async {
    try {
      await _authedCall(() => _authed.delete('/v1/account'));
    } on DioException catch (e) {
      // _authedCall already mapped 401 → Unauthorized (terminal) and a plain
      // 403 → Forbidden (authZ), and rethrew everything else. A 409 means
      // "sole admin of a channel" — map it
      // to the typed domain error carrying the gateway's explanatory `detail`.
      if (e.response?.statusCode == 409) {
        final detail = (e.response?.data is Map)
            ? (e.response!.data as Map)['detail']?.toString()
            : null;
        throw SoleAdminDeletionBlocked(
          detail ?? 'You are the sole admin of a channel.',
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> registerDevice({
    required DevicePlatform platform,
    required String token,
  }) => _authedCall(
    () => _authed.post(
      '/v1/devices',
      data: {'platform': platform.wire, 'token': token},
    ),
  );

  @override
  // DELETE with a body: the island reads the token from the payload rather than
  // the path, so a device token never lands in a URL (and therefore never in an
  // access log or a proxy trace). Dio supports this; some HTTP stacks quietly
  // drop a DELETE body, so this is pinned by a test.
  Future<void> unregisterDevice(String token, {String? credential}) {
    final body = {'token': token};
    if (credential == null) {
      return _authedCall(() => _authed.delete('/v1/devices', data: body));
    }
    // THE BARE CLIENT, not the authed one, and the difference is the point. The
    // authed client's interceptor resolves a credential by READING THE TOKEN
    // STORE at request time — which is the shared mutable state the session
    // teardown is concurrently emptying, and therefore the coupling that made
    // every previous ordering a race. Handing the header over as a value removes
    // the store from the path entirely: this call is correct whether the clear
    // has happened yet or not, so the clear no longer has to wait for it.
    //
    // It also inherits none of the interceptor's 401 handling, which is right in
    // both directions: a dying credential must not trigger a refresh, and a
    // rejection here must not be mapped to terminal `Unauthorized` and log
    // anybody out — there is no session left to end.
    return _bare.delete(
      '/v1/devices',
      data: body,
      options: Options(headers: {'Authorization': 'Bearer $credential'}),
    );
  }

  // Wrapped in _mapNetwork so an unreachable gateway surfaces as the domain
  // NetworkUnavailable — channelsProvider falls back to the cached list on that,
  // delivering offline-first chat rendering (PR #71 follow-up, task #19).
  @override
  Future<List<Channel>> listChannels() => _mapNetwork(
    () => _authedCall(() async {
      final r = await _authed.get('/v1/channels');
      final list = (_map(r.data)['channels'] as List?) ?? const [];
      return list
          .map((e) => Channel.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    }),
  );

  @override
  Future<List<ChannelMember>> listMembers(String channelId) => _mapNetwork(
    () => _authedCall(() async {
      final r = await _authed.get('/v1/channels/$channelId/members');
      final list = (_map(r.data)['members'] as List?) ?? const [];
      return list
          .map(
            (e) => ChannelMember.fromJson((e as Map).cast<String, dynamic>()),
          )
          .toList();
    }),
  );

  // find-or-create the DM channel. Wrapped in _mapNetwork so an unreachable
  // island surfaces as NetworkUnavailable (the DM-open UI can retry/offline),
  // and the 404 is branched to DmTargetNotFound BEFORE any generic surfacing so
  // "no such user" never reads as a logout or a raw transport error. `POST /v1/dm`
  // is idempotent on the island, so a retry after an ambiguous failure is safe.
  @override
  Future<Channel> openDm(String targetUserId) => _mapNetwork(() async {
    try {
      return await _authedCall(() async {
        final r = await _authed.post(
          '/v1/dm',
          data: {'target_user_id': targetUserId},
        );
        return Channel.fromDmJson(_map(r.data));
      });
    } on DioException catch (e) {
      // _authedCall already mapped 401 → Unauthorized (terminal) / plain 403 →
      // Forbidden and rethrew the rest. The only other documented code here is
      // 404 = target isn't a real user (DM handoff §Endpoints).
      if (e.response?.statusCode == 404) throw DmTargetNotFound(targetUserId);
      rethrow;
    }
  });

  @override
  Future<List<Channel>> listDms() => _mapNetwork(
    () => _authedCall(() async {
      final r = await _authed.get('/v1/dm');
      final list = (_map(r.data)['channels'] as List?) ?? const [];
      // Parse PER ROW so one malformed / contract-drifted row can't vaporize the
      // whole DM list (cage-match #132, Tesla — cf. the per-row isolation the
      // reports queue already uses). fromDmJson reads `channel_id` and FAILS CLOSED
      // on kind != dm; here a throw means "omit THAT row", not "no DMs". A skipped
      // row leaves a dev breadcrumb rather than vanishing silently.
      final dms = <Channel>[];
      for (final e in list) {
        try {
          dms.add(Channel.fromDmJson((e as Map).cast<String, dynamic>()));
        } catch (err) {
          debugPrint('listDms: skipping a malformed DM row: $err');
        }
      }
      return dms;
    }),
  );

  @override
  Future<VideoToken> requestVideoToken(String channelId) =>
      _mapNetwork(() async {
        try {
          return await _authedCall(() async {
            final r = await _authed.post('/v1/channels/$channelId/video-token');
            return VideoToken.fromJson(_map(r.data));
          });
        } on DioException catch (e) {
          // _authedCall already mapped 401/403 → Unauthorized/Forbidden and
          // rethrew the rest. Branch the two video-specific codes here, BEFORE
          // any generic surfacing, so a video-less deployment (503) or a
          // non-member/private channel (404, existence-hiding) never reads as a
          // logout or a raw transport error.
          final code = e.response?.statusCode;
          if (code == 503) throw const VideoNotEnabled();
          if (code == 404) throw Forbidden('video-token:$channelId');
          rethrow;
        }
      });

  @override
  Future<HistoryPage> getHistory(
    String channelId, {
    String? before,
    String? after,
    int limit = 50,
  }) => _authedCall(() async {
    final r = await _authed.get(
      '/v1/channels/$channelId/messages',
      queryParameters: {'before': ?before, 'after': ?after, 'limit': limit},
    );
    final data = _map(r.data);
    final list = (data['messages'] as List?) ?? const [];
    final items = <HistoryItem>[];
    for (final e in list) {
      if (e is! Map) continue; // non-object row → skip; can't carry a cursor id
      final m = e.cast<String, dynamic>();
      // Heterogeneous since island #104. Message items historically carried NO
      // `type` (the fanout body is untyped); the history serializer now wraps them
      // as {"type":"message"}. Treat absent-type AND "message" as a message.
      // A retraction is a flat {type, id, target_msg_id, channel_id}. Any OTHER
      // (future) type is carried as an INERT UnknownHistoryItem bearing its id —
      // NOT dropped: the recast's premise is one forward stream that will grow item
      // types (edits, reactions), and the pager advances the watermark through
      // `items.last.id`, so a DROPPED unknown that trails the last known row (or a
      // page of only unknowns) would stall/wedge catch-up at the fence (cage-match
      // Carnot HIGH, PR #102). Carrying it inertly keeps the cursor monotonic
      // across schema evolution. (Re-strike D7-A2 + Carnot.)
      switch (m['type']) {
        case null:
        case 'message':
          // A malformed message row (Map, message-typed, but missing/ill-typed
          // fields) still throws in Message.fromView and aborts the page — the
          // SAME pre-existing behavior as before this PR (the reconnect treats the
          // throw as transient and retries). This parser widens the KNOWN types; it
          // does not change message-row robustness.
          items.add(MessageHistoryItem(Message.fromView(m)));
        case 'retraction':
          final rid = m['id'];
          final target = m['target_msg_id'];
          if (rid is String && target is String) {
            items.add(
              RetractionHistoryItem(
                Retraction(
                  channelId: (m['channel_id'] as String?) ?? channelId,
                  id: rid,
                  targetMsgId: target,
                ),
              ),
            );
          } else {
            // FAIL-CLOSED on a malformed KNOWN retraction (cage-match Tesla HIGH).
            // A retraction is a safety frame, NOT a forward-compat unknown: do NOT
            // salvage it as an inert cursor-bearer, because advancing the watermark
            // past a takedown that never applied is a SILENT MODERATION LEAK (the
            // target stays visible forever, never re-walked). Throw instead — the
            // same family as a malformed message row (Message.fromView throws): the
            // page fails, the reconnect retries, and a persistent malformation
            // wedges catch-up LOUDLY via reconnectFailed telemetry rather than
            // dropping a takedown. Never claim coverage over an unapplied retraction.
            throw FormatException('malformed retraction history item: $m');
          }
        default:
          // Unknown future item type → carry it INERT with its id so the watermark
          // advances through it (see the switch-level comment). An unknown with no
          // recognizable id field (neither `id` nor `msg_id`) is the one residual
          // that must be dropped — there is nothing to advance the cursor to. That
          // is far narrower than dropping every unknown, and island events carry an
          // `id`, so this residual is not expected to fire.
          final uid = m['id'] ?? m['msg_id'];
          if (uid is String) items.add(UnknownHistoryItem(uid));
      }
    }
    return HistoryPage(
      channelId: channelId,
      items: items,
      nextBefore: data['next_before'] as String?,
      nextAfter: data['next_after'] as String?,
    );
  });

  @override
  Future<void> blockUser(String userId) =>
      _authedCall(() => _authed.post('/v1/users/$userId/block'));

  @override
  Future<void> unblockUser(String userId) =>
      _authedCall(() => _authed.delete('/v1/users/$userId/block'));

  @override
  Future<List<BlockedUser>> listBlocks() => _authedCall(() async {
    final r = await _authed.get('/v1/blocks');
    final list = (_map(r.data)['blocks'] as List?) ?? const [];
    return list
        .map((e) => BlockedUser.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  });

  @override
  Future<void> reportMessage(String messageId, ReportReason reason) =>
      _authedCall(
        () => _authed.post(
          '/v1/messages/$messageId/report',
          data: {'reason': reason.wire},
        ),
      );

  // --- operator / moderator actions (#33/#35) --------------------------------
  // All ModeratorUser-gated → a stale-flag caller gets 403 → Forbidden (A3), not
  // a logout. `_authedCall` performs that mapping; the operator controller
  // catches Forbidden to refresh /me.

  @override
  // KNOWN CEILING (cage-match Tesla): a single unpaginated GET. The island caps
  // the page server-side (limit default 100, max 500) and only status=pending is
  // served, so the queue is bounded by policy today; if an island ever grows a
  // long pending backlog, cursor pagination (island #44) is the follow-up.
  Future<List<PendingReport>> listPendingReports() => _authedCall(() async {
    final r = await _authed.get(
      '/v1/reports',
      queryParameters: {'status': 'pending'},
    );
    final list = (_map(r.data)['reports'] as List?) ?? const [];
    // Per-row isolation (cage-match Tesla round 4): a single malformed row must
    // not fail the WHOLE triage queue — fail-loud on a row's identity (strict ids
    // in PendingReport.fromJson), fail-closed on the fleet (skip the bad row, keep
    // the N-1 actionable reports the moderator can still work).
    final out = <PendingReport>[];
    var dropped = 0;
    for (final e in list) {
      try {
        out.add(PendingReport.fromJson((e as Map).cast<String, dynamic>()));
      } catch (_) {
        // Skip this row; the rest of the queue remains actionable.
        dropped++;
      }
    }
    // Don't skip DARKLY (cage-match Tesla round 5): a poisoned field silently
    // shrinking the queue must leave a signal, or "queue looks short" reads as
    // "queue is clear" with no operator/on-call breadcrumb. (dev-only; a real
    // telemetry sink is the follow-up if the island ever emits malformed rows.)
    if (dropped > 0) {
      debugPrint(
        'listPendingReports: dropped $dropped malformed report row(s) of '
        '${list.length}',
      );
    }
    return out;
  });

  @override
  Future<void> resolveReport(String reportId) =>
      _authedCall(() => _authed.post('/v1/reports/$reportId/resolve'));

  @override
  Future<void> dismissReport(String reportId) =>
      _authedCall(() => _authed.post('/v1/reports/$reportId/dismiss'));

  @override
  Future<void> banUser(String userId) =>
      _authedCall(() => _authed.post('/v1/users/$userId/ban'));

  /// Run an authed request, translating a rejection into a domain exception so
  /// callers (the reconcile engine) classify it without importing `dio`. The
  /// status taxonomy: a *terminal* authN failure — a 401 that survived
  /// [AuthInterceptor]'s single-flight refresh-and-retry — becomes [Unauthorized]
  /// (→ logout); the ban body becomes [AccountSuspended]; a plain (non-suspended)
  /// 403 is an authoriZation denial and becomes [Forbidden] (session stays valid,
  /// the caller handles it — NOT a logout). Transient errors (network/timeout/5xx)
  /// and any non-Dio error propagate unchanged: they must NOT be read as a logout
  /// (design 02 — a network blip is not an auth failure).
  static Future<T> _authedCall<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      // A 401 forwarded after a TRANSIENT refresh failure carries the
      // `auth_transient` marker (set by AuthInterceptor) — it is NOT terminal,
      // so propagate it as-is (B4 leaves rows `sending` for redrain). A 401 that
      // survived refresh-and-retry is a terminal `Unauthorized` (authN failed).
      final transient = e.requestOptions.extra['auth_transient'] == true;
      final code = e.response?.statusCode;
      // A ban surfaces here first: the interceptor only refreshes on 401, so a
      // live 403 flows straight through. Branch it BEFORE the generic mapping so
      // the reconcile drain routes it as suspended, not "session expired."
      if (!transient && _isSuspended(e)) throw const AccountSuspended();
      if (!transient && code == 401) throw Unauthorized(code);
      // A non-suspended 403 is authoriZation, not authentication: the session is
      // valid, THIS action is denied. Mapping it to terminal `Unauthorized` would
      // log the user out on a mere permission denial (e.g. an operator hitting a
      // moderator endpoint with a stale flag). Route it to the domain `Forbidden`
      // so the caller reacts locally instead of the reconcile drain logging out.
      if (!transient && code == 403) throw Forbidden(e.requestOptions.path);
      rethrow;
    }
  }

  static Map<String, dynamic> _map(Object? data) =>
      (data as Map).cast<String, dynamic>();
}

/// Wires the gateway backend: a bare client (for refresh/login), a token
/// provider whose refresh uses that bare client, and an authed client whose
/// interceptor uses the provider. One-directional — no provider cycle.
({ChatRestApi api, DefaultTokenProvider tokens}) buildGatewayBackend({
  required String baseUrl,
  required SecureTokenStore store,
  void Function()? onUnauthenticated,
}) {
  final bare = Dio(BaseOptions(baseUrl: baseUrl));
  final tokens = DefaultTokenProvider(
    store: store,
    onUnauthenticated: onUnauthenticated,
    remoteRefresh: (rt) async {
      try {
        final r = await bare.post(
          '/v1/auth/refresh',
          data: {'refresh_token': rt},
        );
        return ((r.data as Map).cast<String, dynamic>())['access_token']
            as String;
      } on DioException catch (e) {
        final code = e.response?.statusCode;
        if (code == 401 || code == 403) throw const RefreshRejected();
        rethrow; // network/timeout/5xx -> transient
      }
    },
  );
  final authed = Dio(BaseOptions(baseUrl: baseUrl));
  authed.interceptors.add(AuthInterceptor(tokens, authed));
  return (api: GatewayRestApi(bare: bare, authed: authed), tokens: tokens);
}
