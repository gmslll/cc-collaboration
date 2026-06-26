package dev.cchandoff.app

import android.content.Intent
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  // Implements the same dev.cchandoff.app/liveactivity channel as iOS, backed by
  // a foreground service + ongoing notification (see LiveActivityService). All
  // work goes through applicationContext (not this Activity) so updates keep
  // flowing while the Activity is backgrounded/stopped.
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    val ctx = applicationContext
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.cchandoff.app/liveactivity")
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "areActivitiesEnabled" ->
            result.success(NotificationManagerCompat.from(ctx).areNotificationsEnabled())

          "startActivity" -> {
            val title = call.argument<String>("sessionTitle") ?: "AI 会话"
            LiveActivityService.currentTitle = title
            val intent = Intent(ctx, LiveActivityService::class.java).apply {
              action = LiveActivityService.ACTION_START
              putExtra(LiveActivityService.EXTRA_TITLE, title)
              putExtra(LiveActivityService.EXTRA_WORKING, true)
              putExtra(LiveActivityService.EXTRA_TEXT, "思考中…")
            }
            try {
              // Started while the session screen is foreground → always allowed.
              ContextCompat.startForegroundService(ctx, intent)
            } catch (e: Exception) {
              // A foreground-start race (e.g. ForegroundServiceStartNotAllowedException)
              // → degrade to a plain ongoing notification (no process keep-alive).
              LiveActivityService.notifyUpdate(ctx, true, "思考中…")
            }
            result.success(true)
          }

          "updateActivity" -> {
            // Refresh the existing notification in place — never re-start the FGS
            // from the background.
            LiveActivityService.notifyUpdate(
              ctx,
              call.argument<Boolean>("working") ?: false,
              call.argument<String>("text") ?: "",
            )
            result.success(null)
          }

          "endActivity" -> {
            ctx.stopService(Intent(ctx, LiveActivityService::class.java))
            result.success(null)
          }

          else -> result.notImplemented()
        }
      }
  }
}
