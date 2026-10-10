package cc.imagineering.aiko_chat_app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Android's side of `SystemCallBridge` (lib/features/call/data/system_call_bridge.dart)
 * — the same two channels, the same names and the same payload keys as
 * `SystemCallChannel` in `ios/Runner/AppDelegate.swift`, so ONE Dart bridge and
 * ONE `SystemCallNavigator` serve both platforms. The names are pinned on all
 * three sides by `system_call_channel_contract_test.dart`.
 */
object CallChannels {
  const val ACTIONS_CHANNEL = "cc.imagineering.aikoChatApp/call/actions"
  const val CONTROL_CHANNEL = "cc.imagineering.aikoChatApp/call/control"

  /** `SystemCallActionKind` names in Dart. */
  const val ACTION_ANSWERED = "answered"
  const val ACTION_ENDED = "ended"

  private val main = Handler(Looper.getMainLooper())
  private var sink: EventChannel.EventSink? = null

  // NO HELD BUFFER — deleted, not keyed (design 21 v2, step 4). It used to
  // queue actions taken before Dart listened, and in PR #210 it leaked into
  // the NEXT engine in all three cage-match rounds: a queue outlives whatever
  // it was queued for. Now Dart is handed STATE when it listens — the answer
  // CallRing has persisted, if any — and every later event is live-only. An
  // event with nobody listening is dropped, and that is correct rather than
  // lossy: whatever it reported is already in CallRing's slots, which are what
  // the next listener reads.

  fun attach(engine: FlutterEngine, app: Context) {
    val messenger = engine.dartExecutor.binaryMessenger
    EventChannel(messenger, ACTIONS_CHANNEL).setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
          sink = events
          // THE SNAPSHOT, read from the persisted cells, so it is the truth
          // NOW, never a backlog from an engine that is gone:
          //  1. every call this device has ended and still remembers, as
          //     `ended` — so a call declined before Dart existed never rings
          //     as a banner when its invite arrives over the websocket
          //     (design 22 v4.2).
          //  2. the answer this device is holding — the cold-start Answer,
          //     given while Dart was still booting.
          CallRing.spentCalls(app).forEach { (channel, callId) ->
            events.success(event(ACTION_ENDED, channel, callId))
          }
          CallRing.heldAnswer(app)?.let { (channel, callId) ->
            events.success(event(ACTION_ANSWERED, channel, callId))
          }
        }

        override fun onCancel(arguments: Any?) {
          sink = null
        }
      },
    )
    MethodChannel(messenger, CONTROL_CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "endSystemCall" -> {
          // Exactly that call (design 22: calling is v2-only, so `call` is
          // always present; without it there is nothing to end).
          val channel = call.argument<String>("channel")
          val callId = call.argument<String>("call")
          if (channel != null && callId != null) CallRing.endFromDart(app, channel, callId)
          result.success(null)
        }
        "callStarted" -> {
          // Dart has a call live in this process — outgoing, or answered and
          // joined. A second system answer is refused until it ends
          // (design 22 v4.2).
          val channel = call.argument<String>("channel")
          val callId = call.argument<String>("call")
          if (channel != null && callId != null) {
            CallRing.callStartedFromDart(app, channel, callId)
          }
          result.success(null)
        }
        "canRingFullScreen" -> result.success(IncomingCallNotifier.canRingFullScreen(app))
        "openFullScreenSettings" -> {
          openFullScreenSettings(app)
          result.success(null)
        }
        else -> result.notImplemented()
      }
    }
  }

  fun detach() {
    sink = null
  }

  /**
   * Live-only. Thread-safe: FCM delivers on a worker thread, and the sink is
   * main-only. [callId] rides as `call` when the call has one (v2), so Dart can
   * tell an `ended` for THIS call from the remains of an older one on the same
   * channel. Absent for v1 — never null, never "". No listener → dropped; see
   * the note above `attach`.
   */
  fun emit(action: String, channel: String, callId: String) {
    main.post { sink?.success(event(action, channel, callId)) }
  }

  private fun event(action: String, channel: String, callId: String) = buildMap {
    put("action", action)
    put("channel", channel)
    put("call", callId)
  }

  /**
   * Android 14+'s per-app full-screen-intent switch. Without the grant the ring
   * still sounds (insistent, from a high-importance channel) but arrives as a
   * heads-up banner instead of taking over a locked screen.
   */
  private fun openFullScreenSettings(app: Context) {
    val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
        .setData(Uri.parse("package:${app.packageName}"))
    } else {
      Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
        .putExtra(Settings.EXTRA_APP_PACKAGE, app.packageName)
    }
    app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
  }
}
