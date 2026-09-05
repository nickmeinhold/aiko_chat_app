/// An in-memory [CallSignalling] pair — the ONLY implementation in the tree,
/// and deliberately so.
///
/// It exists to hold signalling still while the media half of the P2P thesis is
/// tested (see `call_signalling.dart` for why no wire is committed by this
/// spike). Two sessions get the two ends of one pipe, and everything a real
/// transport would do — serialise, deliver, possibly reorder — is replaced by a
/// broadcast stream.
///
/// **It is not a fake of a transport that exists.** There is no real transport
/// yet, so this cannot drift from one. When one is chosen (registrar/EC over the
/// bus, or the gateway relaying over the existing WSS), this stays as the test
/// double and the real implementation lands beside it.
///
/// Lives in `lib/` rather than `test/` because the macOS integration test drives
/// it through the app's own package, and a `test/`-only class is not importable
/// from `integration_test/`.
library;

import 'dart:async';

import '../domain/call_signalling.dart';

/// Creates two connected ends. Whatever is sent on one arrives on the other.
({CallSignalling a, CallSignalling b}) createLoopbackSignallingPair() {
  final toA = StreamController<CallSignal>.broadcast();
  final toB = StreamController<CallSignal>.broadcast();
  return (
    a: _LoopbackEnd(inboundController: toA, outboundController: toB),
    b: _LoopbackEnd(inboundController: toB, outboundController: toA),
  );
}

class _LoopbackEnd implements CallSignalling {
  _LoopbackEnd({
    required StreamController<CallSignal> inboundController,
    required StreamController<CallSignal> outboundController,
  })  : _in = inboundController,
        _out = outboundController;

  final StreamController<CallSignal> _in;
  final StreamController<CallSignal> _out;
  bool _disposed = false;

  @override
  Stream<CallSignal> get inbound => _in.stream;

  @override
  Future<void> send(CallSignal signal) async {
    // A send after teardown is a no-op, not a throw: the far end disposing
    // mid-negotiation is ordinary (the user hung up), and a trickled candidate
    // arriving into a closed pipe must not surface as an error on a call that
    // ended normally.
    if (_disposed || _out.isClosed) return;
    _out.add(signal);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Only the INBOUND controller is closed here. The outbound one belongs to
    // the far end's inbound — closing it would tear down the peer's stream from
    // this side, which no real transport can do and which would let a test pass
    // for the wrong reason.
    await _in.close();
  }
}
