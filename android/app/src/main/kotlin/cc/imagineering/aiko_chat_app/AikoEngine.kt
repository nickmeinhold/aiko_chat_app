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
    // The one-argument constructor REGISTERS THE GENERATED PLUGINS itself
    // (`automaticallyRegisterPlugins = true` → `GeneratedPluginRegister`), which
    // is also why FlutterActivity skips registration for a host-provided engine.
    // Nothing else here needs to; hardware-verified, Firebase and the camera both
    // ran from a ring-started engine. (A cage-match seat read the absence of an
    // explicit call as "no plugins" — this line is that answer.)
    val engine = FlutterEngine(context.applicationContext)
    CallChannels.attach(engine, context.applicationContext)
    engine.addEngineLifecycleListener(
      object : FlutterEngine.EngineLifecycleListener {
        override fun onPreEngineRestart() = Unit

        override fun onEngineWillDestroy() {
          cache.remove(ID)
          CallChannels.detach()
          headless = false
          // The session is the media, and the media is this engine: a call
          // cannot be live in a destroyed isolate. Without this, Back out of a
          // live call left `live` set for the life of the process, and every
          // later answer was refused (Tesla, design 22 delta review).
          CallRing.mediaGone(context)
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
   * The activity is going away mid-ring and has NOT destroyed the engine (see
   * MainActivity.shouldDestroyEngineWithHost). It is headless again, and the
   * ring that is keeping it alive decides when it closes.
   */
  fun detachedDuringRing() {
    headless = true
  }

  /**
   * The ring that started a headless engine is over and nobody opened the app.
   * Destroying it ends the websocket it opened — without this, a declined call
   * leaves an invisible app running until Android kills the process.
   *
   * Returns whether it destroyed one. A destroyed headless engine had nobody to
   * TELL — no activity ever attached, so Dart could not be holding an answer —
   * which is what lets [CallRing.stop] skip the `ended` action rather than queue
   * it for an engine that no longer exists.
   */
  fun releaseIfHeadless(): Boolean {
    if (!headless) return false
    val engine = FlutterEngineCache.getInstance().get(ID) ?: return false
    engine.destroy()
    return true
  }
}
