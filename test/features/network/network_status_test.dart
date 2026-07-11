import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/network/network_status.dart';
import 'package:aiko_chat_app/core/network/network_status_banner.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/transport/chat_transport.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The derived, three-state network status (offline / serverUnreachable /
/// online) picks the right reachability source per auth state, and the banner
/// shows only on trouble.
void main() {
  const user = AppUser(
      userId: 'u', username: 'n', displayName: 'N', aikoUsername: 'n');

  // Minimal auth override: skip the real build()'s listeners, just publish a
  // fixed logged-in/out value so networkStatusProvider can branch on it.
  ProviderContainer container({
    required bool deviceOnline,
    AppUser? loggedInUser,
    ConnectionState? socket,
    bool gatewayReachable = true,
  }) {
    return ProviderContainer(overrides: [
      deviceOnlineProvider.overrideWith((ref) => Stream.value(deviceOnline)),
      connectionStateProvider.overrideWith(
          (ref) => Stream.value(socket ?? ConnectionState.disconnected)),
      gatewayReachableProvider.overrideWith((ref) => Stream.value(gatewayReachable)),
      authControllerProvider.overrideWith(() => _FixedAuth(loggedInUser)),
    ]);
  }

  Future<NetworkStatus> status(ProviderContainer c) async {
    // Keep the async leaves alive and let them settle, then read the derived
    // status. (Awaiting each provider's `.future` proved flaky — Stream.value
    // subscriptions don't always resolve `.future` under the test container;
    // a listen + microtask drain reflects the settled values reliably.)
    c.listen(deviceOnlineProvider, (_, _) {}, fireImmediately: true);
    c.listen(authControllerProvider, (_, _) {}, fireImmediately: true);
    c.listen(gatewayReachableProvider, (_, _) {}, fireImmediately: true);
    c.listen(connectionStateProvider, (_, _) {}, fireImmediately: true);
    c.listen(networkStatusProvider, (_, _) {}, fireImmediately: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return c.read(networkStatusProvider);
  }

  test('device offline → offline (regardless of auth)', () async {
    final c = container(deviceOnline: false, loggedInUser: user);
    addTearDown(c.dispose);
    expect(await status(c), NetworkStatus.offline);
  });

  test('logged in + socket connected → online', () async {
    final c = container(
        deviceOnline: true,
        loggedInUser: user,
        socket: ConnectionState.connected);
    addTearDown(c.dispose);
    expect(await status(c), NetworkStatus.online);
  });

  test('logged in + socket DISCONNECTED → serverUnreachable', () async {
    final c = container(
        deviceOnline: true,
        loggedInUser: user,
        socket: ConnectionState.disconnected);
    addTearDown(c.dispose);
    expect(await status(c), NetworkStatus.serverUnreachable);
  });

  test('logged in + socket CONNECTING → online (no false-alarm flash)',
      () async {
    // The normal connect/revalidate window must NOT paint "can't reach" — that
    // was the PR #72 cage-match false-alarm hole (Tesla).
    final c = container(
        deviceOnline: true,
        loggedInUser: user,
        socket: ConnectionState.connecting);
    addTearDown(c.dispose);
    expect(await status(c), NetworkStatus.online);
  });

  test('logged in + socket UNAUTHENTICATED → online (auth signal, not network)',
      () async {
    final c = container(
        deviceOnline: true,
        loggedInUser: user,
        socket: ConnectionState.unauthenticated);
    addTearDown(c.dispose);
    expect(await status(c), NetworkStatus.online,
        reason: 'unauthenticated is a logout signal, not a network banner');
  });

  test('logged out + gateway reachable → online', () async {
    final c = container(deviceOnline: true, gatewayReachable: true);
    addTearDown(c.dispose);
    expect(await status(c), NetworkStatus.online);
  });

  test('logged out + gateway unreachable → serverUnreachable (the DNS case)',
      () async {
    final c = container(deviceOnline: true, gatewayReachable: false);
    addTearDown(c.dispose);
    expect(await status(c), NetworkStatus.serverUnreachable);
  });

  group('banner', () {
    Future<void> pump(WidgetTester t, NetworkStatus s) => t.pumpWidget(
          ProviderScope(
            overrides: [networkStatusProvider.overrideWithValue(s)],
            child: const MaterialApp(home: Scaffold(body: NetworkStatusBanner())),
          ),
        );

    testWidgets('online → nothing rendered', (t) async {
      await pump(t, NetworkStatus.online);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('offline → red offline text', (t) async {
      await pump(t, NetworkStatus.offline);
      expect(find.text("You're offline"), findsOneWidget);
    });

    testWidgets('serverUnreachable → amber cannot-reach text', (t) async {
      await pump(t, NetworkStatus.serverUnreachable);
      expect(find.text("Can't reach the server"), findsOneWidget);
    });
  });
}

class _FixedAuth extends AuthController {
  _FixedAuth(this._u);
  final AppUser? _u;
  @override
  Future<AppUser?> build() async => _u;
}
