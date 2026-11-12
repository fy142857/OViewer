package com.oviewer.oviewer

import android.app.Service
import android.app.job.JobParameters
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock

/** The API 21-33 foreground-service path is independent of Flutter's engine. */
class UploadTransferService : Service() {
    companion object { var instance: UploadTransferService? = null; private set }
    private val runtime get() = UploadTransferRuntime.get(applicationContext)
    private var wakeLock: PowerManager.WakeLock? = null
    private var finished = false
    private var started = false
    private var acquiredAt = 0L
    override fun onCreate() { super.onCreate(); instance = this }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (started) return START_NOT_STICKY
        started = true
        try {
            val notification = runtime.notification()
            if (Build.VERSION.SDK_INT >= 29) startForeground(UploadTransferRuntime.NOTIFICATION,
                notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(UploadTransferRuntime.NOTIFICATION, notification)
            keepAwake()
            runtime.runAcceptedJob { finished = true; removeForeground(); stopSelf() }
        } catch (_: Exception) { runtime.stoppedBySystem(); stopSelf() }
        return START_NOT_STICKY
    }
    @Suppress("DEPRECATION")
    private fun removeForeground() {
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else stopForeground(true)
    }
    override fun onDestroy() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        if (instance === this) instance = null
        if (!finished) runtime.stoppedBySystem()
        super.onDestroy()
    }
    fun keepAwake() {
        val now = SystemClock.elapsedRealtime()
        if (wakeLock?.isHeld == true && now - acquiredAt < 8 * 60 * 1000L) return
        val value = wakeLock ?: (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OViewer:gallery-upload").apply { setReferenceCounted(false) }
        if (value.isHeld) value.release()
        value.acquire(10 * 60 * 1000L); wakeLock = value; acquiredAt = now
    }
    override fun onTimeout(startId: Int, fgsType: Int) { runtime.stoppedBySystem(); stopSelf() }
}

/** UIDT grants execution on API 34+, including when the Flutter UI is gone. */
class UploadTransferJobService : JobService() {
    private val runtime get() = UploadTransferRuntime.get(applicationContext)
    private var current: JobParameters? = null
    override fun onStartJob(params: JobParameters): Boolean {
        if (Build.VERSION.SDK_INT < 34) return false
        current = params
        return try {
            setNotification(params, UploadTransferRuntime.NOTIFICATION, runtime.notification(),
                JOB_END_NOTIFICATION_POLICY_REMOVE)
            runtime.runAcceptedJob {
                if (current === params) { current = null; jobFinished(params, false) }
            }
            true
        } catch (_: Exception) { current = null; runtime.stoppedBySystem(); false }
    }
    override fun onStopJob(params: JobParameters): Boolean {
        if (current === params) { current = null; runtime.stoppedBySystem() }
        // An interrupted POST is not safe to resend. The receipt must first
        // be reconciled, so the OS must not silently retry this write.
        return false
    }
    override fun onNetworkChanged(params: JobParameters) {
        if (Build.VERSION.SDK_INT >= 34 && current?.jobId == params.jobId) {
            runtime.onJobNetworkChanged()
        }
    }
}

class UploadTransferPauseReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == UploadTransferRuntime.PAUSE) {
            UploadTransferRuntime.get(context).pauseFromNotification()
        }
    }
}
