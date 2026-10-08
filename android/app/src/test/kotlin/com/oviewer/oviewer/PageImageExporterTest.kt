package com.oviewer.oviewer

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Environment
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.Executor

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class PageImageExporterTest {
    private class Result : MethodChannel.Result {
        var value: Any? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { value = code }
        override fun notImplemented() { value = "notImplemented" }
    }
    private fun call(activity: Activity, name: String): MethodCall {
        val source = File(activity.cacheDir, "export.gif")
        source.writeBytes(byteArrayOf(71, 73, 70, 56, 57, 97, 1, 2, 3))
        return MethodCall("saveImage", mapOf("path" to source.path, "name" to name, "mime" to "image/gif"))
    }
    @Test fun deniedLegacyPermissionDoesNotWriteMedia() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        var scans = 0
        val exporter = PageImageExporter(activity, Executor { it.run() }) { _, _, _ -> scans++ }
        val result = Result()
        exporter.onMethodCall(call(activity, "OViewer_1_p0001_123.gif"), result)
        assertNull(result.value)
        exporter.permissionResult(PageImageExporter.PERMISSION_REQUEST, intArrayOf(PackageManager.PERMISSION_DENIED))
        assertEquals("permission_denied", result.value)
        assertEquals(0, scans)
        exporter.dispose()
    }
    @Test fun grantedLegacyPermissionCopiesOriginalBytesAndScans() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        Shadows.shadowOf(activity.application).grantPermissions(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        val name = "OViewer_1_p0001_456.gif"
        val result = Result()
        var saved: File? = null
        val exporter = PageImageExporter(activity, Executor { it.run() }) { file, mime, done ->
            saved = file
            assertEquals("image/gif", mime)
            assertArrayEquals(File(activity.cacheDir, "export.gif").readBytes(), file.readBytes())
            done(true)
        }
        exporter.onMethodCall(call(activity, name), result)
        assertEquals("saved", result.value)
        assertEquals("OViewer", saved!!.parentFile!!.name)
        assertEquals("Pictures", saved!!.parentFile!!.parentFile!!.name)
        saved!!.delete()
        exporter.dispose()
    }
    @Test fun failedMediaScanRemovesOnlyNewFile() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        Shadows.shadowOf(activity.application).grantPermissions(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        val name = "OViewer_1_p0001_789.gif"
        val result = Result()
        var saved: File? = null
        val exporter = PageImageExporter(activity, Executor { it.run() }) { file, _, done -> saved = file; done(false) }
        exporter.onMethodCall(call(activity, name), result)
        assertEquals("save_failed", result.value)
        assertFalse(saved!!.exists())
        exporter.dispose()
    }
    @Test fun notificationFailureDoesNotChangeSuccessfulSave() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        Shadows.shadowOf(activity.application).grantPermissions(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        val result = Result()
        var calls = 0
        var saved: File? = null
        val exporter = PageImageExporter(activity, Executor { it.run() },
            onSaved = { calls++; throw IllegalStateException("notifications disabled") },
            scan = { file, _, done -> saved = file; done(true) })
        val base = call(activity, "OViewer_1_p0001_987.gif")
        val args = (base.arguments as Map<String, Any>) + mapOf("notificationBody" to "saved")
        exporter.onMethodCall(MethodCall("saveImage", args), result)
        assertEquals("saved", result.value)
        assertEquals(1, calls)
        saved!!.delete(); exporter.dispose()
    }

}
