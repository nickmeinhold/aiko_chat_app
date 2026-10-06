package cc.imagineering.aiko_chat_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import java.util.concurrent.CopyOnWriteArraySet

/**
 * The Android ring's state machine, and the total function on `k`.
 *
 * The Android counterpart of `CallKitRinger` in `ios/Runner/AppDelegate.swift`,
 * minus the one obligation that shapes almost all of that class: Android has no
 * must-report rule. A push that should not ring is simply not rung.
 *
 * **THE PUSH IS TRUSTED FOR ONE THING: "ring / end call `m` on channel `c`".**
 * It is unsigned island data. Nothing here joins a room, opens a camera or
 * names a caller. The signed invitation is judged by `admitRing` in Dart, which
 * this file never bypasses — answering hands Dart an `answered` action, and
 * `SystemCallNavigator` joins only an invitation `admitRing` admitted.
 *
 * ## Two identities (design 21 v2)
 *
 * - **`callId` (`m` on the wire)** — WHAT the call is. A ULID the caller minted
 *   and signed into the invite body (island design 12, Decision 1). Decides
 *   duplicate-vs-new: the same invite delivered twice carries the same `m`; a
 *   new call on the same channel carries a new one. Absent for a v1 call, which
 *   falls back to the channel, as before — the weakness stays confined to v1.
 * - **`instance`** — WHICH ring a screen, timer or callback belongs to. Minted
 *   here, per ring (its `elapsedRealtime` start). The ring screen, the stop
 *   listeners and the keyguard callback all carry it, so a stale one can never
 *   act on a newer ring — of the same call or any other.
 *
 * ## Two slots, because Ringing and Answered are different facts
 *
 * ```
 *  RING slot    {channel, callId?, instance}   lives RING_CEILING_MS
 *  ANSWER slot  {channel, callId?}             lives ANSWERED_TRUST_MS
 *
 *  invite(c,m)  same call as RING or ANSWER → duplicate, dropped
 *               otherwise → displace RING if live (retire it), RING := (c,m,new)
 *               — ANSWER is never touched by an invite
 *  end(c,m)     same call as RING   → RING := ∅, retire, ENDED
 *               same call as ANSWER → ANSWER := ∅, tell Dart `ended(c,m)`
 *  answer(i)    RING.instance == i  → ANSWER := (RING.c, RING.m), RING := ∅,
 *                                     retire, tell Dart `answered(c,m)`
 *  dartEnd(c)   clears whichever slot names c
 *  deadline     RING past its ceiling → retire, ENDED (timer by instance, or
 *               any read); ANSWER past its trust → cleared
 * ```
 *
 * "Same call": both carry an `m` and they are equal; or neither does (v1) and
 * the channels match. A v1 invite after a v1 answer on the same channel is
 * dropped as a duplicate — v1 cannot say otherwise, and dropping a re-ring of a
 * call you are already in is the safer of the two wrong answers.
 *
 * Every path that ends a ring goes through [retire]; nothing else takes down
 * the notification, the ring screen or a ring-started engine. One exit, so no
 * path can assume another did the cleanup — the backstop bug of PR #210 round
 * 2 was two paths each assuming exactly that.
 *
 * **PERSISTED, AND DATED IN ONE CLOCK OF ONE BOOT.** The process that starts a
 * ring is not the one that ends it, so both slots live in SharedPreferences,
 * stamped with `elapsedRealtime` (the clock the notification timeout and the
 * timer use) and the boot count (because that clock restarts at boot).
 */
object CallRing {
  /** `WakeKind` values on the island (`push_result.py`). Add, never edit. */
  const val KIND_INVITE = "call_invite"
  const val KIND_END = "call_end"

  /** Intent extras. `c` and `m` are the island's own keys. */
  const val EXTRA_CHANNEL = "c"
  const val EXTRA_CALL = "m"
  const val EXTRA_INSTANCE = "aiko.call.instance"

  /**
   * Set on the intent that opens [IncomingCallActivity] from the notification's
   * Answer button. The answer is decided THERE, never on MainActivity — see
   * [answer] for why.
   */
  const val EXTRA_AUTO_ANSWER = "aiko.call.autoAnswer"

  /**
   * How long one ring may last on this device, with or without a `call_end`.
   *
   * A BACKSTOP, NOT THE CEILING. The island owns the ring's lifetime and ends
   * it with `call_end` (design 16 v2 §3). This exists because that end can be
   * lost — the invite/end pair is not atomic (#4325) — and an insistent
   * notification with no end would ring until the battery dies. 60s matches
   * what CallKit was MEASURED to do on iOS (n=1), so the two platforms give up
   * at about the same moment.
   */
  const val RING_CEILING_MS = 60_000L

  /**
   * How long an answered call can still be ended by the caller's `call_end`.
   * Matches Dart's `kSystemCallRingTrust` (120s) — the window in which an
   * answered-but-not-joined call is held — so the two halves forget an answer
   * at the same moment.
   */
  const val ANSWERED_TRUST_MS = 120_000L

  /**
   * One line per DECISION, never per payload byte. The first hardware run
   * (2026-10-05) failed with this file silent, and an empty log is equally good
   * evidence for every hypothesis. Ids only; they are opaque and already in the
   * island's own logs.
   */
  private const val TAG = "AikoRing"

  private const val PREFS = "aiko_call_ring"

  private data class Ring(val channel: String, val callId: String?, val instance: Long)

  private data class Answered(val channel: String, val callId: String?, val at: Long)

  private val main = Handler(Looper.getMainLooper())

  /** Guards both slots: FCM's worker and the main thread read-modify-write them. */
  private val lock = Any()

  /** Anything that must vanish when ITS ring stops — the lock-screen activity. */
  fun interface StopListener {
    fun onRingStopped(instance: Long)
  }

  // Copy-on-write so [retire] can snapshot from any thread while an activity
  // registers on main. Registration is synchronous: it used to be posted, and a
  // stop landing in that gap finished nobody (PR #210 round 1).
  private val stopListeners = CopyOnWriteArraySet<StopListener>()

  fun addStopListener(l: StopListener) { stopListeners.add(l) }

  fun removeStopListener(l: StopListener) { stopListeners.remove(l) }

  /**
   * One FCM delivery. **Permissive decode**: read the keys we know, ignore the
   * rest, never fail on an extra one (design 16 v2 §7c). A missing `m` means a
   * v1 call, and nothing else — the island sends `m` exactly for v2.
   *
   * **SYNCHRONOUS, ON FCM'S WORKER, INSIDE ITS WAKE LOCK.** The service holds a
   * partial wake lock only until `onMessageReceived` returns; the transition,
   * the notification and the stop all happen before this returns, and only the
   * engine and the listeners are posted to main. (PR #210 round 1.)
   */
  fun handle(context: Context, data: Map<String, String>) {
    // A calling-off build never rings, even with an island sending call wakes.
    if (!BuildConfig.CALLING_ENABLED) {
      Log.i(TAG, "handle: calling disabled in this build, k=${data["k"]}")
      return
    }
    val app = context.applicationContext
    val channel = data["c"]?.takeIf { it.isNotEmpty() }
    // A present-but-malformed `m` is not "v1": the island only ever copies a
    // grammar-checked id out of the signed body, so a bad one is a bad payload,
    // and a bad payload never rings.
    val rawCall = data["m"]
    val callId = rawCall?.takeIf { CALL_ID.matches(it) }
    Log.i(TAG, "handle: k=${data["k"]} c=$channel m=$rawCall")
    if (rawCall != null && callId == null) return
    when (data["k"]) {
      KIND_INVITE -> if (channel != null) ring(app, channel, callId)
      KIND_END -> if (channel != null) end(app, channel, callId)
      // Unknown or missing `k`: NEVER ring (a kind added island-side must not
      // become a ring on an older build). Ordinary message wakes land here too;
      // the plugin's receiver still hands them to Dart.
      else -> Unit
    }
  }

  /**
   * The SAME grammar as `call_wire.dart` and the island's `parse_call_body`:
   * canonical uppercase Crockford, leading 0-7 (fits 128 bits).
   */
  private val CALL_ID = Regex("[0-7][0-9A-HJKMNP-TV-Z]{25}")

  /** The live ring's instance, if [channel] is ringing — for the ring screen. */
  fun ringingInstance(context: Context, channel: String): Long? =
    ringSlot(context.applicationContext)?.takeIf { it.channel == channel }?.instance

  /**
   * The answer this device is holding for Dart, if any — the snapshot a new
   * `call/actions` listener is handed instead of a replayed event queue. Lives
   * [ANSWERED_TRUST_MS] and is cleared by Dart's own end, so a finished call is
   * never re-announced.
   */
  fun heldAnswer(context: Context): Pair<String, String?>? =
    answerSlot(context.applicationContext)?.let { it.channel to it.callId }

  /** Whether any ring is live — MainActivity keeps the engine for it. */
  fun isRinging(context: Context): Boolean = ringSlot(context.applicationContext) != null

  /** Whether [instance] is the ring that is live right now. */
  fun isLive(context: Context, instance: Long): Boolean =
    ringSlot(context.applicationContext)?.instance == instance

  // ---- transitions ---------------------------------------------------------

  private fun sameCall(aChannel: String, aCall: String?, bChannel: String, bCall: String?) =
    if (aCall != null || bCall != null) aCall == bCall else aChannel == bChannel

  /** invite(c, m). */
  private fun ring(app: Context, channel: String, callId: String?) {
    var displaced: Ring? = null
    val ring: Ring
    synchronized(lock) {
      val live = ringSlot(app)
      val answered = answerSlot(app)
      if (live != null && sameCall(live.channel, live.callId, channel, callId)) {
        Log.i(TAG, "ring: duplicate of the live ring (c=$channel m=$callId), ignored")
        return
      }
      if (answered != null && sameCall(answered.channel, answered.callId, channel, callId)) {
        // The second token, or an FCM retry, arriving after the user already
        // answered. Re-ringing would sound a call they are in. (PR #210 r3.)
        Log.i(TAG, "ring: duplicate of the answered call (c=$channel m=$callId), ignored")
        return
      }
      displaced = live
      ring = Ring(channel, callId, SystemClock.elapsedRealtime())
      writeRing(app, ring)
    }
    // displace: the old ring is retired BEFORE the new one is drawn, so its
    // screen finishes (by instance) rather than staying bound to a replaced
    // caller, and the new full-screen intent is a fresh launch.
    displaced?.let {
      Log.i(TAG, "ring: ${it.channel}/${it.callId} displaced")
      retire(app, it, ended = false)
    }
    Log.i(TAG, "ring: c=$channel m=$callId instance=${ring.instance}")
    IncomingCallNotifier.show(app, channel, callId, ring.instance, "Aiko Chat")
    // Start Dart NOW, while the phone rings, exactly as a VoIP push starts the
    // Flutter engine on iOS: the signed invitation is admitted inside its 10s
    // freshness window while ringing, and held for kSystemCallRingTrust — so a
    // late Answer finds it admitted (the #3588 trap). Main-thread only.
    main.post { AikoEngine.warm(app) }
    main.postDelayed({ deadline(app, ring.instance) }, RING_CEILING_MS)
  }

  /** end(c, m): the caller hung up. Any thread. */
  private fun end(app: Context, channel: String, callId: String?) {
    var ended: Ring? = null
    var hungUpAfterAnswer: Answered? = null
    synchronized(lock) {
      val live = ringSlot(app)
      if (live != null && sameCall(live.channel, live.callId, channel, callId)) {
        clearRing(app); ended = live
      } else {
        val answered = answerSlot(app)
        if (answered != null && sameCall(answered.channel, answered.callId, channel, callId)) {
          clearAnswer(app); hungUpAfterAnswer = answered
        }
      }
    }
    ended?.let {
      Log.i(TAG, "end: c=$channel m=$callId stopped while ringing")
      retire(app, it, ended = true)
      return
    }
    hungUpAfterAnswer?.let {
      // Answered, then the caller hung up before the join. The ring is already
      // down; what is left is the answer Dart is holding, and `ended` is what
      // drops it — so the camera never opens into a room the caller left.
      Log.i(TAG, "end: c=$channel m=$callId ended after answer")
      CallChannels.emit(CallChannels.ACTION_ENDED, it.channel, it.callId)
      return
    }
    Log.i(TAG, "end: c=$channel m=$callId names no call on this device, no-op")
  }

  /** decline(instance): the user declined THIS ring. */
  fun decline(context: Context, instance: Long) {
    val app = context.applicationContext
    val live = synchronized(lock) {
      ringSlot(app)?.takeIf { it.instance == instance }?.also { clearRing(app) }
    }
    if (live == null) {
      Log.i(TAG, "decline: instance $instance is not live, no-op")
      return
    }
    Log.i(TAG, "decline: c=${live.channel} m=${live.callId}")
    retire(app, live, ended = true)
  }

  /**
   * answer(instance). Called ONLY from [IncomingCallActivity], which is not
   * exported — an exported component that answers on an intent extra would let
   * any app on the device open the camera into a call. (PR #210 round 1.)
   *
   * Keyed by INSTANCE, so an unlock that completes after this ring was displaced
   * answers nothing rather than the call that replaced it. (PR #210 round 3.)
   * Returns whether there was a ring to answer.
   */
  fun answer(context: Context, instance: Long): Boolean {
    val app = context.applicationContext
    val live = synchronized(lock) {
      ringSlot(app)?.takeIf { it.instance == instance }?.also {
        clearRing(app)
        writeAnswer(app, Answered(it.channel, it.callId, SystemClock.elapsedRealtime()))
      }
    }
    if (live == null) {
      Log.i(TAG, "answer: instance $instance is not live, refused")
      return false
    }
    Log.i(TAG, "answer: c=${live.channel} m=${live.callId}")
    retire(app, live, ended = false)
    CallChannels.emit(CallChannels.ACTION_ANSWERED, live.channel, live.callId)
    return true
  }

  /**
   * dartEnd(c): Dart's `endSystemCall` — the in-app ring was answered or
   * ignored, a join failed, a call screen closed. Safe for any channel (the
   * bridge's documented contract). Tells Dart nothing: Dart is deciding.
   */
  fun endFromDart(context: Context, channel: String) {
    val app = context.applicationContext
    var ring: Ring? = null
    synchronized(lock) {
      ringSlot(app)?.takeIf { it.channel == channel }?.let { clearRing(app); ring = it }
      answerSlot(app)?.takeIf { it.channel == channel }?.let { clearAnswer(app) }
    }
    Log.i(TAG, "endFromDart: $channel ringing=${ring != null}")
    ring?.let { retire(app, it, ended = false) }
  }

  /** The deadline timer: the ring it was armed for, if still current. */
  private fun deadline(app: Context, instance: Long) {
    val live = synchronized(lock) {
      readRing(app)?.takeIf { it.instance == instance }?.also { clearRing(app) }
    }
    if (live != null) {
      Log.i(TAG, "deadline: c=${live.channel} hit ${RING_CEILING_MS}ms")
      retire(app, live, ended = true)
    }
  }

  // ---- the one exit from a ring ---------------------------------------------

  /**
   * Takes down everything a ring put up: the notification, the ring screen
   * bound to THIS instance, and — when the ring [ended] without being taken —
   * the headless engine it started, or, if an engine survives, tells Dart which
   * call ended. The slot is already cleared by the caller.
   */
  private fun retire(app: Context, ring: Ring, ended: Boolean) {
    IncomingCallNotifier.dismiss(app, ring.instance)
    val listeners = stopListeners.toList()
    main.post {
      listeners.forEach { it.onRingStopped(ring.instance) }
      if (!ended) return@post
      // A still-headless engine cannot be holding an answer — answering
      // attaches an activity — so when it is destroyed there is nobody to tell.
      // Deciding that BEFORE emitting is what stops an `ended` from outliving
      // its engine. (PR #210 round 1.)
      if (!AikoEngine.releaseIfHeadless()) {
        CallChannels.emit(CallChannels.ACTION_ENDED, ring.channel, ring.callId)
      }
    }
  }

  // ---- persistence: the only code that touches the record ------------------

  /** The live ring, deadline APPLIED: a ring past its ceiling is retired here. */
  private fun ringSlot(app: Context): Ring? {
    val expired: Ring
    synchronized(lock) {
      val r = readRing(app) ?: return null
      val age = SystemClock.elapsedRealtime() - r.instance
      if (age in 0..RING_CEILING_MS) return r
      clearRing(app)
      expired = r
    }
    Log.i(TAG, "deadline: c=${expired.channel} expired on read")
    retire(app, expired, ended = true)
    return null
  }

  /** The live answer, trust APPLIED. */
  private fun answerSlot(app: Context): Answered? = synchronized(lock) {
    val a = readAnswer(app) ?: return null
    val age = SystemClock.elapsedRealtime() - a.at
    if (age in 0..ANSWERED_TRUST_MS) a else { clearAnswer(app); null }
  }

  private fun prefs(app: Context) = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private fun readRing(app: Context): Ring? {
    val p = prefs(app)
    val channel = p.getString("r_channel", null) ?: return null
    if (p.getInt("r_boot", -1) != bootCount(app)) return null
    return Ring(channel, p.getString("r_call", null), p.getLong("r_at", 0L))
  }

  private fun readAnswer(app: Context): Answered? {
    val p = prefs(app)
    val channel = p.getString("a_channel", null) ?: return null
    if (p.getInt("a_boot", -1) != bootCount(app)) return null
    return Answered(channel, p.getString("a_call", null), p.getLong("a_at", 0L))
  }

  // commit(), not apply(): this process may be killed the moment FCM's
  // callback returns, and a state that never reached disk makes the next
  // process misjudge a real call. (PR #210 round 1.)
  private fun writeRing(app: Context, r: Ring) {
    prefs(app).edit()
      .putString("r_channel", r.channel).putString("r_call", r.callId)
      .putLong("r_at", r.instance).putInt("r_boot", bootCount(app)).commit()
  }

  private fun writeAnswer(app: Context, a: Answered) {
    prefs(app).edit()
      .putString("a_channel", a.channel).putString("a_call", a.callId)
      .putLong("a_at", a.at).putInt("a_boot", bootCount(app)).commit()
  }

  private fun clearRing(app: Context) {
    prefs(app).edit().remove("r_channel").remove("r_call").remove("r_at").remove("r_boot").commit()
  }

  private fun clearAnswer(app: Context) {
    prefs(app).edit().remove("a_channel").remove("a_call").remove("a_at").remove("a_boot").commit()
  }

  /** `Settings.Global.BOOT_COUNT` (API 24+, our minSdk). -2 if unreadable. */
  private fun bootCount(app: Context): Int =
    Settings.Global.getInt(app.contentResolver, Settings.Global.BOOT_COUNT, -2)
}
