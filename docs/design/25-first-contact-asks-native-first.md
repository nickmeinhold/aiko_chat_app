# Design 25: first contact asks native first

**Status:** recast for `/design-temper`, 2026-10-29. Escalated from the cage-match of [app #443](https://github.com/nickmeinhold/aiko_chat_app/pull/443) after two rounds, when Round 9.8's stop signals fired (the round-2 ledger is on the PR).
**Amends:** design 23, requirement 2.

## The producer question, first

**The harm.** In order of severity:

1. A stranger's call rings a person's open app (the phone in their hand, or the desktop app left open all day).
2. A real call is lost by the gate meant to stop strangers: an answered system call is held forever, released before it is decided, or refused as `stale` because the gate's own lookup took too long.

**The trigger** is external. With open sign-up, any account can open a DM with any user id it reads off a public channel, and call it.

**The producers, and what can remove them.**

- **Harm 1 is produced by two doors.**
  - The island wakes a sleeping handset only for a recipient who has posted in that DM (`_spoken_here`, live since v0.11.1). But it delivers the call frame to a *connected* recipient regardless ("IT GATES THE WAKE, NEVER THE INVITE").
  - `admitRing` then admitted any person.
  - The island half could be made unable to produce the harm: the island already computes the per-recipient verdict, and could stamp it on the frame it fans out. That is a cross-repo wire change, filed as a follow-up.
  - The app half cannot be removed without that data, so the app keeps a check: `noPriorConduct`, persons only, placed after every cheaper refusal and before the clocks.
- **Harm 2 is produced by the ORDER in which the app gathers its evidence.**
  - #443 consults the cache first and the native wake second. That order produces harm 2 whichever way the cache lookup is wired:
    - **exposed** to the navigator's `wakeAdmissionFor`, an unbounded read can hold an answered call forever (round 1);
    - **hidden** from it, a held answer can be released while the read is still deciding (round 2).
  - And because freshness is judged again after the read, a slow read (one queued behind the pager on a fresh install) ages a fresh invite into `stale`.
  - This producer **can** be removed: change the order, put the whole decision in one future, and stop charging the app's own latency to the invite.

## The recast

For a person's DM invitation that every cheaper clause has passed:

1. **One admission future, registered synchronously** in the map `wakeAdmissionFor` already reads, before any await. There is no second map, and nothing to hide or expose.
2. **Native first.** If a bridge exists, ask `wakeAge` for this call, with the existing retry-on-`unknown` loop and its existing budget.
   - **`Woke`** is the island's word that this recipient has posted here: it woke this handset only after judging conduct against its whole history. Admit on it, and judge freshness from the wake, as design 23 does. **The cache is never read.**
3. **Otherwise the cache:** no bridge (desktop), or a native answer other than `Woke`. Read `hasPostedIn`, bounded by **what is left of the same budget**.
   - A timeout or a fault is logged `call.ring.conduct_unreadable` and counts as not found.
4. **Judge freshness from arrival.** The re-entry passes the instant Dart first judged the invitation as `receivedAt`, so transit is measured from signature to arrival. The lookup's latency is the app's, not the invitation's (design 23's own principle: freshness bounds transit).
5. **Re-enter `admitRing` once** with the evidence: `spokenHere = cache said yes || wake is Woke`.

**Why this removes harm 2 instead of guarding it.**

- **No hold forever:** one budget bounds the whole decision.
- **No early release:** the one future covers the whole decision, so `wakeAdmissionFor` names it from the first instant to the last.
- **No lost vouched call:** an answered system call can only exist because native rang, which means a wake for this call. Native is asked first and answers `Woke`, so a held answer never depends on the cache at all.
- **No aging:** the lookup's time is not charged to the invite.

## What it amends

Design 23, requirement 2 says: *"`wakeAge` is asked only for an invite refused `stale` at `now`. `receivedAt ≤ now`, so the wake can only rescue what `now` refuses."*

The reasoning still holds. It just has a second instance. `noPriorConduct` is also a refusal at `now` that a wake can rescue, because a wake for this call carries the island's conduct judgement. The amended requirement:

> `wakeAge` is asked only for an invite refused at `now` for a reason a wake can rescue: `stale` (transit) or `noPriorConduct` (conduct).

**Visible consequence:** a person's FRESH invitation now costs one `wakeAge` round trip on a phone. A non-person's fresh invitation still never asks (consent, not conduct, governs it), so the two design-23 tests that pin "a fresh invite never asks the native side" move to a consented agent, which is the population that property is actually about.

## Residuals, named

- **Retracted posts and history still paging (desktop, or a phone not woken):** refused, failing safe. The island's verdict on the frame is the fix; filed.
- **A `Woke` from an island older than v0.11.1** vouches for nobody, since that island woke for anyone. No worse than before #443, which rang it.
- **Conduct, not consent:** one message ever, and that party may ring you; there is no "un-reply". A message-request inbox is a separate design.
- **Load:** a flood of strangers' invitations with distinct call ids costs one `wakeAge` round trip each on a phone, plus one cache read each where native cannot vouch. Each is bounded by the budget, and refused rings are log lines, not rows.

## Tests the recast must pass (beyond #443's)

- A person's invitation with native answering `Woke` rings while the cache is **held forever**. That proves a vouched call never waits on the cache.
- On desktop with a held cache, `wakeAdmissionFor(call)` is non-null for the whole lookup and closes within the budget, refused and logged `conduct_unreadable`. That proves neither an early release nor a hold forever.
- On desktop, a fresh invitation whose lookup outlasts the rest of the freshness window still rings, because it is judged from arrival.
- A consented agent's fresh invitation never asks native (design 23's property, on its true population).
