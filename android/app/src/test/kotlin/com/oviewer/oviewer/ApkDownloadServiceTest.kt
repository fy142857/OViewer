package com.oviewer.oviewer

import android.app.Notification
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers
import java.nio.ByteBuffer
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 33, 35], application = OViewerApplication::class)
class ApkDownloadServiceTest {
    private class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
        val events = mutableListOf<MethodCall>()
        override fun send(channel: String, message: ByteBuffer?) { send(channel, message, null) }
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            if (message != null) events.add(StandardMethodCodec.INSTANCE.decodeMethodCall(message.duplicate().apply { flip() }))
            callback?.reply(null)
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
        fun call(method: String, args: Map<String, Any> = emptyMap()): Any? {
            var result: Any? = "pending"
            val bytes = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, args)).apply { flip() }
            handlers.getValue("oviewer/update_download").onMessage(bytes) { reply ->
                result = StandardMethodCodec.INSTANCE.decodeEnvelope(reply!!.apply { flip() })
            }
            return result
        }
    }
    private fun configured(): Triple<OViewerApplication, ApkUpdateRuntime, Messenger> {
        val app = RuntimeEnvironment.getApplication() as OViewerApplication
        val messenger = Messenger()
        val runtime = ApkUpdateRuntime(app, messenger)
        ReflectionHelpers.setField(app, "updates", runtime)
        ReflectionHelpers.setField(runtime, "session", 42L)
        ReflectionHelpers.setField(runtime, "id", "109:abc")
        ReflectionHelpers.setField(runtime, "version", "1.10.2")
        ReflectionHelpers.setField(runtime, "total", 100L)
        ReflectionHelpers.setField(runtime, "language", "en")
        ReflectionHelpers.setField(runtime, "ready", true)
        app.retainWork("apk:42")
        app.getSharedPreferences("apk_update_notice", Context.MODE_PRIVATE).edit()
            .putLong("session", 42).putString("id", "109:abc").commit()
        return Triple(app, runtime, messenger)
    }
    @Test fun completionReleasesOnlyUpdateOwnerAndLeavesAnInstallNotification() {
        val (app, runtime, messenger) = configured()
        app.retainWork("offline")
        val controller = Robolectric.buildService(ApkDownloadService::class.java).create()
        val service = controller.get()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(Intent().putExtra("session", 42L), 0, 1))
        val notification = Shadows.shadowOf(service).lastForegroundNotification
        assertEquals(Notification.VISIBILITY_PRIVATE, notification.visibility)
        assertEquals("Cancel", notification.actions.single().title)
        val lock: PowerManager.WakeLock = ReflectionHelpers.getField(service, "wakeLock")
        assertTrue(lock.isHeld)
        org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofMinutes(11))
        messenger.call("progress", mapOf("session" to 42L, "received" to 50L, "verifying" to false))
        assertTrue(lock.isHeld)
        service.finish("ready")
        controller.destroy()
        assertFalse(lock.isHeld)
        assertTrue(app.serviceRunning)
        assertNull(runtime.session)
        val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val done = Shadows.shadowOf(manager).getNotification(ApkDownloadService.NOTIFICATION)
        assertEquals("Download complete. Tap to install", done.extras.getString(Notification.EXTRA_TEXT))
        assertEquals(0, done.flags and Notification.FLAG_ONGOING_EVENT)
        val intent = Shadows.shadowOf(done.contentIntent).savedIntent
        assertTrue(intent.getBooleanExtra("install", false))
        runtime.open(intent)
        assertEquals("open", messenger.events.last().method)
        val count = messenger.events.size
        runtime.open(Intent().putExtra("session", 41L).putExtra("id", "109:abc"))
        assertEquals(count, messenger.events.size)
    }
    @Test fun staleFinishAndCancelCannotStopTheCurrentTransfer() {
        val (_, runtime, messenger) = configured()
        messenger.call("finish", mapOf("session" to 41L, "outcome" to "cancelled"))
        runtime.cancel(41)
        assertEquals(42L, runtime.session)
        assertTrue(messenger.events.isEmpty())
        runtime.cancel(42)
        assertEquals("cancel", messenger.events.single().method)
        runtime.stopped(42)
    }
    @Test fun startingWithoutForegroundHostIsRejected() {
        val (app, runtime, messenger) = configured()
        runtime.stopped(42)
        assertEquals(false, messenger.call("start", mapOf("session" to 43L)))
        assertNull(runtime.session)
        assertFalse(app.serviceRunning)
    }
    @Test @Config(sdk = [35]) fun systemTimeoutPostsInterruptionAndReleasesWakeLock() {
        val (_, runtime, messenger) = configured()
        val controller = Robolectric.buildService(ApkDownloadService::class.java).create()
        val service = controller.get()
        service.onStartCommand(Intent().putExtra("session", 42L), 0, 1)
        val lock: PowerManager.WakeLock = ReflectionHelpers.getField(service, "wakeLock")
        service.onTimeout(1, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        assertTrue(Shadows.shadowOf(service).isStoppedBySelf)
        assertEquals("interrupted", messenger.events.last().method)
        controller.destroy()
        assertNull(runtime.session)
        assertFalse(lock.isHeld)
    }
    @Test fun coldProcessCancelTouchesOnlyMatchingOwnedFiles() {
        val app = RuntimeEnvironment.getApplication() as OViewerApplication
        val folder = File(app.cacheDir, "updates").apply { mkdirs() }
        val part = File(folder, "package.part").apply { writeText("bytes") }
        val other = File(folder, "unrelated").apply { writeText("keep") }
        app.getSharedPreferences("apk_update_notice", Context.MODE_PRIVATE).edit().putLong("session", 42L).commit()
        val receiver = ApkUpdateCancelReceiver()
        receiver.onReceive(app, Intent(ApkDownloadService.CANCEL).putExtra("session", 41L))
        assertTrue(part.isFile)
        receiver.onReceive(app, Intent(ApkDownloadService.CANCEL).putExtra("session", 42L))
        assertFalse(part.exists())
        assertTrue(other.isFile)
    }
}
