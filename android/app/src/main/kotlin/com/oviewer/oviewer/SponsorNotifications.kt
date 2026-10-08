package com.oviewer.oviewer

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class SponsorNotifications(private val activity: Activity) {
    companion object {
        const val PERMISSION_REQUEST = 7316
        const val CHANNEL = "sponsor_image_saves"
    }
    private val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val waiters = mutableListOf<MethodChannel.Result>()
    private val pendingMessages = mutableListOf<String>()
    private val prefs = activity.getSharedPreferences("sponsor_notifications", Context.MODE_PRIVATE)
    private var requesting = false
    private var resumed = false

    fun prepare(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 || activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success(enabled()); return
        }
        if (requesting) { waiters.add(result); return }
        if (prefs.getBoolean("asked", false)) { result.success(false); return }
        waiters.add(result)
        requestIfVisible()
    }

    fun onResume() { resumed = true; requestIfVisible() }
    fun onPause() { resumed = false }

    private fun requestIfVisible() {
        if (!resumed || requesting || waiters.isEmpty() || Build.VERSION.SDK_INT < 33) return
        requesting = true
        prefs.edit().putBoolean("asked", true).apply()
        try { activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST) }
        catch (_: Exception) { finishPermission(false) }
    }

    fun permissionResult(code: Int, results: IntArray): Boolean {
        if (code != PERMISSION_REQUEST) return false
        finishPermission(results.isNotEmpty() && results[0] == PackageManager.PERMISSION_GRANTED)
        return true
    }

    private fun finishPermission(granted: Boolean) {
        requesting = false
        val callbacks = waiters.toList(); waiters.clear()
        val messages = pendingMessages.toList(); pendingMessages.clear()
        val allowed = granted && enabled()
        callbacks.forEach { it.success(allowed) }
        if (allowed) messages.forEach { post(it) }
    }

    private fun enabled(): Boolean {
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        return true
    }

    fun show(message: String) {
        if (message.isBlank()) return
        if (requesting || waiters.isNotEmpty()) { pendingMessages.add(message); return }
        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        if (enabled()) post(message)
    }

    private fun post(message: String) {
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(CHANNEL,
                    activity.getString(R.string.sponsor_saved_channel), NotificationManager.IMPORTANCE_DEFAULT).apply {
                    setSound(null, null)
                })
            }
            val intent = Intent(activity, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
            val open = PendingIntent.getActivity(activity, 7316, intent, flags)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(activity, CHANNEL) else Notification.Builder(activity)
            val notification = builder.setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("OViewer").setContentText(message)
                .setStyle(Notification.BigTextStyle().bigText(message))
                .setContentIntent(open).setAutoCancel(true)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setGroup(CHANNEL).build()
            manager.notify("sponsor-save-" + UUID.randomUUID().toString(), 0, notification)
        } catch (_: Exception) { /* Notification failure must not change the save result. */ }
    }

    fun dispose() { finishPermission(false) }
}
