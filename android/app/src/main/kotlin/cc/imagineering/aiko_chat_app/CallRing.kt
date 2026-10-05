package cc.imagineering.aiko_chat_app

import android.content.Context
import android.os.Handler
import android.os.Looper

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
  const val EXTRA_ACTION = "aiko.call.action"
  const val ACTION_ANSWER = "answer"

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

  private const val PREFS = "aiko_call_ring"
  private const val KEY_CHANNEL = "channel"
  private const val KEY_SINCE = "since"

  private val main = Handler(Looper.getMainLooper())

  /** Anything that must vanish when the ring stops — the lock-screen activity. */
  fun interface StopListener {
    fun onRingStopped(channelId: String)
  }

  private val stopListeners = mutableSetOf<StopListener>()

  fun addStopListener(l: StopListener) = main.post { stopListeners.add(l) }

  fun removeStopListener(l: StopListener) = main.post { stopListeners.remove(l) }

  /**
   * One FCM delivery. **Permissive decode** — the cross-repo obligation design
   * 16 v2 §7c names for iOS holds here too: read the keys we know, ignore the
   * rest, never fail on an extra one, so the island can add fields without a
   * payload version.
   *
   * Called on FCM's worker thread; every effect is posted to main.
   */
  fun handle(context: Context, data: Map<String, String>) {
    // A calling-off build (every store build until 0.0.6) never rings, even
    // with an island sending call wakes. Same flag as Dart's, same build.
    if (!BuildConfig.CALLING_ENABLED) return
    val app = context.applicationContext
    val channel = data["c"]?.takeIf { it.isNotEmpty() }
    when (data["k"]) {
      // An invite with no usable channel could never be answered — the iOS
      // `where` clause, for the same reason: ringing a doorbell that cannot
      // open is worse than not ringing.
      KIND_INVITE -> if (channel != null) main.post { ring(app, channel) }
      KIND_END -> if (channel != null) main.post { stop(app, channel) }
      // Unknown or missing `k`: NEVER ring. A third kind added island-side
      // must not become a ring on an older build. Ordinary message wakes, when
      // they exist, also land here, and the plugin's receiver still hands them
      // to Dart — this function only decides whether to RING.
      else -> Unit
    }
  }

  /** The channel ringing on this device right now, across process deaths. */
  fun ringingChannel(context: Context): String? {
    val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val channel = prefs.getString(KEY_CHANNEL, null) ?: return null
    val since = prefs.getLong(KEY_SINCE, 0L)
    // Past the ceiling the notification has timed itself out, so a record
    // older than that describes a ring nobody can see. Expired by reading, so
    // a process that died before its timer fired cannot strand it.
    if (System.currentTimeMillis() - since > RING_CEILING_MS) return null
    return channel
  }

  private fun ring(app: Context, channel: String) {
    // ONE CALL ARRIVING TWICE is normal — two tokens for one handset, or an
    // FCM retry — and on iOS the duplicate was the whole 2026-09-20 bug.
    // Here it is a no-op: re-posting would restart the ringtone mid-ring and
    // re-arm the backstop, extending a ring the caller may already have ended.
    if (ringingChannel(app) == channel) return
    val since = System.currentTimeMillis()
    app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
      .putString(KEY_CHANNEL, channel)
      .putLong(KEY_SINCE, since)
      .apply()
    IncomingCallNotifier.show(app, channel, "Aiko Chat")
    // Start Dart NOW, while the phone rings, exactly as a VoIP push starts the
    // Flutter engine on iOS. The signed invitation reaches this device over the
    // websocket and `admitRing` judges it inside its 10s freshness window — so
    // an Answer pressed twenty seconds later finds an invitation already
    // admitted (held for `kSystemCallRingTrust`). Started from the Answer
    // instead, the invitation would arrive as history, aged past the window,
    // and every call answered from a cold phone would be refused as `stale`:
    // the #3588 trap.
    AikoEngine.warm(app)
    // Keyed on `since` so a stale timer cannot end a NEWER ring of the same
    // channel (call, hang up, call again inside a minute).
    main.postDelayed({ expire(app, channel, since) }, RING_CEILING_MS)
  }

  /**
   * The caller hung up, or the user declined. Ends only the ring it names: a
   * `call_end` for any other channel, or arriving after the ring already
   * stopped, is a no-op — Android owes nobody a report for it.
   */
  fun stop(context: Context, channel: String) {
    val app = context.applicationContext
    if (!forget(app, channel)) return
    // Dart may be holding an answer for this channel (answered, then the
    // caller hung up before the join). `ended` is the action that drops it.
    CallChannels.emit(CallChannels.ACTION_ENDED, channel)
    // An engine this ring started, that the user never opened, has no further
    // reason to run.
    AikoEngine.releaseIfHeadless()
  }

  /**
   * The user pressed Answer. Returns whether there was a ring to answer — a
   * stale intent (an Answer tapped after the ring timed out, a relaunch
   * redelivering an old intent) must not reach Dart as a fresh answer.
   */
  fun answer(context: Context, channel: String): Boolean {
    if (!forget(context.applicationContext, channel)) return false
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
    forget(context.applicationContext, channel)
  }

  private fun expire(app: Context, channel: String, since: Long) {
    val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    if (prefs.getString(KEY_CHANNEL, null) != channel) return
    if (prefs.getLong(KEY_SINCE, 0L) != since) return
    stop(app, channel)
  }

  /** Clears the ring if it is [channel]'s. Returns whether it was. */
  private fun forget(app: Context, channel: String): Boolean {
    if (ringingChannel(app) != channel) return false
    app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    IncomingCallNotifier.dismiss(app)
    val listeners = stopListeners.toList()
    main.post { listeners.forEach { it.onRingStopped(channel) } }
    return true
  }
}
