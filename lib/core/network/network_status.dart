/// The unified, streaming network-status signal the UI shows the user.
///
/// Two truths, not one (the DNS failure that birthed this — PR #71 — proved you
/// need both): the DEVICE being on a network (`connectivity_plus`) is different
/// from the GATEWAY being reachable. On wifi-but-DNS-broken the device is
/// "online" yet nothing works; the honest indicator distinguishes them.
///
/// Sources, by auth state:
///  - device offline (no interface)            → [NetworkStatus.offline]
///  - logged IN: the live WSS socket is the free reachability probe
///      (`connectionStateProvider`): connected → online, else serverUnreachable
///  - logged OUT (login screen — no socket yet): an on-demand HTTP reachability
///      probe of the current gateway ([gatewayReachableProvider])
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../features/auth/application/auth_controller.dart';
import '../../features/chat/data/transport/chat_transport.dart';

enum NetworkStatus {
  /// Talking to the gateway (or, logged-out, the gateway is reachable). No banner.
  online,

  /// On a network, but the gateway can't be reached (the DNS/server-down case).
  serverUnreachable,

  /// No network interface at all.
  offline,
}

// --- device connectivity ----------------------------------------------------

/// Thin seam over `connectivity_plus` so tests can drive connectivity without a
/// platform channel. "Online" = at least one non-`none` interface — note this is
/// interface presence, NOT true reachability (a captive portal reads online),
/// which is exactly why the gateway probe / socket state is layered on top.
abstract interface class ConnectivityService {
  Future<bool> isOnline();
  Stream<bool> get onlineChanges;
}

class PlatformConnectivityService implements ConnectivityService {
  final Connectivity _c;
  PlatformConnectivityService([Connectivity? c]) : _c = c ?? Connectivity();

  static bool _online(List<ConnectivityResult> r) =>
      r.any((x) => x != ConnectivityResult.none);

  @override
  Future<bool> isOnline() async => _online(await _c.checkConnectivity());

  @override
  Stream<bool> get onlineChanges => _c.onConnectivityChanged.map(_online);
}

final connectivityServiceProvider = Provider<ConnectivityService>(
  (ref) => PlatformConnectivityService(),
);

/// Live device-online stream: an immediate seed (so the first frame is truthful)
/// then every change. Distinct-collapsed so a no-op interface swap doesn't churn.
final deviceOnlineProvider = StreamProvider<bool>((ref) {
  final svc = ref.watch(connectivityServiceProvider);
  // Seed with the current value, then live changes; `.distinct()` so a wifi↔
  // cellular swap that stays "online" doesn't churn the gateway re-probe.
  Stream<bool> raw() async* {
    yield await svc.isOnline();
    yield* svc.onlineChanges;
  }

  return raw().distinct();
});

// --- gateway reachability (logged-out probe) --------------------------------

/// Probes whether the gateway answers AT ALL — any HTTP response (even 4xx)
/// proves reachability; a connection/DNS/timeout error means unreachable. Used
/// only pre-auth (logged in, the socket is the probe). Injectable so tests never
/// hit the network.
abstract interface class ReachabilityProbe {
  Future<bool> canReach(String httpBaseUrl);
}

class HttpReachabilityProbe implements ReachabilityProbe {
  @override
  Future<bool> canReach(String httpBaseUrl) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 4),
      // ANY status is "reachable" — we only care that the server answered.
      validateStatus: (_) => true,
    ));
    try {
      await dio.getUri(Uri.parse(httpBaseUrl));
      return true;
    } catch (_) {
      return false;
    } finally {
      dio.close();
    }
  }
}

final reachabilityProbeProvider = Provider<ReachabilityProbe>(
  (ref) => HttpReachabilityProbe(),
);

/// Whether the current gateway is reachable — a live STREAM, not a one-shot
/// sample: it re-probes on an interval so the (pre-auth) login banner CLEARS
/// when a downed gateway comes back, and re-runs immediately when device
/// connectivity flips. Short-circuits to `false` when the device is offline (no
/// point probing with no interface). `autoDispose` stops the loop when nothing
/// watches it (login screen unmounted). Cadence stays under the prompt-cache /
/// battery threshold — this only runs while the login screen is foregrounded.
final gatewayReachableProvider = StreamProvider.autoDispose<bool>((ref) async* {
  final online = ref.watch(deviceOnlineProvider).value ?? true;
  if (!online) {
    yield false;
    return;
  }
  final baseUrl = ref.watch(configProvider).httpBaseUrl;
  final probe = ref.watch(reachabilityProbeProvider);
  while (true) {
    yield await probe.canReach(baseUrl);
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

// --- unified status ---------------------------------------------------------

/// The derived, reactive status the banner renders. Defaults to [online]
/// (banner hidden) while any input is still loading, so startup never flashes a
/// false "unreachable" — the banner appears only once trouble is CONFIRMED.
final networkStatusProvider = Provider<NetworkStatus>((ref) {
  final online = ref.watch(deviceOnlineProvider).value ?? true;
  if (!online) return NetworkStatus.offline;

  final loggedIn = ref.watch(authControllerProvider).value != null;
  if (loggedIn) {
    // Only a DEFINITIVE drop is "trouble". `connecting` and the still-loading
    // (null) state are the normal connect/revalidate window — painting them
    // serverUnreachable would flash a false "can't reach" on every chat open
    // (Tesla, PR #72). `unauthenticated` is an auth signal, not a network one
    // (the controller turns it into a logout), so it shows no banner either.
    final conn = ref.watch(connectionStateProvider).value;
    return conn == ConnectionState.disconnected
        ? NetworkStatus.serverUnreachable
        : NetworkStatus.online;
  }

  final reachable = ref.watch(gatewayReachableProvider).value ?? true;
  return reachable ? NetworkStatus.online : NetworkStatus.serverUnreachable;
});
