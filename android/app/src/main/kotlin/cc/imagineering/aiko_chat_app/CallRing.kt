package cc.imagineering.aiko_chat_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import java.util.concurrent.CopyOnWriteArraySet
import org.json.JSONObject

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
 * ## Calling is v2-only (design 22 v2.0)
 *
 * A call IS its id, `m` (a call/2 ULID the caller signed into the invite). A
 * wake without one is not a call: no store build ever placed a v1 call, and the
 * island no longer wakes for v1 bodies (island PR #192). It is dropped.
 *
 * ## Three cells, each with ONE lifetime (design 22 v4.1)
 *
 * ```
 *  ring        {channel, callId, instance}  invite → retire        persisted
 *  session     {channel, callId, phase}     answer | Dart start    answered: persisted,
 *              phase = answered | live      → end of that call       crash grace ANSWERED_TRUST_MS
 *                                                                  live: process memory
 *  tombstones  callId → at                  every retire / end     persisted, TOMBSTONE_TTL_MS,
 *                                                                  pruned on every write
 * ```
 *
 * - `instance` is NOT a call identity. It names this ring's notification
 *   artifacts (PendingIntents, the ring activity), so a tap on a replaced ring's
 *   button acts on nothing. Dart never sees it.
 * - The tombstone is what makes a call ring AT MOST ONCE on this device: a
 *   redelivered invite for an ended call is dropped, and Dart is told on listen
 *   so a late websocket invite never rings as a banner either.
 * - `live` lives in process memory because the media does: when the process
 *   dies, the call is over, and a persisted `live` would refuse calls forever.
 *
 * ## Every door reads the same fact (design 22 v4.2)
 *
 * - Second answer: refused while the session cell holds ANY call — incoming of
 *   any age, outgoing, answered or live. Refused BEFORE anything is written or
 *   emitted. (A second answer is refused at every door, the pinned product
 *   rule; design 22 v3.1.)
 * - `oneChannelPerCall`: an invite or end naming a known call on a different
 *   channel is a bad payload, refused before any effect. Equality is the call id
 *   alone; this is the one place the channel rule lives on Android.
 * - Every emit to Dart is POSTED INSIDE the critical section that made its
 *   transition, so the main looper's FIFO delivers them in transition order: an
 *   `ended` committed after an `answered` is never observed first. (design 22
 *   v2.4; Tesla, PR #210 v2 round 3.)
 *
 * Every path that ends a ring goes through [retire]; nothing else takes down
 * the notification, the ring screen or a ring-started engine.
 *
 * **PERSISTED, AND DATED IN ONE CLOCK OF ONE BOOT.** The process that starts a
 * ring is not the one that ends it, so the cells live in SharedPreferences,
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
   * notification with no end would ring until the battery dies.
   *
   * **30s = the island's `RING_CEILING_SECONDS`** — the product ceiling (Nick,
   * 2026-09-09), which the island also uses as the FCM invite TTL.
   */
  const val RING_CEILING_MS = 30_000L

  /**
   * Crash grace for an ANSWERED session that no live process has confirmed:
   * the window in which an answer given before Dart was up is still held for
   * it. Matches Dart's `kSystemCallRingTrust` (120s). Once Dart starts the call
   * ([callStartedFromDart]) the session is `live` and this no longer applies.
   */
  const val ANSWERED_TRUST_MS = 120_000L

  /**
   * How long an ended call stays ended on this device — the tombstone.
   *
   * **2 × the longest an invitation can wait in a push provider**, so no
   * redelivery of an invite can outlive its tombstone. The island's invite
   * lifetimes (PR #192): FCM and APNs VoIP `push_result.RING_CEILING_SECONDS`
   * (30s), APNs alert `apns._ALERT_EXPIRATION_SECONDS` (60s, the max). So
   * 2 × 60s. The same number as Dart's `kCallTombstoneTtl` and Swift's, pinned
   * by `system_call_channel_contract_test.dart`. If the island moves either
   * constant (claude-tasks#4233), this moves.
   */
  const val TOMBSTONE_TTL_MS = 120_000L

  /**
   * One line per DECISION, never per payload byte. The first hardware run
   * (2026-10-05) failed with this file silent, and an empty log is equally good
   * evidence for every hypothesis. Ids only; they are opaque and already in the
   * island's own logs.
   */
  private const val TAG = "AikoRing"

  private const val PREFS = "aiko_call_ring"

  private data class Ring(val channel: String, val callId: String, val instance: Long)

  private data class Answered(val channel: String, val callId: String, val at: Long)

  private data class Live(val channel: String, val callId: String)

  private val main = Handler(Looper.getMainLooper())

  /** Guards every cell: FCM's worker and the main thread read-modify-write them. */
  private val lock = Any()

  /**
   * The call Dart has started in THIS process (outgoing, or answered and
   * joined). Process memory on purpose — see the class doc. Under [lock].
   */
  private var live: Live? = null

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
   * rest, never fail on an extra one (design 16 v2 §7c).
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
    val rawCall = data["m"]
    Log.i(TAG, "handle: k=${data["k"]} c=$channel m=$rawCall")
    // The one place the wire's `m` becomes a call. Absent: not a call (v1 is
    // history, design 22 v2.0). Malformed: a bad payload. Either way, dropped.
    val callId = rawCall?.takeIf { CALL_ID.matches(it) } ?: return
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

  /**
   * THE door policy for a call's channel: a call is one DM today. The single
   * seam a cross-channel gathering (island #3196) would change — Dart's
   * `oneChannelPerCall` and Swift's are its twins.
   */
  private fun oneChannelPerCall(stored: String, seen: String) = stored == seen

  /**
   * The answer this device is holding for Dart, if any — the snapshot a new
   * `call/actions` listener is handed instead of a replayed event queue.
   */
  fun heldAnswer(context: Context): Pair<String, String>? =
    answerSlot(context.applicationContext)?.let { it.channel to it.callId }

  /**
   * Calls this device has ended and still remembers — handed to a new listener
   * as `ended` events, so a call declined before Dart existed never rings as a
   * banner when its invite arrives over the websocket (design 22 v4.2).
   */
  fun tombstonedCalls(context: Context): List<Pair<String, String>> =
    synchronized(lock) {
      val app = context.applicationContext
      // NEVER the call this device is holding an answer for. Answering
      // tombstones the RING (it can never ring again), and replaying that as
      // `ended` ahead of the answer snapshot made Dart record the answered
      // call as system-ended — its invitation then arrived dead, was never
      // admitted, and the cold-start answer timed out. (Fix-interaction pass,
      // design 22 build: tombstone-on-answer × replay-on-listen.)
      val held = readAnswerApplied(app)?.callId
      val inProcess = live?.callId
      liveTombstones(app)
        .filterKeys { it != held && it != inProcess }
        .map { (callId, t) -> t.channel to callId }
    }

  /**
   * Whether a ring, or an answer not yet joined, needs the engine kept past
   * its activity — MainActivity hands the engine back instead of destroying it
   * while this is true. NOT a live call: backing out of a live call closes it,
   * as before; keeping it would run a call (and a camera) with no UI.
   * (Fix-interaction pass, design 22 build.)
   */
  fun holdsEngineForRing(context: Context): Boolean {
    val app = context.applicationContext
    return ringSlot(app) != null || answerSlot(app) != null
  }

  /**
   * Whether anything at all needs the engine — the retire runnable's test for
   * "is a headless engine nobody's" (design 22 v4.3).
   */
  fun holdsEngine(context: Context): Boolean {
    val app = context.applicationContext
    return ringSlot(app) != null || synchronized(lock) { live != null } || answerSlot(app) != null
  }

  /** Whether [instance] is the ring that is live right now. */
  fun isLive(context: Context, instance: Long): Boolean =
    ringSlot(context.applicationContext)?.instance == instance

  // ---- transitions ---------------------------------------------------------

  /** Whether [callId] names a call the session cell holds, answered or live. */
  private fun inSession(app: Context, callId: String): Boolean =
    live?.callId == callId || readAnswerApplied(app)?.callId == callId

  /** invite(c, m). */
  private fun ring(app: Context, channel: String, callId: String) {
    var displaced: Ring? = null
    val ring: Ring
    synchronized(lock) {
      // REFUSALS FIRST, every one before any side effect (design 22 §2).
      if (liveTombstones(app).containsKey(callId)) {
        Log.i(TAG, "ring: m=$callId already ended on this device, dropped")
        return
      }
      val current = ringSlot(app)
      if (current != null && current.callId == callId) {
        if (!oneChannelPerCall(current.channel, channel)) {
          Log.i(TAG, "ring: m=$callId on $channel, but it rings on ${current.channel} — bad payload")
        } else {
          Log.i(TAG, "ring: duplicate of the live ring (m=$callId), ignored")
        }
        return
      }
      if (inSession(app, callId)) {
        // The second token, or an FCM retry, arriving after the user already
        // answered. Re-ringing would sound a call they are in. (PR #210 r3.)
        Log.i(TAG, "ring: duplicate of the call in session (m=$callId), ignored")
        return
      }
      displaced = current
      ring = Ring(channel, callId, SystemClock.elapsedRealtime())
      displaced?.let { retireLocked(app, it, ended = true) }
      writeRing(app, ring)
    }
    // displace: the old ring is retired BEFORE the new one is drawn, so its
    // screen finishes (by instance) rather than staying bound to a replaced
    // caller, and the new full-screen intent is a fresh launch.
    displaced?.let {
      Log.i(TAG, "ring: m=${it.callId} displaced by m=$callId")
      IncomingCallNotifier.dismiss(app, it.instance)
    }
    Log.i(TAG, "ring: c=$channel m=$callId instance=${ring.instance}")
    IncomingCallNotifier.show(app, channel, callId, ring.instance, "Aiko Chat")
    // The ring was written under the lock and drawn after it. If it was ended
    // in that gap (Dart's endFromDart, from the in-app banner), its dismiss ran
    // before this show and cancelled nothing — and an INSISTENT ring would
    // sound over an empty slot until the timeout (Tesla, design 22 delta
    // review). Re-read the slot now that the notification is up.
    if (!isLive(app, ring.instance)) IncomingCallNotifier.dismiss(app, ring.instance)
    // Start Dart NOW, while the phone rings, exactly as a VoIP push starts the
    // Flutter engine on iOS: the signed invitation is admitted inside its 10s
    // freshness window while ringing, and held for kSystemCallRingTrust — so a
    // late Answer finds it admitted (the #3588 trap). Main-thread only.
    main.post { AikoEngine.warm(app) }
    main.postDelayed({ deadline(app, ring.instance) }, RING_CEILING_MS)
  }

  /** end(c, m): the caller hung up. Any thread. */
  private fun end(app: Context, channel: String, callId: String) {
    var stoppedRing: Ring? = null
    synchronized(lock) {
      val current = ringSlot(app)
      if (current != null && current.callId == callId) {
        // The door, BEFORE any effect (Carnot, design 22 temper round 3).
        if (!oneChannelPerCall(current.channel, channel)) {
          Log.i(TAG, "end: m=$callId names ${current.channel}, wake said $channel — refused")
          return
        }
        clearRing(app)
        // A call can be ringing AND live at once (Dart joined it in-app before
        // the native ring was retired); its end clears both (Tesla, design 22
        // delta review).
        if (live?.callId == callId) live = null
        retireLocked(app, current, ended = true)
        stoppedRing = current
      } else {
        val answered = readAnswerApplied(app)?.takeIf { it.callId == callId }
        val inLive = live?.takeIf { it.callId == callId }
        val stored = answered?.channel ?: inLive?.channel
        if (stored == null) {
          // Still tombstoned, so a late invite for it never rings.
          tombstone(app, callId, channel)
          Log.i(TAG, "end: m=$callId names no call on this device, tombstoned")
          return
        }
        if (!oneChannelPerCall(stored, channel)) {
          Log.i(TAG, "end: m=$callId names $stored, wake said $channel — refused")
          return
        }
        // Answered (or joined), then the caller hung up. What is left is the
        // session Dart is holding, and `ended` is what drops it — so the
        // camera never opens into a room the caller left. Posted INSIDE the
        // lock, so it can never overtake the `answered` it follows.
        clearAnswer(app)
        if (inLive != null) live = null
        tombstone(app, callId, stored)
        CallChannels.emit(CallChannels.ACTION_ENDED, stored, callId)
        Log.i(TAG, "end: m=$callId ended after answer")
      }
    }
    stoppedRing?.let {
      Log.i(TAG, "end: m=$callId stopped while ringing")
      IncomingCallNotifier.dismiss(app, it.instance)
    }
  }

  /** decline(instance): the user declined THIS ring. */
  fun decline(context: Context, instance: Long) {
    val app = context.applicationContext
    val declined = synchronized(lock) {
      ringSlot(app)?.takeIf { it.instance == instance }?.also {
        clearRing(app)
        retireLocked(app, it, ended = true)
      }
    }
    if (declined == null) {
      Log.i(TAG, "decline: instance $instance is not live, no-op")
      return
    }
    Log.i(TAG, "decline: m=${declined.callId}")
    IncomingCallNotifier.dismiss(app, declined.instance)
  }

  /**
   * answer(instance). Called ONLY from [IncomingCallActivity], which is not
   * exported — an exported component that answers on an intent extra would let
   * any app on the device open the camera into a call. (PR #210 round 1.)
   *
   * Keyed by INSTANCE, so an unlock that completes after this ring was displaced
   * answers nothing rather than the call that replaced it. (PR #210 round 3.)
   *
   * **REFUSED while any call is in session** — answered or live, incoming or
   * outgoing — before anything is written or emitted: a second answer is
   * refused at every door (design 22 v3.1 / v4.2). The refused ring is retired,
   * which ends it for the caller exactly as a decline does.
   *
   * Returns whether the call was answered.
   */
  fun answer(context: Context, instance: Long): Boolean {
    val app = context.applicationContext
    var refused: Ring? = null
    val answered = synchronized(lock) {
      val current = ringSlot(app)?.takeIf { it.instance == instance } ?: return@synchronized null
      if (live?.callId == current.callId) {
        // Already live in Dart (joined in-app): the notification is stale. Not
        // a second answer, and not a fresh crash-grace cell either — that would
        // re-arm what the join superseded (Tesla, design 22 delta review).
        clearRing(app)
        retireLocked(app, current, ended = false)
        return@synchronized current
      }
      val busy = live ?: readAnswerApplied(app)?.let { Live(it.channel, it.callId) }
      if (busy != null && busy.callId != current.callId) {
        clearRing(app)
        retireLocked(app, current, ended = true)
        refused = current
        return@synchronized null
      }
      clearRing(app)
      writeAnswer(app, Answered(current.channel, current.callId, SystemClock.elapsedRealtime()))
      // The ring is over for this device; it can never ring again.
      tombstone(app, current.callId, current.channel)
      // Posted INSIDE the lock, ahead of any `ended` a racing call_end could
      // post for this call (Tesla, PR #210 v2 round 3).
      CallChannels.emit(CallChannels.ACTION_ANSWERED, current.channel, current.callId)
      retireLocked(app, current, ended = false)
      current
    }
    refused?.let {
      Log.i(TAG, "answer: m=${it.callId} refused — a call is already in session")
      IncomingCallNotifier.dismiss(app, it.instance)
      return false
    }
    if (answered == null) {
      Log.i(TAG, "answer: instance $instance is not live, refused")
      return false
    }
    Log.i(TAG, "answer: m=${answered.callId}")
    IncomingCallNotifier.dismiss(app, answered.instance)
    return true
  }

  /**
   * callStarted(c, m): Dart has a call live in this process — outgoing from
   * the moment it was placed, incoming from the moment it was joined. From here
   * a second system answer is refused until Dart ends it (design 22 v4.2).
   * The answered cell is superseded: `live` is the fact now.
   */
  fun callStartedFromDart(context: Context, channel: String, callId: String) {
    val app = context.applicationContext
    val ring = synchronized(lock) {
      live = Live(channel, callId)
      readAnswer(app)?.takeIf { it.callId == callId }?.let { clearAnswer(app) }
      // The call is live; a native ring for it is over (it was answered in
      // the app). Left up, its Answer could be pressed into a second
      // `answered` (Tesla, design 22 delta review).
      readRing(app)?.takeIf { it.callId == callId }?.also {
        clearRing(app)
        retireLocked(app, it, ended = false)
      }
    }
    Log.i(TAG, "callStarted: m=$callId")
    ring?.let { IncomingCallNotifier.dismiss(app, it.instance) }
  }

  /**
   * The engine that held Dart is being destroyed, so no call can be live in
   * this process any more (design 22 delta review: the session is the media).
   */
  fun mediaGone() {
    synchronized(lock) { live = null }
  }

  /**
   * dartEnd(c, m): Dart's `endSystemCall` — the in-app ring was answered or
   * ignored, a join failed, a call screen closed. Ends exactly that call,
   * wherever it is held. Tells Dart nothing: Dart is deciding.
   */
  fun endFromDart(context: Context, channel: String, callId: String) {
    val app = context.applicationContext
    val ring = synchronized(lock) {
      tombstone(app, callId, channel)
      if (live?.callId == callId) live = null
      readAnswer(app)?.takeIf { it.callId == callId }?.let { clearAnswer(app) }
      ringSlot(app)?.takeIf { it.callId == callId }?.also {
        clearRing(app)
        retireLocked(app, it, ended = false)
      }
    }
    Log.i(TAG, "endFromDart: m=$callId ringing=${ring != null}")
    ring?.let { IncomingCallNotifier.dismiss(app, it.instance) }
  }

  /** The deadline timer: the ring it was armed for, if still current. */
  private fun deadline(app: Context, instance: Long) {
    val expired = synchronized(lock) {
      readRing(app)?.takeIf { it.instance == instance }?.also {
        clearRing(app)
        retireLocked(app, it, ended = true)
      }
    }
    if (expired != null) {
      Log.i(TAG, "deadline: m=${expired.callId} hit ${RING_CEILING_MS}ms")
      IncomingCallNotifier.dismiss(app, expired.instance)
    }
  }

  // ---- the one exit from a ring ---------------------------------------------

  /**
   * Takes down what a ring put up, except its notification (a binder call,
   * which the caller makes OUTSIDE the lock via [IncomingCallNotifier.dismiss],
   * by this ring's own tag). CALLED UNDER [lock], so the runnable it posts is
   * queued in transition order with every other emit (design 22 v2.4).
   *
   * Tombstones the call. When the ring [ended] without being taken, the posted
   * runnable either releases the headless engine it started (nobody to tell)
   * or tells Dart which call ended. It decides only WHETHER anyone is
   * listening; what happened is sealed here, now.
   */
  private fun retireLocked(app: Context, ring: Ring, ended: Boolean) {
    tombstone(app, ring.callId, ring.channel)
    val listeners = stopListeners.toList()
    main.post {
      listeners.forEach { it.onRingStopped(ring.instance) }
      if (!ended) return@post
      // The engine belongs to whatever the cells still hold: a newer ring, or
      // a call in session. Only when they are empty is a headless engine
      // nobody's, and then there is nobody to tell. (design 22 v4.3)
      if (holdsEngine(app) || !AikoEngine.releaseIfHeadless()) {
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
      retireLocked(app, r, ended = true)
      expired = r
    }
    Log.i(TAG, "deadline: m=${expired.callId} expired on read")
    IncomingCallNotifier.dismiss(app, expired.instance)
    return null
  }

  /** The held answer, crash grace APPLIED. */
  private fun answerSlot(app: Context): Answered? = synchronized(lock) { readAnswerApplied(app) }

  /** Under [lock]. */
  private fun readAnswerApplied(app: Context): Answered? {
    val a = readAnswer(app) ?: return null
    val age = SystemClock.elapsedRealtime() - a.at
    return if (age in 0..ANSWERED_TRUST_MS) a else { clearAnswer(app); null }
  }

  private fun prefs(app: Context) = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private fun readRing(app: Context): Ring? {
    val p = prefs(app)
    val channel = p.getString("r_channel", null) ?: return null
    val callId = p.getString("r_call", null) ?: return null
    if (p.getInt("r_boot", -1) != bootCount(app)) return null
    return Ring(channel, callId, p.getLong("r_at", 0L))
  }

  private fun readAnswer(app: Context): Answered? {
    val p = prefs(app)
    val channel = p.getString("a_channel", null) ?: return null
    val callId = p.getString("a_call", null) ?: return null
    if (p.getInt("a_boot", -1) != bootCount(app)) return null
    return Answered(channel, callId, p.getLong("a_at", 0L))
  }

  private data class Tomb(val channel: String, val at: Long)

  /**
   * Tombstones still inside [TOMBSTONE_TTL_MS], this boot. Under [lock]. A
   * tombstone from another boot is expired by definition (its clock restarted).
   */
  private fun liveTombstones(app: Context): Map<String, Tomb> {
    val p = prefs(app)
    if (p.getInt("t_boot", -1) != bootCount(app)) return emptyMap()
    val json = runCatching { JSONObject(p.getString("t_calls", "{}") ?: "{}") }
      .getOrElse { JSONObject() }
    val now = SystemClock.elapsedRealtime()
    val out = mutableMapOf<String, Tomb>()
    for (key in json.keys()) {
      val entry = json.optJSONObject(key) ?: continue
      val tomb = Tomb(entry.optString("c"), entry.optLong("at", -1L))
      if (tomb.channel.isNotEmpty() && now - tomb.at in 0..TOMBSTONE_TTL_MS) out[key] = tomb
    }
    return out
  }

  /**
   * Remember [callId] (on [channel]) as ended. PRUNES ON EVERY WRITE, so the
   * store holds only the last [TOMBSTONE_TTL_MS] of calls and cannot grow
   * without bound (Kelvin, design 22 temper rounds 1 and 3). Under [lock].
   */
  private fun tombstone(app: Context, callId: String, channel: String) {
    val kept = liveTombstones(app).toMutableMap()
    kept[callId] = Tomb(channel, SystemClock.elapsedRealtime())
    val json = JSONObject()
    kept.forEach { (k, t) -> json.put(k, JSONObject().put("c", t.channel).put("at", t.at)) }
    prefs(app).edit()
      .putString("t_calls", json.toString()).putInt("t_boot", bootCount(app)).commit()
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
