package com.oviewer.oviewer

import android.app.Application
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** One Dart runtime and queue, retained while a download service owns work. */
class OViewerApplication : Application() {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var host = WeakReference<MainActivity>(null)
    private val handler = Handler(Looper.getMainLooper())
    var serviceRunning = false
        private set
    private var pendingOpen = false
    private var dartReady = false

    fun acquireEngine(): FlutterEngine {
        engine?.let { return it }
        val created = FlutterEngine(this)
        engine = created
        channel = MethodChannel(created.dartExecutor.binaryMessenger, "oviewer/offline").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> { dartReady = true; result.success(null) }
                    "consumeOpenRequest" -> { val value = pendingOpen; pendingOpen = false; result.success(value) }
                    "start" -> {
                        val activity = host.get()
                        if (activity == null || activity.isFinishing) { result.success(false); return@setMethodCallHandler }
                        try {
                            val intent = Intent(this, OfflineDownloadService::class.java)
                                .putExtra("language", call.argument<String>("language") ?: "zh")
                            serviceRunning = true // Retain engine during asynchronous service startup.
                            ContextCompat.startForegroundService(this, intent)
                            requestNotifications(activity)
                            result.success(true)
                        } catch (_: Exception) {
                            serviceRunning = false
                            result.success(false)
                        }
                    }
                    "progress" -> {
                        OfflineDownloadService.instance?.progress(
                            call.argument<Number>("pages")?.toInt() ?: 0,
                            call.argument<Number>("total")?.toInt() ?: 0,
                            call.argument<Number>("active")?.toInt() ?: 0,
                            call.argument<String>("language") ?: "zh")
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, OfflineDownloadService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }

    fun attach(activity: MainActivity) { host = WeakReference(activity) }
    fun detach(activity: MainActivity) {
        if (host.get() === activity) host.clear()
        releaseIfIdle()
    }
    fun serviceStopped() { serviceRunning = false; releaseIfIdle() }
    fun send(method: String) { if (dartReady) channel?.invokeMethod(method, null) }
    fun openDownloads() {
        pendingOpen = true
        if (dartReady) { pendingOpen = false; channel?.invokeMethod("openDownloads", null) }
    }
    private fun releaseIfIdle() {
        // Allow Activity recreation and the final Dart platform reply to settle.
        handler.postDelayed({
            if (!serviceRunning && host.get() == null) {
                channel?.setMethodCallHandler(null)
                channel = null
                engine?.destroy()
                engine = null
                dartReady = false
            }
        }, 1000)
    }
    private fun requestNotifications(activity: MainActivity) {
        if (Build.VERSION.SDK_INT < 33 ||
            activity.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val preferences = getSharedPreferences("offline_service", MODE_PRIVATE)
        if (preferences.getBoolean("notification_requested", false)) return
        preferences.edit().putBoolean("notification_requested", true).apply()
        activity.requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 7701)
    }
}
