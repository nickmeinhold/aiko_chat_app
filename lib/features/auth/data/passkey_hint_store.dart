import 'package:shared_preferences/shared_preferences.dart';

/// Sticky per-island record of "a passkey for this island exists on this device".
///
/// Exists to decide which ingress the login screen EMPHASISES, and it is a hint,
/// never a gate.
///
/// **Why a local hint rather than asking the platform.** There is no
/// cross-platform way to ask "does a passkey exist for this relying party".
/// Android's Credential Manager can answer via `prepareGetCredential`; iOS has no
/// silent query at all — every check runs the ceremony and shows system UI. So a
/// pre-render decision cannot be made from the authenticator, only remembered.
///
/// **Why NOT [CachedUserStore].** That store is cleared on logout, by design, so
/// it answers "am I signed in right now" — a different question. A user who signs
/// out still has their passkey, and would get the wrong emphasis on the very next
/// screen.
///
/// **Deliberately NOT cleared on logout**, for the same reason: the passkey
/// outlives the session. Keyed per island BASE URL (not the display label, which is for humans and could collapse two islands onto one string) because a passkey is scoped to a
/// relying party — having one for `chat.imagineering.cc` says nothing about
/// `chat.enspyr.co`, and a shared flag would mis-emphasise on every island switch.
///
/// **It can be WRONG in one direction, and that direction is the safe one.** A
/// reinstall (or a new device restored from iCloud Keychain / Google Password
/// Manager) leaves a real passkey with NO local hint. So `false` means "we have no
/// evidence", never "there is no passkey" — which is exactly why the sign-in
/// affordance must remain present when this reads false. Hiding it would strand a
/// returning user who holds a valid credential.
class PasskeyHintStore {
  static const _prefix = 'aiko_passkey_seen_';

  final SharedPreferences? _prefs;

  PasskeyHintStore(this._prefs);

  static String _keyFor(String baseUrl) => '$_prefix$baseUrl';

  /// Have we ever completed a passkey ceremony for [host] on this device?
  /// Synchronous, off already-loaded prefs, so the login screen's first frame can
  /// use it without an await (an async read would flash the wrong emphasis).
  bool seenFor(String baseUrl) => _prefs?.getBool(_keyFor(baseUrl)) ?? false;

  /// Record that a passkey ceremony SUCCEEDED for [host]. Called after both
  /// registration and sign-in: either one proves a usable credential is here.
  Future<bool> markSeen(String baseUrl) =>
      _prefs?.setBool(_keyFor(baseUrl), true) ?? Future.value(false);
}
