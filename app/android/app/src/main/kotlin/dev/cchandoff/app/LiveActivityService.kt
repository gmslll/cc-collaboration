package dev.cchandoff.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

// LiveActivityService is the Android equivalent of the iOS Live Activity: a
// foreground service whose ongoing notification shows the watched AI session's
// "干活中 / 已完成 + 最新输出". The service exists to keep the process (and the
// main-isolate relay WebSocket) alive while the user is in another app, so the
// notification keeps updating. The MethodChannel handler in MainActivity drives
// start/update/end; updates refresh the SAME notification id via notify(),
// never by re-starting the service (a background FGS start would be rejected).
class LiveActivityService : Service() {

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_STOP -> {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
      }
      else -> { // START (or a restart with a null intent — shouldn't happen, START_NOT_STICKY)
        currentTitle = intent?.getStringExtra(EXTRA_TITLE) ?: currentTitle
        val working = intent?.getBooleanExtra(EXTRA_WORKING, true) ?: true
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "思考中…"
        ensureChannel(this)
        val n = buildNotification(this, working, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
          startForeground(NOTIF_ID, n)
        }
      }
    }
    // Don't let the system resurrect an empty AI-status service after a kill.
    return START_NOT_STICKY
  }

  // Android 15+ caps a backgrounded dataSync FGS at ~6h/day, then calls this; we
  // must stop within seconds or the system raises an ANR. (Sessions are far
  // shorter, so this is a safety backstop, not an expected path.)
  override fun onTimeout(startId: Int, fgsType: Int) {
    stopForeground(STOP_FOREGROUND_REMOVE)
    stopSelf()
  }

  companion object {
    const val CHANNEL_ID = "cc_live_activity"
    const val NOTIF_ID = 0xCCA1
    const val ACTION_START = "dev.cchandoff.app.LA_START"
    const val ACTION_STOP = "dev.cchandoff.app.LA_STOP"
    const val EXTRA_TITLE = "title"
    const val EXTRA_WORKING = "working"
    const val EXTRA_TEXT = "text"

    // Title is set at start and reused for in-place notify() updates (which only
    // carry working/text), keeping the MethodChannel contract identical to iOS.
    @Volatile
    var currentTitle: String = "AI 会话"

    // ensureChannel creates the LOW-importance channel once (no sound / no
    // heads-up — it's an ambient status card, not an alert). Separate from the
    // high-importance "cc_handoff" channel used for one-shot banners.
    fun ensureChannel(ctx: Context) {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
      val mgr = ctx.getSystemService(NotificationManager::class.java)
      if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
        mgr.createNotificationChannel(
          NotificationChannel(CHANNEL_ID, "AI 状态", NotificationManager.IMPORTANCE_LOW).apply {
            description = "显示远程 AI 会话的干活状态"
            setShowBadge(false)
          }
        )
      }
    }

    // buildNotification renders the current state; reused by the service (start)
    // and the MethodChannel handler (update) so both post an identical layout.
    fun buildNotification(ctx: Context, working: Boolean, text: String): Notification {
      val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
      val pi = PendingIntent.getActivity(
        ctx, 0, launch ?: Intent(),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
      )
      return NotificationCompat.Builder(ctx, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_notify_sync)
        .setContentTitle(currentTitle)
        .setContentText(text)
        .setStyle(NotificationCompat.BigTextStyle().bigText(text))
        .setSubText(if (working) "AI 干活中" else "已完成")
        .setOngoing(working) // dismissible once done
        .setAutoCancel(!working)
        .setOnlyAlertOnce(true) // frequent updates never re-buzz
        .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        .setContentIntent(pi)
        .build()
    }

    // notifyUpdate refreshes the existing notification in place (no FGS restart).
    fun notifyUpdate(ctx: Context, working: Boolean, text: String) {
      ensureChannel(ctx)
      NotificationManagerCompat.from(ctx).notify(NOTIF_ID, buildNotification(ctx, working, text))
    }
  }
}
