import '../domain/gateway_capabilities.dart';

/// Transitional allowlist of hosts KNOWN to carry the sovereign `origin`
/// envelope, used ONLY while the island's `GET /capabilities` endpoint is not
/// yet deployed (it 404s on prod as of 2026-07-26). It exists so shipping the
/// capability gate does not regress the live round-trip against the one carriage
/// island whose `/capabilities` still 404s.
///
/// Once `/capabilities` is live on every island this list becomes dead code and
/// should be deleted — the endpoint is then authoritative. See task #1896.
const kKnownCarriageHosts = {'chat.imagineering.cc'};

/// Holds the "does the CURRENT gateway carry `origin`?" decision that the
/// transport's emit gate reads synchronously on every send.
///
/// Resolution order (task #1896):
///  1. If `GET /capabilities` answered, its `carriage.origin` is authoritative
///     (it can turn a known host OFF, or a stranger ON).
///  2. If it 404'd / was unreachable (endpoint not deployed yet), fall back to
///     the [kKnownCarriageHosts] allowlist for this host.
///
/// The fallback NEVER flips a working carriage host OFF: the initial value is
/// already the allowlist answer, and a failed [refresh] leaves it intact. So
/// chat.imagineering.cc (which 404s `/capabilities`) keeps emitting `origin`,
/// while a brand-new non-allowlisted island stays origin-OFF until it *proves*
/// carriage. Fail-closed for strangers, no-regression for the known host.
class CarriageCapability {
  final Future<GatewayCapabilities?> Function() _fetch;
  final void Function(String message)? _log;
  bool _carriesOrigin;

  CarriageCapability({
    required String host,
    required Future<GatewayCapabilities?> Function() fetch,
    Set<String> knownCarriageHosts = kKnownCarriageHosts,
    void Function(String message)? log,
  })  : _fetch = fetch,
        _log = log,
        // Normalize before the allowlist match so a case/trailing-dot variant of
        // the known host doesn't silently seed false and drop origin against the
        // one island that still 404s (cage-match Tesla). Uri.host already
        // lowercases, but this is the single door for the match, so normalize
        // here regardless of how the caller derived `host`.
        _carriesOrigin =
            knownCarriageHosts.contains(_normalizeHost(host));

  static String _normalizeHost(String host) {
    var h = host.toLowerCase();
    if (h.endsWith('.')) h = h.substring(0, h.length - 1); // strip FQDN root dot
    return h;
  }

  /// The synchronous gate the transport reads per-send.
  bool get carriesOrigin => _carriesOrigin;

  /// Re-resolve from the live endpoint; called on every (re)connect. A null
  /// result (404 / unreachable) or a thrown error KEEPS the current
  /// (allowlist-seeded) value — never a regression to origin-off for a host that
  /// was carrying.
  Future<void> refresh() async {
    try {
      final caps = await _fetch();
      if (caps != null) _carriesOrigin = caps.carriesOrigin;
    } catch (e) {
      _log?.call(
          'capabilities refresh failed, keeping carriage=$_carriesOrigin: $e');
    }
  }
}
