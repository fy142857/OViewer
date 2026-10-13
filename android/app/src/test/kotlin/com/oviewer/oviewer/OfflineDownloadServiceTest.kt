package com.oviewer.oviewer

import android.app.Notification
import android.app.Service
import android.content.Intent
import android.os.PowerManager
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [21, 26, 29, 33, 35], application = OViewerApplication::class)
class OfflineDownloadServiceTest {
    @Test fun foregroundNotificationIsPrivateAndServiceNeverRestartsItself() {
        val controller = Robolectric.buildService(OfflineDownloadService::class.java).create()
        val service = controller.get()
        val result = service.onStartCommand(Intent().putExtra("language", "en"), 0, 1)
        assertEquals(Service.START_NOT_STICKY, result)
        val shadow = Shadows.shadowOf(service)
        val notification = shadow.lastForegroundNotification
        assertNotNull(notification)
        assertEquals(Notification.VISIBILITY_PRIVATE, notification.visibility)
        assertEquals(OfflineDownloadService.NOTIFICATION, shadow.lastForegroundNotificationId)
        assertEquals("Offline downloads", notification.extras.getString(Notification.EXTRA_TITLE))
        assertNotNull(notification.contentIntent)
        assertEquals("Pause", notification.actions.single().title)
        val lock: PowerManager.WakeLock = ReflectionHelpers.getField(service, "wakeLock")
        assertTrue(lock.isHeld)
        service.progress(3, 12, 2, "en")
        controller.destroy()
        assertFalse(lock.isHeld)
        assertNull(OfflineDownloadService.instance)
    }

    @Test @Config(sdk = [35]) fun timeoutStopsTheServiceWithoutAutomaticRestart() {
        val controller = Robolectric.buildService(OfflineDownloadService::class.java).create()
        val service = controller.get()
        service.onStartCommand(Intent(), 0, 1)
        service.onTimeout(1, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        assertTrue(Shadows.shadowOf(service).isStoppedBySelf)
        controller.destroy()
    }
}
