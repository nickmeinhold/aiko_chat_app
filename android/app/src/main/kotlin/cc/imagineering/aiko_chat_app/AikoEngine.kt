package cc.imagineering.aiko_chat_app

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * The ONE Flutter engine this process runs, whoever started it.
 *
 * Two starters exist: [MainActivity] (the user opened the app) and [CallRing]
 * (a call push arrived, and Dart must be running to admit the signed invitation
 * while the phone rings — see [CallRing.ring]). **They must share an engine, not
 * each make one**: two engines are two copies of the app — two websockets, two
 * ring overlays, two `SystemCallNavigator`s holding two different answers. So
 * both go through [obtain], and the activity attaches to whatever is already
 * running rather than booting a second app beside it.
 */
object AikoEngine {
  private const val ID = "aiko_main"

  /**
   * True only for an engine a ring started that no activity has attached to —
   * the one engine nobody will ever close, because nobody can see it.
   */
  private var headless = false

  /** The running engine, or a new one with Dart already started. Main thread. */
  fun obtain(context: Context): FlutterEngine {
    val cache = FlutterEngineCache.getInstance()
    cache.get(ID)?.let { return it }
    val engine = FlutterEngine(context.applicationContext)
    CallChannels.attach(engine, context.applicationContext)
    engine.addEngineLifecycleListener(
      object : FlutterEngine.EngineLifecycleListener {
        override fun onPreEngineRestart() = Unit

        override fun onEngineWillDestroy() {
          cache.remove(ID)
          CallChannels.detach()
          headless = false
        }
      },
    )
    engine.dartExecutor.executeDartEntrypoint(
      DartExecutor.DartEntrypoint.createDefault(),
    )
    cache.put(ID, engine)
    return engine
  }

  /** Start Dart for a ring, unless the app is already running. Main thread. */
  fun warm(context: Context) {
    if (FlutterEngineCache.getInstance().contains(ID)) return
    obtain(context)
    headless = true
  }

  /** An activity now shows this engine; it owns its lifetime from here. */
  fun attachedToActivity() {
    headless = false
  }

  /**
   * The ring that started a headless engine is over and nobody opened the app.
   * Destroying it ends the websocket it opened — without this, a declined call
   * leaves an invisible app running until Android kills the process.
   */
  fun releaseIfHeadless() {
    if (!headless) return
    FlutterEngineCache.getInstance().get(ID)?.destroy()
  }
}
