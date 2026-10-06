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


/// How a tally resolved its selected pair.
///
/// A closed set, so an enum: this rides alongside the relay fraction, and a
/// reading whose provenance is a bare string is a reading nobody can filter on
/// later.
enum SelectedPairSource {
  /// Not resolved — no transport named a pair and no pair succeeded.
  none,

  /// The connection's own `transport.selectedCandidatePairId`. Authoritative.
  transportSelectedId,

  /// Reconstructed from `state == 'succeeded'` because no transport report
  /// named a pair. Known to be blind on the controlled ICE role against
  /// libwebrtc via flutter_webrtc 1.6.0 on Darwin — a reading from here is
  /// weaker evidence and should be filterable as such.
  succeededHeuristic,
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

  /// How the pair above was resolved. See [SelectedPairSource].
  SelectedPairSource selectedPairSource = SelectedPairSource.none;

  /// Ends of a SELECTED pair that could not be resolved to a known type — a
  /// missing id, an id naming no report, or a token this parser does not know
  /// (a stack spelling relay `relayed` is the live candidate). Counted rather
  /// than shrugged off: each one is a path that silently leaves the sample, and
  /// a population that loses its unreadable members is biased toward whatever
  /// the readable ones happened to say. Non-zero forbids a `false`.
  int selectedUnparsed = 0;

  /// Latches behind [usedRelay]. Relay-ness is existential over pairs and over
  /// samples. Private because nothing outside this class may un-see a relay.
  bool _relayEverSeen = false;
  bool _directFullySeen = false;

  /// How many samples produced an observable pool. A `false` from ONE sample
  /// is a fact about that instant, not about the call — and nothing in this
  /// spike schedules sampling, so the relay fraction a caller quotes is a
  /// function of a cadence that does not yet exist. Exposed so a reading can be
  /// weighted rather than quoted flat (Tesla).
  int sampleCount = 0;

  /// A transport NAMED a selected pair that is not in the report. The
  /// authoritative answer existed and could not be read, so it may have been a
  /// relay. Blocks `false` permanently — distinct from having no transport
  /// report at all, which is merely an absence of evidence.
  bool _selectionUnresolved = false;

  /// A relay pair SUCCEEDED but was never named as selected — so it may or may
  /// not have carried anything. Blocks `false` without asserting `true`.
  bool _relayAmbiguous = false;

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

  /// Record the pair(s) the connection actually used, from
  /// `RTCPeerConnection.getStats()`.
  ///
  /// [stats] is the raw report as a list of `{id, type, ...}` maps — passed in
  /// rather than fetched here so this class stays platform-free and directly
  /// testable without a live PeerConnection. **Safe to call repeatedly**; that
  /// is the normal case, because sampling a live call is how a path change gets
  /// observed at all.
  ///
  /// ## Ask the stack; do not reconstruct what it already answered
  ///
  /// `RTCTransportStats.selectedCandidatePairId` is the connection's OWN answer
  /// to "which pair is carrying this call". Measured present and populated on
  /// both ICE roles in 8 of 8 captures (`test/features/call/fixtures/`, harvested
  /// from a live macOS stack, not authored). Reading it is the difference between
  /// reading the answer and re-deriving it from the evidence the answer came from.
  ///
  /// The round-1 `state == 'succeeded'` rule is kept, but the two sets are now
  /// UNIONED rather than one preferred over the other — see the bias note below.
  /// It was demoted because the controlled ICE role reported ZERO succeeded
  /// pairs in 1 run of 4 while connected and moving bytes.
  ///
  /// ## THE QUANTIFIER IS `EXISTS`, NOT `ARGMAX` — the correction of record
  ///
  /// This method used to reduce every selected pair to a single `best` and let
  /// [usedRelay] read that one pair. Four adversarial families and this author's
  /// own pass converged on why that is wrong, and it is worth stating as a law,
  /// because this file has now produced FIVE instances of the same defect:
  ///
  /// > **[usedRelay] asks whether a relay was involved AT ALL. That is an
  /// > existential question over every selected pair and every sample. A
  /// > reduction to one pair, or to one moment, answers a different question —
  /// > and answers it in the direction that flatters the measurement.**
  ///
  /// Two concrete failures the reduction produced, both now closed:
  ///
  /// - **Across PAIRS.** Without BUNDLE there is one transport per m-line, so
  ///   several pairs are selected at once. Audio direct on `host` carrying most
  ///   of the bytes, video relayed through TURN carrying fewer: the bytes
  ///   tiebreak picks audio and a call that used TURN is filed as **direct**.
  /// - **Across TIME.** A call that starts direct and fails over to a relay is
  ///   a call that needed a relay. Reading only the latest resolvable sample —
  ///   or worse, holding an earlier one because a later read saw nothing — files
  ///   it as direct. Kelvin: *"a thermometer that, upon reaching a freezing
  ///   temperature, decides it will never get warmer again."*
  ///
  /// So relay-ness LATCHES. `false` is reachable only from a sample in which
  /// every selected pair resolved on both ends, none was a relay, and nothing
  /// anywhere failed to parse.
  ///
  /// ## Three states, because a succeeded relay pair is not a USED relay pair
  ///
  /// The first attempt at the fix above simply unioned the transport-named set
  /// with the succeeded set and quantified relay over both. The existing suite
  /// caught it immediately, and the suite was right: **ICE succeeds on pairs it
  /// never carries media over.** A relay pair routinely succeeds merely because
  /// TURN is configured — which is the exact conflation this file's opening
  /// docstring exists to forbid ("gathering a relay candidate says only that a
  /// TURN server was configured, not that anything used it"). Unioning
  /// reintroduced it one level down, and would have reported `true` on almost
  /// every call in a TURN-configured deployment.
  ///
  /// So there are three states, not two, and the middle one is the point:
  ///
  /// - A relay among the pairs the transport **NAMED** → `true`. Latches.
  /// - A relay among succeeded-but-**not-named** pairs → **ambiguous**. It does
  ///   NOT assert `true` (the call may never have touched it) and it forbids
  ///   `false` (Tesla's stale-name case, where the named pair is dead and the
  ///   succeeded relay is the live one, is exactly this shape). Latches.
  /// - No relay anywhere, everything resolved → `false`.
  ///
  /// Refusing to guess in either direction is the only move that is not a fold.
  void recordSelectedPair(List<Map<String, dynamic>> stats) {
    num bytesOf(Map<String, dynamic> s) {
      num one(Object? v) => v is num ? v : (v is String ? num.tryParse(v) ?? 0 : 0);
      return one(s['bytesSent']) + one(s['bytesReceived']);
    }

    final selectedIds = <String>{};
    for (final s in stats) {
      if (s['type'] != 'transport') continue;
      final id = s['selectedCandidatePairId'];
      if (id is String && id.isNotEmpty) selectedIds.add(id);
    }

    final named = <Map<String, dynamic>>[];
    final pool = <Map<String, dynamic>>[];
    for (final s in stats) {
      if (s['type'] != 'candidate-pair') continue;
      final id = s['id'];
      final isNamed = id is String && selectedIds.contains(id);
      if (isNamed) named.add(s);
      if (isNamed || s['state'] == 'succeeded') pool.add(s);
    }

    // THE STACK SPOKE AND WE COULD NOT HEAR IT. A transport that names a pair
    // absent from the report is NOT the same unknown as a report with no
    // transport at all: in the first case the authoritative answer exists and
    // this parser failed to read it, so the selected pair could have been a
    // relay and we would never know. Falling through to the succeeded heuristic
    // and reporting `false` off host/srflx pairs is the same fold again, at the
    // one place that looks most like graceful degradation (Carnot).
    if (selectedIds.isNotEmpty && named.isEmpty) _selectionUnresolved = true;

    // Nothing observable this sample. Say nothing: do not erase what an earlier
    // sample established, and do not claim to have measured.
    if (pool.isEmpty) return;

    var sampleUnparsed = 0;
    IceCandidateType? typeOf(Object? id) {
      if (id is! String) {
        sampleUnparsed++;
        return null;
      }
      for (final s in stats) {
        if (s['id'] != id) continue;
        // Tolerant, not a cast. Darwin hands `report.values` to the channel
        // untransformed, so `as String?` could throw AFTER one end was already
        // assigned — a partial commit wearing a "committed together" comment.
        final raw = s['candidateType'];
        final parsed = IceCandidateType.parse(raw is String ? raw : null);
        if (parsed == null) sampleUnparsed++;
        return parsed;
      }
      sampleUnparsed++;
      return null;
    }

    // Relay-ness is computed over the pairs the TRANSPORT NAMED. A succeeded
    // pair the transport did not name is evidence of a path that WORKED, not of
    // a path that CARRIED — see the three-states note above.
    final namedSet = named.isEmpty ? pool : named;
    var namedRelay = false;
    var namedAllResolved = true;
    for (final s in namedSet) {
      final l = typeOf(s['localCandidateId']);
      final r = typeOf(s['remoteCandidateId']);
      if (l == IceCandidateType.relay || r == IceCandidateType.relay) {
        namedRelay = true;
      }
      if (l == null || r == null) namedAllResolved = false;
    }
    // When NOTHING was named there is no authoritative selection, so the only
    // evidence about which pair actually carried the call is whether it moved
    // bytes. A relay pair with bytes on it carried media — that is a true
    // positive and must not be thrown away. A mixed set in which nothing has
    // moved yet is genuinely undecidable, and guessing either way is the fold.
    if (named.isEmpty && namedRelay) {
      bool isRelay(Map<String, dynamic> s) =>
          typeOf(s['localCandidateId']) == IceCandidateType.relay ||
          typeOf(s['remoteCandidateId']) == IceCandidateType.relay;
      final allRelay = namedSet.every(isRelay);
      final relayCarriedBytes =
          namedSet.any((s) => isRelay(s) && bytesOf(s) > 0);
      if (!allRelay && !relayCarriedBytes) {
        namedRelay = false;
        _relayAmbiguous = true;
      }
    }
    // A relay sitting in the succeeded set outside the named set blocks `false`
    // without asserting `true`.
    for (final s in pool) {
      if (namedSet.contains(s)) continue;
      final l = typeOf(s['localCandidateId']);
      final r = typeOf(s['remoteCandidateId']);
      if (l == IceCandidateType.relay || r == IceCandidateType.relay) {
        _relayAmbiguous = true;
      }
    }

    // The representative pair, for [describe] only. NEVER the basis of
    // [usedRelay] — that reduction is what this comment exists about.
    Map<String, dynamic> best = pool.first;
    for (final s in pool.skip(1)) {
      final bestNominated = best['nominated'] == true;
      final thisNominated = s['nominated'] == true;
      if (thisNominated != bestNominated) {
        if (thisNominated) best = s;
        continue;
      }
      if (bytesOf(s) > bytesOf(best)) best = s;
    }

    sampleCount++;
    selectedUnparsed += sampleUnparsed;
    if (namedRelay) _relayEverSeen = true;
    if (namedAllResolved && !namedRelay && !_relayAmbiguous && sampleUnparsed == 0) {
      _directFullySeen = true;
    }
    // NOT `?? selectedLocal`. Carrying the previous sample's endpoints forward
    // while `selectedPairSource` advances to the latest source produces a
    // summary line that reads `selected=host/host via=transportSelectedId`
    // about a sample whose endpoints could not be parsed — stale and flattering
    // in the field most likely to land in a log (Carnot). The representative
    // pair describes THIS sample or says it does not know.
    selectedLocal = typeOf(best['localCandidateId']);
    selectedRemote = typeOf(best['remoteCandidateId']);
    selectedPairSource = named.isNotEmpty
        ? SelectedPairSource.transportSelectedId
        : SelectedPairSource.succeededHeuristic;
  }


  /// Whether a relay carried any part of this call — the fallback case, and
  /// the number the SFU decision needs.
  ///
  /// **EXISTENTIAL over pairs and over samples**, not a read of one chosen
  /// pair at one moment. See [recordSelectedPair]'s quantifier note; this
  /// getter is deliberately a thin read of latches so that no future edit can
  /// reintroduce a reduction here.
  ///
  /// - `true` — a relay end was seen on any selected pair in any sample. It
  ///   LATCHES: a call that failed over to TURN needed TURN, whatever it did
  ///   afterwards.
  /// - `false` — some sample resolved every named pair on both ends with no
  ///   relay among them, no relay succeeded elsewhere in the report, and
  ///   nothing anywhere failed to parse. Absence of evidence is not evidence of
  ///   absence, so this is deliberately the demanding branch.
  /// - `null` — unmeasured. Never conflate with `false`.
  ///
  /// **`false` is bounded by the sampling cadence, and this class does not set
  /// one.** A single sample taken at `connected` cannot see a failover that
  /// happens later; `true` latches so it survives a sparse cadence, but `false`
  /// can only ever mean "no relay in any sample TAKEN". [sampleCount] is
  /// exposed so a one-sample `false` is not quoted as a call-lifetime fact —
  /// the asymmetry is real and is the honest limit of the instrument, not a
  /// defect to be argued away (Tesla).
  ///
  /// The original bug this asymmetry was written for: returning `null` only
  /// when BOTH ends were unknown, so `host` locally plus an unresolved remote
  /// reported a measured direct connection. Carnot's framing is still the one
  /// to keep — *unknown heat loss is not zero heat loss*.
  bool? get usedRelay {
    if (_relayEverSeen) return true;
    if (_directFullySeen &&
        !_relayAmbiguous &&
        !_selectionUnresolved &&
        selectedUnparsed == 0) {
      return false;
    }
    return null;
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
    return 'selected=$l/$r via=${selectedPairSource.name} '
        'relay=${usedRelay ?? '?'} samples=$sampleCount gathered[$g]'
        '${unparsed > 0 ? ' unparsed=$unparsed' : ''}'
        '${selectedUnparsed > 0 ? ' selectedUnparsed=$selectedUnparsed' : ''}'
        '${_selectionUnresolved ? ' selectionUnresolved' : ''}';
  }
}
