package cc.imagineering.aiko_chat_app

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
  /**
   * The engine a ring may already have started — see [AikoEngine]. Attaching
   * to it is the point: that engine has been connected and admitting the signed
   * invitation while the phone rang, so the Answer below finds it admitted.
   * A host-provided engine is not re-registered or re-run by FlutterActivity
   * (`configureFlutterEngine` returns early; `doInitialFlutterViewRun` sees Dart
   * already executing).
   */
  override fun provideFlutterEngine(context: Context): FlutterEngine =
    AikoEngine.obtain(context)

  /**
   * FlutterActivity defaults this to FALSE for a host-provided engine, which
   * would keep the whole app — websocket included — running invisibly after
   * the user backs out. Closing the activity closes the app, as it did before
   * the engine was shared.
   */
  override fun shouldDestroyEngineWithHost(): Boolean = true

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    AikoEngine.attachedToActivity()
    // Only a FRESH launch carries a fresh answer; a recreated activity is
    // redelivered its original intent and must not answer twice.
    if (savedInstanceState == null) route(intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    route(intent)
  }

  private fun route(intent: Intent) {
    if (intent.getStringExtra(CallRing.EXTRA_ACTION) != CallRing.ACTION_ANSWER) return
    val channel = intent.getStringExtra(CallRing.EXTRA_CHANNEL) ?: return
    // Consumed: an intent is sticky on the activity, and an answer is an event.
    intent.removeExtra(CallRing.EXTRA_ACTION)
    CallRing.answer(this, channel)
  }
}
