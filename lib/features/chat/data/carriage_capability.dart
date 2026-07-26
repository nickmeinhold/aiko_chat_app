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
/// **Two inputs, three outcomes.** The endpoint is authoritative when it gives
/// an explicit answer; the allowlist is the fallback for every "unknown":
///  1. `GET /capabilities` returns an explicit bool (`GatewayCapabilities.parse`
///     → non-null) → use it (it can turn a known host OFF, or a stranger ON).
///  2. Anything else — 404, unreachable, a thrown error, or a stub/partial/
///     malformed 200 (parse → null) → **fall back to the allowlist seed for
///     this host.** Unknown always resolves to the seed, never to a sticky prior
///     value.
///
/// The allowlist is a live fallback, not merely a construction-time seed
/// (cage-match Tesla + Carnot). That matters two ways: an allowlisted host that
/// briefly emits an explicit `false` (canary/misdeploy) and then goes back to
/// 404 re-resolves to ON — no permanent sovereignty-off; and a stranger that
/// proved carriage and then loses its endpoint re-resolves to OFF — fail-closed,
/// never a lingering emit that an island would `bad_origin`-drop. A malformed
/// 200 is treated as unknown (not an authoritative false) on purpose: reading it
/// as false would flip an allowlisted, already-carrying host off during the
/// island's `/capabilities` rollout — the exact no-regression break this design
/// exists to prevent. Fail-closed lives in the DECODE (only `== true` enables)
/// and in the stranger SEED (unknown → false for a non-allowlisted host).
class CarriageCapability {
  final Future<GatewayCapabilities?> Function() _fetch;
  final void Function(String message)? _log;

  /// The allowlist answer for this host — the value every "unknown" resolves to.
  final bool _seed;
  bool _carriesOrigin;

  CarriageCapability({
    required String host,
    required Future<GatewayCapabilities?> Function() fetch,
    Set<String> knownCarriageHosts = kKnownCarriageHosts,
    void Function(String message)? log,
  })  : _fetch = fetch,
        _log = log,
        // Normalize BOTH sides of the match (cage-match Carnot): the input host
        // and every allowlist entry, so a case/trailing-dot variant on either
        // side can't silently seed false against the one island that 404s.
        _seed = knownCarriageHosts
            .map(_normalizeHost)
            .contains(_normalizeHost(host)),
        _carriesOrigin = knownCarriageHosts
            .map(_normalizeHost)
            .contains(_normalizeHost(host));

  static String _normalizeHost(String host) {
    var h = host.trim().toLowerCase();
    while (h.endsWith('.')) {
      h = h.substring(0, h.length - 1); // strip any trailing FQDN root dot(s)
    }
    return h;
  }

  /// The synchronous gate the transport reads per-send.
  bool get carriesOrigin => _carriesOrigin;

  /// Re-resolve from the live endpoint; called on every (re)connect.
  ///
  /// An EXPLICIT bool from the endpoint (`parse` → non-null) is authoritative.
  /// Every "unknown" answer — 404, unreachable, a thrown error, or a
  /// stub/partial/malformed 200 (parse → null) — re-resolves to the allowlist
  /// [_seed], so the allowlist is a live fallback rather than a one-shot seed
  /// (cage-match Tesla + Carnot: no sticky OFF after a transient explicit false,
  /// no sticky ON for a stranger whose endpoint went dark).
  Future<void> refresh() async {
    try {
      final caps = await _fetch();
      _carriesOrigin = caps?.carriesOrigin ?? _seed;
      _log?.call(caps != null
          ? 'carriage=${caps.carriesOrigin} (endpoint authoritative)'
          : 'carriage=$_seed (unknown → allowlist seed)');
    } catch (e) {
      // Belt-and-braces: the production fetch (GatewayRestApi.getCapabilities)
      // catches all transport errors and returns null, so a transient DNS/
      // timeout arrives at the null branch above, NOT here — this catch only
      // fires for an injected/future fetch that itself throws. Either way the
      // resolution is the same: unknown → seed. That is deliberately fail-closed
      // over keep-prior, because if the gateway has silently stopped carrying,
      // keeping emit ON causes a `bad_origin` DROP (data loss), which is strictly
      // worse than the unsigned-but-delivered message a re-seed-to-false yields.
      _carriesOrigin = _seed;
      _log?.call('carriage refresh failed, resolved to seed=$_seed: $e');
    }
  }
}
