package cc.imagineering.aiko_chat_app

import android.content.Context
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
  }

  // NO call extras are read here, deliberately. This activity is EXPORTED (it
  // is the launcher), so anything it does on an intent extra, any app on the
  // device can make it do. Answering lives in IncomingCallActivity, which is
  // not exported; by the time this opens, the answer is already on its way to
  // Dart. (Maxwell, PR #210 round 1.)
}
