import 'package:flutter/services.dart';

import '../application/push_telemetry.dart';
import '../domain/install_id_source.dart';

/// The handset id, out of the iOS Keychain.
///
/// THE BINDING IS THE ENTIRE FEATURE, so the storage choice is not an
/// implementation detail the native side happens to have made. The value must
/// not survive onto a second physical device: `UserDefaults` and ordinary files
/// are swept into iCloud Backup, so a restore puts two handsets under one id,
/// and the island — grouping by that id to suppress the redundant banner —
/// would silence the alert row that is the second handset's only reach. A
/// missed call, produced by the very field minted to prevent one.
///
/// The native half answers from a Keychain item with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, whose exclusion from
/// backup and device transfer is a documented platform guarantee rather than an
/// observed behaviour. See `InstallIdChannel` in `AppDelegate.swift` for why
/// `identifierForVendor` was rejected despite needing no storage at all.
///
/// CACHED FOR THE LIFE OF THE INSTANCE, and that is a correctness property, not
/// a performance one. Both device registrars run concurrently at a sign-in edge
/// and both register a token for this handset; if the two reads could return
/// different answers the island would group one phone as two, which is the
/// failure the field exists to prevent. One instance, one answer — enforced by
/// sharing the instance (see `installIdSourceProvider`) and by memoising here.
/// A null is cached too: a platform that has no answer now will not grow one
/// mid-session, and re-asking would only produce a stream of identical log
/// lines.
class KeychainInstallIdSource implements InstallIdSource {
  KeychainInstallIdSource({
    MethodChannel? methods,
    PushTelemetry telemetry = PushTelemetry.noop,
  }) : _methods = methods ?? const MethodChannel(_channelName),
       _telemetry = telemetry;

  static const _channelName = 'cc.imagineering.aikoChatApp/install';

  final MethodChannel _methods;
  final PushTelemetry _telemetry;

  /// THE MEMO IS THE FUTURE, NOT THE VALUE, and the difference is a live bug.
  ///
  /// An earlier revision cached `String? _cached` behind a `bool _asked` flag
  /// set BEFORE the platform call was awaited. A second caller arriving during
  /// that await saw "already asked" and read a `_cached` nothing had written
  /// yet — so it got null. Production calls it exactly that way: both registrar
  /// chains are fired `unawaited` at a sign-in edge and are in flight together
  /// (`pushPairingProvider`, whose own comment says so). The alert row would
  /// carry the id and the voip row null, the two would never group, and the
  /// feature would silently do nothing — the outcome it exists to prevent.
  ///
  /// Memoising a VALUE is not memoising an OPERATION. Caching the future makes
  /// concurrent callers await the one in-flight call and receive one answer,
  /// and it is why this needs no lock: assignment is atomic on the single
  /// isolate, and `??=` cannot interleave.
  ///
  /// **A NULL IS NOT CACHED, AND THAT IS TESLA'S FINDING.** An earlier revision
  /// memoised the null too, reasoning that "a platform with no answer now will
  /// not grow one mid-session". That is false in the case that matters most: the
  /// Keychain is SEALED until the first unlock after boot, so a VoIP wake on a
  /// just-booted handset reads nil — and `DeviceRegistrar` then sets
  /// `_registered` on the successful POST and skips re-registration for that
  /// token (`device_registrar.dart:359`). The phone that most needs grouping,
  /// the one being rung while locked, would be the one that never acquires it,
  /// permanently, for the life of the process.
  ///
  /// So a SUCCESSFUL answer is cached forever (an id must never change) and a
  /// null clears the slot, letting the next registration round ask again once
  /// the device is unlocked.
  ///
  /// The in-flight future is still shared either way, which is what keeps
  /// concurrent callers consistent WITHIN a round: both registrars at one
  /// sign-in edge see the same answer, null or not. Across rounds they can
  /// differ (locked at boot, unlocked later) — but that is two rows converging
  /// on an id rather than splitting, and it is strictly better than two rows
  /// permanently agreeing on nothing.
  ///
  /// **NAMED RESIDUAL — this makes the retry POSSIBLE, it does not SCHEDULE
  /// one.** Nothing inside a process asks again on its own: `DeviceRegistrar`
  /// skips re-registration once `token == _registered`
  /// (`device_registrar.dart:359`), so a background VoIP-wake process that
  /// registered while the Keychain was sealed keeps its null for that
  /// process's life. What closes it is the next FOREGROUND launch, which
  /// builds a fresh registrar whose `_registered` is null and so registers
  /// again — by which time the device has been unlocked. The bound is
  /// therefore "one short-lived background process", not "forever", and the
  /// clearing above is what makes even that recoverable; without it the id
  /// would never arrive no matter how long the process lived. Scheduling a
  /// re-registration the moment an id becomes available is real machinery and
  /// is deliberately not built here — but the gap is stated rather than left
  /// for a reader to discover, because the fix above reads as total and is
  /// not. Deferred with the shape it would take: **claude-tasks#4696**.
  String? _resolved;
  Future<String?>? _pending;

  @override
  Future<String?> installId() {
    final done = _resolved;
    if (done != null) return Future<String?>.value(done);
    return _pending ??= _resolve().then((value) {
      _resolved = value;
      // RETRYABLE. Clearing the slot on null is the whole of the fix above;
      // leaving it set is what made a locked-at-boot read permanent.
      if (value == null) _pending = null;
      return value;
    });
  }

  Future<String?> _resolve() async {
    try {
      return _valid(await _methods.invokeMethod<String>('installId'));
    } on PlatformException catch (e) {
      _telemetry.installIdUnavailable(e);
      return null;
    } on MissingPluginException catch (e) {
      // The native half is not in this build — a desktop target, or a `.swift`
      // outside the Runner target. Degrades dedup and nothing else, so it is
      // NOT `nativeChannelMissing`: that one means push is inoperable in this
      // binary, and reporting a lost banner-suppression at the same severity
      // would make the signal that matters harder to find.
      _telemetry.installIdUnavailable(e);
      return null;
    } catch (e) {
      // THE CATCH-ALL IS LOAD-BEARING, not defensive clutter (Tesla,
      // cage-match round 1). The two named exceptions are not the whole
      // surface: a codec mismatch throws a cast error, and this future is
      // awaited INSIDE `_register`'s try, AFTER the unregister debt is
      // written. An escape there is classified as a maybe-landed POST that
      // never left — a debt owed for a row that does not exist, from a field
      // whose entire contract is that it can never be a gate.
      _telemetry.installIdUnavailable(e);
      return null;
    }
  }

  /// The island's boundary contract, enforced BEFORE the value can reach a
  /// request: non-empty, at most 64 characters, `^[A-Za-z0-9_.:-]+$`.
  ///
  /// CHECKED HERE RATHER THAN TRUSTED, even though the native side mints a UUID
  /// that satisfies it by construction. The asymmetry of the two failures is the
  /// argument: a rejected value costs a banner nobody wanted, while sending one
  /// costs a 422 that fails the WHOLE registration — a handset that does not
  /// wake at all, for a field whose entire purpose is cosmetic. An unexpected
  /// value is therefore dropped, not forwarded.
  String? _valid(String? value) {
    if (value == null) return null;
    if (value.isEmpty || value.length > 64) {
      _telemetry.installIdRejected('length ${value.length}');
      return null;
    }
    if (!_charset.hasMatch(value)) {
      _telemetry.installIdRejected('charset');
      return null;
    }
    return value;
  }

  static final _charset = RegExp(r'^[A-Za-z0-9_.:-]+$');
}
