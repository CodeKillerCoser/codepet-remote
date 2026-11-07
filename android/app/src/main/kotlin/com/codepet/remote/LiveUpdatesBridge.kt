package com.codepet.remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Silent standard notifications; promotion is a system decision, never a vendor check. */
class LiveUpdatesBridge(private val context: Context, engine: FlutterEngine) {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val prefs = context.getSharedPreferences("live_updates", Context.MODE_PRIVATE)
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.codepet.remote/live_updates")
    private var launch: String? = null
    init {
        // A new engine cannot claim an old task is still running.
        manager.cancel(ID)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "begin" -> { prefs.edit().remove("dismissed").putString("current", call.arguments as String).apply(); result.success(null) }
                    "end" -> { manager.cancel(ID); prefs.edit().remove("current").apply(); result.success(null) }
                    "show" -> result.success(show(call.arguments as Map<*, *>))
                    "takeLaunch" -> { result.success(launch); launch = null }
                    "capabilities" -> result.success(mapOf(
                        "supported" to (Build.VERSION.SDK_INT >= 36),
                        "allowed" to manager.areNotificationsEnabled(),
                        "promotionAllowed" to (Build.VERSION.SDK_INT >= 36 && manager.canPostPromotedNotifications()),
                        "promoted" to (Build.VERSION.SDK_INT >= 36 && manager.activeNotifications.any {
                            it.id == ID && it.notification.flags and Notification.FLAG_PROMOTED_ONGOING != 0
                        })
                    ))
                    "settings" -> {
                        val action = if (Build.VERSION.SDK_INT >= 36) "android.settings.MANAGE_APP_PROMOTED_NOTIFICATIONS" else Settings.ACTION_APP_NOTIFICATION_SETTINGS
                        val settings = Intent(action).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        if (settings.resolveActivity(context.packageManager) == null) settings.action = Settings.ACTION_APP_NOTIFICATION_SETTINGS
                        context.startActivity(settings)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) { result.error("live_update_failed", error.message, null) }
        }
    }
    fun open(intent: Intent?) {
        val payload = intent?.getStringExtra(EXTRA) ?: return
        intent.removeExtra(EXTRA)
        launch = payload
        channel.invokeMethod("open", payload)
    }
    private fun show(args: Map<*, *>): Boolean {
        val key = args["key"] as String
        if (prefs.getString("current", null) != key || prefs.getString("dismissed", null) == key) return false
        if (!manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "关注中的任务", NotificationManager.IMPORTANCE_LOW).apply {
                description = "静默显示主动关注的任务状态；系统决定是否提升为实时更新"
                setSound(null, null)
            })
            if (manager.getNotificationChannel(CHANNEL).importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        val open = Intent(context, MainActivity::class.java).putExtra(EXTRA, args["payload"] as String)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val content = PendingIntent.getActivity(context, ID, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val dismiss = PendingIntent.getBroadcast(context, ID,
            Intent(context, LiveUpdateDismissReceiver::class.java).putExtra("key", key),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = NotificationCompat.Builder(context, CHANNEL)
        val title = args["title"] as String
        builder.setSmallIcon(R.drawable.ic_notification).setContentTitle(title)
            .setContentText(args["body"] as String).setContentIntent(content)
            .setStyle(NotificationCompat.BigTextStyle().bigText(args["body"] as String))
            .setOngoing(true).setOnlyAlertOnce(true).setSilent(true).setShowWhen(false)
            .setCategory(Notification.CATEGORY_STATUS).setDeleteIntent(dismiss)
            .setVisibility(if (args["preview"] == true) Notification.VISIBILITY_PRIVATE else Notification.VISIBILITY_PUBLIC)
            .addAction(0, "取消关注", dismiss)
        if (Build.VERSION.SDK_INT >= 26) builder.setTimeoutAfter(180000)
        if (Build.VERSION.SDK_INT >= 36) {
            builder.setRequestPromotedOngoing(true).setShortCriticalText(title.take(7))
        }
        manager.notify(ID, builder.build())
        return true
    }
    companion object {
        const val ID = 42
        const val CHANNEL = "live_tasks_v1"
        const val EXTRA = "codepet_live_target"
    }
}

class LiveUpdateDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val key = intent.getStringExtra("key") ?: return
        val prefs = context.getSharedPreferences("live_updates", Context.MODE_PRIVATE)
        if (prefs.getString("current", null) != key) return
        prefs.edit().putString("dismissed", key).apply()
        context.getSystemService(NotificationManager::class.java).cancel(LiveUpdatesBridge.ID)
    }
}
