/// A selectable gateway in the picker (#4).
///
/// Deliberately a flat value object (label + base URL) so the source of the list
/// can swap — from the hardcoded presets to the live discovery directory
/// (Design 05 §10, #36) — without touching the picker UI. The directory entry
/// carries a little more (id/description/region) for future grouping + display;
/// the picker only ever *needs* the label + URL, so those two stay required and
/// the rest are optional metadata.
library;

class ServerEntry {
  /// Human label shown in the picker, e.g. "Production".
  final String label;

  /// The gateway HTTP base URL, e.g. `https://chat.imagineering.cc`. Normalized
  /// at switch time via `GatewayConfig.normalized`.
  final String httpBaseUrl;

  /// Stable directory id/slug, when this entry came from the live directory.
  /// Null for the built-in presets. Not used for matching (we dedupe on the
  /// normalized URL, the thing that actually identifies a gateway) — carried for
  /// future grouping/telemetry.
  final String? id;

  /// Optional one-line description from the directory (e.g. "Imagineering's
  /// flagship island"). Null for presets; not rendered yet.
  final String? description;

  /// Optional region hint from the directory (e.g. "au"). Null for presets.
  final String? region;

  const ServerEntry({
    required this.label,
    required this.httpBaseUrl,
    this.id,
    this.description,
    this.region,
  });

  /// Tolerantly parse one directory entry. The cross-tab contract (#1548) is
  /// `{ id, name/display name, base URL, description?, region? }`, but the wire
  /// casing isn't pinned yet (the gateway is Python/SQLite → likely snake_case),
  /// so we accept the common spellings of each field. An entry with no usable
  /// base URL is unparseable — return null so the caller can skip it rather than
  /// surfacing a tile that points nowhere. A missing name falls back to the host,
  /// so a half-populated directory still renders something tappable.
  static ServerEntry? tryFromJson(Map<String, dynamic> json) {
    final url = _firstString(json, const ['base_url', 'baseUrl', 'httpBaseUrl', 'url']);
    if (url == null || url.trim().isEmpty) return null;
    final trimmed = url.trim();
    // The directory is attacker-influenceable content, and a preset/directory
    // tile bypasses the picker's custom-URL validation (it goes straight to
    // switchGateway). So hold each entry to the SAME bar as a typed URL: an
    // absolute http(s) URL with a host. A malformed entry is skipped, not
    // surfaced as a tile that points nowhere.
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    final name = _firstString(json, const ['name', 'display_name', 'displayName', 'label']) ??
        Uri.tryParse(trimmed)?.host ??
        trimmed;
    return ServerEntry(
      label: name,
      httpBaseUrl: trimmed,
      id: _firstString(json, const ['id', 'slug']),
      description: _firstString(json, const ['description', 'desc']),
      region: _firstString(json, const ['region']),
    );
  }

  /// First key in [keys] whose value is a non-empty string, else null.
  static String? _firstString(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final v = json[key];
      if (v is String && v.trim().isNotEmpty) return v;
    }
    return null;
  }

  /// Serialize for local persistence (the "islands I've met" seed store, #36).
  /// Deliberately written in the SAME snake_case wire shape [tryFromJson] reads,
  /// so a stored entry is re-hydrated through the exact same validating parser —
  /// a persisted base URL is attacker-influenceable (it came from a directory
  /// response) and must clear the same http(s)+host bar as a freshly-fetched one.
  Map<String, dynamic> toJson() => {
        'base_url': httpBaseUrl,
        'display_name': label,
        if (id != null) 'id': id,
        if (description != null) 'description': description,
        if (region != null) 'region': region,
      };
}

/// The built-in seeds — the always-present bootstrap source for the picker list,
/// AND the seed-first fallback when the live directory is unreachable/unset (#36).
///
/// MULTIPLE real internet islands are bundled (not just one), so bootstrap
/// discovery survives any single one being down — the irreducible chicken-egg
/// of a federated network (cf. BitTorrent DHT bootstrap nodes, a Mastodon
/// server pick). Every island serves the FULL peer directory from `/v1/gateways`,
/// so reaching ANY one of these teaches the app about all the others; the
/// ever-seen set is then persisted and grows (see the seed store), so these are
/// only the cold-start floor, not the ceiling.
///
/// Production is first so the common case (point at the live server) is one tap.
/// Local and the Android-emulator loopback cover dev against a gateway on the
/// host machine — entries no remote directory advertises, so they stay bundled
/// regardless of what the directory returns (the merge dedups any overlap on the
/// normalized base URL, so bundling an island the directory also lists is safe).
const kGatewayPresets = <ServerEntry>[
  ServerEntry(label: 'Production', httpBaseUrl: 'https://chat.imagineering.cc'),
  ServerEntry(label: 'Enspyr', httpBaseUrl: 'https://chat.enspyr.co'),
  ServerEntry(label: 'Local', httpBaseUrl: 'http://localhost:8095'),
  ServerEntry(
      label: 'Android emulator', httpBaseUrl: 'http://10.0.2.2:8095'),
];
