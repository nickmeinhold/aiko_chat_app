# Design 23 — The session survives the lock

**Status:** DRAFT v1, 2026-10-09 · **Issue:** #219 · **Blocks:** iOS half of 0.0.6 (#214)
**Touches a trust boundary:** at-rest protection of the session credentials. Needs
`/design-temper` before build, `/cage-match` on the PR.

## The defect, measured

On a locked iPhone with the app not running, a call rings, but **answering it never
joins.** Four rings on 2026-10-09 (iOS 26.6.2, 0.0.6 ad-hoc build, enspyr) isolated why:

| Run | Phone state | Push → first Dart request | Joined |
|---|---|---|---|
| 1 | locked a while | +13.7 s, after Face ID | no |
| 2 | app in foreground | invite admitted over the websocket at ~1 s | yes |
| 3 | just locked (inside iOS's post-lock grace period) | **+1.1 s**, before Answer | yes |
| 4 | locked 2 h; answer, wait 5 s, then Face ID | +13.7 s, ~7 s after Answer | no |

Runs 3 and 4 differ only in whether the keychain could be read. `SecureTokenStore` uses
`FlutterSecureStorage()` with no iOS options, and in the locked plugin
(flutter_secure_storage 10.3.1 / darwin 0.3.2) the default is
`KeychainAccessibility.unlocked`, which is `kSecAttrAccessibleWhenUnlocked`. While the
phone is locked, Dart cannot read its access or refresh token, so it cannot restore the
session, fetch the invite, or admit it. It waits for Face ID. By then the invite is older
than `kCallInviteFreshness` (10 s) and is refused. The native half (PushKit, CallKit,
the audio session) needs no keychain and works.

The wait is the user's unlock latency. It is unbounded, so no tuning of the freshness
window fixes it on its own.

## Decision

Store the **session tokens** (`aiko_access_token`, `aiko_refresh_token`) with
`KeychainAccessibility.first_unlock_this_device`
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), on iOS only.

- **Why `first_unlock`:** after the first unlock since boot, the item stays readable
  while the device is locked. That is exactly the state a PushKit-woken app runs in.
  Run 3 shows the result: auth 1.1 s after the push, invite admitted at about 3 s, joined.
- **Why `_this_device`:** the default `unlocked` is backup-eligible (the key-backup
  crucible noted this for the signing key). A refresh token restored onto another phone
  from an encrypted backup is a session that moved without a sign-in. Device-bound is
  the honest scope for a bearer credential. Cost: restoring a backup to a new phone
  means signing in again, which is already the case for passkey re-binding.
- **Not the sovereign signing key.** `SovereignKeyStore` stays `unlocked`. Admitting and
  joining a call need *auth*, not our private key: verifying the caller's signature
  uses *their* public key. Signing happens on send, which needs the user present
  anyway. The identity key keeps the stronger class. This split is the point: the
  credential the island can revoke gets the weaker class, and the one nobody can revoke
  keeps the stronger one.
- **Not macOS, not Android.** macOS has no cold-start ring (no PushKit/CallKit path),
  and `MacOsOptions` is a separate parameter. Android's credential storage is already
  readable after the first unlock, which is why the Pixel joins in 4.2 s.

## What this trades

A seized iPhone that has been unlocked once since boot and is now locked ("AFU",
after first unlock) exposes the session tokens to an attacker who can run code as the
app or extract the keychain in that state. Before this change, those items were
protected by the class-A key, which is discarded about 10 s after lock.

What an extracted token is worth:
- the **access token** is short-lived (the run 1 and run 4 logs show it expired and
  was refreshed);
- the **refresh token** is a standing session until revoked. The island can revoke it,
  and the user can sign out other sessions. It **cannot sign messages**: messages and
  reactions are signed at birth with the sovereign key, which keeps class-A protection.
  A stolen session can read the account's messages. **Assumption, for the temper to
  check:** traffic it sends without the sovereign key shows as unverified to
  signed-at-birth peers. That is the intent of message signing, but this note has not
  verified every surface that renders a message.

So the trade is confidentiality of the session (read access) in the AFU-locked seizure
case, against calls that can be answered at all. Apple documents `AfterFirstUnlock` as
the class for items that background apps need. The system default is `WhenUnlocked`, so
this is an explicit choice to step down, not a return to a default.

## Migration: the trap in the plugin

`flutter_secure_storage_darwin` 0.3.2 puts `kSecAttrAccessible` **into the lookup
query** (`baseQuery`, FlutterSecureStorage.swift:219), and accessibility is a matchable
attribute. Item identity (service + account) does not include it. Consequences if the
options are simply switched:

1. **Read with new options misses the old item.** The user looks signed out.
2. **Write with new options:** `containsKey` misses, so it calls `SecItemAdd`, which
   collides with the old item on service and account: `errSecDuplicateItem`. **The write
   fails.** If this happens inside a token refresh, the island has already rotated the
   refresh token and the app fails to persist the new one, which logs the user out.

So the store must migrate explicitly:

```
read():
  t = read(new options)
  if t: return t
  t = read(legacy options)          # fails while locked; that's fine (see below)
  if t:
    delete(legacy options)
    write(new options, t)           # now a clean add
  return t

write(tokens):
  delete(legacy options)            # best effort; removes any unmigrated item first
  write(new options, tokens)

clear():
  delete(new options); delete(legacy options)
```

- **Migration only completes while unlocked**, because the legacy item cannot be read
  while locked. The first cold call after the update can therefore still fail if the
  user has not opened the app unlocked since updating. Opening the app after an update
  is the normal path, so this is a one-time window, not a steady state.
- **Unknown, to measure on hardware before merge:** can `SecItemDelete` remove a
  `WhenUnlocked` item while the device is locked? If not, `write()` while locked with
  an unmigrated legacy item still collides. A refresh while locked can only happen
  after a cold wake. **The order is what makes it safe:** `read()` runs (and migrates)
  before any refresh can be needed, and on a locked phone with an unmigrated item
  `read()` returns null, so there is no session to refresh. The app is signed out for
  that ring, not corrupted. That must be verified, not assumed.
- **Delete-then-add is not atomic.** A crash between the two loses the session (the
  user signs in again). The alternative, `SecItemUpdate` of `kSecAttrAccessible` on the
  existing item, avoids the gap, but the plugin does not expose it. A small native
  shim would be needed. Recommendation: accept the gap for v1. It is a one-time
  migration that needs a crash in a microsecond window, and its failure mode is a
  sign-in, not data loss.

## How we know it worked

1. **Hardware, the test that failed:** lock the iPhone for 30 s or more (past the grace
   period), kill the app, ring through enspyr (`tool/hw_ring.dart invite --island`,
   `HW_RING_CHANNEL=01M02Y4QS94QRRQ3658BZAB0PG`), answer, **wait 5 s, then Face ID**.
   Pass = `/v1/me` on enspyr within about 2 s of the push (before Answer) and a
   video-token mint for `nick`.
2. **Migration on hardware:** install over the current 0.0.6 ad-hoc build (legacy
   items present), open unlocked once, then repeat test 1.
3. **Locked write:** with an unmigrated legacy item, lock, cold-wake, and confirm the
   app reads as signed out rather than corrupting state (the unknown above).
4. **Unit:** a fake `FlutterSecureStorage` that models accessibility as part of the
   query (so the duplicate-item collision is reproducible), covering read-migrate,
   write-over-legacy, clear-both, and locked-legacy (read returns null and nothing is
   deleted).

## Not in scope

- The freshness window itself (claude-tasks#4233). With this fix the iOS cold path
  admits in about 1–2 s, so the window is no longer the binding constraint on iOS. The
  "answered native session proves timeliness" idea stays as the safety net for real
  push latency.
- #220 (stale native ring state across calls).
