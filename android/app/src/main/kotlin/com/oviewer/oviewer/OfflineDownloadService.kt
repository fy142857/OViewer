package com.oviewer.oviewer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class OfflineDownloadService : Service() {
    companion object {
        const val CHANNEL = "offline_downloads"
        const val NOTIFICATION = 7701
        const val OPEN = "com.oviewer.oviewer.OPEN_DOWNLOADS"
        private const val PAUSE = "com.oviewer.oviewer.PAUSE_DOWNLOADS"
        var instance: OfflineDownloadService? = null
            private set
    }
    private var wakeLock: PowerManager.WakeLock? = null
    private var language = "zh"
    private var pages = 0
    private var total = 0
    private var active = 0
    private val runtime get() = application as OViewerApplication
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(CHANNEL, "Offline downloads", NotificationManager.IMPORTANCE_LOW)
            channel.lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == PAUSE) { runtime.send("pause"); return START_NOT_STICKY }
        language = intent?.getStringExtra("language") ?: "zh"
        try {
            val notification = notification()
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(NOTIFICATION, notification)
            holdWakeLock()
        } catch (_: Exception) {
            runtime.send("serviceUnavailable")
            stopSelf()
        }
        return START_NOT_STICKY
    }
    fun progress(pages: Int, total: Int, active: Int, language: String) {
        this.pages = pages; this.total = total; this.active = active; this.language = language
        holdWakeLock()
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION, notification())
    }
    private fun holdWakeLock() {
        if (wakeLock?.isHeld == true) return
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OViewer:offline-download")
            .apply { setReferenceCounted(false); acquire(15 * 60 * 1000L) }
    }
    private fun notification(): Notification {
        val chinese = language != "en"
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).setAction(OPEN)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val pause = PendingIntent.getService(this, 1,
            Intent(this, OfflineDownloadService::class.java).setAction(PAUSE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val text = if (chinese) "$active 本 · $pages/$total 页" else "$active galleries · $pages/$total pages"
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(if (chinese) "漫画离线缓存" else "Offline downloads")
            .setContentText(text).setContentIntent(open)
            .setProgress(total.coerceAtLeast(0), pages.coerceAtLeast(0), total <= 0)
            .setOngoing(true).setOnlyAlertOnce(true).setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(android.R.drawable.ic_media_pause, if (chinese) "暂停" else "Pause", pause)
            .build()
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        runtime.send("timeout")
        stopSelf()
    }
    override fun onDestroy() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        stopForeground(true)
        instance = null
        runtime.serviceStopped()
        super.onDestroy()
    }
}
