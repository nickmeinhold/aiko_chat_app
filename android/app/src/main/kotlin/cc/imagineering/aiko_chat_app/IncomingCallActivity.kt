package cc.imagineering.aiko_chat_app

import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The ring screen a full-screen intent puts over a LOCKED phone.
 *
 * **WHY THIS IS NOT THE FLUTTER APP.** The full-screen intent's activity is
 * shown above the keyguard. Were that `MainActivity`, a ringing phone would hand
 * every conversation on it to whoever is holding it — the lock screen would stop
 * locking for the length of a ring. So the only thing drawn over the keyguard is
 * this: who the call is from, and two buttons. Answer asks for the unlock FIRST
 * and only then opens the app — the shape CallKit has on iOS, where the system
 * call UI is above the lock screen and the app is behind it.
 *
 * Deliberately plain and native: it must appear inside the FCM high-priority
 * window on a cold process, before any Flutter frame could.
 */
class IncomingCallActivity : Activity() {
  private var channel: String? = null

  private val onStopped = CallRing.StopListener { stopped ->
    if (stopped == channel) finish()
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    showOverKeyguard()
    // Registered for the activity's LIFE, not while visible: a ring ending
    // while the screen is off must still take this down, or the next unlock
    // reveals a stale call screen.
    CallRing.addStopListener(onStopped)
    setContentView(layout())
    bind(intent)
  }

  /**
   * `singleInstance`: a SECOND ring arrives here, not in a new screen. Without
   * this the screen kept the FIRST call's channel, so a second caller (two
   * people ringing at once) got a ring screen whose buttons answered and
   * declined a call that no longer existed — both silently refused by
   * [CallRing]. (Maxwell, PR #210 round 1.)
   */
  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    bind(intent)
  }

  private fun bind(intent: Intent) {
    val c = intent.getStringExtra(CallRing.EXTRA_CHANNEL)
    // A ring that already ended (caller hung up while the screen was waking)
    // gets no screen — a call UI for a call that is gone is the phantom this
    // whole arc keeps having to remove.
    if (c == null || CallRing.ringingChannel(this) != c) {
      finish()
      return
    }
    channel = c
    // The notification's Answer button lands here rather than on MainActivity:
    // this activity is not exported, so it is the only door that answers.
    if (intent.getBooleanExtra(CallRing.EXTRA_AUTO_ANSWER, false)) {
      intent.removeExtra(CallRing.EXTRA_AUTO_ANSWER)
      answer()
    }
  }

  override fun onDestroy() {
    CallRing.removeStopListener(onStopped)
    super.onDestroy()
  }

  private fun showOverKeyguard() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
      setShowWhenLocked(true)
      setTurnScreenOn(true)
    } else {
      @Suppress("DEPRECATION")
      window.addFlags(
        WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
          WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
      )
    }
  }

  private fun answer() {
    val c = channel ?: return
    val keyguard = getSystemService(KeyguardManager::class.java)
    if (keyguard != null && keyguard.isKeyguardLocked && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      // The unlock is the gate between a call screen and the app. Cancelled
      // or failed, the user stays here, still ringing, still able to try again.
      keyguard.requestDismissKeyguard(
        this,
        object : KeyguardManager.KeyguardDismissCallback() {
          override fun onDismissSucceeded() = openAnswered(c)
        },
      )
    } else {
      openAnswered(c)
    }
  }

  private fun openAnswered(c: String) {
    // Answer HERE, then open the app with no call extras at all. A ring that
    // ended while the unlock prompt was up is refused by CallRing and opens
    // nothing — the user unlocked, and lands on their phone, not a dead call.
    if (CallRing.answer(this, c)) {
      startActivity(
        Intent(this, MainActivity::class.java)
          .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
      )
    }
    finish()
  }

  private fun decline() {
    channel?.let { CallRing.stop(this, it) }
    finish()
  }

  private fun layout(): LinearLayout {
    fun dp(v: Int) = TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics,
    ).toInt()

    fun label(text: String, sp: Float) = TextView(this).apply {
      this.text = text
      setTextColor(Color.WHITE)
      setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
      gravity = Gravity.CENTER
    }

    fun button(text: String, color: Int, onTap: () -> Unit) = Button(this).apply {
      this.text = text
      setTextColor(Color.WHITE)
      setBackgroundColor(color)
      setOnClickListener { onTap() }
      layoutParams = LinearLayout.LayoutParams(0, dp(64), 1f).apply {
        setMargins(dp(12), 0, dp(12), 0)
      }
    }

    val buttons = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      setPadding(dp(24), dp(48), dp(24), 0)
      // "Decline", not "Ignore": on the lock screen the shorter, conventional
      // word is the one a startled hand finds. The caller is told neither way.
      addView(button("Decline", Color.parseColor("#C62828")) { decline() })
      addView(button("Answer", Color.parseColor("#2E7D32")) { answer() })
    }

    return LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      setBackgroundColor(Color.parseColor("#0B1F2A"))
      addView(label("Aiko Chat", 30f))
      addView(label("Incoming call", 18f).apply { setPadding(0, dp(8), 0, 0) })
      addView(buttons)
    }
  }
}
