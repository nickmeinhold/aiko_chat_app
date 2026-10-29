/// The signalling seam for a DIRECT (peer-to-peer) call — deliberately abstract,
/// and deliberately NOT wired to any wire.
///
/// ## Why this file exists as an interface and not an implementation
///
/// The P2P thesis (claude-tasks#3740) is that **the hard part of P2P WebRTC is
/// rendezvous, not media** — two peers finding each other and trading SDP + ICE
/// is why everyone reaches for an SFU, and aiko's registrar + bus is already a
/// rendezvous channel. If that is right, the centralised media plane is not a
/// technical necessity; it is a workaround for a problem the Dart port dissolves.
///
/// That claim is about *signalling*, so the honest way to test the *media* half
/// is to hold signalling still. This interface is the seam that lets the media
/// half be proven with a loopback while the real transport is still undecided —
/// registrar/EC over the bus (option 3), or the gateway relaying over the
/// existing WSS (option 2). Both were priced as delivering identical media
/// privacy and cost wins; only the shape differs.
///
/// ## What this file MUST NOT become, and why the restraint is load-bearing
///
/// The obvious implementation is "carry SDP in a signed message, like the call
/// invite already does." **That is a one-way door and it is not this spike's to
/// open.** `kCallInviteBody` is a pinned sentinel inside permanent signed
/// history on a live island, confirmed by Nick before first transmission; the
/// file that defines it says changing it is "a v2 with a compatibility branch,
/// never an edit". A new sentinel for SDP would be the same kind of door, and it
/// is a cross-repo contract the island tab co-owns.
///
/// So this spike commits **no wire at all**. The interface is real; the only
/// implementation in the tree is an in-memory loopback used by tests. Wiring it
/// is a separate, deliberate, two-tab decision.
library;

/// One message on the signalling channel between two peers of a direct call.
///
/// Sealed so the transport that eventually carries these has an exhaustive set
/// to serialise, and so adding a fourth kind cannot silently fall through a
/// switch. Closed set, closed type — never a `String` `kind` field.
sealed class CallSignal {
  const CallSignal();
}

/// The caller's SDP offer. Sent once, at the start.
final class CallOffer extends CallSignal {
  const CallOffer(this.sdp);

  /// The raw SDP text from `RTCSessionDescription.sdp`.
  final String sdp;
}

/// The callee's SDP answer, in reply to a [CallOffer].
final class CallAnswer extends CallSignal {
  const CallAnswer(this.sdp);

  final String sdp;
}

/// One trickled ICE candidate.
///
/// TRICKLED, not batched with the SDP, and the difference is user-visible: an
/// implementation that waits for ICE gathering to complete before sending its
/// offer adds the full gathering timeout to call setup — seconds, on exactly the
/// networks where gathering is slowest. Trickle is the reason a direct call can
/// connect as fast as an SFU one.
final class CallIceCandidate extends CallSignal {
  const CallIceCandidate({
    required this.candidate,
    required this.sdpMid,
    required this.sdpMLineIndex,
  });

  /// The candidate line, e.g.
  /// `candidate:1 1 udp 2122260223 192.168.1.5 51234 typ host ...`.
  ///
  /// The `typ` token in here is what [IceCandidateTally] reads.
  final String candidate;

  final String? sdpMid;
  final int? sdpMLineIndex;
}

/// A bidirectional signalling channel for ONE call, from one peer's point of
/// view.
///
/// Implementations are responsible for delivery only. They do not interpret
/// signals, and they are **not** a trust boundary: a direct call's security
/// comes from DTLS-SRTP between the peers, so a signalling relay that could read
/// or reorder these still cannot read the media. (It can deny the call, and it
/// learns that a call is happening — which is the metadata question, tracked
/// separately against the 2026-08-25 sender-anonymity decision.)
abstract interface class CallSignalling {
  /// Signals from the far peer, in arrival order.
  Stream<CallSignal> get inbound;

  /// Send one signal to the far peer. Best-effort; a transport may drop, and
  /// [CallIceCandidate] loss degrades connectivity rather than failing the call
  /// — losing the offer or answer does fail it.
  Future<void> send(CallSignal signal);

  Future<void> dispose();
}
