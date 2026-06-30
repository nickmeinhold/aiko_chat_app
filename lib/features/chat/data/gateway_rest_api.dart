import 'dart:convert';

import 'package:dio/dio.dart';

import '../../auth/data/social_auth_client.dart';
import '../../auth/domain/auth_models.dart';
import '../../auth/domain/auth_provider.dart';
import '../../auth/domain/social_models.dart';
import '../../moderation/domain/moderation_models.dart';
import '../../../core/auth/token_provider.dart';
import '../../../services/secure_token_store.dart';
import '../domain/channel.dart';
import '../domain/message.dart';
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
      RequestOptions options, RequestInterceptorHandler handler) async {
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
  /// Token-less client for unauthenticated endpoints (social/claim/refresh).
  final Dio _bare;

  /// Interceptor-wrapped client for authed endpoints (me/channels/history).
  final Dio _authed;

  GatewayRestApi({required Dio bare, required Dio authed})
      : _bare = bare,
        _authed = authed;

  @override
  Future<String> refresh(String refreshToken) async {
    final r = await _bare
        .post('/v1/auth/refresh', data: {'refresh_token': refreshToken});
    return _map(r.data)['access_token'] as String;
  }

  @override
  Future<SocialOutcome> socialSignIn({
    required SocialProvider provider,
    required String idToken,
    required String rawNonce,
    String? name,
  }) async {
    final r = await _bare.post('/v1/auth/social', data: {
      'provider': provider.name, // 'apple' | 'google'
      'id_token': idToken,
      'nonce': rawNonce,
      if (name != null) 'name': name,
    });
    return _resolveOutcome(_map(r.data));
  }

  @override
  Future<List<AuthProviderInfo>> listAuthProviders() async {
    final r = await _bare.get('/v1/auth/providers');
    final raw = (_map(r.data)['providers'] as List?) ?? const [];
    return raw
        .cast<Map>()
        .map((e) => AuthProviderInfo.tryParse(e.cast<String, dynamic>()))
        // Drop provider kinds this build doesn't understand (fail-closed).
        .whereType<AuthProviderInfo>()
        .toList(growable: false);
  }

  @override
  Future<SocialOutcome> exchangeOAuth(String code, String verifier) async {
    // Same single-door response shape as /social — known identity → tokens, new
    // identity → provisioning_token. Reuse the exact resolver so the broker and
    // native paths can never diverge on how they read the outcome. The
    // app_verifier binds this redemption to the app that started the flow.
    final r = await _bare.post('/v1/auth/oauth/exchange',
        data: {'code': code, 'app_verifier': verifier});
    return _resolveOutcome(_map(r.data));
  }

  @override
  Future<PasskeyChallenge> startPasskeyRegistration() =>
      _passkeyStart('/v1/auth/passkey/register/start');

  @override
  Future<SocialOutcome> finishPasskeyRegistration(
          String state, String credentialJson) =>
      _passkeyFinish('/v1/auth/passkey/register/finish', state, credentialJson);

  @override
  Future<PasskeyChallenge> startPasskeyAuthentication() =>
      _passkeyStart('/v1/auth/passkey/authenticate/start');

  @override
  Future<SocialOutcome> finishPasskeyAuthentication(
          String state, String credentialJson) =>
      _passkeyFinish(
          '/v1/auth/passkey/authenticate/finish', state, credentialJson);

  /// Begin a passkey ceremony: the gateway returns `{state, options}` where
  /// `options` is the WebAuthn options object. We re-encode `options` to the
  /// opaque JSON string the device authenticator consumes, and carry `state`
  /// untouched to the `finish` call (server-side challenge binding).
  Future<PasskeyChallenge> _passkeyStart(String path) async {
    final r = await _bare.post(path);
    final m = _map(r.data);
    final options = m['options'];
    final state = m['state'];
    if (options is! Map || state is! String) {
      throw const FormatException(
          'passkey: start response missing state/options');
    }
    return (state: state, optionsJson: jsonEncode(options));
  }

  /// Complete a passkey ceremony: POST the device's response [credentialJson]
  /// (WebAuthn JSON the authenticator produced) plus the binding [state], and
  /// route the gateway's identity response through the SAME single-door resolver
  /// as native/broker — passkeys can never diverge on how the outcome is read.
  Future<SocialOutcome> _passkeyFinish(
      String path, String state, String credentialJson) async {
    final Object? credential;
    try {
      credential = jsonDecode(credentialJson);
    } on FormatException catch (e) {
      // The authenticator's own toJsonString is the producer, so a decode
      // failure here is client-plumbing corruption, not a server rejection.
      // Tag it (like the start path) so it doesn't read as a generic auth fail.
      throw FormatException(
          'passkey: finish received malformed credential JSON from the '
          'authenticator: ${e.message}');
    }
    final r = await _bare.post(path, data: {
      'state': state,
      'credential': credential,
    });
    return _resolveOutcome(_map(r.data));
  }

  /// Resolve the gateway's identity response (from /social OR /oauth/exchange)
  /// into a [SocialOutcome]. Route on the PRIMARY signal — a provisioning_token
  /// (or explicit status:pending) — not the mere ABSENCE of an access_token, so a
  /// malformed authenticated response fails loudly instead of casting a null
  /// provisioning_token (cage-match consensus: Maxwell/Kelvin/Carnot).
  SocialOutcome _resolveOutcome(Map<String, dynamic> m) {
    final ptok = m['provisioning_token'];
    if (m['status'] == 'pending' || ptok != null) {
      if (ptok is! String) {
        throw const FormatException(
            'auth: pending response missing provisioning_token');
      }
      return PendingHandle(
        provisioningToken: ptok,
        suggestedName: m['suggested_name'] as String?,
        email: m['email'] as String?,
      );
    }
    if (m['access_token'] == null) {
      throw const FormatException(
          'auth: response has neither access_token nor provisioning_token');
    }
    return Authenticated(AuthSession.fromJson(m));
  }

  @override
  Future<AuthSession> claimHandle({
    required String provisioningToken,
    required String handle,
    required String displayName,
  }) async {
    try {
      final r = await _bare.post('/v1/auth/social/claim', data: {
        'provisioning_token': provisioningToken,
        'handle': handle,
        'display_name': displayName,
      });
      return AuthSession.fromJson(_map(r.data));
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) throw const HandleTaken();
      rethrow;
    }
  }

  @override
  Future<AppUser> me() => _authedCall(() async {
        final r = await _authed.get('/v1/me');
        return AppUser.fromJson(_map(r.data));
      });

  @override
  Future<void> deleteAccount() async {
    try {
      await _authedCall(() => _authed.delete('/v1/account'));
    } on DioException catch (e) {
      // _authedCall already mapped a terminal 401/403 → Unauthorized and
      // rethrew everything else. A 409 means "sole admin of a channel" — map it
      // to the typed domain error carrying the gateway's explanatory `detail`.
      if (e.response?.statusCode == 409) {
        final detail = (e.response?.data is Map)
            ? (e.response!.data as Map)['detail']?.toString()
            : null;
        throw SoleAdminDeletionBlocked(
            detail ?? 'You are the sole admin of a channel.');
      }
      rethrow;
    }
  }

  @override
  Future<List<Channel>> listChannels() => _authedCall(() async {
        final r = await _authed.get('/v1/channels');
        final list = (_map(r.data)['channels'] as List?) ?? const [];
        return list
            .map((e) => Channel.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
      });

  @override
  Future<HistoryPage> getHistory(String channelId,
          {String? before, String? after, int limit = 50}) =>
      _authedCall(() async {
        final r = await _authed.get(
          '/v1/channels/$channelId/messages',
          queryParameters: {
            'before': ?before,
            'after': ?after,
            'limit': limit,
          },
        );
        final data = _map(r.data);
        final list = (data['messages'] as List?) ?? const [];
        return HistoryPage(
          channelId: channelId,
          messages: list
              .map((e) => Message.fromView((e as Map).cast<String, dynamic>()))
              .toList(),
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
      _authedCall(() => _authed.post('/v1/messages/$messageId/report',
          data: {'reason': reason.wire}));

  /// Run an authed request, translating a *terminal* auth rejection — a 401 that
  /// survived [AuthInterceptor]'s single-flight refresh-and-retry, or a 403 —
  /// into the domain [Unauthorized], so callers (the reconcile engine) classify
  /// it without importing `dio`. Transient errors (network/timeout/5xx) and any
  /// non-Dio error propagate unchanged: they must NOT be read as a logout
  /// (design 02 — a network blip is not an auth failure).
  static Future<T> _authedCall<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      // A 401 forwarded after a TRANSIENT refresh failure carries the
      // `auth_transient` marker (set by AuthInterceptor) — it is NOT terminal,
      // so propagate it as-is (B4 leaves rows `sending` for redrain). Only a
      // genuinely terminal rejection — a 401 that survived refresh-and-retry, or
      // a 403 — becomes the domain `Unauthorized`.
      final transient = e.requestOptions.extra['auth_transient'] == true;
      final code = e.response?.statusCode;
      if (!transient && (code == 401 || code == 403)) throw Unauthorized(code);
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
        final r =
            await bare.post('/v1/auth/refresh', data: {'refresh_token': rt});
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
