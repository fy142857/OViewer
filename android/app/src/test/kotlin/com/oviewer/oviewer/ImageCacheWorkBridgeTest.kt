package com.oviewer.oviewer

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers
import android.os.Looper
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], application = OViewerApplication::class)
class ImageCacheWorkBridgeTest {
    private val result = object : MethodChannel.Result {
        override fun success(value: Any?) {}
        override fun error(code: String, message: String?, details: Any?) { fail(message) }
        override fun notImplemented() { fail("unexpected method") }
    }

    @Test fun cacheWorkSurvivesHostAbsenceAndReleasesOnlyItsOwnOwner() {
        val app = RuntimeEnvironment.getApplication() as OViewerApplication
        val bridge = ImageCacheWorkBridge(app)
        app.retainWork("offline")
        app.retainWork("apk:42")
        bridge.onMethodCall(MethodCall("retain", null), result)
        // Simulate the existing delayed idle check after the Activity leaves.
        ReflectionHelpers.callInstanceMethod<Void>(app, "releaseIfIdle")
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(2))
        val owners: Set<String> = ReflectionHelpers.getField(app, "workOwners")
        assertEquals(setOf("offline", "apk:42", "image-cache"), owners)
        bridge.onMethodCall(MethodCall("release", null), result)
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(2))
        assertEquals(setOf("offline", "apk:42"), owners)
        assertTrue(app.serviceRunning)
    }

    @Test fun absentHostCannotDisposeRuntimeUntilCacheWorkFinishes() {
        val app = RuntimeEnvironment.getApplication() as OViewerApplication
        val bridge = ImageCacheWorkBridge(app)
        ReflectionHelpers.setField(app, "dartReady", true)
        bridge.onMethodCall(MethodCall("retain", null), result)
        ReflectionHelpers.callInstanceMethod<Void>(app, "releaseIfIdle")
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(2))
        assertTrue(ReflectionHelpers.getField<Boolean>(app, "dartReady"))
        bridge.onMethodCall(MethodCall("release", null), result)
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(2))
        assertFalse(ReflectionHelpers.getField<Boolean>(app, "dartReady"))
    }
}
