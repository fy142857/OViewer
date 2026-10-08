package com.oviewer.oviewer

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class SponsorNotificationsTest {
    private class Result : MethodChannel.Result {
        var value: Any? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { value = code }
        override fun notImplemented() { value = "notImplemented" }
    }
    @Test fun postsSeparateSystemNotificationsWithoutAnActiveFlutterPage() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val notifier = SponsorNotifications(activity)
        val result = Result(); notifier.prepare(result)
        assertEquals(true, result.value)
        notifier.onPause()
        notifier.show("WeChat code saved to Photos")
        notifier.show("Alipay code saved to Photos")
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val messages = Shadows.shadowOf(manager).allNotifications
        assertEquals(2, messages.size)
        assertEquals(setOf("WeChat code saved to Photos", "Alipay code saved to Photos"), messages.map { it.extras.getString(Notification.EXTRA_TEXT) }.toSet())
        assertTrue(messages.all { it.extras.getString(Notification.EXTRA_TITLE) == "OViewer" && it.contentIntent != null })
        assertEquals(NotificationManager.IMPORTANCE_DEFAULT, manager.getNotificationChannel(SponsorNotifications.CHANNEL).importance)
    }
    @Test fun disabledChannelDoesNotPostOrThrow() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(SponsorNotifications.CHANNEL, "Saved", NotificationManager.IMPORTANCE_NONE))
        val notifier = SponsorNotifications(activity)
        val result = Result(); notifier.prepare(result)
        assertEquals(false, result.value)
        notifier.show("saved")
        assertTrue(Shadows.shadowOf(manager).allNotifications.isEmpty())
    }
    @Test @Config(sdk = [33])
    fun permissionGrantFlushesBothCompletedSavesAndBothWaiters() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        Shadows.shadowOf(activity.application).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val notifier = SponsorNotifications(activity)
        notifier.onResume()
        val first = Result(); val second = Result()
        notifier.prepare(first); notifier.prepare(second)
        notifier.show("wechat saved"); notifier.show("alipay saved")
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        assertNull(first.value); assertNull(second.value)
        assertTrue(Shadows.shadowOf(manager).allNotifications.isEmpty())
        Shadows.shadowOf(activity.application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        notifier.permissionResult(SponsorNotifications.PERMISSION_REQUEST, intArrayOf(PackageManager.PERMISSION_GRANTED))
        assertEquals(true, first.value); assertEquals(true, second.value)
        assertEquals(2, Shadows.shadowOf(manager).allNotifications.size)
    }
    @Test @Config(sdk = [33])
    fun denialDoesNotRepeatPromptAndDiscardsQueuedMessages() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        Shadows.shadowOf(activity.application).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val notifier = SponsorNotifications(activity)
        val first = Result(); notifier.prepare(first)
        notifier.show("saved while background")
        assertNull(first.value)
        notifier.onResume()
        notifier.permissionResult(SponsorNotifications.PERMISSION_REQUEST, intArrayOf(PackageManager.PERMISSION_DENIED))
        assertEquals(false, first.value)
        val second = Result(); notifier.prepare(second)
        assertEquals(false, second.value)
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        assertTrue(Shadows.shadowOf(manager).allNotifications.isEmpty())
        notifier.dispose()
    }
}
