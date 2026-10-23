package com.oviewer.oviewer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat

class ApkDownloadService : Service() {
    companion object {
        const val CHANNEL = "apk_downloads"
        const val NOTIFICATION = 7702
        const val OPEN = "com.oviewer.oviewer.OPEN_UPDATE"
        const val CANCEL = "com.oviewer.oviewer.CANCEL_UPDATE"
        var instance: ApkDownloadService? = null
            private set
    }
    private val runtime get() = (application as OViewerApplication).updates
    private var wakeLock: PowerManager.WakeLock? = null
    private var acquiredAt = 0L
    private var session = 0L
    private var finished = false
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() { super.onCreate(); instance = this }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val requested = intent?.getLongExtra("session", 0) ?: 0
        if (requested == 0L || runtime?.session != requested) {
            stopSelf(startId); return START_NOT_STICKY
        }
        session = requested
        try {
            val notification = runtime!!.notification("downloading")
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(NOTIFICATION, notification)
            holdWakeLock()
            runtime?.started(session, true)
        } catch (_: Exception) {
            runtime?.started(session, false); stopSelf()
        }
        return START_NOT_STICKY
    }
    private fun holdWakeLock() {
        val now = SystemClock.elapsedRealtime()
        if (wakeLock?.isHeld == true && now - acquiredAt < 10 * 60 * 1000L) return
        val lock = wakeLock ?: (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OViewer:apk-update")
            .apply { setReferenceCounted(false) }
        if (lock.isHeld) lock.release()
        lock.acquire(15 * 60 * 1000L)
        wakeLock = lock
        acquiredAt = now
    }
    fun progress() {
        holdWakeLock()
        runtime?.let {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION, it.notification(if (it.verifying) "verifying" else "downloading"))
        }
    }
    fun finish(outcome: String) {
        finished = true
        val notification = if (outcome == "cancelled") null else runtime?.notification(outcome)
        stopForeground(true)
        if (notification != null) {
            try { (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION, notification) }
            catch (_: SecurityException) { /* Notification denial does not fail the transfer. */ }
        }
        stopSelf()
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        runtime?.interrupt(session, "service_timeout")
        finish("interrupted")
    }
    override fun onDestroy() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        if (instance === this) instance = null
        if (!finished) runtime?.interrupt(session, "background_unavailable")
        runtime?.stopped(session)
        super.onDestroy()
    }
}

class ApkUpdateCancelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ApkDownloadService.CANCEL) return
        val app = context.applicationContext as OViewerApplication
        val session = intent.getLongExtra("session", 0)
        if (app.updates != null) {
            app.updates?.cancel(session)
        } else {
            // A process killed by Android has no writer. Only delete the task
            // still represented by this notification, never another attempt.
            val prefs = app.getSharedPreferences("apk_update_notice", Context.MODE_PRIVATE)
            if (session == 0L || prefs.getLong("session", 0) != session) return
            val folder = java.io.File(app.cacheDir, "updates")
            for (name in listOf("package.part", "resume.json", "resume.tmp", "package.apk", "metadata.json", "metadata.part")) {
                java.io.File(folder, name).delete()
            }
            prefs.edit().clear().apply()
            (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(ApkDownloadService.NOTIFICATION)
        }
    }
}
