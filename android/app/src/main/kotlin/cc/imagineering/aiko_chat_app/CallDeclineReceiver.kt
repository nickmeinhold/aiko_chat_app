package cc.imagineering.aiko_chat_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * The notification's Decline button. A receiver rather than an activity, so
 * declining from the shade does not open the app (or ask for an unlock) just to
 * say no.
 *
 * Decline is "Ignore" in the sense #139 settled: the caller is never told. It
 * stops this device ringing and nothing else.
 */
class CallDeclineReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    val channel = intent.getStringExtra(CallRing.EXTRA_CHANNEL) ?: return
    CallRing.stop(context, channel)
  }
}
