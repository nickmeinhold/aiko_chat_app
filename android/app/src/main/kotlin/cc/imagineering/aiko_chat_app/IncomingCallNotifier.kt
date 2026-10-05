package cc.imagineering.aiko_chat_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * The Android half of "a call must ring the handset like a telephone"
 * (Nick, 2026-09-09).
 *
 * A high-importance notification carrying a FULL-SCREEN INTENT: on a locked or
 * idle device Android launches the intent directly, which is the incoming-call
 * screen; on an active device it degrades to a heads-up banner, which is the
 * correct behaviour rather than a fallback (you are already looking at the
 * phone).
 *
 * **THIS IS NOT ConnectionService.** Design 12 Decision 8 names both. The
 * telecom integration — system dialer, call log, audio focus against a cellular
 * call — is a separate, larger piece. What is here is the RING, and it is what
 * `USE_FULL_SCREEN_INTENT` actually governs.
 *
 * **THE PERMISSION IS NOT A MANIFEST LINE ON ANDROID 14+.** `USE_FULL_SCREEN_INTENT`
 * became a special access permission in API 34, auto-granted only to apps Google
 * has approved as calling or alarm apps — via a Play Console declaration that
 * only appears once a bundle declaring the permission has been uploaded. So the
 * grant can be ABSENT at runtime with everything here correct, and the failure
 * is silent: the notification simply posts as a heads-up and never takes over
 * the screen. [canRingFullScreen] exists so that state is reportable instead of
 * mysterious.
 */
object IncomingCallNotifier {
  private const val CHANNEL_ID = "aiko_incoming_calls"
  private const val NOTIFICATION_ID = 4201

  // Distinct request codes. Android identifies a PendingIntent by its intent's
  // action/data/component/categories plus this code — EXTRAS ARE IGNORED — and
  // FLAG_UPDATE_CURRENT then rewrites the match's extras. The three targets
  // differ by component today; the codes keep them apart if two ever share one.
  private const val REQUEST_RING = 0
  private const val REQUEST_ANSWER = 1
  private const val REQUEST_DECLINE = 2

  /**
   * Whether this device will actually honour a full-screen intent right now.
   *
   * Below API 34 the permission is normal and a manifest declaration is enough.
   * From 34 it is a special access grant, so this is the only honest answer —
   * and it is deliberately surfaced to Dart rather than logged, because "the
   * ring did not take over the screen" has no other observable.
   */
  fun canRingFullScreen(context: Context): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
    val manager = context.getSystemService(NotificationManager::class.java)
    return manager?.canUseFullScreenIntent() ?: false
  }

  private fun ensureChannel(context: Context) {
    val manager = context.getSystemService(NotificationManager::class.java) ?: return
    if (manager.getNotificationChannel(CHANNEL_ID) != null) return
    val channel = NotificationChannel(
      CHANNEL_ID,
      "Incoming calls",
      // HIGH, not DEFAULT: a full-screen intent is only honoured from a
      // high-importance channel, and importance cannot be raised after the
      // channel is created — a channel made at DEFAULT stays that way for the
      // life of the install, and the only repair is a new channel id.
      NotificationManager.IMPORTANCE_HIGH,
    ).apply {
      description = "Rings when someone calls you on Aiko Chat"
      setSound(
        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
        AudioAttributes.Builder()
          .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
          .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
          .build(),
      )
      enableVibration(true)
      lockscreenVisibility = Notification.VISIBILITY_PUBLIC
    }
    manager.createNotificationChannel(channel)
  }

  /**
   * Ring for [callerLabel] on [channelId]. Called only by [CallRing], which
   * owns whether a ring should exist; this only draws it.
   *
   * The channel id rides every intent under the SAME one-character key the
   * island's push payload uses (`c`), so there is one name for this value across
   * the wire, the iOS delegate and here.
   */
  fun show(context: Context, channelId: String, callerLabel: String) {
    ensureChannel(context)

    // The full-screen target is the NATIVE ring screen, never the app — see
    // IncomingCallActivity for why the Flutter app must not be drawn over the
    // keyguard. Tapping the banner on an unlocked phone opens the same screen.
    val ringScreen = PendingIntent.getActivity(
      context,
      REQUEST_RING,
      Intent(context, IncomingCallActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION
        putExtra(CallRing.EXTRA_CHANNEL, channelId)
      },
      // IMMUTABLE is required from S and is correct here regardless: nothing
      // outside this process has any business rewriting the target.
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    // Answer from the shade goes straight to the app. Android asks for the
    // unlock before launching an activity from a locked-screen notification
    // action, so this is gated the same way the ring screen's Answer is.
    val answer = PendingIntent.getActivity(
      context,
      REQUEST_ANSWER,
      Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        putExtra(CallRing.EXTRA_ACTION, CallRing.ACTION_ANSWER)
        putExtra(CallRing.EXTRA_CHANNEL, channelId)
      },
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    val decline = PendingIntent.getBroadcast(
      context,
      REQUEST_DECLINE,
      Intent(context, CallDeclineReceiver::class.java)
        .putExtra(CallRing.EXTRA_CHANNEL, channelId),
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    val notification = NotificationCompat.Builder(context, CHANNEL_ID)
      .setSmallIcon(android.R.drawable.sym_call_incoming)
      .setContentTitle(callerLabel)
      .setContentText("Incoming call")
      .setCategory(NotificationCompat.CATEGORY_CALL)
      .setPriority(NotificationCompat.PRIORITY_HIGH)
      .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
      // `true` = "this is important enough to interrupt". Without it the
      // full-screen intent is advisory and the system may quietly choose a
      // banner even when it could have taken the screen.
      .setFullScreenIntent(ringScreen, true)
      .setContentIntent(ringScreen)
      .addAction(0, "Decline", decline)
      .addAction(0, "Answer", answer)
      // Ongoing so it cannot be swiped away mid-ring. NOT auto-cancel: opening
      // the ring screen is not a decision, and the ring must keep sounding
      // until Answer, Decline, the caller's end, or the ceiling.
      .setOngoing(true)
      // The backstop for a lost `call_end` — see CallRing.RING_CEILING_MS.
      .setTimeoutAfter(CallRing.RING_CEILING_MS)
      .build()
    // A channel sound plays ONCE. A phone call rings until someone acts, and
    // INSISTENT is the flag that loops the channel's ringtone until the
    // notification is cancelled — without it this is a chime, not a ring.
    notification.flags = notification.flags or Notification.FLAG_INSISTENT

    // POST_NOTIFICATIONS may be denied on 13+; NotificationManagerCompat throws
    // SecurityException rather than no-opping, and a denied notification
    // permission is an ordinary user choice, not a crash.
    try {
      NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
    } catch (_: SecurityException) {
      // Nothing to recover: the user declined notifications. The in-app ring
      // overlay still fires when the app is foregrounded.
    }
  }

  /** Stop ringing — answered, ignored, retracted, or expired. */
  fun dismiss(context: Context) {
    NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
  }
}
