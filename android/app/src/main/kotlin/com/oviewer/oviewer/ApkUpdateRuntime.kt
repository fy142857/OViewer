package com.oviewer.oviewer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Owns background transfers and queues notification opens until Dart is ready. */
class ApkUpdateRuntime(private val app: OViewerApplication, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "oviewer/update_download")
    private val handler = Handler(Looper.getMainLooper())
    private val prefs = app.getSharedPreferences("apk_update_notice", Context.MODE_PRIVATE)
    var session: Long? = null
        private set
    private var startReply: MethodChannel.Result? = null
    private var finishReply: MethodChannel.Result? = null
    private var pendingOpen: Map<String, Any>? = null
    private var ready = false
    private var id = ""
    private var version = ""
    private var language = "zh"
    private var received = 0L
    private var total = 0L
    var verifying = false
        private set
    init {
        if (Build.VERSION.SDK_INT >= 26) {
            manager().createNotificationChannel(NotificationChannel(ApkDownloadService.CHANNEL,
                "App updates", NotificationManager.IMPORTANCE_LOW).apply {
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            })
        }
        channel.setMethodCallHandler { call, result ->
            val requested = call.argument<Number>("session")?.toLong()
            when (call.method) {
                "ready" -> { ready = true; val open = pendingOpen; pendingOpen = null; result.success(open) }
                "clear" -> { if (session == null) clear(); result.success(null) }
                "maintain" -> {
                    if (session == null) {
                        val installed = call.argument<Number>("installedBuild")?.toLong() ?: 0
                        val savedBuild = prefs.getString("id", "")?.substringBefore(':')?.toLongOrNull() ?: 0
                        val folder = java.io.File(app.cacheDir, "updates")
                        if (savedBuild <= installed || (!java.io.File(folder, "metadata.json").isFile &&
                            !java.io.File(folder, "resume.json").isFile)) clear()
                    }
                    result.success(null)
                }
                "start" -> {
                    val activity = app.foregroundActivity()
                    if (session != null || requested == null || activity == null) {
                        result.success(false); return@setMethodCallHandler
                    }
                    session = requested
                    id = call.argument<String>("id") ?: ""
                    version = call.argument<String>("version") ?: ""
                    language = call.argument<String>("language") ?: "zh"
                    total = call.argument<Number>("total")?.toLong() ?: 0
                    received = 0; verifying = false
                    startReply = result
                    app.retainWork("apk:$requested")
                    prefs.edit().putLong("session", requested).putString("id", id).apply()
                    try {
                        ContextCompat.startForegroundService(app,
                            Intent(app, ApkDownloadService::class.java).putExtra("session", requested))
                        app.requestNotifications(activity)
                        handler.postDelayed({
                            if (session == requested && startReply != null) {
                                started(requested, false)
                                app.stopService(Intent(app, ApkDownloadService::class.java))
                            }
                        }, 6000)
                    } catch (_: Exception) { started(requested, false) }
                }
                "progress" -> {
                    if (session == requested) {
                        received = (call.argument<Number>("received")?.toLong() ?: 0).coerceIn(0, total.coerceAtLeast(0))
                        verifying = call.argument<Boolean>("verifying") == true
                        try { ApkDownloadService.instance?.progress() }
                        catch (_: Exception) { interrupt(requested ?: 0, "background_unavailable") }
                    }
                    result.success(null)
                }
                "finish" -> {
                    if (session != requested) { result.success(null); return@setMethodCallHandler }
                    val outcome = call.argument<String>("outcome") ?: "interrupted"
                    finishReply?.success(null)
                    finishReply = result
                    val service = ApkDownloadService.instance
                    if (service != null) service.finish(outcome)
                    else stopped(requested ?: 0)
                    if (outcome == "cancelled") clear()
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun manager() = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    fun started(value: Long, success: Boolean) {
        if (session != value) return
        startReply?.success(success); startReply = null
        if (!success) { session = null; clear(); app.releaseWork("apk:$value") }
    }
    fun stopped(value: Long) {
        app.releaseWork("apk:$value")
        if (session != value) return
        startReply?.success(false); startReply = null
        finishReply?.success(null); finishReply = null
        session = null
    }
    fun cancel(value: Long) {
        if (session == value && ready) channel.invokeMethod("cancel", mapOf("session" to value))
    }
    fun interrupt(value: Long, reason: String) {
        if (session == value && ready) channel.invokeMethod("interrupted", mapOf("session" to value, "reason" to reason))
    }
    fun open(intent: Intent) {
        if (intent.getLongExtra("session", 0) != prefs.getLong("session", -1)) return
        val request = mapOf("id" to (intent.getStringExtra("id") ?: ""),
            "install" to intent.getBooleanExtra("install", false))
        if (ready) channel.invokeMethod("open", request) else pendingOpen = request
    }
    private fun clear() { manager().cancel(ApkDownloadService.NOTIFICATION); prefs.edit().clear().apply() }
    fun notification(outcome: String): Notification {
        val zh = language != "en"
        val working = outcome == "downloading" || outcome == "verifying"
        val install = outcome == "ready"
        val open = PendingIntent.getActivity(app, 7702,
            Intent(app, MainActivity::class.java).setAction(ApkDownloadService.OPEN)
                .putExtra("id", id).putExtra("install", install).putExtra("session", session ?: prefs.getLong("session", 0))
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val text = when (outcome) {
            "ready" -> if (zh) "下载完成，点击安装" else "Download complete. Tap to install"
            "verifying" -> if (zh) "正在校验安装包" else "Verifying update"
            "interrupted" -> if (zh) "下载已中断，点击继续" else "Download interrupted. Tap to continue"
            "error" -> if (zh) "更新失败，点击查看" else "Update failed. Tap for details"
            else -> String.format(java.util.Locale.ROOT, "%d%% · %.1f / %.1f MB",
                if (total > 0) (received * 100 / total).toInt() else 0,
                received / 1048576.0, total / 1048576.0)
        }
        val builder = NotificationCompat.Builder(app, ApkDownloadService.CHANNEL)
            .setSmallIcon(if (working) android.R.drawable.stat_sys_download else android.R.drawable.stat_sys_download_done)
            .setContentTitle(if (zh) "OViewer 更新 $version" else "OViewer update $version")
            .setContentText(text).setContentIntent(open)
            .setOngoing(working).setAutoCancel(!working).setOnlyAlertOnce(true).setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        if (working) {
            builder.setProgress(100, if (total > 0) (received * 100 / total).toInt() else 0, outcome == "verifying" || total == 0L)
            val cancel = PendingIntent.getBroadcast(app, 7703,
                Intent(app, ApkUpdateCancelReceiver::class.java).setAction(ApkDownloadService.CANCEL)
                    .putExtra("session", session ?: 0),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, if (zh) "取消" else "Cancel", cancel)
        }
        return builder.build()
    }
    fun dispose() { ready = false; channel.setMethodCallHandler(null) }
}
