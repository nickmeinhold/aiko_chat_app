package cc.imagineering.aiko_chat_app

import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService

/**
 * The plugin's messaging service, with the ring added.
 *
 * **EXTENDED, NOT ADDED BESIDE.** Android delivers `MESSAGING_EVENT` to ONE
 * service, so a second one would race the plugin's for every push. The manifest
 * removes the plugin's declaration and names this subclass instead; token
 * rotation (`onNewToken`) still runs the plugin's code.
 *
 * **THE PLUGIN DOES NOT LOSE ANY MESSAGES.** `FlutterFirebaseMessagingService.onMessageReceived`
 * is an intentional no-op — the plugin hands every message to Dart from its
 * `c2dm` broadcast RECEIVER, which this class does not touch. So adding
 * behaviour here takes nothing away from `onMessage` / `onBackgroundMessage`.
 *
 * Kotlin, not a Dart background handler: a locked phone must ring within the
 * FCM high-priority window, and a Dart handler would first boot an isolate that
 * cannot reach [IncomingCallNotifier] anyway.
 */
class AikoMessagingService : FlutterFirebaseMessagingService() {
  override fun onMessageReceived(remoteMessage: RemoteMessage) {
    super.onMessageReceived(remoteMessage)
    CallRing.handle(this, remoteMessage.data)
  }
}
