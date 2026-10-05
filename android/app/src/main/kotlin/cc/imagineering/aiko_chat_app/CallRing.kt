package cc.imagineering.aiko_chat_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
 * **WHICH CHANNEL IS RINGING LIVES IN SharedPreferences, NOT A FIELD**, for the
 * reason iOS learned keeping its channel→UUID map in UserDefaults: the process
 * that started a ring is not the process that ends it. An FCM push wakes a
 * process, posts the notification and may be killed; the user's Answer, or the
 * caller's `call_end`, arrives in a fresh one. A field would read null there and
 * the hangup would stop nothing.
 *
 * **THE PUSH IS TRUSTED FOR ONE THING: "ring this channel".** It is unsigned
 * island data. Nothing here joins a room, opens a camera or names a caller. The
 * signed invitation is judged by `admitRing` in Dart, which this file never
 * bypasses — answering hands Dart an `answered` action, and
 * `SystemCallNavigator` joins only an invitation `admitRing` admitted.
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
   * One line per DECISION, never per payload byte. The first hardware run
   * (2026-10-05) failed with this file silent: a `call_end` arrived and the
   * ring did not stop, and the log could not say whether `handle` ran, which
   * arm it took, or what `ringingChannel` answered. An empty log is equally good
   * evidence for every hypothesis — the iOS ring paid for that lesson first.
   * Channel ids only; they are opaque and already in the island's own logs.
   */
  private const val TAG = "AikoRing"

  private const val PREFS = "aiko_call_ring"
  private const val KEY_CHANNEL = "channel"
  private const val KEY_SINCE = "since"

  private val main = Handler(Looper.getMainLooper())

  /** Anything that must vanish when the ring stops — the lock-screen activity. */
  fun interface StopListener {
    fun onRingStopped(channelId: String)
  }

  // Copy-on-write so [forget] can snapshot from any thread while an activity
  // registers on main. Registration is SYNCHRONOUS: it used to be posted, so a
  // stop landing between the ring screen's "is this ringing?" check and its
  // registration ran first, finished nobody, and left a stale call screen up.
  // (Tesla, PR #210 round 1.)
  private val stopListeners = CopyOnWriteArraySet<StopListener>()

  fun addStopListener(l: StopListener) { stopListeners.add(l) }

  fun removeStopListener(l: StopListener) { stopListeners.remove(l) }

  /** Guards the record: FCM's worker and the main thread both read-modify-write it. */
  private val lock = Any()

  /**
   * One FCM delivery. **Permissive decode** — the cross-repo obligation design
   * 16 v2 §7c names for iOS holds here too: read the keys we know, ignore the
   * rest, never fail on an extra one, so the island can add fields without a
   * payload version.
   *
   * **SYNCHRONOUS, ON FCM'S WORKER, INSIDE ITS WAKE LOCK.** The service holds a
   * partial wake lock only until `onMessageReceived` returns, and a clean
   * return marks the push consumed. Work posted to main and left for later ran
   * OUTSIDE that lock: a cold `call_end` could be frozen before the ring
   * stopped, leaving an insistent ringtone to the 60s backstop. So the record,
   * the notification and the stop all happen before this returns; only what
   * truly needs the main thread (the engine) is posted. (Tesla, PR #210 r1.)
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

  /**
   * The channel ringing on this device right now, across process deaths.
   *
   * **ONE CLOCK.** The record is dated with `elapsedRealtime` — the same
   * monotonic clock that times the notification (`setTimeoutAfter`) and the
   * backstop (`postDelayed`). It used to be wall time, so an NTP step riding
   * the same Doze wake as the push could expire the RECORD while the ringtone
   * kept looping — and an expired record refuses Answer, Decline and
   * `call_end` alike, so nothing could stop it. (Tesla, PR #210 round 1.)
   *
   * Expiry by reading also DISMISSES, so a ring this function declares over is
   * over on screen too, in the same breath.
   */
  fun ringingChannel(context: Context): String? = synchronized(lock) {
    val app = context.applicationContext
    val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val channel = prefs.getString(KEY_CHANNEL, null) ?: return null
    val age = SystemClock.elapsedRealtime() - prefs.getLong(KEY_SINCE, 0L)
    // Negative age = a record from before a reboot, which no notification
    // survived. Either way the ring nobody can see is cleared, not reported.
    if (age < 0 || age > RING_CEILING_MS) {
      clearRecord(app)
      IncomingCallNotifier.dismiss(app)
      return null
    }
    channel
  }

  private fun ring(app: Context, channel: String) {
    // ONE CALL ARRIVING TWICE is normal — two tokens for one handset, or an
    // FCM retry — and on iOS the duplicate was the whole 2026-09-20 bug.
    // Here it is a no-op: re-posting would restart the ringtone mid-ring and
    // re-arm the backstop, extending a ring the caller may already have ended.
    val since = synchronized(lock) {
      if (ringingChannel(app) == channel) null
      else SystemClock.elapsedRealtime().also { now ->
        // commit(), not apply(): this process may be killed the moment FCM's
        // callback returns, and a record that never reached disk makes the
        // NEXT process misjudge a real redial as a duplicate. (Tesla, r1.)
        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
          .putString(KEY_CHANNEL, channel)
          .putLong(KEY_SINCE, now)
          .commit()
      }
    }
    if (since == null) {
      Log.i(TAG, "ring: duplicate for $channel, ignored")
      return
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
    // Keyed on `since` so a stale timer cannot end a NEWER ring of the same
    // channel (call, hang up, call again inside a minute).
    main.postDelayed({ expire(app, channel, since) }, RING_CEILING_MS)
  }

  /**
   * The caller hung up, or the user declined. Ends only the ring it names: a
   * `call_end` for any other channel, or arriving after the ring already
   * stopped, is a no-op — Android owes nobody a report for it. Any thread.
   */
  fun stop(context: Context, channel: String) {
    val app = context.applicationContext
    if (!forget(app, channel)) {
      Log.i(TAG, "stop: $channel is not the ringing channel (${ringingChannel(app)}), no-op")
      return
    }
    Log.i(TAG, "stop: $channel stopped")
    main.post {
      // An engine this ring started, that the user never opened, has no
      // further reason to run — and nobody in it to tell: answering is what
      // attaches an activity, so a still-headless engine cannot be holding an
      // answer.
      //
      // ORDER IS THE FIX. Emitting first and destroying second queued `ended`
      // on the main looper, then tore the engine down before it ran, so it
      // landed in CallChannels' held buffer and was delivered to the NEXT
      // engine, hours later. Deciding whether an engine survives BEFORE
      // emitting removes the case instead of draining it. (Maxwell + Carnot +
      // Tesla, PR #210 round 1.)
      if (!AikoEngine.releaseIfHeadless()) {
        // Dart may be holding an answer for this channel (answered, then the
        // caller hung up before the join). `ended` is the action that drops it.
        CallChannels.emit(CallChannels.ACTION_ENDED, channel)
      }
    }
  }

  /**
   * The user pressed Answer. Called ONLY from [IncomingCallActivity], which is
   * not exported: an exported component that answers on an intent extra would
   * let any app on the device open the camera into a call, given a channel id
   * — and channel ids are not secrets. (Maxwell, PR #210 round 1.)
   *
   * Returns whether there was a ring to answer — a
   * stale intent (an Answer tapped after the ring timed out, a relaunch
   * redelivering an old intent) must not reach Dart as a fresh answer.
   */
  fun answer(context: Context, channel: String): Boolean {
    if (!forget(context.applicationContext, channel)) {
      Log.i(TAG, "answer: $channel is not ringing, refused")
      return false
    }
    Log.i(TAG, "answer: $channel")
    CallChannels.emit(CallChannels.ACTION_ANSWERED, channel)
    return true
  }

  /**
   * Dart's `endSystemCall`: the in-app ring was answered or ignored, a join
   * failed, or a call screen closed. Safe to call for any channel — that is
   * the bridge's documented contract, so the call screen's teardown can call
   * it without knowing how the call began. Emits nothing: Dart is the one
   * deciding.
   */
  fun endFromDart(context: Context, channel: String) {
    val ended = forget(context.applicationContext, channel)
    Log.i(TAG, "endFromDart: $channel ended=$ended")
  }

  private fun expire(app: Context, channel: String, since: Long) {
    val current = synchronized(lock) {
      val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
      prefs.getString(KEY_CHANNEL, null) == channel && prefs.getLong(KEY_SINCE, 0L) == since
    }
    if (current) stop(app, channel)
  }

  /** Clears the ring if it is [channel]'s. Returns whether it was. Any thread. */
  private fun forget(app: Context, channel: String): Boolean {
    val was = synchronized(lock) {
      (ringingChannel(app) == channel).also { if (it) clearRecord(app) }
    }
    if (!was) return false
    IncomingCallNotifier.dismiss(app)
    val listeners = stopListeners.toList()
    main.post { listeners.forEach { it.onRingStopped(channel) } }
    return true
  }

  /** Only this file's two keys — never `clear()` the file. Caller holds [lock]. */
  private fun clearRecord(app: Context) {
    app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
      .remove(KEY_CHANNEL).remove(KEY_SINCE).commit()
  }
}
