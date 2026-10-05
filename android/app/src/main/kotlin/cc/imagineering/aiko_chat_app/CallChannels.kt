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

  /**
   * Bounded: a backlog is only ever the few actions taken while Dart was
   * booting. Anything past this is not a backlog, it is a bug, and dropping the
   * oldest keeps the newest — the one the user just pressed.
   */
  private const val MAX_HELD = 8

  private val main = Handler(Looper.getMainLooper())
  private var sink: EventChannel.EventSink? = null

  /**
   * Actions taken before Dart listened. NORMAL, not an edge: the user answers
   * from the notification while the engine is still booting, and an action
   * emitted into no listener would be the doorbell on the empty house.
   */
  private val held = ArrayDeque<Map<String, String>>()

  fun attach(engine: FlutterEngine, app: Context) {
    val messenger = engine.dartExecutor.binaryMessenger
    EventChannel(messenger, ACTIONS_CHANNEL).setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
          sink = events
          while (held.isNotEmpty()) events.success(held.removeFirst())
        }

        override fun onCancel(arguments: Any?) {
          sink = null
        }
      },
    )
    MethodChannel(messenger, CONTROL_CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "endSystemCall" -> {
          call.argument<String>("channel")?.let { CallRing.endFromDart(app, it) }
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

  /** Thread-safe: FCM delivers on a worker thread, and the sink is main-only. */
  fun emit(action: String, channel: String) {
    main.post {
      val event = mapOf("action" to action, "channel" to channel)
      val live = sink
      if (live != null) {
        live.success(event)
      } else {
        if (held.size >= MAX_HELD) held.removeFirst()
        held.addLast(event)
      }
    }
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
