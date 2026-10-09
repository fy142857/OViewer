package com.oviewer.oviewer

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.widget.Toast
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowToast

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 33])
class SponsorSavedToastTest {
    @Test fun showsShortTextToastWithoutPostingANotification() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val toast = SponsorSavedToast(activity)
        toast.show("WeChat code saved to Photos")
        assertEquals("WeChat code saved to Photos", ShadowToast.getTextOfLatestToast())
        assertEquals(Toast.LENGTH_SHORT, ShadowToast.getLatestToast().duration)
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        assertTrue(Shadows.shadowOf(manager).allNotifications.isEmpty())
    }
    @Test fun clearsOnlyTheOldSponsorChannelAndSupportsBothSaveMessages() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel("sponsor_image_saves", "Old", NotificationManager.IMPORTANCE_DEFAULT))
        manager.createNotificationChannel(NotificationChannel("unrelated", "Other", NotificationManager.IMPORTANCE_DEFAULT))
        val toast = SponsorSavedToast(activity)
        toast.show("WeChat saved")
        toast.show("Alipay saved")
        assertEquals("Alipay saved", ShadowToast.getTextOfLatestToast())
        assertNull(manager.getNotificationChannel("sponsor_image_saves"))
        assertNotNull(manager.getNotificationChannel("unrelated"))
        assertTrue(Shadows.shadowOf(manager).allNotifications.isEmpty())
    }
}
