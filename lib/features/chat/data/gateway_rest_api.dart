import 'package:dio/dio.dart';

import '../../auth/domain/auth_models.dart';
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
      handler.next(err); // transient refresh failure -> surface original error
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
  /// Token-less client for unauthenticated endpoints (login/register/refresh).
  final Dio _bare;

  /// Interceptor-wrapped client for authed endpoints (me/channels/history).
  final Dio _authed;

  GatewayRestApi({required Dio bare, required Dio authed})
      : _bare = bare,
        _authed = authed;

  @override
  Future<AuthSession> login(String username, String password) async {
    final r = await _bare.post('/v1/auth/login',
        data: {'username': username, 'password': password});
    return AuthSession.fromJson(_map(r.data));
  }

  @override
  Future<AuthSession> register(
      String username, String displayName, String password) async {
    final r = await _bare.post('/v1/auth/register', data: {
      'username': username,
      'display_name': displayName,
      'password': password,
    });
    return AuthSession.fromJson(_map(r.data));
  }

  @override
  Future<String> refresh(String refreshToken) async {
    final r = await _bare
        .post('/v1/auth/refresh', data: {'refresh_token': refreshToken});
    return _map(r.data)['access_token'] as String;
  }

  @override
  Future<AppUser> me() async {
    final r = await _authed.get('/v1/me');
    return AppUser.fromJson(_map(r.data));
  }

  @override
  Future<List<Channel>> listChannels() async {
    final r = await _authed.get('/v1/channels');
    final list = (_map(r.data)['channels'] as List?) ?? const [];
    return list
        .map((e) => Channel.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  @override
  Future<HistoryPage> getHistory(String channelId,
      {String? before, int limit = 50}) async {
    final r = await _authed.get(
      '/v1/channels/$channelId/messages',
      queryParameters: {
        'before': ?before,
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
    );
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
