/// How a direct call actually connected — the instrument that decides whether
/// the SFU is a FALLBACK or a DELETION.
///
/// ## The question this exists to answer
///
/// If 1:1 media moves to a direct path (claude-tasks#3740), some calls will
/// still fail to form one — symmetric NAT, corporate firewalls — and must fall
/// back to a relay. The whole fallback-vs-deletion argument turns on **what
/// fraction**, and nobody has that number for aiko's actual users. Published
/// WebRTC figures are a fact about somebody else's population.
///
/// So this is built now, before the first real direct call, rather than bolted
/// on after someone asks. It is a handful of lines and it is the difference
/// between deciding that question with evidence and deciding it with a
/// recollection.
///
/// ## Gathered candidates are NOT the answer; the selected pair is
///
/// A peer gathers `host`, `srflx` and `relay` candidates more or less always —
/// gathering a relay candidate says only that a TURN server was configured, not
/// that anything used it. **The fact that decides the question is which pair the
/// connection actually nominated**, which lives in `getStats()`, not in the
/// candidates that went over the wire.
///
/// Both are recorded because they answer different questions ([gathered] is
/// cheap, always available, and tells you the *options*; [selected] is the
/// outcome), and because a tally that conflated them would report "relay used"
/// on every call and be silently, confidently wrong — a reading independent of
/// the thing it measures.
library;

/// The four ICE candidate types, as they appear in the `typ` token of a
/// candidate line and in the `candidateType` stat.
///
/// A closed set gets an enum: this drives a decision, and a stringly-typed
/// version would let a typo read as "no relay used" forever.
enum IceCandidateType {
  /// A local interface address. Both peers on the same LAN, or a VPN.
  host('host'),

  /// Server-reflexive — the peer's public address as seen by STUN. The ordinary
  /// successful direct path across the internet.
  srflx('srflx'),

  /// Peer-reflexive — learned from an incoming check rather than from STUN.
  prflx('prflx'),

  /// Relayed through TURN. **This is the fallback**, and the count of these over
  /// real calls is the number the SFU decision needs.
  relay('relay');

  const IceCandidateType(this.wireName);

  /// The token as it appears in SDP and in the `candidateType` stat. Display and
  /// parsing both key off this; the enum is the identity.
  final String wireName;

  /// Parse a `typ` token. Returns null for anything unrecognised rather than
  /// guessing — an unknown type must not be silently counted as a known one.
  static IceCandidateType? parse(String? token) {
    if (token == null) return null;
    for (final t in IceCandidateType.values) {
      if (t.wireName == token) return t;
    }
    return null;
  }
}

/// Extracts the `typ` token from a raw ICE candidate line.
///
/// A candidate line is space-delimited with `typ <type>` somewhere after the
/// first six fields, e.g.
/// `candidate:1 1 udp 2122260223 192.168.1.5 51234 typ host generation 0`.
///
/// Parsed positionally off the `typ` keyword rather than by a fixed index,
/// because the trailing extension fields vary by browser/stack and a fixed index
/// would read the wrong token on some of them.
IceCandidateType? iceTypeOfCandidateLine(String candidate) {
  final parts = candidate.split(' ');
  for (var i = 0; i + 1 < parts.length; i++) {
    if (parts[i] == 'typ') return IceCandidateType.parse(parts[i + 1]);
  }
  return null;
}

/// What one call's connectivity looked like.
class IceCandidateTally {
  IceCandidateTally();

  final Map<IceCandidateType, int> _gatheredLocal = {};
  final Map<IceCandidateType, int> _gatheredRemote = {};

  /// Candidate lines that arrived but carried no recognisable `typ`. Counted
  /// rather than dropped: a nonzero value here means the parser is behind the
  /// stack, and a silently-dropped candidate would make the tally quietly
  /// under-report.
  int unparsed = 0;

  /// The types of the pair the connection actually nominated, once known.
  /// Null until [recordSelectedPair] runs — and **null is not "no relay"**, it
  /// is "not yet measured". Callers must not collapse the two.
  IceCandidateType? selectedLocal;
  IceCandidateType? selectedRemote;

  Map<IceCandidateType, int> get gatheredLocal => Map.unmodifiable(_gatheredLocal);
  Map<IceCandidateType, int> get gatheredRemote =>
      Map.unmodifiable(_gatheredRemote);

  void recordLocalCandidate(String candidateLine) =>
      _record(_gatheredLocal, candidateLine);

  void recordRemoteCandidate(String candidateLine) =>
      _record(_gatheredRemote, candidateLine);

  void _record(Map<IceCandidateType, int> into, String line) {
    final t = iceTypeOfCandidateLine(line);
    if (t == null) {
      unparsed++;
      return;
    }
    into[t] = (into[t] ?? 0) + 1;
  }

  /// Record the nominated pair, from `RTCPeerConnection.getStats()`.
  ///
  /// [stats] is the raw report as a list of `{id, type, ...}` maps — passed in
  /// rather than fetched here so this class stays platform-free and directly
  /// testable without a live PeerConnection. The shape follows the W3C stats
  /// spec: a `candidate-pair` names its endpoints by id, and the ids resolve to
  /// `local-candidate` / `remote-candidate` entries carrying `candidateType`.
  ///
  /// ## Which pair counts, and why the obvious rule was wrong
  ///
  /// An earlier version took *the first pair that was nominated OR succeeded*,
  /// breaking on the first nominated one. Two independent reviewers (Carnot,
  /// Tesla) killed it: **stats order is not ICE priority.** `nominated == true`
  /// on a pair whose `state` is `in-progress` or `failed` would win outright,
  /// and where a stack never sets `nominated` — the case the OR existed for —
  /// the winner was whichever succeeded pair the map happened to enumerate
  /// first. Multiple succeeded pairs are ordinary (several m-lines, or an ICE
  /// restart). That produces a confidently wrong *fraction*, which is worse than
  /// a noisy one, on the exact number an architecture decision turns on.
  ///
  /// The rule now: **`state == 'succeeded'` is mandatory** — a pair that did not
  /// succeed carried nothing. Among those, a `nominated` one wins; ties break on
  /// bytes carried, because the pair that moved the most media is the pair that
  /// was the call. No succeeded pair at all leaves the tally unmeasured.
  void recordSelectedPair(List<Map<String, dynamic>> stats) {
    num bytesOf(Map<String, dynamic> s) =>
        (s['bytesSent'] as num? ?? 0) + (s['bytesReceived'] as num? ?? 0);

    Map<String, dynamic>? best;
    for (final s in stats) {
      if (s['type'] != 'candidate-pair') continue;
      if (s['state'] != 'succeeded') continue; // never a pair that didn't carry
      if (best == null) {
        best = s;
        continue;
      }
      final bestNominated = best['nominated'] == true;
      final thisNominated = s['nominated'] == true;
      if (thisNominated != bestNominated) {
        if (thisNominated) best = s;
        continue;
      }
      if (bytesOf(s) > bytesOf(best)) best = s;
    }
    if (best == null) return;

    IceCandidateType? typeOf(Object? id) {
      if (id is! String) return null;
      for (final s in stats) {
        if (s['id'] == id) {
          return IceCandidateType.parse(s['candidateType'] as String?);
        }
      }
      return null;
    }

    selectedLocal = typeOf(best['localCandidateId']);
    selectedRemote = typeOf(best['remoteCandidateId']);
  }

  /// True when this call went through TURN on either end — the fallback case.
  /// False only when BOTH ends resolved and neither was a relay. Null otherwise.
  ///
  /// ## The bug this shape exists to prevent — found by review, not by me
  ///
  /// The first version returned null only when **both** ends were unknown
  /// (`&&`), which meant `host` on the local side plus an unresolved remote
  /// reported **`false`: a measured direct connection.** Carnot and Tesla found
  /// it independently. Carnot's framing is the one to keep:
  ///
  /// > unknown heat loss is not zero heat loss
  ///
  /// A relay on *either* end is the whole thing being counted, so an unresolved
  /// end could be exactly the case that matters — one absent `candidateType`,
  /// one id that isn't a String, one stack spelling it `relayed`, and a call
  /// that went through TURN is filed as direct evidence for deleting the SFU.
  ///
  /// **`true` needs only one relay; `false` needs both ends known.** The
  /// asymmetry is the point: positive evidence of a relay is conclusive, absence
  /// of evidence is not evidence of absence.
  bool? get usedRelay {
    if (selectedLocal == IceCandidateType.relay ||
        selectedRemote == IceCandidateType.relay) {
      return true;
    }
    if (selectedLocal == null || selectedRemote == null) return null;
    return false;
  }

  /// True when the selected pair is fully resolved on both ends.
  ///
  /// Exposed so a caller can tell the two null cases apart — "no succeeded pair
  /// at all" from "a pair, half of it unreadable" — which are different problems
  /// with different fixes.
  bool get selectedPairFullyResolved =>
      selectedLocal != null && selectedRemote != null;

  /// A one-line summary for the ring buffer / telemetry.
  String describe() {
    final l = selectedLocal?.wireName ?? '?';
    final r = selectedRemote?.wireName ?? '?';
    final g = _gatheredLocal.entries
        .map((e) => '${e.key.wireName}=${e.value}')
        .join(' ');
    return 'selected=$l/$r gathered[$g]'
        '${unparsed > 0 ? ' unparsed=$unparsed' : ''}';
  }
}
