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
 * must-report rule. A push that should not ring is simply not rung — there is no
 * "report, then end immediately" cell, because nothing punishes silence.
 *
 * **THE PUSH IS TRUSTED FOR ONE THING: "ring this channel".** It is unsigned
 * island data. Nothing here joins a room, opens a camera or names a caller. The
 * signed invitation is judged by `admitRing` in Dart, which this file never
 * bypasses — answering hands Dart an `answered` action, and
 * `SystemCallNavigator` joins only an invitation `admitRing` admitted.
 *
 * ## The state machine — WRITTEN DOWN, because it was found one bug at a time
 *
 * Cage-match PR #210 rounds 1-2 found five defects that were all one thing: a
 * transition nobody had tabled (answered-then-hung-up, a ring displaced by
 * another channel, a reboot mid-ring, the backstop at the expiry boundary, a
 * stop racing a listener). #139 recorded the same lesson for the Dart ring.
 * So the whole machine is here, and the code below implements THIS table —
 * a transition missing from it is a bug in the table, not in a branch.
 *
 * ```
 *  state \ event │ invite(c)       invite(x≠c)        end/decline(c)    answer(c)      dartEnd(c)  deadline
 *  ──────────────┼─────────────────────────────────────────────────────────────────────────────────────────
 *  Idle          │ → Ringing(c)    → Ringing(x)       no-op             refused        no-op       —
 *  Ringing(c)    │ no-op (dup)     displace→Ring(x)   → Idle, ENDED     → Answered(c)  → Idle      → Idle, ENDED
 *  Answered(c)   │ → Ringing(c)    → Ringing(x)       → Idle, tell Dart refused        → Idle      → Idle
 * ```
 *
 * - **Ringing** puts up the notification and ring screen and warms the engine.
 *   Leaving it by ANY edge goes through [retire], which takes them down — the
 *   one exit, so no path can assume another did the cleanup.
 * - **ENDED** = the ring ended without being taken: a headless engine the ring
 *   started is closed; if an engine survives, Dart is told `ended`.
 * - **Answered** exists so a `call_end` AFTER Answer still reaches Dart: the
 *   caller hangs up while the callee is unlocking, and without this state the
 *   answer joined a room the caller had left. (Carnot + Tesla, round 2.)
 * - **displace** retires the old ring (its screen finishes) before the new one
 *   rings, so the screen never stays bound to a caller who was replaced.
 *   (Tesla, round 2.)
 * - **deadline**: Ringing lasts [RING_CEILING_MS]; Answered lasts
 *   [ANSWERED_TRUST_MS]. Past it the state is Idle whoever reads it — the
 *   backstop timer and every read reach the SAME transition, so the timer can
 *   no longer arrive one millisecond after a read has silently expired the
 *   ring and find nothing to do. (Maxwell, round 2.)
 *
 * **PERSISTED, AND DATED IN ONE CLOCK OF ONE BOOT.** The process that starts a
 * ring is not the one that ends it (iOS learned this with UserDefaults), so the
 * state lives in SharedPreferences. Its timestamp is `elapsedRealtime` — the
 * clock the notification timeout and the timer use, so an NTP step cannot split
 * them (Tesla, round 1) — stamped with the BOOT COUNT, because elapsedRealtime
 * restarts at boot and a stamp from a short previous boot can otherwise land
 * inside the window and read as live (Tesla, round 2).
 */
object CallRing {
  /** `WakeKind` values on the island (`push_result.py`). Add, never edit. */
  const val KIND_INVITE = "call_invite"
  const val KIND_END = "call_end"

  /** Intent extras. `c` is the island's own key for the channel id. */
  const val EXTRA_CHANNEL = "c"

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
   * what CallKit was MEASURED to do on iOS (n=1; see
   * `reference_voip_must_report_measured`), so the two platforms give up at
   * about the same moment.
   */
  const val RING_CEILING_MS = 60_000L

  /**
   * How long an Answered state can still be ended by the caller's `call_end`.
   * Matches Dart's `kSystemCallRingTrust` (120s) — the window in which an
   * answered-but-not-joined call is held — so the two halves forget an answer
   * at the same moment.
   */
  const val ANSWERED_TRUST_MS = 120_000L

  /**
   * One line per DECISION, never per payload byte. The first hardware run
   * (2026-10-05) failed with this file silent: a `call_end` arrived and the
   * ring did not stop, and the log could not say whether `handle` ran, which
   * arm it took, or what the state was. An empty log is equally good evidence
   * for every hypothesis. Channel ids only; they are opaque and already in the
   * island's own logs.
   */
  private const val TAG = "AikoRing"

  private const val PREFS = "aiko_call_ring"
  private const val KEY_PHASE = "phase"
  private const val KEY_CHANNEL = "channel"
  private const val KEY_AT = "at"
  private const val KEY_BOOT = "boot"

  /** The non-Idle states of the table above. Persisted by name. */
  private enum class Phase { RINGING, ANSWERED }

  private data class State(val phase: Phase, val channel: String, val at: Long)

  private val main = Handler(Looper.getMainLooper())

  /** Guards the record: FCM's worker and the main thread both read-modify-write it. */
  private val lock = Any()

  /** Anything that must vanish when the ring stops — the lock-screen activity. */
  fun interface StopListener {
    fun onRingStopped(channelId: String)
  }

  // Copy-on-write so [retire] can snapshot from any thread while an activity
  // registers on main. Registration is SYNCHRONOUS: it used to be posted, so a
  // stop landing between the ring screen's "is this ringing?" check and its
  // registration ran first, finished nobody, and left a stale call screen up.
  // (Tesla, PR #210 round 1.)
  private val stopListeners = CopyOnWriteArraySet<StopListener>()

  fun addStopListener(l: StopListener) { stopListeners.add(l) }

  fun removeStopListener(l: StopListener) { stopListeners.remove(l) }

  /**
   * One FCM delivery. **Permissive decode** — the cross-repo obligation design
   * 16 v2 §7c names for iOS holds here too: read the keys we know, ignore the
   * rest, never fail on an extra one, so the island can add fields without a
   * payload version.
   *
   * **SYNCHRONOUS, ON FCM'S WORKER, INSIDE ITS WAKE LOCK.** The service holds a
   * partial wake lock only until `onMessageReceived` returns, and a clean
   * return marks the push consumed. The state transition, the notification and
   * the stop all happen before this returns; only what truly needs the main
   * thread (the engine, the listeners) is posted. (Tesla, PR #210 round 1.)
   */
  fun handle(context: Context, data: Map<String, String>) {
    // A calling-off build (every store build until 0.0.6) never rings, even
    // with an island sending call wakes. Same flag as Dart's, same build.
    if (!BuildConfig.CALLING_ENABLED) {
      Log.i(TAG, "handle: calling disabled in this build, k=${data["k"]}")
      return
    }
    Log.i(TAG, "handle: k=${data["k"]} c=${data["c"]}")
    val app = context.applicationContext
    val channel = data["c"]?.takeIf { it.isNotEmpty() }
    when (data["k"]) {
      // An invite with no usable channel could never be answered — the iOS
      // `where` clause, for the same reason: ringing a doorbell that cannot
      // open is worse than not ringing.
      KIND_INVITE -> if (channel != null) ring(app, channel)
      KIND_END -> if (channel != null) stop(app, channel)
      // Unknown or missing `k`: NEVER ring. A third kind added island-side
      // must not become a ring on an older build. Ordinary message wakes, when
      // they exist, also land here, and the plugin's receiver still hands them
      // to Dart — this function only decides whether to RING.
      else -> Unit
    }
  }

  /** The channel ringing on this device right now — the Ringing row only. */
  fun ringingChannel(context: Context): String? =
    current(context.applicationContext)?.takeIf { it.phase == Phase.RINGING }?.channel

  // ---- transitions ---------------------------------------------------------

  /** invite(c). */
  private fun ring(app: Context, channel: String) {
    var displaced: String? = null
    val at: Long
    synchronized(lock) {
      val was = current(app)
      // ONE CALL ARRIVING TWICE is normal — two tokens for one handset, or an
      // FCM retry — and on iOS the duplicate was the whole 2026-09-20 bug.
      // Re-posting would restart the ringtone mid-ring and re-arm the backstop,
      // extending a ring the caller may already have ended.
      if (was?.phase == Phase.RINGING && was.channel == channel) {
        Log.i(TAG, "ring: duplicate for $channel, ignored")
        return
      }
      if (was?.phase == Phase.RINGING) displaced = was.channel
      at = SystemClock.elapsedRealtime()
      write(app, State(Phase.RINGING, channel, at))
    }
    // displace: the old ring is retired BEFORE the new one is drawn, so its
    // screen finishes rather than staying bound to a replaced caller, and the
    // new notification's full-screen intent is a fresh launch, not an update.
    displaced?.let {
      Log.i(TAG, "ring: $it displaced by $channel")
      retire(app, it, ended = false)
    }
    Log.i(TAG, "ring: $channel")
    IncomingCallNotifier.show(app, channel, "Aiko Chat")
    // Start Dart NOW, while the phone rings, exactly as a VoIP push starts the
    // Flutter engine on iOS. The signed invitation reaches this device over the
    // websocket and `admitRing` judges it inside its 10s freshness window — so
    // an Answer pressed twenty seconds later finds an invitation already
    // admitted (held for `kSystemCallRingTrust`). Started from the Answer
    // instead, the invitation would arrive as history, aged past the window,
    // and every call answered from a cold phone would be refused as `stale`:
    // the #3588 trap. The engine is main-thread only, so this one step posts.
    main.post { AikoEngine.warm(app) }
    // The deadline, armed as a TIMER for a process that stays alive. It is not
    // the only way the deadline fires — every read applies it too — and it
    // reaches the same transition, keyed on `at` so a timer from an older ring
    // of this channel cannot end a newer one.
    main.postDelayed({ deadline(app, channel, at) }, RING_CEILING_MS)
  }

  /**
   * end(c) / decline(c): the caller hung up, or the user declined. Any thread.
   * A channel this device is not ringing or holding an answer for is a no-op —
   * Android owes nobody a report for it.
   */
  fun stop(context: Context, channel: String) {
    val app = context.applicationContext
    val was = synchronized(lock) {
      current(app)?.takeIf { it.channel == channel }?.also { clear(app) }
    }
    when (was?.phase) {
      Phase.RINGING -> {
        Log.i(TAG, "stop: $channel stopped while ringing")
        retire(app, channel, ended = true)
      }
      Phase.ANSWERED -> {
        // Answered, then the caller hung up before the join. The ring is
        // already down; what is left is the answer Dart is holding, and
        // `ended` is the action that drops it — so the camera never opens into
        // a room the caller has left. Answering opened the app, so there is an
        // engine to tell.
        Log.i(TAG, "stop: $channel ended after answer")
        CallChannels.emit(CallChannels.ACTION_ENDED, channel)
      }
      null -> Log.i(TAG, "stop: $channel is not this device's ring, no-op")
    }
  }

  /**
   * answer(c). Called ONLY from [IncomingCallActivity], which is not exported:
   * an exported component that answers on an intent extra would let any app on
   * the device open the camera into a call, given a channel id — and channel
   * ids are not secrets. (Maxwell, PR #210 round 1.)
   *
   * Returns whether there was a ring to answer — a stale intent (an Answer
   * tapped after the ring ended) must not reach Dart as a fresh answer.
   */
  fun answer(context: Context, channel: String): Boolean {
    val app = context.applicationContext
    val ok = synchronized(lock) {
      val was = current(app)
      (was?.phase == Phase.RINGING && was.channel == channel).also {
        if (it) write(app, State(Phase.ANSWERED, channel, SystemClock.elapsedRealtime()))
      }
    }
    if (!ok) {
      Log.i(TAG, "answer: $channel is not ringing, refused")
      return false
    }
    Log.i(TAG, "answer: $channel")
    retire(app, channel, ended = false)
    CallChannels.emit(CallChannels.ACTION_ANSWERED, channel)
    return true
  }

  /**
   * dartEnd(c): Dart's `endSystemCall` — the in-app ring was answered or
   * ignored, a join failed, a call screen closed. Safe for any channel; that is
   * the bridge's documented contract, so the call screen's teardown can call it
   * without knowing how the call began. Tells Dart nothing: Dart is deciding.
   */
  fun endFromDart(context: Context, channel: String) {
    val app = context.applicationContext
    val was = synchronized(lock) {
      current(app)?.takeIf { it.channel == channel }?.also { clear(app) }
    }
    Log.i(TAG, "endFromDart: $channel was=${was?.phase}")
    if (was?.phase == Phase.RINGING) retire(app, channel, ended = false)
  }

  /** deadline, from the timer: the ring it was armed for, if still current. */
  private fun deadline(app: Context, channel: String, at: Long) {
    // Identity, not age. Reading through current() would apply the deadline
    // itself and retire there — also correct — but matching (channel, at)
    // directly makes this timer end exactly the ring it was armed for.
    val expired = synchronized(lock) {
      val was = read(app)
      (was?.phase == Phase.RINGING && was.channel == channel && was.at == at)
        .also { if (it) clear(app) }
    }
    if (expired) {
      Log.i(TAG, "deadline: $channel hit ${RING_CEILING_MS}ms")
      retire(app, channel, ended = true)
    }
  }

  // ---- the one exit from Ringing --------------------------------------------

  /**
   * Takes down everything Ringing put up: the notification, the ring screen
   * (via the stop listeners) and — when the ring [ended] without being taken —
   * the headless engine it started, or, if an engine survives, tells Dart.
   */
  private fun retire(app: Context, channel: String, ended: Boolean) {
    IncomingCallNotifier.dismiss(app)
    val listeners = stopListeners.toList()
    main.post {
      listeners.forEach { it.onRingStopped(channel) }
      if (!ended) return@post
      // ORDER IS THE FIX. Emitting first and destroying second queued `ended`
      // on the main looper, then tore the engine down before it ran, so it
      // landed in CallChannels' held buffer and was delivered to the NEXT
      // engine, hours later. A still-headless engine cannot be holding an
      // answer — answering attaches an activity — so when it is destroyed
      // there is nobody to tell. (Maxwell + Carnot + Tesla, round 1.)
      if (!AikoEngine.releaseIfHeadless()) {
        CallChannels.emit(CallChannels.ACTION_ENDED, channel)
      }
    }
  }

  // ---- persistence: the only code that touches the record ------------------

  /**
   * The live state, with its deadline APPLIED. A Ringing state past its
   * deadline is retired here, by whoever happens to read it — so a process
   * that died before its timer fired cannot strand a ring. Takes [lock]
   * itself (reentrant), so callers already holding it are fine.
   */
  private fun current(app: Context): State? {
    val expired: State
    synchronized(lock) {
      val s = read(app) ?: return null
      val age = SystemClock.elapsedRealtime() - s.at
      val limit = if (s.phase == Phase.RINGING) RING_CEILING_MS else ANSWERED_TRUST_MS
      if (age in 0..limit) return s
      clear(app)
      expired = s
    }
    if (expired.phase == Phase.RINGING) {
      Log.i(TAG, "deadline: ${expired.channel} expired on read")
      retire(app, expired.channel, ended = true)
    }
    return null
  }

  /** The raw record, or null if absent, malformed, or from another boot. */
  private fun read(app: Context): State? {
    val p = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val phase = p.getString(KEY_PHASE, null)
      ?.let { n -> Phase.entries.firstOrNull { it.name == n } }
    val channel = p.getString(KEY_CHANNEL, null)
    if (phase == null || channel == null) return null
    // A record from ANOTHER BOOT describes a ring no notification survived,
    // whatever its elapsedRealtime says — that clock restarts at boot.
    if (p.getInt(KEY_BOOT, -1) != bootCount(app)) return null
    return State(phase, channel, p.getLong(KEY_AT, 0L))
  }

  // commit(), not apply(): this process may be killed the moment FCM's
  // callback returns, and a state that never reached disk makes the next
  // process misjudge a real redial as a duplicate. (Tesla, round 1.)
  private fun write(app: Context, s: State) {
    app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
      .putString(KEY_PHASE, s.phase.name)
      .putString(KEY_CHANNEL, s.channel)
      .putLong(KEY_AT, s.at)
      .putInt(KEY_BOOT, bootCount(app))
      .commit()
  }

  /** Only this file's keys — never `clear()` the file. (Kelvin, round 1.) */
  private fun clear(app: Context) {
    app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
      .remove(KEY_PHASE).remove(KEY_CHANNEL).remove(KEY_AT).remove(KEY_BOOT)
      .commit()
  }

  /** `Settings.Global.BOOT_COUNT` (API 24+, our minSdk). -2 if unreadable. */
  private fun bootCount(app: Context): Int =
    Settings.Global.getInt(app.contentResolver, Settings.Global.BOOT_COUNT, -2)
}
