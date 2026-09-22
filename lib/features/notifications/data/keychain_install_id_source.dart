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
  /// A null ANSWER is cached too — the future completing with null is still a
  /// completed future, so a platform with no id is asked once, not once per
  /// registration. Only a THROW would leave the slot poisoned, and `_resolve`
  /// cannot throw: every arm returns.
  Future<String?>? _pending;

  @override
  Future<String?> installId() => _pending ??= _resolve();

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
